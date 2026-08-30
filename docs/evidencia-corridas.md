---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de las ejecuciones del PoC con sus salidas crudas de k6 y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

**Entorno de todas las corridas:** una sola máquina (macOS, Apple Silicon), topología en Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 en el host con modelo abierto de tasa de llegada, 6 símbolos, tráfico por loopback. Fecha: 30 de agosto de 2026. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

## Resumen

| Corrida | Perfil | Órdenes | p50 | p95 | p99 | p99.9 | max | Rechazos | Criterio p95 ≤ 200 ms |
|---|---|---|---|---|---|---|---|---|---|
| Smoke (F1 recortada) | 17/s · 1 min | 1.021 | 8,88 ms | **13,94 ms** | 53,6 ms | 203,6 ms | 204,2 ms | 0 | ✅ |
| **F1 — Baseline (oficial)** | 17/s · 12 min | 12.241 | 5,35 ms | **9,64 ms** | 13,6 ms | 88,98 ms | 303,8 ms | 0 | ✅ margen ≈ 20× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s, pico sostenido 30 min, retorno a 17/s · 40 min | 167.430 | 2,82 ms | **4,91 ms** | 7,47 ms | 36,44 ms | 334,1 ms | 0 | ✅ margen ≈ 40× |
| F4 — Partición caliente | 84/s · 1 símbolo (exploratoria) | — | — | — | — | — | — | — | pendiente |

*(Latencias de `grpc_req_duration`: extremo a extremo del RPC medido por k6.)*

## Lectura de los resultados

**F1 valida ASR-02 en el PoC**: a la tasa de Ambiente A (1.000 emp/min sostenidos 12 minutos, arribo estocástico), el p95 extremo a extremo fue 9,64 ms contra un presupuesto de 200 ms — margen de ~20×, con la tasa clavada en 17,001 iters/s y 0 rechazos por backpressure (la cola acotada nunca se activó). La hipótesis **H1** queda confirmada para este entorno: el costo por evento del camino LMAX deja casi todo el presupuesto disponible.

**F2+F3 valida ASR-03 en el PoC con N=2 shards**: la rampa de 1.000 a 5.000 emp/min, el pico contractual sostenido 30 minutos (84/s) y el retorno a régimen procesaron 167.430 órdenes con 100 % de éxito, 0 rechazos y p95 = 4,91 ms — el promedio efectivo de toda la ventana fue 69,76 iters/s, exactamente el valor teórico del perfil por etapas, lo que confirma que el generador sostuvo la rampa completa. La hipótesis **H2** queda confirmada: el pico transitorio 5× se absorbió sin degradar la latencia ni activar la amortiguación, y al cerrar la ventana el sistema regresó a régimen (la última etapa corre a 17/s — es lo que muestra la línea final de k6).

**Un hallazgo contraintuitivo que confirma la mecánica del patrón**: el p95 bajo pico (4,91 ms) fue *mejor* que el del baseline (9,64 ms). Es el efecto de lote del Disruptor descrito en el diseño: cuando se acumulan ráfagas, el único hilo escritor procesa varios eventos por pasada y reparte el costo fijo entre ellos — el sistema se vuelve más eficiente por evento justo cuando más carga tiene, lo contrario de un sistema con locks. A esto se suman el JIT plenamente caliente durante 40 minutos y 13× más muestras diluyendo el arranque en frío (el `max` ≈ 334 ms sigue siendo la primera orden fría del agregado de k6; el diseño excluye el warm-up del análisis).

**Implicación para F4**: a las tasas del reto, dos shards absorben el pico contractual con margen de ~40×, así que es improbable que 84/s concentrados en un solo símbolo revelen el techo de una partición. Para que la fase exploratoria encuentre el punto de quiebre real, el script acepta `PEAK` (p. ej. `k6 run -e PHASE=f4 -e PEAK=500 poc.js`) para empujar un único shard mucho más allá del contrato.

## Salidas crudas de k6

### Smoke — `make smoke` (PHASE=f1, SMOKE=1)

```text
scenarios: f1: 17.00 iterations/s for 1m0s (maxVUs: 60-300)

THRESHOLDS
  grpc_req_duration            ✓ 'p(95)<200' p(95)=13.94ms
  orders_rejected_backpressure ✓ 'count==0'  count=0

checks_succeeded...: 100.00% 1021 out of 1021
orders_rejected_backpressure: 0
grpc_req_duration: avg=9.84ms p(50)=8.88ms p(95)=13.94ms p(99)=53.6ms p(99.9)=203.61ms max=204.16ms
iterations: 1021  17.014704/s
```

### F1 — `make f1` (oficial, baseline ASR-02)

```text
scenarios: f1: 17.00 iterations/s for 12m0s (maxVUs: 60-300)

THRESHOLDS
  grpc_req_duration            ✓ 'p(95)<200' p(95)=9.64ms
  orders_rejected_backpressure ✓ 'count==0'  count=0

checks_succeeded...: 100.00% 12241 out of 12241
orders_rejected_backpressure: 0
grpc_req_duration: avg=5.76ms p(50)=5.35ms p(95)=9.64ms p(99)=13.6ms p(99.9)=88.98ms max=303.81ms
iterations: 12241  17.001315/s
running (12m00.0s) — 12241 complete, 0 interrupted
```

### F2+F3 — `make f2` (oficial, rampa + pico 30 min + retorno, ASR-03)

```text
scenarios: f2: Up to 84.00 iterations/s for 40m0s over 5 stages (maxVUs: 120-800)
  etapas: 2m @17/s (precalentamiento) → 2m rampa 17→84/s → 30m @84/s (pico Ambiente B)
          → 1m rampa 84→17/s → 5m @17/s (F3: retorno a régimen)

THRESHOLDS
  grpc_req_duration            ✓ 'p(95)<200' p(95)=4.91ms
  orders_rejected_backpressure ✓ 'count==0'  count=0

checks_succeeded...: 100.00% 167430 out of 167430
orders_rejected_backpressure: 0
grpc_req_duration: avg=3.03ms p(50)=2.82ms p(95)=4.91ms p(99)=7.47ms p(99.9)=36.44ms max=334.14ms
iterations: 167430  69.762254/s   (promedio de todo el perfil; valor teórico ≈ 69.8/s)
running (40m00.0s) — 167430 complete, 0 interrupted
```

### F4

*Pendiente de ejecución — al pico contractual (`make f4`) y, dado el margen observado en F2, también con `PEAK` elevado para buscar el punto de quiebre real de un shard. Se agregará la comparación N=2 vs N=4 (`make up-n4`) si el equipo la corre.*
