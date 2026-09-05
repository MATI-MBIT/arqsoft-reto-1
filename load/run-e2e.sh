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
#
# Cada fase escribe además sus métricas a Prometheus, de modo que el tablero de
# Grafana cubre el ciclo completo en una sola línea de tiempo. La observabilidad
# NO se recicla entre fases: si se bajara con los demás contenedores, la serie
# quedaría partida en cinco pedazos y el tablero dejaría de ser evidencia.
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
# Confinamiento de recursos: 0 = sin limite. Va al manifiesto por la misma razon
# que BIZ_MICROS -- sin el, una corrida confinada y una libre son
# indistinguibles en la evidencia.
export SHARD_CPUS="${SHARD_CPUS:-0}"
export SHARD_CPUSET="${SHARD_CPUSET:-}"
export SHARD_MEM="${SHARD_MEM:-0}"
# Directorio de resultados. RESULTS_DIR permite REANUDAR una corrida
# interrumpida sobre el mismo directorio: las fases ya completas se omiten.
# Es valido porque cada fase corre sobre una topologia recien levantada y no
# comparte estado con las demas -- esa independencia ya era requisito de la
# medicion, aqui solo se aprovecha.
OUT="${RESULTS_DIR:-$ROOT/load/k6/results/$STAMP-$MODE-S${BIZ_MICROS}us}"
mkdir -p "$OUT"

SMOKE_FLAG=""
[ "$MODE" = "smoke" ] && SMOKE_FLAG="-e SMOKE=1"

# Salida a Prometheus. Va por variables de entorno para que un anfitrion sin
# Prometheus pueda apagarla con K6_OUT="" sin tocar el script.
export K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-http://localhost:9090/api/v1/write}"
export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),p(99.9),max,avg}"
export K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
K6_OUT="${K6_OUT--o experimental-prometheus-rw}"

FAILED=()

# Topología limpia por fase. Es requisito de la medición, no higiene: el shard
# publica sus percentiles ACUMULADOS al recibir SIGTERM, y solo son los de ESTA
# fase si el proceso vivió exactamente esta fase. Además evita que el estado del
# libro de una fase contamine la siguiente.
# Servicios de la aplicacion: los unicos que se reciclan. Prometheus y Grafana
# siguen vivos toda la corrida para no partir la serie de tiempo.
APP_SERVICES="matching-shard-0 matching-shard-1 matching-shard-2 matching-shard-3 ingest-router"

fresh_topology() {
  # shellcheck disable=SC2086
  $COMPOSE --profile n4 rm -sf $APP_SERVICES >/dev/null 2>&1 || true
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
  # shellcheck disable=SC2086
  $COMPOSE stop $APP_SERVICES >/dev/null 2>&1 || true
  $COMPOSE logs --no-color --since "$since" 2>/dev/null \
    | grep -E "modelo de logica|runtime:|ACUMULADO|shard=[0-9]+ n=" > "$OUT/$name-shard.log" || true
  grep "ACUMULADO" "$OUT/$name-shard.log" 2>/dev/null | sed 's/^/  /' || true
}

# Una fase esta COMPLETA si dejo su resumen de k6 y el motor alcanzo a publicar
# su ACUMULADO. Completa no es lo mismo que valida: una fase que incumplio su
# umbral esta completa y no hay que repetirla, la decision ya se tomo.
fase_completa() {
  local n="$1"
  [ -f "$OUT/$n.txt" ] || return 1
  grep -qE "^[[:space:]]+grpc_req_duration" "$OUT/$n.txt" || return 1
  grep -q ACUMULADO "$OUT/$n-shard.log" 2>/dev/null || return 1
  return 0
}

run_phase() {
  local name="$1"; shift
  if fase_completa "$name"; then
    echo ""
    echo "  Fase: $name — ya completa en el directorio, se omite"
    return
  fi
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: $name"
  echo "════════════════════════════════════════════════════"
  # ANTES de fresh_topology: el shard declara su punto de operacion al arrancar
  # y con la marca tomada despues esa linea queda siempre fuera de la captura.
  # fresh_topology hace `down` primero, asi que no se arrastra la fase anterior.
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fresh_topology
  # shellcheck disable=SC2086
  ( cd "$ROOT/load/k6" && k6 run $K6_OUT --tag fase="$name" $SMOKE_FLAG "$@" \
      --summary-export="$OUT/$name.json" poc.js ) 2>&1 | tee "$OUT/$name.txt"
  local rc=${PIPESTATUS[0]}
  capture_shard_logs "$name" "$since"
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
  fi
}

