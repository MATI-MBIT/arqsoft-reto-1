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


def objetivo(expr, leyenda="", ref="A", instantaneo=False):
    return {"datasource": DS, "expr": expr, "legendFormat": leyenda, "refId": ref,
            "editorMode": "code", "range": not instantaneo, "instant": instantaneo}


def construir(filas):
    mapeo = [{"type": "value", "options": {
        f["id"]: {"text": nombre(f), "index": i} for i, f in enumerate(filas)}}]
    seleccion = ",".join("%s : %s" % (nombre(f), f["id"]) for f in filas)
    C = 'corrida=~"$corrida"'
    MEDIDO = 'scenario!="calentamiento"'
    VERDE_ROJO = [{"color": "green", "value": None}, {"color": "red", "value": 0.2}]

    paneles = [
        {"type": "row", "title": "Las corridas del plan — una fila cada una",
         "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "panels": []},

        {"type": "table", "title": "¿Cuál cumple y cuál no?", "datasource": DS,
         "description": "Verde: el percentil 95 quedó bajo los 200 ms del contrato. Rojo: no. "
                        "Naranja en «se quedaron fuera»: el generador se quedó sin clientes y "
                        "la latencia de esa fila mide su propio límite, no el motor.",
         "gridPos": {"h": 14, "w": 24, "x": 0, "y": 1},
         "targets": [
             objetivo('max by (corrida) (max_over_time(k6_grpc_req_duration_p95{%s}[$__range]))' % MEDIDO, "", "A", True),
             objetivo('max by (corrida) (k6_dropped_iterations_total)', "", "B", True),
             objetivo('max by (corrida) (engine_operating_point_micros)', "", "C", True),
             objetivo('max by (corrida) (max_over_time(engine_window_wait_micros{quantile="0.95"}[$__range]))', "", "D", True),
             objetivo('max by (corrida) (max_over_time(engine_window_service_micros{quantile="0.95"}[$__range]))', "", "E", True)],
         "transformations": [
             {"id": "merge", "options": {}},
             {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {
                 "corrida": "Corrida", "Value #A": "Latencia p95", "Value #B": "Se quedaron fuera",
                 "Value #C": "Costo por orden", "Value #D": "Esperando en fila", "Value #E": "Trabajo real"}}},
             {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": "Corrida"}]}}],
         "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True}}, "overrides": [
             {"matcher": {"id": "byName", "options": "Corrida"},
              "properties": [{"id": "mappings", "value": mapeo}, {"id": "custom.width", "value": 340}]},
             {"matcher": {"id": "byName", "options": "Latencia p95"},
              "properties": [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 3},
                             {"id": "custom.cellOptions", "value": {"type": "color-background"}},
                             {"id": "thresholds", "value": {"mode": "absolute", "steps": VERDE_ROJO}}]},
             {"matcher": {"id": "byName", "options": "Se quedaron fuera"},
              "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background"}},
                             {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                 {"color": "green", "value": None}, {"color": "orange", "value": 1}]}}]},
             {"matcher": {"id": "byName", "options": "Costo por orden"},
              "properties": [{"id": "unit", "value": "µs"}, {"id": "decimals", "value": 0}]},
             {"matcher": {"id": "byName", "options": "Esperando en fila"},
              "properties": [{"id": "unit", "value": "µs"}, {"id": "decimals", "value": 0}]},
             {"matcher": {"id": "byName", "options": "Trabajo real"},
              "properties": [{"id": "unit", "value": "µs"}, {"id": "decimals", "value": 0}]}]}},

        {"type": "row", "title": "Una corrida en detalle — elígela en el selector de arriba",
         "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 15}, "panels": []},

        {"type": "timeseries", "title": "Lo que espera el cliente, contra el límite de 200 ms",
         "datasource": DS,
         "description": "La línea roja punteada es el contrato. El calentamiento se dibuja aparte "
                        "porque aporta tráfico y no cuenta para el veredicto.",
         "gridPos": {"h": 10, "w": 12, "x": 0, "y": 16},
         "targets": [objetivo('k6_grpc_req_duration_p95{%s,%s}' % (C, MEDIDO), "la mitad peor (p95)", "A"),
                     objetivo('k6_grpc_req_duration_p99{%s,%s}' % (C, MEDIDO), "1 de cada 100 (p99)", "B"),
                     objetivo('k6_grpc_req_duration_p95{%s,scenario="calentamiento"}' % C, "calentamiento (no cuenta)", "C")],
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}},
         "fieldConfig": {"defaults": {"unit": "s", "custom": {
             "drawStyle": "line", "lineWidth": 2, "fillOpacity": 6, "showPoints": "never",
             "spanNulls": True, "thresholdsStyle": {"mode": "dashed"}},
             "thresholds": {"mode": "absolute", "steps": VERDE_ROJO}}, "overrides": []}},

        {"type": "timeseries", "title": "¿Se va el tiempo esperando, o trabajando?",
         "datasource": DS,
         "description": "Si crece la ESPERA, hay que agregar particiones: la orden hace fila. "
                        "Si crece el TRABAJO, hay que abaratar la orden — más particiones no ayudan.",
         "gridPos": {"h": 10, "w": 12, "x": 12, "y": 16},
         "targets": [objetivo('engine_window_wait_micros{quantile="0.95",%s}' % C, "esperando en fila · partición {{shard}}", "A"),
                     objetivo('engine_window_service_micros{quantile="0.95",%s}' % C, "trabajo real · partición {{shard}}", "B")],
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}},
         "fieldConfig": {"defaults": {"unit": "µs", "min": 0, "custom": {
             "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10, "showPoints": "never",
             "spanNulls": True, "stacking": {"mode": "normal", "group": "A"}}}, "overrides": []}},

        {"type": "table", "title": "Con qué corrió", "datasource": DS,
         "description": "Sin esto, dos corridas con resultados distintos son indistinguibles.",
         "gridPos": {"h": 7, "w": 24, "x": 0, "y": 26},
         "targets": [objetivo('engine_info{%s}' % C, "", "A", True),
                     objetivo('engine_available_processors{%s}' % C, "", "B", True),
                     objetivo('engine_ceiling_orders_per_second{%s}' % C, "", "C", True)],
         "transformations": [
             {"id": "merge", "options": {}},
             {"id": "organize", "options": {
                 "excludeByName": {"Time": True, "__name__": True, "job": True,
                                   "instance": True, "experimento": True, "Value #A": True},
                 "renameByName": {"corrida": "Corrida", "shard": "Partición",
                                  "forma": "Forma del costo", "cs2": "Variabilidad (Cs²)",
                                  "journal": "Bitácora", "Value #B": "CPU que ve la JVM",
                                  "Value #C": "Techo teórico (órd/s)"}}}],
         "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [
             {"matcher": {"id": "byName", "options": "Corrida"},
              "properties": [{"id": "mappings", "value": mapeo}]}]}},
    ]

    return {
        "uid": "e01-motor-emparejamiento",
        "title": "E01 · Motor de emparejamiento",
        "description": "Arriba, todas las corridas del experimento con una fila cada una. "
                       "Abajo, el detalle de la que elijas en el selector.",
        "tags": ["e01", "arqsoft"], "timezone": "browser", "editable": True,
        "schemaVersion": 39, "version": 3, "refresh": "10s",
        "time": {"from": "now-12h", "to": "now"},
        "templating": {"list": [{
            "name": "corrida", "label": "Corrida", "type": "custom",
            "query": seleccion, "multi": True, "includeAll": True,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}}]},
        "panels": paneles,
    }


if __name__ == "__main__":
    filas = leer_plan()
    io.open(SALIDA, "w", encoding="utf-8").write(
        json.dumps(construir(filas), indent=2, ensure_ascii=False) + "\n")
    print("tablero generado desde %d corridas del plan -> %s" % (len(filas), SALIDA))
