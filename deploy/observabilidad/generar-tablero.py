#!/usr/bin/env python3
"""Genera el tablero de Grafana A PARTIR del plan de corridas.

Se hace así por una razón concreta: el tablero muestra el nombre de cada
corrida y el plan es quien lo define. Escritos a mano en dos sitios, se
desincronizan a la primera corrida que se agregue.

En disco las corridas tienen id corto (`q-n2-220`) porque es un nombre de
directorio. En el tablero se ven como «Quiebre · 2 particiones · 220 órd/s»,
que es lo que alguien necesita leer. La traducción se deriva del plan.

    python3 deploy/observabilidad/generar-tablero.py
"""
import io, json, os, re, sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLAN = os.path.join(RAIZ, "load", "plan.tsv")
SALIDA = os.path.join(RAIZ, "deploy", "observabilidad", "grafana", "dashboards", "e01.json")
DS = {"type": "prometheus", "uid": "prometheus-e01"}


def leer_plan():
    filas = []
    for linea in io.open(PLAN, encoding="utf-8"):
        if linea.startswith("#") or not linea.strip():
            continue
        c = linea.rstrip("\n").split("\t")
        if len(c) < 9:
            continue
        filas.append(dict(zip(
            "grupo id hip fase perfil n vars crit preg".split(), c)))
    return filas


def var(fila, clave, defecto=None):
    m = re.search(r"(?:^|;)%s=([^;]*)" % clave, fila["vars"])
    return m.group(1) if m else defecto


def nombre(f):
    """El nombre legible de una corrida, derivado de lo que la corrida ES."""
    n, peak = f["n"], var(f, "PEAK", "84")
    s = int(var(f, "BIZ_MICROS", "0")) // 1000
    part = "1 partición" if n == "1" else "%s particiones" % n
    g = f["grupo"]
    if g == "oficial":
        return {"f1": "OFICIAL · régimen · 17 órd/s · 12 min",
                "f2": "OFICIAL · pico 5× · 84 órd/s · 30 min",
                "f4": "OFICIAL · todo el pico en UN activo"}[f["fase"]]
    if g == "h2-minimo":
        return "¿Cuántas bastan? · %s · 84 órd/s" % part
    if g == "h2-quiebre":
        return "Quiebre · %s · %s órd/s" % (part, peak)
    if g == "h2b-caliente":
        return "Activo caliente · %s órd/s en UN activo" % peak
    if g == "h1-bitacora":
        return "Bitácora · %s" % {"off": "apagada", "paralelo": "en paralelo",
                                  "serie": "en serie (camino crítico)"}[var(f, "JOURNAL")]
    if g == "h2-cpu":
        q = var(f, "SHARD_CPUS")
        return "CPU · %s" % ("sin límite" if not q else "medio núcleo" if q == "0.5"
                             else "1 núcleo" if q == "1.0" else "%s núcleos" % q.rstrip("0").rstrip("."))
    if g == "presupuesto":
        return "%s · orden de %d ms" % (
            "Presupuesto caliente" if f["fase"] == "f4" else "Presupuesto", s)
    if g == "forma":
        return "Forma · lognormal (cola sin tope)"
    if g == "jfr":
        return "Atascos · grabación de la JVM"
    return f["id"]


def corto(f):
    """La etiqueta dentro de su propia comparación: solo el eje que cambia.

    En un panel que compara particiones, «1 partición» dice todo; repetir
    «Quiebre · 1 partición · 90 órd/s» en cada barra es ruido, porque el resto
    ya lo dice el título del panel.
    """
    n, peak = f["n"], var(f, "PEAK", "84")
    s = int(var(f, "BIZ_MICROS", "0")) // 1000
    g = f["grupo"]
    if g == "oficial":
        return {"f1": "régimen · 17 órd/s", "f2": "pico 5× · 84 órd/s",
                "f4": "todo en UN activo"}[f["fase"]]
    if g == "h2-minimo":
        return "1 partición" if n == "1" else "%s particiones" % n
    if g in ("h2-quiebre", "h2b-caliente"):
        return "%s órd/s" % peak
    if g == "h1-bitacora":
        return {"off": "apagada", "paralelo": "en paralelo",
                "serie": "en serie"}[var(f, "JOURNAL")]
    if g == "h2-cpu":
        q = var(f, "SHARD_CPUS")
        return ("sin límite" if not q else "medio núcleo" if q == "0.5"
                else "1 núcleo" if q == "1.0" else "%s núcleos" % q.rstrip("0").rstrip("."))
    if g == "presupuesto":
        return "%d ms" % s
    return f["id"]


