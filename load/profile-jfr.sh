#!/usr/bin/env bash
# ==============================================================================
# Perfila una fase con Java Flight Recorder y atribuye los atascos.
#
# El problema que resuelve: el motor registra atascos aislados de cientos de
# milisegundos --una orden que espera 250 ms en el ring cuando el p99.9 de la
# fase esta en 2 ms-- y hasta ahora no se podian atribuir. Un solo evento asi
# incumple el SLA por si mismo, asi que saber si son GC, JIT, safepoints o
# contencion del host decide que se ataca.
#
# JFR se anexa a JAVA_OPTS (ver Dockerfile), de modo que ZGC sigue activo: se
# perfila la configuracion real, no otra.
#
# Uso:  ./load/profile-jfr.sh [fase]      (default: f2)
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"
FASE="${1:-f2}"
BIZ="${BIZ_MICROS:-8000}"
OUT="$ROOT/load/k6/results/jfr-$(date +%Y%m%d-%H%M%S)"
JFR_BIN="$(/usr/libexec/java_home 2>/dev/null)/bin/jfr"
mkdir -p "$OUT"

[ -x "$JFR_BIN" ] || { echo "ERROR: no se encontro el binario jfr en $JFR_BIN"; exit 1; }

# duration=0 -> sin limite; dumponexit -> el archivo se escribe al recibir SIGTERM.
# settings=profile da muestreo de pila y eventos de safepoint que 'default' omite.
export JFR_OPTS="-XX:StartFlightRecording=duration=0,filename=/var/lib/engine/jfr/shard.jfr,settings=profile,dumponexit=true -XX:FlightRecorderOptions:stackdepth=64"

echo "== JFR · fase=$FASE · S=${BIZ}us · N=2 =="
echo "   salida: $OUT"
$COMPOSE build
$COMPOSE --profile n4 down -v --remove-orphans >/dev/null 2>&1 || true
BIZ_MICROS="$BIZ" $COMPOSE up -d >/dev/null
sleep 20

( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE="$FASE" -e PEAK=84 poc.js ) 2>&1 | tee "$OUT/k6.txt"

# stop -> SIGTERM -> hook de cierre + volcado de JFR. Debe ir ANTES del down.
$COMPOSE stop >/dev/null 2>&1 || true
sleep 3
$COMPOSE logs --no-color 2>/dev/null | grep -E "modelo de logica|runtime:|ACUMULADO" > "$OUT/shard.log" || true

for i in 0 1; do
  cid="$($COMPOSE ps -aq matching-shard-$i 2>/dev/null | head -1)"
  [ -n "$cid" ] && docker cp "$cid:/var/lib/engine/jfr/shard.jfr" "$OUT/shard-$i.jfr" 2>/dev/null \
    && echo "  grabacion shard-$i: $(du -h "$OUT/shard-$i.jfr" | cut -f1)"
done
$COMPOSE --profile n4 down -v --remove-orphans >/dev/null 2>&1 || true

for f in "$OUT"/shard-*.jfr; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .jfr)"
  echo ""
  echo "════════ $n ════════"
  "$JFR_BIN" summary "$f" > "$OUT/$n-summary.txt" 2>&1

  echo "--- pausas de GC (ms) ---"
  "$JFR_BIN" print --events jdk.GCPhasePause "$f" 2>/dev/null \
    | awk '/duration =/{gsub(/[^0-9.]/,"",$3); if($3+0>0) print $3}' \
    | sort -rn | head -5 | sed 's/^/    /'
  "$JFR_BIN" print --events jdk.GCPhasePause "$f" 2>/dev/null \
    | grep -c "duration =" | sed 's/^/    total de pausas: /'

  echo "--- safepoints mas largos (ms) ---"
  "$JFR_BIN" print --events jdk.SafepointBegin,jdk.ExecuteVMOperation "$f" 2>/dev/null \
    | awk '/duration =/{gsub(/[^0-9.]/,"",$3); if($3+0>1) print $3}' \
    | sort -rn | head -5 | sed 's/^/    /'

  echo "--- compilacion JIT mas larga (ms) ---"
  "$JFR_BIN" print --events jdk.Compilation "$f" 2>/dev/null \
    | awk '/duration =/{gsub(/[^0-9.]/,"",$3); if($3+0>1) print $3}' \
    | sort -rn | head -5 | sed 's/^/    /'

  echo "--- resumen de eventos (top 12 por conteo) ---"
  grep -E "^ +jdk\." "$OUT/$n-summary.txt" | sort -k2 -rn | head -12 | sed 's/^/  /'
done
echo ""
echo "Grabaciones y volcados en: $OUT"
echo "Explorar a mano:  $JFR_BIN print --events <evento> $OUT/shard-0.jfr"
