#!/usr/bin/env bash
# ==============================================================================
# Prueba de la clausula de H1: "journaling FUERA del camino critico".
#
# Nunca se habia probado porque el PoC no tenia journaling. El Disruptor permite
# dos disposiciones y la diferencia entre ellas ES la afirmacion:
#
#   paralelo  handleEventsWith(journal, matcher)  el journal no suma latencia al
#                                                 cliente, pero el acuse se emite
#                                                 sin esperar al disco
#   serie     handleEventsWith(journal).then(m)   durabilidad antes del acuse, con
#                                                 el journal en el camino critico
#
# No hay una correcta: son dos contratos distintos. Esto mide el precio de cada uno.
#
# Uso:  ./load/compare-journal.sh [modos]        (default: off paralelo serie)
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"
MODOS="${*:-off paralelo serie}"
BIZ="${BIZ_MICROS:-8000}"
OUT="$ROOT/load/k6/results/journal-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

k6_metric() { grep -E "^[[:space:]]+$2\.+:" "$1" | head -1 | grep -oE '[0-9]+' | head -1; }

echo "== Journaling · S=${BIZ}us · fase f2 · N=2 =="
echo "   modos: $MODOS"
echo "   salida: $OUT"
$COMPOSE build

ROWS="$OUT/resumen.tsv"
printf "modo\tk6_p95_ms\tk6_p99_ms\tmotor_p95_us\tespera_p95_us\tserv_p50_us\tjournal_p50_us\tjournal_p95_us\tord_por_fsync\tregistros\n" > "$ROWS"

for M in $MODOS; do
  echo ""
  echo "──────────── journal=$M ────────────"
  # -v: los volumenes del journal deben empezar vacios en cada punto.
  $COMPOSE --profile n4 down -v --remove-orphans >/dev/null 2>&1 || true
  BIZ_MICROS="$BIZ" JOURNAL="$M" $COMPOSE up -d >/dev/null
  sleep 20

  ( cd "$ROOT/load/k6" && k6 run -e SMOKE=1 -e PHASE=f2 -e PEAK=84 poc.js ) > "$OUT/$M.txt" 2>&1

  $COMPOSE stop >/dev/null 2>&1 || true
  $COMPOSE logs --no-color 2>/dev/null \
    | grep -E "modelo de logica|runtime:|journal:|ACUMULADO|JOURNAL shard" > "$OUT/$M-shard.log" || true

  g="$(grep -E '^\s+grpc_req_duration\.*:' "$OUT/$M.txt")"
  read -r mp95 wp95 sp50 <<<"$(awk '
    function num(L,p,  s){if(!match(L,p))return 0;s=substr(L,RSTART,RLENGTH);sub(/.*=/,"",s);return s+0}
    /ACUMULADO/{t=num($0,"total p50=[0-9]+us p95=[0-9]+");w=num($0,"espera p50=[0-9]+us p95=[0-9]+");
                d=num($0,"servicio p50=[0-9]+"); if(t>mt){mt=t;mw=w;md=d}}
    END{printf "%d %d %d", mt+0, mw+0, md+0}' "$OUT/$M-shard.log")"
  read -r jp50 jp95 opf regs <<<"$(awk '
    function num(L,p,  s){if(!match(L,p))return 0;s=substr(L,RSTART,RLENGTH);sub(/.*=/,"",s);return s+0}
    /JOURNAL shard/{a=num($0,"p50=[0-9]+");b=num($0,"p50=[0-9]+us p95=[0-9]+");
                    c=num($0,"ordenes_por_fsync=[0-9.]+");r=num($0,"registros=[0-9]+");
                    if(b>mb){ma=a;mb=b;mc=c;mr=r}}
    END{printf "%d %d %.1f %d", ma+0, mb+0, mc+0, mr+0}' "$OUT/$M-shard.log")"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$M" \
    "$(grep -oE 'p\(95\)=[^ ]+' <<<"$g" | cut -d= -f2)" "$(grep -oE 'p\(99\)=[^ ]+' <<<"$g" | cut -d= -f2)" \
    "$mp95" "$wp95" "$sp50" "$jp50" "$jp95" "$opf" "$regs" >> "$ROWS"
  echo "  → $(tail -1 "$ROWS" | cut -f1,2,4,5,7,8,9 | tr '\t' ' ')"
done

$COMPOSE --profile n4 down -v --remove-orphans >/dev/null 2>&1 || true
echo ""
echo "════════════ JOURNALING ════════════"
column -t -s$'\t' "$ROWS"
echo "Crudos en: $OUT"
