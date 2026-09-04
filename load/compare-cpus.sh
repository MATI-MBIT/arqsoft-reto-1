#!/usr/bin/env bash
# ==============================================================================
# Efecto del CONFINAMIENTO DE CPU sobre el ASR.
#
# Por que existe: el PoC corre sin limites sobre una maquina de 14 vCPU, cosa que
# ningun despliegue real hace. Medido, cada particion usa 23,6 % de un nucleo en
# media y 58,3 % en pico --el patron de unico escritor la acota a un hilo-- asi
# que el limite no muerde por el lado del matcher. Donde si importa es en la JVM:
# dimensiona los hilos de ZGC, de compilacion JIT y el executor de gRPC a partir
# de availableProcessors(), y con 14 CPU visibles elige algo muy distinto a lo que
# elegiria con una cuota de 1 nucleo.
#
# Ademas convierte la clausula de H2 --"sin exigir mas de un nucleo por
# particion"-- de observacion en RESTRICCION: con cpus=1.0 el sistema tiene que
# cumplir el ASR dentro de ese presupuesto, no simplemente resultar que lo cumple.
#
# Uso:  ./load/compare-cpus.sh [lista de cuotas]      (default: 0 2.0 1.0 0.5)
#       0 = sin limite (la corrida de referencia)
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
CUOTAS="${*:-0 2.0 1.0 0.5}"
BIZ="${BIZ_MICROS:-8000}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/load/k6/results/cpus-$STAMP"
mkdir -p "$OUT"

k6_metric() {
  grep -E "^[[:space:]]+$2\.+:" "$1" | head -1 | grep -oE '[0-9]+' | head -1
}

echo "== Confinamiento de CPU · S=${BIZ}us · fase f2 · N=2 =="
echo "   cuotas: $CUOTAS   (0 = sin limite)"
echo "   salida: $OUT"
$COMPOSE build

ROWS="$OUT/resumen.tsv"
printf "cpus\tavailProc\tk6_p95_ms\tk6_p99_ms\tmotor_p95_us\tespera_p95_us\tserv_p50_us\tordenes\tdescartes\n" > "$ROWS"

for Q in $CUOTAS; do
  echo ""
  echo "──────────── cpus=$Q ────────────"
  $COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true
  BIZ_MICROS="$BIZ" SHARD_CPUS="$Q" $COMPOSE up -d >/dev/null
  sleep 20

  # VERIFICAR el cgroup, no confiar en el YAML. NanoCpus = cuota * 1e9.
  nano="$(docker inspect arqsoft-reto-1-matching-shard-0-1 --format '{{.HostConfig.NanoCpus}}' 2>/dev/null)"
  echo "  docker inspect NanoCpus=$nano  (esperado: $(awk -v q="$Q" 'BEGIN{printf "%.0f", q*1000000000}'))"

  ( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE=f2 -e PEAK=84 poc.js ) > "$OUT/q$Q.txt" 2>&1

  $COMPOSE stop >/dev/null 2>&1 || true
  $COMPOSE logs --no-color 2>/dev/null \
    | grep -E "modelo de logica|runtime:|ACUMULADO" > "$OUT/q$Q-shard.log" || true

  ap="$(grep -m1 -oE "availableProcessors=[0-9]+" "$OUT/q$Q-shard.log" | cut -d= -f2)"
  g="$(grep -E '^\s+grpc_req_duration\.*:' "$OUT/q$Q.txt")"
  p95="$(grep -oE 'p\(95\)=[^ ]+' <<<"$g" | cut -d= -f2)"
  p99="$(grep -oE 'p\(99\)=[^ ]+' <<<"$g" | cut -d= -f2)"
  read -r mp95 wp95 sp50 <<<"$(awk '
    function num(L,p,  s){if(!match(L,p))return 0;s=substr(L,RSTART,RLENGTH);sub(/.*=/,"",s);return s+0}
    /ACUMULADO/{t=num($0,"total p50=[0-9]+us p95=[0-9]+");w=num($0,"espera p50=[0-9]+us p95=[0-9]+");
                d=num($0,"servicio p50=[0-9]+"); if(t>mt){mt=t;mw=w;md=d}}
    END{printf "%d %d %d", mt+0, mw+0, md+0}' "$OUT/q$Q-shard.log")"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$Q" "${ap:-?}" "${p95:-NA}" "${p99:-NA}" \
    "$mp95" "$wp95" "$sp50" "$(k6_metric "$OUT/q$Q.txt" iterations)" \
    "$(k6_metric "$OUT/q$Q.txt" dropped_iterations)" >> "$ROWS"
  echo "  → availableProcessors=${ap:-?} · k6 p95=${p95:-NA} · motor p95=${mp95}us · espera p95=${wp95}us"
done

$COMPOSE --profile n4 down --remove-orphans >/dev/null 2>&1 || true
echo ""
echo "════════════ CONFINAMIENTO DE CPU ════════════"
column -t -s$'\t' "$ROWS"
echo "Crudos en: $OUT"
