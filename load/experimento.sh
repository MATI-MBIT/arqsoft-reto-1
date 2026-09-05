#!/usr/bin/env bash
# ==============================================================================
# El ÚNICO orquestador del experimento E01.
#
# Antes esto eran seis scripts. Cada pregunta nueva traía un .sh nuevo, con su
# propia copia del ciclo levantar → correr → capturar → extraer, y sus propias
# decisiones sobre qué hace válida una corrida. Seis copias de la misma lógica
# son seis sitios donde puede divergir.
#
# Ahora el QUÉ se corre es dato (plan.tsv) y el CÓMO se corre es este archivo.
# Agregar un punto de medida es agregar una línea al plan.
#
# Uso:  ./load/experimento.sh                    # el plan completo (~4h30m)
#       ./load/experimento.sh oficial            # solo las fases contractuales
#       ./load/experimento.sh h2-quiebre h2-cpu  # los grupos que se indiquen
#       RESULTS_DIR=... ./load/experimento.sh    # reanudar una corrida cortada
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT/deploy/docker-compose.yml"
PLAN="$ROOT/load/plan.tsv"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${RESULTS_DIR:-$ROOT/load/k6/results/e01-$STAMP}"
mkdir -p "$OUT"

SHARDS_N4="matching-shard-0:9090,matching-shard-1:9090,matching-shard-2:9090,matching-shard-3:9090"
APP="matching-shard-0 matching-shard-1 matching-shard-2 matching-shard-3 ingest-router"

# Prometheus recibe lo que k6 mide desde afuera; el raspado trae lo que los
# servicios miden por dentro. La observabilidad NUNCA se recicla entre corridas:
# si se bajara, la serie quedaría partida en cuarenta pedazos.
export K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-http://localhost:9090/api/v1/write}"
export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),p(99.9),max,avg}"
export K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
K6_OUT="${K6_OUT--o experimental-prometheus-rw}"

RESULTADOS="$OUT/resultados.tsv"
[ -f "$RESULTADOS" ] || printf "id\thipotesis\tgrupo\tfase\tn\tvars\tcriterio\tk6_p95_ms\tk6_p99_ms\tk6_p999_ms\tmotor_p95_us\tespera_p95_us\tserv_p50_us\ttasa_lograda\tordenes\trechazos\tdescartes\tveredicto\tlatencia_valida\n" > "$RESULTADOS"

# ---------------------------------------------------------------------------
# Topología
# ---------------------------------------------------------------------------
levantar() {
  local n="$1"; shift
  # shellcheck disable=SC2086
  $COMPOSE --profile n4 rm -sf $APP >/dev/null 2>&1 || true
  for v in journal-0 journal-1 journal-2 journal-3 jfr-0 jfr-1 jfr-2 jfr-3; do
    docker volume rm -f "arqsoft-reto-1_$v" >/dev/null 2>&1 || true
  done
  case "$n" in
    1) SHARDS="matching-shard-0:9090" $COMPOSE up -d ingest-router matching-shard-0 prometheus grafana >/dev/null ;;
    4) SHARDS="$SHARDS_N4" $COMPOSE --profile n4 up -d >/dev/null ;;
    *) $COMPOSE up -d >/dev/null ;;
  esac
  sleep 20
}

# ---------------------------------------------------------------------------
# Lectura del resumen de k6. Anclado a "^  <nombre>....:" a proposito: k6 lista
# los nombres de metricas SIN valor antes del resumen, y un patron no anclado
# engancha esa lista y devuelve vacio -> se reportaria 0 siempre.
# ---------------------------------------------------------------------------
metrica() { grep -E "^[[:space:]]+$2\.+:" "$1" | head -1 | grep -oE '[0-9]+' | head -1; }