def objetivo(expr, leyenda="", ref="A", instantaneo=False):
    return {"datasource": DS, "expr": expr, "legendFormat": leyenda, "refId": ref,
            "editorMode": "code", "range": not instantaneo, "instant": instantaneo}


# ---------------------------------------------------------------------------
# El tablero se organiza POR HIPÓTESIS, no por un filtro.
#
# Con un selector, el tablero no cuenta nada: hay que saber de antemano qué
# corrida mirar. Agrupado por hipótesis, el tablero ES el argumento — cada
# bloque dice la apuesta y debajo trae las corridas que la ponen a prueba.
#
# Y se compara con barras, no con series superpuestas: para «¿cuál de estas
# cuatro configuraciones cumple?», una barra por configuración se lee de un
# vistazo y cuarenta líneas encima no se leen nunca.
# ---------------------------------------------------------------------------

LIMITE = 0.2  # el contrato: 200 ms, en segundos (la unidad en que k6 publica)
VERDE_ROJO = [{"color": "green", "value": None}, {"color": "red", "value": LIMITE}]
MEDIDO = 'scenario!="calentamiento"'


def texto(titulo, cuerpo, x, y, w=6, h=9):
    return {"type": "text", "title": titulo, "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "options": {"mode": "markdown", "content": cuerpo}}


def barras(titulo, series, x, y, w, h, desc, unidad="s", dec=3, tope=None, pasos=None):
    """Una barra por corrida. El valor siempre se ve, aunque la barra sature."""
    return {"type": "bargauge", "title": titulo, "datasource": DS, "description": desc,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "targets": [objetivo(e, l, chr(65 + i), True) for i, (l, e) in enumerate(series)],
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "orientation": "horizontal", "displayMode": "gradient",
                        "showUnfilled": True, "valueMode": "color", "namePlacement": "left",
                        "minVizWidth": 8, "minVizHeight": 16},
            "fieldConfig": {"defaults": {"unit": unidad, "decimals": dec, "min": 0, "max": tope,
                                         "thresholds": {"mode": "absolute",
                                                        "steps": pasos or VERDE_ROJO}},
                            "overrides": []}}


def p95_de(ids):
    """El peor p95 por ventana de esas corridas. Más estricto que el p95 de la corrida."""
    return 'max(max_over_time(k6_grpc_req_duration_p95{corrida=~"%s",%s}[$__range]))' % (
        "|".join(ids), MEDIDO)


def mediana_motor(ids):
    return 'max(max_over_time(engine_window_latency_micros{quantile="0.5",corrida=~"%s"}[$__range]))' % "|".join(ids)


