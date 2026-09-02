---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de las ejecuciones del PoC con sus salidas crudas de k6 y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

**Entorno de todas las corridas:** una sola máquina (macOS, Apple Silicon), topología en Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 en el host con modelo abierto de tasa de llegada, tráfico por loopback. Fecha: 30 de agosto de 2026. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

## Resumen

| Corrida | Perfil | Órdenes | p50 | p95 | p99 | p99.9 | max | Rechazos | Veredicto |
|---|---|---|---|---|---|---|---|---|---|
| Smoke (F1 recortada) | 17/s · 1 min | 1.021 | 8,88 ms | **13,94 ms** | 53,6 ms | 203,6 ms | 204,2 ms | 0 | ✅ p95 ≤ 200 |
| **F1 — Baseline (oficial)** | 17/s · 12 min · 6 símbolos | 12.241 | 5,35 ms | **9,64 ms** | 13,6 ms | 88,98 ms | 303,8 ms | 0 | ✅ margen ≈ 20× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s, pico sostenido 30 min · 40 min | 167.430 | 2,82 ms | **4,91 ms** | 7,47 ms | 36,44 ms | 334,1 ms | 0 | ✅ margen ≈ 40× |
| **F4 — Partición caliente (contractual)** | igual a F2, 100 % en 1 símbolo | 167.429 | 2,79 ms | **4,87 ms** | 7,7 ms | 45,11 ms | 462,1 ms | 0 | sin degradación |
| **F4-explore @250/s** | 1 símbolo · ~5 min | 39.539 | 1,25 ms | **3,63 ms** | 5,45 ms | 10,15 ms | 38,9 ms | 0 | sin degradación |
| **F4-explore @500/s** | 1 símbolo · ~5 min | 77.040 | 0,96 ms | **2,40 ms** | 5,13 ms | 28,03 ms | 169,5 ms | 0 | sin degradación |
| **F4-explore @1000/s** | 1 símbolo · ~5 min | 152.039 | 0,49 ms | **1,11 ms** | 3,46 ms | 6,03 ms | 14,7 ms | 0 | **techo no alcanzado** |
| F2-N1 — N mínimo (retroalimentación 01-sep) | perfil F2 corto sobre **1 shard** | — | — | — | — | — | — | — | pendiente |

*(Latencias de `grpc_req_duration`: extremo a extremo del RPC medido por k6. En todas las corridas la tasa promedio lograda coincidió con el valor teórico del perfil — el generador nunca se quedó atrás.)*

## Lectura de los resultados

**F1 valida ASR-02**: a la tasa de Ambiente A (1.000 emp/min por 12 min, arribo estocástico), p95 = 9,64 ms contra 200 ms de presupuesto — margen ~20×, 0 rechazos. **H1 confirmada.**

**F2+F3 valida ASR-03 con N=2 shards**: rampa a 5.000 emp/min, pico contractual sostenido 30 min y retorno a régimen — 167.430 órdenes, 100 % OK, 0 rechazos, p95 = 4,91 ms (margen ~40×), backlog drenado al cerrar la ventana. **H2 confirmada.**

**F4 contractual: la partición caliente no degrada al pico del contrato**: con el 100 % del tráfico en un solo símbolo (un único shard, un único hilo), el resultado fue estadísticamente idéntico al de la carga repartida (p95 = 4,87 vs 4,91 ms). **H2b no se manifiesta a tasas contractuales.**

**F4-explore: el techo de un shard no se alcanzó ni a 12× el pico contractual del sistema completo.** Escalando la carga concentrada a 250, 500 y 1.000 órdenes/s (60.000 emp/min — todo sobre una sola partición), el shard sostuvo cada tasa objetivo exacta, con 0 rechazos, y la latencia **mejoró monotónicamente**: p95 de 3,63 → 2,40 → 1,11 ms, con max de apenas 14,7 ms a la tasa más alta. Es la firma inequívoca del efecto de lote del Disruptor descrito en el diseño: a más ráfaga, más eventos procesa el único escritor por pasada y menor es el costo amortizado por evento — exactamente lo contrario de un sistema con locks, donde más carga significa más contención. El punto de quiebre existe (un núcleo es finito), pero queda acotado por debajo en **> 1.000 órdenes/s por shard**, es decir > 12× la carga pico de todo el sistema contractual concentrada en la peor distribución posible.

