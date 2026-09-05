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


def texto(titulo, cuerpo, y, h=5):
    """La explicación va ANCHA y arriba del bloque, no en una columna al lado.

    En columna compite por espacio con las gráficas y se lee en vertical, que es
    justo lo contrario de lo que hace falta: primero entender la apuesta, después
    mirar la evidencia."""
    return {"type": "text", "title": titulo, "gridPos": {"h": h, "w": 24, "x": 0, "y": y},
            "options": {"mode": "markdown", "content": cuerpo}}


def sin_repetidas(titulo, series):
    """Dos series con el mismo nombre vuelven ilegible un panel: no hay forma de
    saber cuál es cuál. Pasó de verdad --la corrida del pico devuelve DOS series,
    el escenario del pico y el del retorno-- así que se comprueba, no se confía."""
    vistas, repes = set(), []
    for etiqueta, _ in series:
        if etiqueta in vistas:
            repes.append(etiqueta)
        vistas.add(etiqueta)
    if repes:
        raise SystemExit("panel «%s»: etiquetas repetidas -> %s" % (titulo, repes))
    return series


def lineas(titulo, series, x, y, w, h, desc, unidad="s", pasos=None, apilado=False, mini=0):
    """Cómo se comportó la prueba mientras corría. Cada corrida es su propio episodio
    en la línea de tiempo, así que se ven una tras otra sin pisarse."""
    return {"type": "timeseries", "title": titulo, "datasource": DS, "description": desc,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "targets": [objetivo(e, l, chr(65 + i))
                        for i, (l, e) in enumerate(sin_repetidas(titulo, series))],
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "fieldConfig": {"defaults": {"unit": unidad, "min": mini, "custom": {
                "drawStyle": "line", "lineWidth": 2, "fillOpacity": 12 if apilado else 5,
                "showPoints": "never", "spanNulls": False,
                "stacking": {"mode": "normal" if apilado else "none", "group": "A"},
                "thresholdsStyle": {"mode": "dashed" if pasos else "off"}},
                "thresholds": {"mode": "absolute", "steps": pasos or [{"color": "text", "value": None}]}},
                "overrides": []}}


