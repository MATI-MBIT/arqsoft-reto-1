#!/usr/bin/env python3
"""Lee los resultados de una corrida del plan y dicta el veredicto de cada una.

Va aparte del orquestador a propósito: la regla de validez cambió DESPUÉS de
correr, y rehacer cuatro horas de medición para recalcular una columna sería
absurdo. Las salidas crudas están todas guardadas, así que el veredicto se
deriva; no se re-mide.

    python3 load/analizar.py load/k6/results/e01-<marca>
"""
import csv, io, os, sys


def percentil_efectivo(observadas, descartadas):
    """A qué percentil VERDADERO corresponde el p95 que k6 reportó.

    Cuando el generador se queda sin clientes descarta iteraciones, y las que
    descarta son las de los momentos peores. El p95 de lo que sí midió no es el
    p95 de la población: es el percentil 0,95 × observadas ÷ intentadas.

    Con 26 descartes sobre 28.000 da p94,9 —indistinguible de un p95—. Con
    11.111 sobre 39.000 da p68, que es otra cosa por completo. La regla binaria
    «cualquier descarte invalida» trataba a las dos igual.
    """
    intentadas = observadas + descartadas
    return 95.0 * observadas / intentadas if intentadas else 0.0


# Por debajo de este percentil, la cifra deja de ser un p95 y no se publica.
PISO = 94.0
LIMITE_MS = 200.0


def veredicto(fila):
    obs = float(fila["ordenes"] or 0)
    des = float(fila["descartes"] or 0)
    pef = percentil_efectivo(obs, des)
    if pef < PISO:
        return "NO MEDIBLE", pef
    if fila["criterio"] != "p95<200":
        return "observa", pef
    p95 = float(fila["k6_p95_ms"] or 0)
    return ("CUMPLE" if p95 < LIMITE_MS else "NO CUMPLE"), pef


def main(directorio):
    ruta = os.path.join(directorio, "resultados.tsv")
    filas = list(csv.DictReader(io.open(ruta, encoding="utf-8"), delimiter="\t"))
    print("== %s · %d corridas ==" % (os.path.basename(directorio), len(filas)))
    grupos = {}
    for f in filas:
        grupos.setdefault(f["grupo"], []).append(f)
    for g, fs in grupos.items():
        print("\n%s" % g.upper())
        for f in fs:
            v, pef = veredicto(f)
            aviso = "   ← el p95 reportado es en realidad p%.1f" % pef if pef < 94.9 else ""
            print("  %-16s %10s ms  espera %8s us  %-11s%s"
                  % (f["id"], f["k6_p95_ms"], f["espera_p95_us"], v, aviso))
    return filas


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1])