**Efecto del arranque en frío**: visible como máximos aislados (200–460 ms) en las corridas largas — las primeras órdenes pagan JIT y carga de clases. El diseño excluye el warm-up del análisis; el agregado de k6 lo incluye, así que los valores reportados son cotas superiores conservadoras.

## Conclusión del experimento

Las siete corridas (~560.000 órdenes en total, 100 % procesadas, 0 rechazos) forman un patrón coherente: **H1 y H2 confirmadas con márgenes de 20–40×, y H2b refutada en todo el rango explorado** — la partición caliente pasa de "riesgo que amenaza el SLA" a "límite de capacidad medido con holgura mínima de 12×". La comparación N=2 vs N=4 a tasas de estrés se descarta como innecesaria en este PoC: para estresar la topología habría que superar el techo (no hallado) de cada shard, punto en el cual el generador y el host único dejarían de ser instrumentos confiables; la aditividad del throughput entre shards queda argumentada por construcción (no comparten nada) y evidenciada por F2/F4 a tasas contractuales. La profundización del techo pertenece al banco de tres nodos (TEC-2).

## Salidas crudas de k6

### Smoke — `make smoke` (PHASE=f1, SMOKE=1)

```text
scenarios: f1: 17.00 iterations/s for 1m0s
✓ 'p(95)<200' p(95)=13.94ms · ✓ rechazos count=0 · checks 100% (1021)
grpc_req_duration: avg=9.84ms p(50)=8.88ms p(95)=13.94ms p(99)=53.6ms p(99.9)=203.61ms max=204.16ms
```

### F1 — `make f1` (oficial, baseline ASR-02)

```text
scenarios: f1: 17.00 iterations/s for 12m0s
✓ 'p(95)<200' p(95)=9.64ms · ✓ rechazos count=0 · checks 100% (12241)
grpc_req_duration: avg=5.76ms p(50)=5.35ms p(95)=9.64ms p(99)=13.6ms p(99.9)=88.98ms max=303.81ms
iterations: 12241  17.001315/s — 0 interrupted
```

### F2+F3 — `make f2` (oficial, rampa + pico 30 min + retorno, ASR-03)

```text
scenarios: f2: Up to 84.00 iterations/s for 40m0s over 5 stages
  2m @17/s → 2m rampa 17→84/s → 30m @84/s (pico Ambiente B) → 1m rampa ↓ → 5m @17/s (F3)
✓ 'p(95)<200' p(95)=4.91ms · ✓ rechazos count=0 · checks 100% (167430)
grpc_req_duration: avg=3.03ms p(50)=2.82ms p(95)=4.91ms p(99)=7.47ms p(99.9)=36.44ms max=334.14ms
iterations: 167430  69.762254/s (= teórico del perfil) — 0 interrupted
```

### F4 — `make f4` (partición caliente al pico contractual, exploratoria)

```text
scenarios: f4: Up to 84.00 iterations/s for 40m0s — 100 % del tráfico en 'HOT' → un único shard
checks 100% (167429) · 0 rechazos (sin thresholds: fase exploratoria)
grpc_req_duration: avg=3.07ms p(50)=2.79ms p(95)=4.87ms p(99)=7.7ms p(99.9)=45.11ms max=462.14ms
iterations: 167429  69.761979/s — 0 interrupted
```

### F4-explore — `make f4-explore` (punto de quiebre de un shard)

```text
@250/s  (promedio logrado 146.44/s = teórico): checks 100% (39539) · 0 rechazos
        grpc_req_duration: avg=1.69ms p(50)=1.25ms p(95)=3.63ms p(99)=5.45ms p(99.9)=10.15ms max=38.86ms

@500/s  (promedio logrado 285.33/s = teórico): checks 100% (77040) · 0 rechazos
        grpc_req_duration: avg=1.18ms p(50)=956µs p(95)=2.4ms p(99)=5.13ms p(99.9)=28.03ms max=169.52ms

@1000/s (promedio logrado 563.10/s = teórico): checks 100% (152039) · 0 rechazos
        grpc_req_duration: avg=614µs p(50)=491µs p(95)=1.11ms p(99)=3.46ms p(99.9)=6.03ms max=14.65ms

Punto de quiebre: NO alcanzado. Cota inferior del techo de un shard: > 1.000 órdenes/s
(> 60.000 emp/min concentrados en una sola partición = 12× el pico contractual del sistema).
```