def barras(titulo, series, x, y, w, h, desc, unidad="s", dec=3, tope=None, pasos=None):
    """Una barra por corrida. El valor siempre se ve, aunque la barra sature."""
    return {"type": "bargauge", "title": titulo, "datasource": DS, "description": desc,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "targets": [objetivo(e, l, chr(65 + i), True)
                        for i, (l, e) in enumerate(sin_repetidas(titulo, series))],
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
    ids = lambda g: [f["id"] for f in por.get(g, [])]
    ser = lambda fs: [(corto(f), p95_de([f["id"]])) for f in fs]

    def lat(fs, etiq=None, con_retorno=False):
        """Una serie por consulta, con el escenario EXPLÍCITO.

        Filtrar solo por «no es calentamiento» devuelve dos series en las corridas
        de pico --el pico y el retorno-- y las dos heredaban la misma etiqueta.
        El `max()` de fuera garantiza además que nunca salga más de una línea por
        consulta, aunque k6 agregue etiquetas nuevas."""
        out = []
        for f in fs:
            e = etiq(f) if etiq else corto(f)
            out.append((e, 'max(k6_grpc_req_duration_p95{corrida="%s",scenario="%s"})'
                        % (f["id"], f["fase"])))
            if con_retorno and f["fase"] == "f2":
                out.append(("retorno a régimen · 17 órd/s",
                            'max(k6_grpc_req_duration_p95{corrida="%s",scenario="f3"})' % f["id"]))
        return out

    def espera_servicio(g):
        r = '|'.join(ids(g))
        return [("esperando en fila", 'max(engine_window_wait_micros{quantile="0.95",corrida=~"%s"})' % r),
                ("trabajo real", 'max(engine_window_service_micros{quantile="0.95",corrida=~"%s"})' % r)]

    P, y = [], 0

    def fila(t, colapsada=False, paneles=None):
        nonlocal y
        P.append({"type": "row", "title": t, "collapsed": colapsada,
                  "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": paneles or []})
        y += 1

    # ───────────────────────────── H1 ─────────────────────────────
    fila("H1 · Si el motor procesa de a una orden, en memoria y sin esperar a nadie, responde a tiempo")
    P.append(texto("La apuesta", """
**Si** el motor procesa las órdenes una por una, en memoria y sin esperar a nadie —ni base de datos, ni candados, ni otros hilos—, **entonces** responde a tiempo en operación normal. Con una cláusula: el registro durable va **fuera** del camino crítico.

**Cómo leer este bloque.** Las barras dicen *si cumple* — verde por debajo de los 200 ms del contrato, rojo por encima. Las líneas dicen *cómo se comportó mientras corría*: si la latencia se mantuvo plana o se fue degradando, y si el tiempo se fue esperando en fila o trabajando. · En la bitácora se mira la **mediana del motor**, no el p95: el efecto es de medio milisegundo y el p95 no lo distingue del ruido.
""", y))
    y += 5
    P.append(barras("¿Responde a tiempo? (p95 contra el límite de 200 ms)",
                    ser(por.get("oficial", [])), 0, y, 8, 9,
                    "Las tres fases contractuales."))
    P.append(barras("Lo que cuesta registrar cada orden (mediana del motor)",
                    [(corto(f), mediana_motor([f["id"]])) for f in por.get("h1-bitacora", [])],
                    8, y, 8, 9,
                    "En paralelo la bitácora corre junto al cruce y el cliente no la paga. "
                    "En serie va delante, y la orden espera al disco.",
                    unidad="µs", dec=0, pasos=[{"color": "blue", "value": None}]))
    P.append(lineas("Cómo evolucionó la latencia en cada fase",
                    lat(por.get("oficial", []), con_retorno=True), 16, y, 8, 9,
                    "Cada fase es un episodio propio en la línea de tiempo. Una latencia plana durante "
                    "media hora dice más que un percentil: significa que el sistema no se degrada con el tiempo.",
                    pasos=VERDE_ROJO))
    y += 9
    P.append(lineas("¿El tiempo se fue esperando en fila, o trabajando? (fases oficiales)",
                    espera_servicio("oficial"), 0, y, 24, 8,
                    "Apiladas, las dos suman la latencia interna. Si domina la ESPERA hay que agregar "
                    "particiones; si domina el TRABAJO hay que abaratar la orden.",
                    unidad="µs", apilado=True))
    y += 8

    # ───────────────────────────── H2 ─────────────────────────────
    fila("H2 · Si las órdenes se reparten entre varios motores, el sistema aguanta el pico")
    P.append(texto("La apuesta", """
**Si** las órdenes se reparten entre varios motores independientes —cada activo siempre en el mismo motor—, **entonces** el sistema aguanta el pico de mercado sin dejar de responder a tiempo. La ficha exige además decir **cuántos motores bastan**: ese número no se supone, se mide.

**Cómo leer este bloque.** La primera barra busca el mínimo que cumple; la segunda pregunta si una partición cabe en un núcleo, que es lo que el patrón implica. El barrido de abajo busca **a qué tasa deja de cumplir** cada topología: si la capacidad escala, el quiebre debería moverse en proporción —el doble con dos particiones, el cuádruple con cuatro—. Al lado, cómo se degrada cada una mientras sube la carga.
""", y))
    y += 5
    P.append(barras("¿Cuántas particiones bastan para el pico contractual?",
                    ser(por.get("h2-minimo", [])), 0, y, 8, 9,
                    "La misma carga de 84 órd/s repartida entre 1, 2 y 4 particiones."))
    P.append(barras("¿Cabe una partición en un núcleo?",
                    ser(por.get("h2-cpu", [])), 8, y, 8, 9,
                    "El prototipo corre sobre 14 CPU, cosa que ningún despliegue real hace."))
    P.append(lineas("¿Se reparte parejo entre particiones?",
                    [("partición {{shard}}",
                      'sum by (shard) (rate(engine_orders_total{corrida=~"%s"}[1m]))'
                      % "|".join(ids("h2-minimo") + ids("oficial")))],
                    16, y, 8, 9,
                    "Órdenes por segundo que resuelve cada partición. Con los 36 activos del conjunto "
                    "el reparto es 18/18 con dos y 9/9/9/9 con cuatro. Un desbalance aquí se disfrazaría "
                    "de problema de latencia.", unidad="reqps"))
    y += 9
    P.append(barras("¿A qué tasa deja de cumplir, según cuántas particiones haya?",
                    [("%s · %s" % ("1 partición" if f["n"] == "1" else "%s particiones" % f["n"], corto(f)),
                      p95_de([f["id"]])) for f in por.get("h2-quiebre", [])],
                    0, y, 12, 14,
                    "El punto de quiebre es la primera tasa en rojo. La barra satura arriba de 0,5 s, "
                    "pero el número siempre se ve.", tope=0.5))
    P.append(lineas("Cómo se degrada cada topología al subir la carga",
                    lat(por.get("h2-quiebre", []),
                        etiq=lambda f: "%s · %s" % ("1 partición" if f["n"] == "1"
                                                    else "%s particiones" % f["n"], corto(f))),
                    12, y, 12, 14,
                    "Cada corrida del barrido, en su propio momento. Lo que se busca no es el valor final "
                    "sino la FORMA: mientras hay holgura la línea es plana; cerca del techo se dispara.",
                    pasos=VERDE_ROJO))
    y += 14

    # ──────────────────────────── H2b ─────────────────────────────
    fila("H2b · Si todo el pico cae en un solo activo, el sistema deja de responder a tiempo")
    P.append(texto("La apuesta", """
**Si** todo el pico se concentra en un solo activo, **entonces** el sistema deja de responder a tiempo **antes** de llegar al pico completo. Es el caso donde repartir no ayuda: las órdenes de un activo las atiende siempre el mismo motor y los demás no pueden echarle una mano.

**Cómo leer este bloque.** Si la barra de 84 órd/s —el pico contractual— sale **verde**, la apuesta queda **refutada**: la partición caliente aguanta lo que se predijo que no aguantaría, y una hipótesis refutada también es un resultado. A la derecha, la cola formándose: es el mecanismo del quiebre, no su veredicto.
""", y))
    y += 5
    P.append(barras("¿A qué tasa se cae una partición caliente?",
                    ser(por.get("h2b-caliente", [])), 0, y, 8, 10,
                    "Todo el tráfico sobre un solo activo, subiendo la tasa.", tope=0.5))
    P.append(lineas("La cola formándose sobre la partición caliente",
                    espera_servicio("h2b-caliente"), 8, y, 8, 10,
                    "El trabajo real se mantiene plano —no depende de la carga— mientras la espera crece. "
                    "Esa separación ES la saturación.", unidad="µs", apilado=True))
    P.append(lineas("¿El generador logró sostener la tasa que pidió?",
                    [(corto(f), 'sum(rate(k6_iterations_total{corrida="%s"}[1m]))' % f["id"])
                     for f in por.get("h2b-caliente", [])],
                    16, y, 8, 10,
                    "Cuando la tasa lograda se despega de la pedida, el motor topó. A partir de ahí la "
                    "latencia mide el límite del generador y no el del sistema: deja de ser publicable.",
                    unidad="reqps"))
    y += 10

    # ────────────────────────── presupuesto ───────────────────────
    fila("El entregable · ¿Cuánto puede costar procesar una orden?")
    P.append(texto("Por qué esto, y no un percentil", """
El prototipo **no implementa la lógica de negocio** —validar, verificar riesgo y saldos, calcular comisiones, generar el trato—. Como el motor procesa de a una, ese costo se serializa y fija el techo: **techo = 1 ÷ costo por orden**. Medir la capacidad con el cruce de juguete del prototipo mediría una estructura de datos, no un motor de bolsa.

Por eso el entregable no es una cifra de latencia sino un **presupuesto**: *el diseño cumple el contrato mientras procesar una orden cueste menos de X*. Cuando la lógica real exista, se mide su costo y se compara contra X — la afirmación es verificable desde hoy.

**Cómo leer este bloque.** El presupuesto es el último costo que queda en verde. Y a la derecha, el mecanismo: el trabajo sigue al costo declarado, pero lo que dispara la latencia es la **espera**.
""", y, h=6))
    y += 6
    P.append(barras("Con el pico repartido entre 2 particiones",
                    ser([f for f in por.get("presupuesto", []) if f["fase"] == "f2"]),
                    0, y, 8, 9, "Cuánto puede costar una orden sin romper el contrato.", tope=0.4))
    P.append(barras("Con todo el pico en una sola partición",
                    ser([f for f in por.get("presupuesto", []) if f["fase"] == "f4"]),
                    8, y, 8, 9, "El mismo barrido en el peor caso.", tope=0.4))
    P.append(lineas("El trabajo sigue al costo; la espera es la que explota",
                    espera_servicio("presupuesto"), 16, y, 8, 9,
                    "Al subir el costo por orden, el trabajo real sube en proporción y de forma predecible. "
                    "La espera no: crece de golpe cuando la ocupación se acerca a uno. Repartir la carga "
                    "ataca la espera; nada ataca al trabajo salvo abaratar la orden.",
                    unidad="µs", apilado=True))
    y += 9

    # ─────────────────────── detalle, plegado ─────────────────────
    mapeo = [{"type": "value", "options": {
        f["id"]: {"text": nombre(f), "index": i} for i, f in enumerate(filas)}}]
    C = 'corrida=~"$corrida"'
    detalle = [
        {"type": "table", "title": "Con qué corrió la corrida seleccionada", "datasource": DS,
         "description": "Sin esto, dos corridas con resultados distintos son indistinguibles.",
         "gridPos": {"h": 8, "w": 24, "x": 0, "y": y + 1},
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
    fila("Procedencia de UNA corrida — desplegar y elegirla arriba", True, detalle)

    seleccion = ",".join("%s : %s" % (nombre(f), f["id"]) for f in filas)
    return {
        "uid": "e01-motor-emparejamiento",
        "title": "E01 · Motor de emparejamiento",
        "description": "Un bloque por hipótesis: la apuesta arriba, y debajo las barras que dicen si cumple "
                       "y las líneas que dicen cómo se comportó mientras corría.",
        "tags": ["e01", "arqsoft"], "timezone": "browser", "editable": True,
        "schemaVersion": 39, "version": 5, "refresh": "30s",
        "time": {"from": "now-24h", "to": "now"},
        "templating": {"list": [{
            "name": "corrida", "label": "Corrida (solo para la procedencia de abajo)", "type": "custom",
            "query": seleccion, "multi": False, "includeAll": False,
            "current": {"selected": True, "text": nombre(filas[0]), "value": filas[0]["id"]}}]},
        "panels": P,
    }


def verificar(tablero, prometheus="http://localhost:9090"):
    """Comprueba contra Prometheus que ninguna GRÁFICA dibuje dos líneas con el
    mismo nombre.

    La guarda estática solo ve etiquetas repetidas en el archivo. El caso real
    fue otro: UNA consulta que devuelve varias series --la corrida del pico
    devuelve el escenario del pico y el del retorno-- y las dos heredan la misma
    etiqueta. Eso solo se ve preguntándole a Prometheus.

    Las tablas se saltan: ahí varias filas es lo correcto.
    """
    import urllib.parse, urllib.request, time
    fin = int(time.time()); ini = fin - 86400
    def todos(t):
        for p in t["panels"]:
            if p["type"] == "row":
                for q in p.get("panels", []):
                    yield q
            else:
                yield p
    malos = 0
    for p in todos(tablero):
        if p["type"] not in ("timeseries", "bargauge"):
            continue
        for tg in p.get("targets", []):
            if "{{" in tg.get("legendFormat", ""):
                continue  # la leyenda distingue las series por sí sola
            e = tg["expr"].replace("$__range", "24h")
            u = (prometheus + "/api/v1/query_range?query=" + urllib.parse.quote(e)
                 + "&start=%d&end=%d&step=300" % (ini, fin))
            try:
                r = json.load(urllib.request.urlopen(u, timeout=10))["data"]["result"]
            except Exception:
                return None  # sin Prometheus a mano no se puede comprobar
            if len(r) > 1:
                print("  ✗ «%s» / «%s» dibuja %d líneas con el mismo nombre"
                      % (p["title"], tg["legendFormat"], len(r)))
                malos += 1
    return malos


if __name__ == "__main__":
    filas = leer_plan()
    tablero = construir(filas)
    io.open(SALIDA, "w", encoding="utf-8").write(
        json.dumps(tablero, indent=2, ensure_ascii=False) + "\n")
    print("tablero generado desde %d corridas del plan -> %s" % (len(filas), SALIDA))
    if "--verificar" in sys.argv:
        malos = verificar(tablero)
        if malos is None:
            print("  (Prometheus no responde: no se pudo comprobar contra datos reales)")
        elif malos:
            sys.exit("  %d gráfica(s) con líneas homónimas" % malos)
        else:
            print("  comprobado contra Prometheus: ninguna gráfica dibuja líneas homónimas")
