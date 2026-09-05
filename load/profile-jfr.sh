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

# Un backend caido responde mas rapido que uno vivo: los RPC fallan al instante y
# el p95 sale mejor que en una corrida buena. Sin este guardia, un experimento
# roto entrega una cifra plausible. Se verifica que los checks pasaron y que el
# motor emitio su ACUMULADO antes de creerle a ningun numero.
verificar_corrida() {
  local k6out="$1" shardlog="${2:-}"
  local ok
  ok="$(grep -E "^[[:space:]]+checks_succeeded" "$k6out" | grep -oE '[0-9]+\.[0-9]+%' | head -1)"
  if [ "${ok%%.*}" != "100" ]; then
    echo "  ✗ CORRIDA INVALIDA: checks_succeeded=$ok (se esperaba 100%)"
    grep -E "^[[:space:]]+checks_failed" "$k6out" | sed 's/^/    /'
    return 1
  fi
  if [ -n "$shardlog" ] && ! grep -q ACUMULADO "$shardlog" 2>/dev/null; then
    echo "  ✗ CORRIDA INVALIDA: el motor no emitio ACUMULADO"
    return 1
  fi
  return 0
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"

# Servicios de la aplicacion. Se reciclan estos y NO la observabilidad: un
# `down -v` global borraria el historico de Prometheus, que es evidencia de las
# corridas anteriores. Los volumenes de datos se vacian por nombre.
APP_SERVICES="matching-shard-0 matching-shard-1 matching-shard-2 matching-shard-3 ingest-router"
DATA_VOLUMES="journal-0 journal-1 journal-2 journal-3 jfr-0 jfr-1 jfr-2 jfr-3"

reciclar_app() {
  # shellcheck disable=SC2086
  $COMPOSE --profile n4 rm -sf $APP_SERVICES >/dev/null 2>&1 || true
  for v in $DATA_VOLUMES; do
    docker volume rm -f "arqsoft-reto-1_$v" >/dev/null 2>&1 || true
  done
}

FASE="${1:-f2}"
BIZ="${BIZ_MICROS:-8000}"
OUT="$ROOT/load/k6/results/jfr-$(date +%Y%m%d-%H%M%S)"
JFR_BIN="$(/usr/libexec/java_home 2>/dev/null)/bin/jfr"
mkdir -p "$OUT"

[ -x "$JFR_BIN" ] || { echo "ERROR: no se encontro el binario jfr en $JFR_BIN"; exit 1; }

# SIN `duration`: omitirlo deja la grabacion sin limite. `duration=0` NO es "sin
# limite" -- la JVM lo rechaza ("duration must be at least 1 second") y ni siquiera
# arranca. dumponexit escribe el archivo al recibir SIGTERM.
# settings=profile da muestreo de pila y eventos de safepoint que 'default' omite.
export JFR_OPTS="-XX:StartFlightRecording=filename=/var/lib/engine/jfr/shard.jfr,settings=profile,dumponexit=true -XX:FlightRecorderOptions:stackdepth=64"

echo "== JFR · fase=$FASE · S=${BIZ}us · N=2 =="
echo "   salida: $OUT"
$COMPOSE build
reciclar_app
export BIZ_MICROS="$BIZ"
$COMPOSE up -d >/dev/null
sleep 20

# El banner declara la intencion; esto verifica lo que el contenedor recibio.
# Una corrida anterior anuncio "S=8000us" y arranco con S=0: la procedencia se
# comprueba en el log del motor, no se imprime desde una variable.
declarado="$($COMPOSE logs matching-shard-0 2>/dev/null | grep -m1 'modelo de logica' | sed 's/.*negocio: //')"
echo "  punto de operacion REAL del shard: $declarado"
if [ "$BIZ" != "0" ] && ! grep -q "media=${BIZ}us" <<<"$declarado"; then
  echo "  ✗ ABORTA: se pidio S=${BIZ}us y el shard arranco con: $declarado"
  reciclar_app
  exit 1
fi
# El log se captura ANTES de filtrar. Con `set -o pipefail`, un `grep -q` en
# tuberia sale al primer acierto, manda SIGPIPE a `compose logs` y su estado de
# error se propaga: el guardia falla justo cuando la condicion SI se cumple.
arranque="$($COMPOSE logs matching-shard-0 2>/dev/null || true)"
if ! grep -q "Started recording" <<<"$arranque"; then
  echo "  ✗ ABORTA: la JVM no inicio la grabacion JFR"
  $COMPOSE logs matching-shard-0 2>/dev/null | grep -i jfr | head -3 | sed 's/^/    /'
  reciclar_app
  exit 1
fi

( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE="$FASE" -e PEAK=84 poc.js ) 2>&1 | tee "$OUT/k6.txt"

# stop -> SIGTERM -> hook de cierre + volcado de JFR. Debe ir ANTES del down.
# shellcheck disable=SC2086
  $COMPOSE stop $APP_SERVICES >/dev/null 2>&1 || true
sleep 3
$COMPOSE logs --no-color 2>/dev/null | grep -E "modelo de logica|runtime:|ACUMULADO|jfr" > "$OUT/shard.log" || true

if ! verificar_corrida "$OUT/k6.txt" "$OUT/shard.log"; then
  echo "  No se analiza la grabacion: la corrida no es valida."
  $COMPOSE logs --no-color 2>/dev/null | grep -iE "error|exception" | head -5 | sed 's/^/    /'
  reciclar_app
  exit 1
fi

for i in 0 1; do
  cid="$($COMPOSE ps -aq matching-shard-$i 2>/dev/null | head -1)"
  [ -n "$cid" ] && docker cp "$cid:/var/lib/engine/jfr/shard.jfr" "$OUT/shard-$i.jfr" 2>/dev/null \
    && echo "  grabacion shard-$i: $(du -h "$OUT/shard-$i.jfr" | cut -f1)"
done
reciclar_app

for f in "$OUT"/shard-*.jfr; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .jfr)"
  echo ""
  echo "════════ $n ════════"
  "$JFR_BIN" summary "$f" > "$OUT/$n-summary.txt" 2>&1

  # Las duraciones vienen como "0,00696 ms": coma decimal y unidad en $4. Quitar
  # los no-digitos convertiria eso en 000696 y multiplicaria por mil cualquier
  # lectura. Se normaliza a milisegundos.
  ms() { awk '/duration =/{v=$3; gsub(",",".",v); u=$4;
               if(u=="s")v*=1000; else if(u=="us")v/=1000; else if(u=="ns")v/=1000000;
               print v}'; }

  echo "--- el atasco a explicar (del ACUMULADO de esta corrida) ---"
  grep -o "max=[0-9]*us" "$OUT/shard.log" | head -1 | sed 's/max=/    total max = /;s/us/ us/'

  for ev in jdk.GCPhasePause jdk.ExecuteVMOperation jdk.SafepointBegin jdk.Compilation; do
    top="$("$JFR_BIN" print --events $ev "$f" 2>/dev/null | ms | sort -rn | head -1)"
    cnt="$("$JFR_BIN" print --events $ev "$f" 2>/dev/null | grep -c 'duration =')"
    [ -n "$top" ] && awk -v e="$ev" -v m="$top" -v c="$cnt" \
      'BEGIN{printf "    %-26s max %8.3f ms   (%s eventos)\n", e, m, c}'
  done

  echo "--- cualquier evento con un maximo > 50 ms (excluidos los de espera ociosa) ---"
  for ev in $(grep -oE "^ +jdk\.[A-Za-z]+" "$OUT/$n-summary.txt" | tr -d ' '); do
    case "$ev" in jdk.ThreadPark|jdk.JavaMonitorWait|jdk.ThreadSleep) continue;; esac
    top="$("$JFR_BIN" print --events $ev "$f" 2>/dev/null | ms | sort -rn | head -1)"
    [ -n "$top" ] && awk -v e="$ev" -v m="$top" 'BEGIN{if(m>50)printf "    %-30s %.1f ms\n",e,m}'
  done

  echo "--- resumen de eventos (top 12 por conteo) ---"
  grep -E "^ +jdk\." "$OUT/$n-summary.txt" | sort -k2 -rn | head -12 | sed 's/^/  /'
done
echo ""
echo "Grabaciones y volcados en: $OUT"
echo "Explorar a mano:  $JFR_BIN print --events <evento> $OUT/shard-0.jfr"