# p95/p99/p99.9 del ESCENARIO medido, no del global: el calentamiento tiene su
# propio escenario y no debe entrar en el veredicto.
stat_escenario() {
  local f="$1" fase="$2" cual="$3"
  # Busqueda por CAMPO con index(), no por expresion regular: awk -v procesa las
  # barras invertidas de la asignacion, asi que un 'p\(95\)' llegaba convertido
  # en el grupo de captura (95) y terminaba buscando "p95=". Con index() el
  # patron es texto literal y no hay nada que escapar.
  awk -v fase="$fase" -v cual="$cual" '
    $0 ~ "\\{ scenario:" fase " \\}" {
      for (i = 1; i <= NF; i++) {
        if (index($i, cual "=") == 1) {
          v = substr($i, length(cual) + 2)
          u = v; gsub(/[0-9.]/, "", u); gsub(/[^0-9.]/, "", v)
          k = (u == "s") ? 1000 : (u == "ms") ? 1 : (u == "us" || u == "\302\265s") ? 0.001 : 0.000001
          printf "%.2f", v * k; exit
        }
      }
    }' "$f"
}

# Una corrida es VALIDA si todas las respuestas fueron correctas y el motor
# alcanzo a publicar su resumen. Un backend muerto responde mas rapido que uno
# vivo: sin esta comprobacion, una topologia caida produce cifras excelentes.
corrida_valida() {
  local k6out="$1" shardlog="$2"
  local ok; ok="$(grep -E "^[[:space:]]+checks_succeeded" "$k6out" | grep -oE '[0-9]+\.[0-9]+%' | head -1)"
  [ "${ok%%.*}" = "100" ] || return 1
  grep -q ACUMULADO "$shardlog" 2>/dev/null || return 1
  return 0
}

ejecutar() {
  local grupo="$1" id="$2" hip="$3" fase="$4" perfil="$5" n="$6" vars="$7" criterio="$8" pregunta="$9"
  local dir="$OUT/$id"

  if [ -f "$dir/k6.txt" ] && grep -q ACUMULADO "$dir/shard.log" 2>/dev/null; then
    echo "  · $id — ya completa, se omite"; return 0
  fi
  mkdir -p "$dir"

  # Variables de la corrida. Se limpian SIEMPRE antes: un JOURNAL o un
  # SHARD_CPUS heredado de la corrida anterior falsearia esta.
  unset BIZ_MICROS BIZ_DIST JOURNAL SHARD_CPUS SHARD_CPUSET SHARD_MEM JFR_OPTS PEAK JFR
  export RUN_ID="$id"
  export SHARD_CPUS=0 SHARD_CPUSET="" SHARD_MEM=0 JOURNAL=off BIZ_DIST=mezcla JFR_OPTS=""
  local IFS_ANT="$IFS"; IFS=';'
  for kv in $vars; do export "${kv?}"; done
  IFS="$IFS_ANT"
  if [ "${JFR:-0}" = "1" ]; then
    export JFR_OPTS="-XX:StartFlightRecording=filename=/var/lib/engine/jfr/shard.jfr,settings=profile,dumponexit=true -XX:FlightRecorderOptions:stackdepth=64"
  fi

  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "  $id  ·  $hip  ·  fase=$fase perfil=$perfil N=$n  ·  $(date +%H:%M:%S)"
  echo "  $pregunta"
  echo "  $vars"
  levantar "$n"

  # La procedencia se VERIFICA, no se declara: una corrida anterior anuncio
  # S=8000us y arranco con S=0.
  local real; real="$($COMPOSE logs matching-shard-0 2>/dev/null | grep -m1 'modelo de logica' | sed 's/.*negocio: //')"
  echo "  motor: $real"
  if [ "${BIZ_MICROS:-0}" != "0" ] && ! grep -q "media=${BIZ_MICROS}us" <<<"$real"; then
    echo "  ✗ ABORTA: se pidió S=${BIZ_MICROS}us y el motor arrancó con: $real"
    echo -e "$id\t$hip\t$grupo\t$fase\t$n\t$vars\t$criterio\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tABORTADA\tno" >> "$RESULTADOS"
    return 1
  fi
  if [ "${SHARD_CPUS:-0}" != "0" ]; then
    local nano; nano="$(docker inspect "$($COMPOSE ps -q matching-shard-0)" --format '{{.HostConfig.NanoCpus}}' 2>/dev/null)"
    echo "  cgroup: NanoCpus=$nano (pedido: $SHARD_CPUS núcleos)"
  fi

  local smoke=""; [ "$perfil" = "corto" ] && smoke="-e SMOKE=1"
  # shellcheck disable=SC2086
  ( cd "$ROOT/load/k6" && k6 run $K6_OUT --tag corrida="$id" --tag hipotesis="$hip" \
      $smoke -e PHASE="$fase" -e PEAK="${PEAK:-84}" \
      --summary-export="$dir/k6.json" poc.js ) > "$dir/k6.txt" 2>&1

  # shellcheck disable=SC2086
  $COMPOSE stop $APP >/dev/null 2>&1 || true
  $COMPOSE logs --no-color 2>/dev/null \
    | grep -E "modelo de logica|runtime:|journal:|ACUMULADO|JOURNAL shard" > "$dir/shard.log" || true
  [ "${JFR:-0}" = "1" ] && perfilar_jfr "$dir"

  registrar "$grupo" "$id" "$hip" "$fase" "$n" "$vars" "$criterio" "$dir"
}