def construir(filas):
    por = {}
    for f in filas:
        por.setdefault(f["grupo"], []).append(f)
    ser = lambda fs, etiq=None: [((etiq(f) if etiq else corto(f)), p95_de([f["id"]])) for f in fs]

    P, y = [], 0

    def fila(t, colapsada=False, paneles=None):
        nonlocal y
        P.append({"type": "row", "title": t, "collapsed": colapsada,
                  "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
                  "panels": paneles or []})
        y += 1

    # ───────────────────────────── H1 ─────────────────────────────
    fila("H1 · Si el motor procesa de a una orden, en memoria y sin esperar a nadie, responde a tiempo")
    P.append(texto("La apuesta", """
**Si** el motor procesa las órdenes una por una, en memoria y sin esperar a nadie
—ni base de datos, ni candados, ni otros hilos—, **entonces** responde a tiempo
en operación normal.

**Cómo leerlo.** Verde = por debajo de los 200 ms del contrato. Rojo = no cumple.

La cláusula extra: el registro durable va **fuera** del camino crítico. Se prueba
comparando las tres disposiciones de la bitácora. Ahí se mira la **mediana del
motor**, no el p95: el efecto es de medio milisegundo y el p95 no lo distingue
del ruido.
""", 0, y))
    P.append(barras("¿Responde a tiempo? (p95 contra el límite de 200 ms)",
                    ser(por.get("oficial", [])), 6, y, 9, 9,
                    "Las tres fases contractuales. Verde: cumple. Rojo: no."))
    P.append(barras("Lo que cuesta registrar cada orden (mediana del motor)",
                    [(corto(f), mediana_motor([f["id"]])) for f in por.get("h1-bitacora", [])],
                    15, y, 9, 9,
                    "En paralelo la bitácora corre junto al cruce y el cliente no la paga. "
                    "En serie va delante, y la orden espera al disco.",
                    unidad="µs", dec=0, pasos=[{"color": "blue", "value": None}]))
    y += 9

    # ───────────────────────────── H2 ─────────────────────────────
    fila("H2 · Si las órdenes se reparten entre varios motores, el sistema aguanta el pico")
    P.append(texto("La apuesta", """
**Si** las órdenes se reparten entre varios motores independientes —cada activo
siempre en el mismo motor—, **entonces** el sistema aguanta el pico de mercado
sin dejar de responder a tiempo.

La ficha exige además decir **cuántos motores bastan**: ese número no se supone,
se mide.

**Cómo leerlo.** El primer panel busca el mínimo que cumple. El segundo pregunta
si una partición cabe en un núcleo, que es lo que el patrón implica. El tercero
busca **a qué tasa deja de cumplir** cada topología: si la capacidad escala,
el quiebre debería moverse en proporción al número de particiones.
""", 0, y))
    P.append(barras("¿Cuántas particiones bastan para el pico contractual?",
                    ser(por.get("h2-minimo", [])), 6, y, 9, 9,
                    "La misma carga de 84 órd/s repartida entre 1, 2 y 4 particiones. "
                    "La menor que quede verde es el mínimo que satisface el contrato."))
    P.append(barras("¿Cabe una partición en un núcleo?",
                    ser(por.get("h2-cpu", [])), 15, y, 9, 9,
                    "El prototipo corre sobre 14 CPU, cosa que ningún despliegue real hace. "
                    "Aquí se confina cada partición y se mide qué cuesta."))
    y += 9
    P.append(barras("¿A qué tasa deja de cumplir, según cuántas particiones haya?",
                    [("%s · %s" % ("1 partición" if f["n"] == "1" else "%s particiones" % f["n"],
                                   corto(f)), p95_de([f["id"]]))
                     for f in por.get("h2-quiebre", [])],
                    0, y, 24, 14,
                    "El punto de quiebre es la primera tasa que se pone en rojo. Si la capacidad "
                    "escala agregando particiones, ese punto debería moverse en proporción: el doble "
                    "con dos, el cuádruple con cuatro. La barra satura arriba de 0,5 s, pero el número "
                    "siempre se ve.", tope=0.5))
    y += 14

    # ──────────────────────────── H2b ─────────────────────────────
    fila("H2b · Si todo el pico cae en un solo activo, el sistema deja de responder a tiempo")
    P.append(texto("La apuesta", """
**Si** todo el pico se concentra en un solo activo, **entonces** el sistema deja
de responder a tiempo **antes** de llegar al pico completo.

Es el caso donde repartir no ayuda: las órdenes de un activo las atiende siempre
el mismo motor y los demás no pueden echarle una mano.

**Cómo leerlo.** Si la barra de 84 órd/s —el pico contractual— sale **verde**,
la apuesta queda **refutada**: la partición caliente aguanta lo que se predijo
que no aguantaría. Y una hipótesis refutada también es un resultado.
""", 0, y))
    P.append(barras("¿A qué tasa se cae una partición caliente?",
                    ser(por.get("h2b-caliente", [])), 6, y, 18, 9,
                    "Todo el tráfico sobre un solo activo, subiendo la tasa. 84 órd/s es el pico "
                    "contractual; el resto explora dónde está el quiebre.", tope=0.5))
    y += 9

    # ────────────────────────── presupuesto ───────────────────────
    fila("El entregable · ¿Cuánto puede costar procesar una orden?")
    P.append(texto("Por qué esto y no un percentil", """
El prototipo **no implementa la lógica de negocio** —validar, verificar riesgo y
saldos, calcular comisiones, generar el trato—. Como el motor procesa de a una,
ese costo se serializa y fija el techo: **techo = 1 ÷ costo por orden**.

Por eso el entregable no es una cifra de latencia sino un **presupuesto**: *el
diseño cumple el contrato mientras procesar una orden cueste menos de X*. Cuando
la lógica real exista, se mide su costo y se compara contra X.

**Cómo leerlo.** El presupuesto es el último costo que queda en verde.
""", 0, y))
    P.append(barras("Con el pico repartido entre 2 particiones",
                    ser([f for f in por.get("presupuesto", []) if f["fase"] == "f2"]),
                    6, y, 9, 9, "Cuánto puede costar una orden sin romper el contrato.", tope=0.4))
    P.append(barras("Con todo el pico en una sola partición",
                    ser([f for f in por.get("presupuesto", []) if f["fase"] == "f4"]),
                    15, y, 9, 9, "El mismo barrido en el peor caso.", tope=0.4))
    y += 9

    # ─────────────────────── detalle, plegado ─────────────────────
    mapeo = [{"type": "value", "options": {
        f["id"]: {"text": nombre(f), "index": i} for i, f in enumerate(filas)}}]
    C = 'corrida=~"$corrida"'
    detalle = [
        {"type": "timeseries", "title": "Lo que espera el cliente, contra el límite de 200 ms",
         "datasource": DS, "gridPos": {"h": 9, "w": 12, "x": 0, "y": y + 1},
         "description": "El calentamiento se dibuja aparte porque aporta tráfico y no cuenta para el veredicto.",
         "targets": [objetivo('k6_grpc_req_duration_p95{%s,%s}' % (C, MEDIDO), "p95", "A"),
                     objetivo('k6_grpc_req_duration_p99{%s,%s}' % (C, MEDIDO), "p99", "B"),
                     objetivo('k6_grpc_req_duration_p95{%s,scenario="calentamiento"}' % C, "calentamiento (no cuenta)", "C")],
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}},
         "fieldConfig": {"defaults": {"unit": "s", "custom": {
             "drawStyle": "line", "lineWidth": 2, "fillOpacity": 6, "showPoints": "never",
             "spanNulls": True, "thresholdsStyle": {"mode": "dashed"}},
             "thresholds": {"mode": "absolute", "steps": VERDE_ROJO}}, "overrides": []}},
        {"type": "timeseries", "title": "¿Se va el tiempo esperando, o trabajando?",
         "datasource": DS, "gridPos": {"h": 9, "w": 12, "x": 12, "y": y + 1},
         "description": "Si crece la ESPERA, hay que agregar particiones: la orden hace fila. "
                        "Si crece el TRABAJO, hay que abaratar la orden.",
         "targets": [objetivo('engine_window_wait_micros{quantile="0.95",%s}' % C, "esperando en fila · partición {{shard}}", "A"),
                     objetivo('engine_window_service_micros{quantile="0.95",%s}' % C, "trabajo real · partición {{shard}}", "B")],
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}},
         "fieldConfig": {"defaults": {"unit": "µs", "min": 0, "custom": {
             "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10, "showPoints": "never",
             "spanNulls": True, "stacking": {"mode": "normal", "group": "A"}}}, "overrides": []}},
        {"type": "table", "title": "Con qué corrió", "datasource": DS,
         "description": "Sin esto, dos corridas con resultados distintos son indistinguibles.",
         "gridPos": {"h": 7, "w": 24, "x": 0, "y": y + 10},
         "targets": [objetivo('engine_info{%s}' % C, "", "A", True),
                     objetivo('engine_available_processors{%s}' % C, "", "B", True),
                     objetivo('engine_ceiling_orders_per_second{%s}' % C, "", "C", True),
                     objetivo('engine_operating_point_micros{%s}' % C, "", "D", True)],
         "transformations": [
             {"id": "merge", "options": {}},
             {"id": "organize", "options": {
                 "excludeByName": {"Time": True, "__name__": True, "job": True, "instance": True,
                                   "experimento": True, "Value #A": True},
                 "renameByName": {
                     "corrida": "Corrida", "shard": "Partición",
                     "forma": "Forma del costo por orden", "cs2": "Variabilidad del costo (Cs²)",
                     "journal": "Bitácora", "Value #B": "CPU que ve la máquina virtual",
                     "Value #C": "Techo teórico (órdenes/s)", "Value #D": "Costo medio por orden (µs)"}}}],
         "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [
             {"matcher": {"id": "byName", "options": "Corrida"},
              "properties": [{"id": "mappings", "value": mapeo}]}]}},
    ]
    fila("Detalle de UNA corrida en el tiempo — desplegar y elegirla arriba", True, detalle)

    seleccion = ",".join("%s : %s" % (nombre(f), f["id"]) for f in filas)
    return {
        "uid": "e01-motor-emparejamiento",
        "title": "E01 · Motor de emparejamiento",
        "description": "Un bloque por hipótesis: la apuesta, y debajo las corridas que la ponen a prueba. "
                       "Verde es cumple, rojo es no cumple. El último bloque, plegado, trae el detalle "
                       "en el tiempo de una corrida.",
        "tags": ["e01", "arqsoft"], "timezone": "browser", "editable": True,
        "schemaVersion": 39, "version": 4, "refresh": "30s",
        "time": {"from": "now-24h", "to": "now"},
        "templating": {"list": [{
            "name": "corrida", "label": "Corrida (solo para el detalle de abajo)", "type": "custom",
            "query": seleccion, "multi": False, "includeAll": False,
            "current": {"selected": True, "text": nombre(filas[0]), "value": filas[0]["id"]}}]},
        "panels": P,
    }


if __name__ == "__main__":
    filas = leer_plan()
    io.open(SALIDA, "w", encoding="utf-8").write(
        json.dumps(construir(filas), indent=2, ensure_ascii=False) + "\n")
    print("tablero generado desde %d corridas del plan -> %s" % (len(filas), SALIDA))