echo "== E2E experimento E01 · modo=$MODE · BIZ_MICROS=${BIZ_MICROS}us · SHARD_CPUS=${SHARD_CPUS} · resultados en $OUT =="
for f in f1 f2 f4 f4-explore-250 f4-explore-500 f4-explore-1000; do
  fase_completa "$f" && echo "   reanudando: $f ya esta completa"
done
if [ "$BIZ_MICROS" = "0" ]; then
  echo "   AVISO: lógica de negocio APAGADA — se mide solo el patrón; el p95 de"
  echo "          esta corrida NO es el de un motor con lógica real."
fi
{ echo "modo=$MODE"; echo "biz_micros=$BIZ_MICROS"; echo "biz_dist=${BIZ_DIST:-mezcla}";
  echo "shard_cpus=$SHARD_CPUS"; echo "shard_cpuset=$SHARD_CPUSET"; echo "shard_mem=$SHARD_MEM";
  echo "fecha=$(date -u +%Y-%m-%dT%H:%M:%SZ)";
  echo "k6=$(k6 version 2>/dev/null | head -1)"; echo "commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)";
  echo "prometheus=${K6_PROMETHEUS_RW_SERVER_URL:-apagado}"; echo "tablero=http://localhost:3000";
} > "$OUT/manifiesto-$STAMP.txt"
[ -f "$OUT/manifiesto.txt" ] || cp "$OUT/manifiesto-$STAMP.txt" "$OUT/manifiesto.txt"

# 1. Construir imágenes una vez; cada fase levanta su propia topología limpia.
$COMPOSE build

# 2. Fases oficiales (con thresholds: fallan la corrida si p95>200ms o hay rechazos)
run_phase f1 -e PHASE=f1
run_phase f2 -e PHASE=f2

# 3. Partición caliente (exploratoria, sin criterio binario)
run_phase f4 -e PHASE=f4

# 4. Exploración del techo de un shard (siempre corta)
for peak in 250 500 1000; do
  if fase_completa "f4-explore-$peak"; then
    echo ""
    echo "  Fase: f4-explore @ ${peak}/s — ya completa, se omite"
    continue
  fi
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  Fase: f4-explore @ ${peak}/s"
  echo "════════════════════════════════════════════════════"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fresh_topology
  # shellcheck disable=SC2086
  ( cd "$ROOT/load/k6" && k6 run $K6_OUT --tag fase="f4-explore-$peak" \
      -e SMOKE=1 -e PHASE=f4 -e PEAK="$peak" \
      --summary-export="$OUT/f4-explore-$peak.json" poc.js ) 2>&1 | tee "$OUT/f4-explore-$peak.txt"
  capture_shard_logs "f4-explore-$peak" "$since"
done

# 5. Bajar la aplicacion. La observabilidad queda ARRIBA a proposito: el tablero
# es parte del entregable y tiene que poder leerse cuando la corrida termina.
# shellcheck disable=SC2086
$COMPOSE stop $APP_SERVICES >/dev/null 2>&1 || true

# 6. Resumen
echo ""
echo "══════════════════ RESUMEN E2E · BIZ_MICROS=${BIZ_MICROS}us ══════════════════"
for f in "$OUT"/*.txt; do
  n="$(basename "$f" .txt)"
  [ "$n" = "manifiesto" ] && continue   # no es una fase
  p95="$(grep 'grpc_req_duration' "$f" | grep -o 'p(95)=[^ ]*' | head -1)"
  rej="$(k6_metric "$f" orders_rejected_backpressure)"
  drop="$(k6_metric "$f" dropped_iterations)"
  printf "  %-18s %-16s rechazos=%s descartes=%s\n" "$n" "${p95:-sin dato}" "${rej:-0}" "${drop:-0}"
done
echo "  Salidas crudas (.txt) y resúmenes (.json) en: $OUT"
echo "  Tablero con el ciclo completo: http://localhost:3000 (fuente: Prometheus en :9090)"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  ✗ FASES OFICIALES CON THRESHOLD INCUMPLIDO: ${FAILED[*]}"
  exit 1
fi
echo "  ✓ Todas las fases oficiales cumplieron sus thresholds (p95<200ms, 0 rechazos)."