registrar() {
  local grupo="$1" id="$2" hip="$3" fase="$4" n="$5" vars="$6" criterio="$7" dir="$8"
  local k6="$dir/k6.txt" log="$dir/shard.log"

  local p95 p99 p999
  p95="$(stat_escenario "$k6" "$fase" 'p(95)')"
  p99="$(stat_escenario "$k6" "$fase" 'p(99)')"
  p999="$(stat_escenario "$k6" "$fase" 'p(99.9)')"
  local ordenes rechazos descartes tasa
  ordenes="$(metrica "$k6" iterations)"
  rechazos="$(metrica "$k6" orders_rejected_backpressure)"
  descartes="$(metrica "$k6" dropped_iterations)"
  tasa="$(grep -E "^[[:space:]]+iterations\.+:" "$k6" | grep -oE '[0-9.]+/s' | head -1)"

  # Percentiles internos: el maximo entre particiones, que es el que manda.
  local mp95 ep95 sp50
  # Se extrae el numero que sigue a la etiqueta, no el enesimo campo: "p50"
  # contiene digitos, asi que barrer los no-digitos convierte la propia etiqueta
  # en un campo y desplaza todo. Ese fue un error real: se publicaban p50 como
  # si fueran p95.
  read -r mp95 ep95 sp50 <<<"$(awk '
    /ACUMULADO/ {
      if (match($0, /total p50=[0-9]+us p95=[0-9]+us/)) {
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p95=[0-9]+/)) { v = substr(t, RSTART + 4, RLENGTH - 4) + 0; if (v > m) m = v }
      }
      if (match($0, /espera p50=[0-9]+us p95=[0-9]+us/)) {
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p95=[0-9]+/)) { v = substr(t, RSTART + 4, RLENGTH - 4) + 0; if (v > e) e = v }
      }
      if (match($0, /servicio p50=[0-9]+us/)) {
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p50=[0-9]+/)) { s = substr(t, RSTART + 4, RLENGTH - 4) + 0 }
      }
    } END { printf "%d %d %d", m, e, s }' "$log")"

  # DOS juicios distintos, y confundirlos fue un error real de este proyecto:
  #  - latencia_valida: ¿la cifra mide el sistema? Con descartes > 0 el generador
  #    se quedo sin clientes, el modelo abierto degenera en cerrado y la latencia
  #    pasa a ser (clientes / throughput) -- mide el generador, no el motor.
  #  - veredicto: ¿cumple el criterio? Solo tiene sentido si la latencia es valida.
  local valida="si"
  [ "${descartes:-0}" != "0" ] && valida="no"
  corrida_valida "$k6" "$log" || valida="no"

  local veredicto="observa"
  if [ "$criterio" = "p95<200" ]; then
    if [ "$valida" = "no" ]; then veredicto="NO MEDIBLE"
    elif [ -n "$p95" ] && [ "$(echo "$p95 < 200" | bc -l)" = "1" ]; then veredicto="CUMPLE"
    else veredicto="NO CUMPLE"; fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$id" "$hip" "$grupo" "$fase" "$n" "$vars" "$criterio" \
    "${p95:--}" "${p99:--}" "${p999:--}" "$mp95" "$ep95" "$sp50" \
    "${tasa:--}" "${ordenes:-0}" "${rechazos:-0}" "${descartes:-0}" "$veredicto" "$valida" >> "$RESULTADOS"

  printf "  → p95=%s ms · motor=%s us · espera=%s us · tasa=%s · descartes=%s · %s\n" \
    "${p95:--}" "$mp95" "$ep95" "${tasa:--}" "${descartes:-0}" "$veredicto"
  [ "$valida" = "no" ] && echo "  ⚠ latencia NO publicable (el generador se quedó sin clientes: mide su pool, no el motor)"
}

