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

# Lee una metrica del RESUMEN de k6. Anclado a "^  <nombre>....:" a proposito:
# k6 lista los nombres de metricas sin valor antes del resumen, y un patron no
# anclado engancha esa lista y devuelve vacio -> se reportaria 0 siempre.
k6_metric() {
  grep -E "^[[:space:]]+$2\.+:" "$1" | head -1 | grep -oE '[0-9]+' | head -1
}

MODE="${1:-smoke}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Punto de operación de la lógica de negocio, en µs por orden. NO tiene default
# silencioso: con BIZ_MICROS=0 la corrida mide el patrón con la lógica APAGADA y
# su p95 no es comparable con el de un motor real (ver BusinessLogicModel). Se
# exporta para que compose lo reciba y queda en el nombre del directorio y en el
# manifiesto: una corrida cuyo S nadie anotó no es evidencia de nada.
export BIZ_MICROS="${BIZ_MICROS:-0}"
OUT="$ROOT/load/k6/results/$STAMP-$MODE-S${BIZ_MICROS}us"
mkdir -p "$OUT"

SMOKE_FLAG=""
[ "$MODE" = "smoke" ] && SMOKE_FLAG="-e SMOKE=1"

FAILED=()

# Topología limpia por fase. Es requisito de la medición, no higiene: el shard
# publica sus percentiles ACUMULADOS al recibir SIGTERM, y solo son los de ESTA
# fase si el proceso vivió exactamente esta fase. Además evita que el estado del
# libro de una fase contamine la siguiente.
fresh_topology() {
  $COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true
  $COMPOSE up -d >/dev/null
  sleep 20
}

# Percentiles internos del shard (total | espera | servicio), contraparte de la
# medición de k6: su contraste separa el costo del patrón del del transporte.
# `stop` dispara el hook de cierre de la JVM, que emite la línea ACUMULADO con
# los percentiles VERDADEROS sobre toda la población de órdenes de la fase.
# Los logs se capturan antes del `down`, que destruye los contenedores.
capture_shard_logs() {
  local name="$1" since="$2"
  $COMPOSE stop >/dev/null 2>&1 || true
  $COMPOSE logs --no-color --since "$since" 2>/dev/null \
    | grep -E "modelo de logica|ACUMULADO|shard=[0-9]+ n=" > "$OUT/$name-shard.log" || true
  grep "ACUMULADO" "$OUT/$name-shard.log" 2>/dev/null | sed 's/^/  /' || true
}

run_phase() {
  local name="$1"; shift
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: $name"
  echo "════════════════════════════════════════════════════"
  fresh_topology
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ( cd "$ROOT/load/k6" && k6 run $SMOKE_FLAG "$@" --summary-export="$OUT/$name.json" poc.js ) 2>&1 | tee "$OUT/$name.txt"
  local rc=${PIPESTATUS[0]}
  capture_shard_logs "$name" "$since"
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
  fi
}

echo "== E2E experimento E01 · modo=$MODE · BIZ_MICROS=${BIZ_MICROS}us · resultados en $OUT =="
if [ "$BIZ_MICROS" = "0" ]; then
  echo "   AVISO: lógica de negocio APAGADA — se mide solo el patrón; el p95 de"
  echo "          esta corrida NO es el de un motor con lógica real."
fi
{ echo "modo=$MODE"; echo "biz_micros=$BIZ_MICROS"; echo "fecha=$(date -u +%Y-%m-%dT%H:%M:%SZ)";
  echo "k6=$(k6 version 2>/dev/null | head -1)"; echo "commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)";
} > "$OUT/manifiesto.txt"

# 1. Construir imágenes una vez; cada fase levanta su propia topología limpia.
$COMPOSE build

# 2. Fases oficiales (con thresholds: fallan la corrida si p95>200ms o hay rechazos)
run_phase f1 -e PHASE=f1
run_phase f2 -e PHASE=f2

# 3. Partición caliente (exploratoria, sin criterio binario)
run_phase f4 -e PHASE=f4

# 4. Exploración del techo de un shard (siempre corta)
for peak in 250 500 1000; do
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: f4-explore @ ${peak}/s"
  echo "════════════════════════════════════════════════════"
  fresh_topology
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE=f4 -e PEAK="$peak" \
      --summary-export="$OUT/f4-explore-$peak.json" poc.js ) 2>&1 | tee "$OUT/f4-explore-$peak.txt"
  capture_shard_logs "f4-explore-$peak" "$since"
done

# 5. Bajar topología
$COMPOSE down --remove-orphans >/dev/null 2>&1 || true

# 6. Resumen
echo ""
echo "══════════════════ RESUMEN E2E · BIZ_MICROS=${BIZ_MICROS}us ══════════════════"
for f in "$OUT"/*.txt; do
  n="$(basename "$f" .txt)"
  p95="$(grep 'grpc_req_duration' "$f" | grep -o 'p(95)=[^ ]*' | head -1)"
  rej="$(k6_metric "$f" orders_rejected_backpressure)"
  drop="$(k6_metric "$f" dropped_iterations)"
  printf "  %-18s %-16s rechazos=%s descartes=%s\n" "$n" "${p95:-sin dato}" "${rej:-0}" "${drop:-0}"
done
echo "  Salidas crudas (.txt) y resúmenes (.json) en: $OUT"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  ✗ FASES OFICIALES CON THRESHOLD INCUMPLIDO: ${FAILED[*]}"
  exit 1
fi
echo "  ✓ Todas las fases oficiales cumplieron sus thresholds (p95<200ms, 0 rechazos)."
