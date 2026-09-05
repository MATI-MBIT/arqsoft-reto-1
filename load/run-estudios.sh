#!/usr/bin/env bash
# ==============================================================================
# Los seis estudios que producen las tablas de la evidencia, en una sola cadena.
#
# Por qué existe: cada estudio es un comando distinto y la evidencia los cita
# juntos. Corridos en sesiones separadas quedaban medidos con instrumentos
# distintos —el separador del calentamiento entró después que varios de ellos—
# y un documento que mezcla instrumentos sin decirlo no es evidencia.
#
# Espera a que termine cualquier ciclo e2e en curso: comparten la topología.
#
# Uso:  ./load/run-estudios.sh            # los seis (~2h)
#       ./load/run-estudios.sh presupuesto journal   # solo esos
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGS="$ROOT/load/k6/results/estudios-$STAMP"
mkdir -p "$LOGS"
export BIZ_MICROS="${BIZ_MICROS:-8000}"

# Los estudios y la pregunta que responde cada uno.
declare -a ORDEN=(presupuesto caliente forma journal cpus jfr)

corre() {
  local nombre="$1"; shift
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Estudio: $nombre   ($(date +%H:%M:%S))"
  echo "════════════════════════════════════════════════════════════"
  ( "$@" ) > "$LOGS/$nombre.log" 2>&1
  local rc=$?
  echo "  -> rc=$rc · log: $LOGS/$nombre.log"
  tail -20 "$LOGS/$nombre.log"
  return $rc
}

# `env` explicito. Probado en bash 3.2, poner las asignaciones delante de la
# funcion tambien funciona y tampoco se filtran al estudio siguiente -- pero ese
# comportamiento depende del shell: en modo POSIX la asignacion PERSISTE tras el
# retorno, y entonces los MICROS de un barrido contaminarian el siguiente sin
# avisar. `env` no deja lugar a la duda y se lee igual de bien.
estudio() {
  case "$1" in
    presupuesto) # ¿Hasta cuánto puede costar una orden con el pico repartido?
      corre presupuesto env MICROS="0 5000 10000 12000 13000 15000" PHASE=f2 PEAK=84 N=2 \
        "$ROOT/load/sweep-service.sh" ;;
    caliente)    # ¿Y con todo el pico en una sola partición?
      corre caliente env MICROS="0 5000 8000 9000 10000 12000" PHASE=f4 PEAK=84 N=1 \
        "$ROOT/load/sweep-service.sh" ;;
    forma)       # ¿El resultado depende de la FORMA de la distribución, o solo de sus dos momentos?
      corre forma env MICROS="8000" PHASE=f2 PEAK=84 N=2 BIZ_DIST=lognormal \
        "$ROOT/load/sweep-service.sh" ;;
    journal)     # ¿Se puede registrar cada orden sin pagarlo en latencia?
      corre journal "$ROOT/load/compare-journal.sh" off paralelo serie ;;
    cpus)        # ¿Basta un núcleo por partición?
      corre cpus "$ROOT/load/compare-cpus.sh" 0 2.0 1.0 0.5 ;;
    jfr)         # ¿Qué causa los atascos de cientos de milisegundos?
      corre jfr "$ROOT/load/profile-jfr.sh" f2 ;;
    *) echo "  estudio desconocido: $1"; return 1 ;;
  esac
}

# Comparten la topología con el ciclo e2e: esperar en vez de pelear por ella.
if pgrep -f "run-e2e.sh" >/dev/null 2>&1; then
  echo "== hay un ciclo e2e en curso; esperando a que libere la topología =="
  while pgrep -f "run-e2e.sh" >/dev/null 2>&1; do sleep 30; done
  echo "== e2e terminado, arrancan los estudios =="
fi

SELECCION=("$@")
[ "${#SELECCION[@]}" -eq 0 ] && SELECCION=("${ORDEN[@]}")

echo "== Estudios · S=${BIZ_MICROS}us · $(date) =="
echo "   selección: ${SELECCION[*]}"
echo "   logs: $LOGS"

FALLARON=()
for e in "${SELECCION[@]}"; do
  estudio "$e" || FALLARON+=("$e")
done

echo ""
echo "══════════════════ ESTUDIOS TERMINADOS ══════════════════"
echo "  logs y tablas en: $LOGS"
ls "$ROOT/load/k6/results" | tail -12
if [ "${#FALLARON[@]}" -gt 0 ]; then
  echo "  ✗ con error: ${FALLARON[*]}"
  exit 1
fi
echo "  ✓ los seis estudios terminaron sin error"