perfilar_jfr() {
  local dir="$1"
  local jdk; jdk="$(/usr/libexec/java_home -v 21 2>/dev/null)/bin/jfr"
  [ -x "$jdk" ] || { echo "  (sin herramienta jfr: se guarda la grabación sin resumir)"; }
  for s in 0 1; do
    # docker cp funciona con el contenedor detenido y evita traer otra imagen.
    $COMPOSE cp "matching-shard-$s:/var/lib/engine/jfr/shard.jfr" "$dir/shard-$s.jfr" >/dev/null 2>&1 || true
    [ -x "$jdk" ] && [ -s "$dir/shard-$s.jfr" ] && "$jdk" summary "$dir/shard-$s.jfr" > "$dir/shard-$s-eventos.txt" 2>&1
  done
  {
    echo "--- pausas que detienen la ejecución de la JVM ---"
    for s in 0 1; do
      [ -s "$dir/shard-$s.jfr" ] || continue
      for ev in jdk.GCPhasePause jdk.ExecuteVMOperation jdk.SafepointBegin; do
        [ -x "$jdk" ] && "$jdk" print --events "$ev" "$dir/shard-$s.jfr" 2>/dev/null \
          | grep -oE 'duration = [0-9,.]+ (ms|s|us)' \
          | awk -v e="$ev" -v s="$s" '{v=$3; gsub(",",".",v); u=$4; f=(u=="s")?1000:(u=="ms")?1:0.001; d=v*f; if(d>m)m=d; n++}
                                       END{printf "  shard-%s %-26s max %8.3f ms  (%d eventos)\n", s, e, m, n}'
      done
    done
  } > "$dir/pausas.txt" 2>&1
  cat "$dir/pausas.txt"
}

# ---------------------------------------------------------------------------
GRUPOS=("$@")
echo "══════════════════════════════════════════════════════════════"
echo "  EXPERIMENTO E01  ·  $(date)"
echo "  plan: $PLAN"
echo "  salida: $OUT"
[ "${#GRUPOS[@]}" -gt 0 ] && echo "  grupos: ${GRUPOS[*]}" || echo "  grupos: TODOS"
echo "══════════════════════════════════════════════════════════════"
$COMPOSE build
$COMPOSE up -d prometheus grafana >/dev/null 2>&1 || true

TOTAL=0
while IFS=$'\t' read -r grupo id hip fase perfil n vars criterio pregunta; do
  case "$grupo" in ''|'#'*) continue ;; esac
  if [ "${#GRUPOS[@]}" -gt 0 ]; then
    local_ok=0
    for g in "${GRUPOS[@]}"; do [ "$g" = "$grupo" ] && local_ok=1; done
    [ "$local_ok" = "1" ] || continue
  fi
  TOTAL=$((TOTAL+1))
  ejecutar "$grupo" "$id" "$hip" "$fase" "$perfil" "$n" "$vars" "$criterio" "$pregunta"
done < "$PLAN"

# shellcheck disable=SC2086
$COMPOSE stop $APP >/dev/null 2>&1 || true

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  RESUMEN · $TOTAL corridas · $OUT"
echo "══════════════════════════════════════════════════════════════"
column -t -s $'\t' "$RESULTADOS" | cut -c1-190
echo ""
echo "  Tablero: http://localhost:3000/d/e01-motor-emparejamiento"
echo "  Tabla:   $RESULTADOS"
