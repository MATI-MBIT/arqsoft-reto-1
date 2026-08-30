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
| F2 — Rampa + pico 30 min | 17→84/s · ~40 min | — | — | — | — | — | — | — | pendiente |
| F4 — Partición caliente | 84/s · 1 símbolo | — | — | — | — | — | — | — | pendiente (exploratoria) |

*(Latencias de `grpc_req_duration`: extremo a extremo del RPC medido por k6.)*

## Lectura de los resultados

**F1 valida ASR-02 en el PoC**: a la tasa de Ambiente A (1.000 emp/min sostenidos 12 minutos, arribo estocástico), el p95 extremo a extremo fue 9,64 ms contra un presupuesto de 200 ms — margen de ~20×, con la tasa clavada en 17,001 iters/s y 0 rechazos por backpressure (la cola acotada nunca se activó). La hipótesis **H1** queda confirmada para este entorno: el costo por evento del camino LMAX deja casi todo el presupuesto disponible.

**El efecto del arranque en frío es visible y explicable**: en el smoke (1 min, sin precalentamiento efectivo) la cola p99.9 tocó ~204 ms; en F1 (12 min, 12× más muestras) cayó a 89 ms y solo el máximo aislado (~304 ms, las primeras órdenes que pagan JIT y carga de clases) recuerda el arranque. El diseño del experimento excluye el warm-up del análisis; el agregado de k6 lo incluye, así que estos valores son cotas superiores conservadoras.

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

### F2 y F4

*Pendientes de ejecución — se agregarán aquí con el mismo formato (resumen interpretado + salida cruda), incluyendo la comparación N=2 vs N=4 para la escalabilidad por sharding.*
