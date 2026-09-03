#!/usr/bin/env bash
# ==============================================================================
# Barrido del costo por orden S → PRESUPUESTO DE TIEMPO DE SERVICIO.
#
# Por qué existe: en un diseño de un único escritor el costo por evento se
# serializa, así que fija el techo del shard (techo = 1/S, con rho = lambda·S).
# El PoC no implementa la lógica de negocio, así que medir la capacidad con el
# match() de juguete mide un TreeMap. Barriendo S el entregable deja de ser un
# p95 y pasa a ser una cota falsable: «el patrón sostiene el ASR mientras
# procesar una orden cueste menos de X».
#
# El presupuesto NO es una constante del patrón: depende de la carga y de N,
# porque lo que satura es rho = (lambda/N)·S. Por eso el barrido es
# parametrizable en fase, tasa y número de shards.
#
# Uso:
#   ./load/sweep-service.sh                                  # f2 · 84/s · N=2
#   PHASE=f4 MICROS="5000 8000 10000" ./load/sweep-service.sh # partición caliente
#   N=4 ./load/sweep-service.sh                              # ¿el presupuesto escala con N?
#
# Variables: PHASE (f1|f2|f4) · PEAK (órd/s) · N (1|2|4) · MICROS (lista de S en µs)
#            FULL=1 usa el perfil oficial largo en vez del corto
# ==============================================================================
set -uo pipefail

# Lee una metrica del RESUMEN de k6. Anclado a "^  <nombre>....:" a proposito:
# k6 lista los nombres de metricas sin valor antes del resumen, y un patron no
# anclado engancha esa lista y devuelve vacio -> se reportaria 0 siempre.
k6_metric() {
  grep -E "^[[:space:]]+$2\.+:" "$1" | head -1 | grep -oE '[0-9]+' | head -1
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"

PHASE="${PHASE:-f2}"
PEAK="${PEAK:-84}"
N="${N:-2}"
MICROS="${MICROS:-0 5000 10000 15000 20000 25000}"
FULL="${FULL:-0}"
DIST="${BIZ_DIST:-mezcla}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$ROOT/load/k6/results/sweep-$STAMP-$PHASE-p$PEAK-n$N-$DIST}"
mkdir -p "$OUT"

SMOKE_FLAG="-e SMOKE=1"
[ "$FULL" = "1" ] && SMOKE_FLAG=""

SHARDS_N4="matching-shard-0:9090,matching-shard-1:9090,matching-shard-2:9090,matching-shard-3:9090"

# Levanta la topología pedida. Limpia por punto: el shard publica sus
# percentiles ACUMULADOS al recibir SIGTERM y solo son de ESTE punto si el
# proceso vivió exactamente este punto.
topology_up() {
  local biz="$1"
  $COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true
  case "$N" in
    1) BIZ_MICROS="$biz" BIZ_DIST="$DIST" SHARDS="matching-shard-0:9090" $COMPOSE up -d ingest-router matching-shard-0 >/dev/null ;;
    4) BIZ_MICROS="$biz" BIZ_DIST="$DIST" SHARDS="$SHARDS_N4" $COMPOSE --profile n4 up -d >/dev/null ;;
    *) BIZ_MICROS="$biz" BIZ_DIST="$DIST" $COMPOSE up -d >/dev/null ;;
  esac
  sleep 20
}

# `stop` dispara el hook de cierre de la JVM → línea ACUMULADO con los
# percentiles VERDADEROS de toda la población de órdenes del punto.
# Se conserva también la línea de provenance: sin ella el punto es ambiguo.
capture() {
  local log="$1"
  $COMPOSE stop >/dev/null 2>&1 || true
  $COMPOSE logs --no-color 2>/dev/null \
    | grep -E "modelo de logica|ACUMULADO|shard=[0-9]+ n=" > "$log" || true
}

# Del conjunto de shards toma el PEOR: el SLA lo incumple la particion mas
# lenta, no el promedio de las particiones.
#
# Nada de -F'|': `docker compose logs` antepone "<servicio>  | " a cada linea,
# asi que ese separador desplaza todos los campos una posicion. Cada segmento se
# localiza por su etiqueta sobre la linea completa, que es univoca.
# Los patrones van como CADENA: un literal /re/ en posicion de argumento awk lo
# evalua como ($0 ~ /re/) y devolveria 0/1 en vez del valor.
worst() {
  awk '
    function num(line, pat,   s) {
      if (!match(line, pat)) return 0
      s = substr(line, RSTART, RLENGTH); sub(/.*=/, "", s); return s+0
    }
    /ACUMULADO/ {
      t = num($0, "total p50=[0-9]+us p95=[0-9]+")
      w = num($0, "espera p50=[0-9]+us p95=[0-9]+")
      d = num($0, "servicio p50=[0-9]+")
      if (t > mt) mt = t
      if (w > mw) mw = w
      if (d > md) md = d
      sh++
    }
    END { printf "%d %d %d %d", mt+0, mw+0, md+0, sh+0 }' "$1"
}

echo "== Barrido de tiempo de servicio =="
echo "   fase=$PHASE  pico=$PEAK ord/s  N=$N  dist=$DIST  perfil=$([ "$FULL" = 1 ] && echo oficial || echo corto)"
echo "   S (us): $MICROS"
echo "   salida: $OUT"
$COMPOSE build

ROWS="$OUT/resumen.tsv"
printf "S_us\tk6_p95_ms\tmotor_p95_us\tespera_p95_us\tservicio_p50_us\trechazos\tdescartes\tordenes\n" > "$ROWS"

for S in $MICROS; do
  echo ""
  echo "──────────── S=${S}us · ${PEAK}/s · fase $PHASE · N=$N ────────────"
  topology_up "$S"
  ( cd "$ROOT/load/k6" && k6 run $SMOKE_FLAG -e PHASE="$PHASE" -e PEAK="$PEAK" \
      --summary-export="$OUT/S$S.json" poc.js ) 2>&1 | tee "$OUT/S$S.txt"
  capture "$OUT/S$S-shard.log"

  k6p95="$(grep 'grpc_req_duration' "$OUT/S$S.txt" | grep -o 'p(95)=[^ ]*' | head -1 | sed 's/p(95)=//')"
  rej="$(k6_metric "$OUT/S$S.txt" orders_rejected_backpressure)"
  drop="$(k6_metric "$OUT/S$S.txt" dropped_iterations)"
  ord="$(k6_metric "$OUT/S$S.txt" iterations)"
  read -r tp95 wp95 sp50 nsh <<<"$(worst "$OUT/S$S-shard.log")"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$S" "${k6p95:-NA}" "$tp95" "$wp95" "$sp50" "${rej:-0}" "${drop:-0}" "${ord:-NA}" >> "$ROWS"
  echo "  → k6 p95=${k6p95:-NA} · motor p95=${tp95}us · espera p95=${wp95}us · servicio p50=${sp50}us · shards con datos=${nsh}"
done

$COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true

echo ""
echo "════════════ PRESUPUESTO · fase=$PHASE pico=$PEAK N=$N ════════════"
column -t -s$'\t' "$ROWS"
echo ""
echo "Lectura: 'servicio' debe seguir a S y NO depender de la tasa (es el costo"
echo "propio); 'espera' es lo que explota cuando rho -> 1. El presupuesto es el"
echo "mayor S cuyo k6 p95 sigue bajo 200 ms."
echo "Crudos en: $OUT"
