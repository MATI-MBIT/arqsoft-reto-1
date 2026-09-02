#!/usr/bin/env bash
# ==============================================================================
# Ciclo E2E del experimento E01 — un solo comando, todo el ciclo:
#   levantar topología → F1 (ASR-02) → F2+F3 (ASR-03) → F4 → F4-explore → bajar
# Guarda la salida cruda (.txt) y el resumen JSON de cada fase en
# load/k6/results/<timestamp>-<modo>/ y termina con código != 0 si alguna fase
# oficial incumplió sus thresholds (p95<200ms, 0 rechazos) — apto para CI.
#
# Uso:  ./load/run-e2e.sh full    # corridas oficiales (~1h40m)
#       ./load/run-e2e.sh smoke   # versión corta (~25 min) — regresión diaria
# ==============================================================================
set -uo pipefail

MODE="${1:-smoke}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/load/k6/results/$STAMP-$MODE"
mkdir -p "$OUT"

SMOKE_FLAG=""
[ "$MODE" = "smoke" ] && SMOKE_FLAG="-e SMOKE=1"

FAILED=()

# Percentiles internos del shard de la fase (total | espera | servicio). Es la
# contraparte de la medición de k6: su contraste separa el costo del patrón del
# costo de transporte. Hay que capturarlos ANTES de bajar la topología — al
# destruir los contenedores se pierden sus logs.
capture_shard_logs() {
  local name="$1" since="$2"
  $COMPOSE logs --no-color --since "$since" 2>/dev/null \
    | grep -E "shard=[0-9]+ n=" > "$OUT/$name-shard.log" || true
}

run_phase() {
  local name="$1"; shift
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: $name"
  echo "════════════════════════════════════════════════════"
  ( cd "$ROOT/load/k6" && k6 run $SMOKE_FLAG "$@" --summary-export="$OUT/$name.json" poc.js ) 2>&1 | tee "$OUT/$name.txt"
  local rc=${PIPESTATUS[0]}
  capture_shard_logs "$name" "$since"
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
  fi
}

echo "== E2E experimento E01 · modo=$MODE · resultados en $OUT =="

# 1. Topología limpia (N=2)
$COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true
$COMPOSE up --build -d
echo "Esperando arranque de la topología (JVMs)..."
sleep 20

# 2. Fases oficiales (con thresholds: fallan la corrida si p95>200ms o hay rechazos)
run_phase f1 -e PHASE=f1
run_phase f2 -e PHASE=f2

# 3. Partición caliente (exploratoria, sin criterio binario)
run_phase f4 -e PHASE=f4

# 4. Exploración del techo de un shard (siempre corta)
for peak in 250 500 1000; do
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: f4-explore @ ${peak}/s"
  echo "════════════════════════════════════════════════════"
  ( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE=f4 -e PEAK="$peak" \
      --summary-export="$OUT/f4-explore-$peak.json" poc.js ) 2>&1 | tee "$OUT/f4-explore-$peak.txt"
  capture_shard_logs "f4-explore-$peak" "$since"
done

# 5. Bajar topología
$COMPOSE down --remove-orphans >/dev/null 2>&1 || true

# 6. Resumen
echo ""
echo "══════════════════ RESUMEN E2E ══════════════════"
for f in "$OUT"/*.txt; do
  n="$(basename "$f" .txt)"
  p95="$(grep 'grpc_req_duration' "$f" | grep -o 'p(95)=[^ ]*' | head -1)"
  rej="$(grep -o 'orders_rejected_backpressure[^0-9]*[0-9]*' "$f" | head -1 | grep -o '[0-9]*$')"
  drop="$(grep -o 'dropped_iterations[^0-9]*[0-9]*' "$f" | head -1 | grep -o '[0-9]*$')"
  printf "  %-18s %-16s rechazos=%s descartes=%s\n" "$n" "${p95:-sin dato}" "${rej:-0}" "${drop:-0}"
done
echo "  Salidas crudas (.txt) y resúmenes (.json) en: $OUT"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  ✗ FASES OFICIALES CON THRESHOLD INCUMPLIDO: ${FAILED[*]}"
  exit 1
fi
echo "  ✓ Todas las fases oficiales cumplieron sus thresholds (p95<200ms, 0 rechazos)."
