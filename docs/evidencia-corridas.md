---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de las ejecuciones del PoC con sus salidas crudas de k6 y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

**Entorno de todas las corridas:** una sola máquina (macOS, Apple Silicon), topología en Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 en el host con modelo abierto de tasa de llegada, tráfico por loopback. Fecha: 30 de agosto de 2026. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

> **Advertencia de validez — corridas pendientes de repetir.** Las siete corridas de esta sección se tomaron con la versión del generador anterior al 02-sep: k6 emitía las órdenes **equiespaciadas** (Ca² = 0), no con el arribo estocástico que nombra H1, y los 6 símbolos de entonces repartían 67 %/33 % con N=2 (con N=4 un shard quedaba ocioso). Con varianza de arribo nula no hay aglomeración, el ring buffer no acumula y los percentiles —sobre todo p95/p99— son **cotas optimistas**. Medido en A/B sobre el mismo shard: la espera en cola p99.9 pasó de 83–303 µs con arribo periódico a 1.409–4.375 µs con arribo estocástico. Los veredictos de abajo deben releerse como provisionales hasta repetirlas con el generador corregido. **El barrido del tiempo de servicio (más abajo) sí se corrió con el generador corregido** y no está afectado por esta advertencia.

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

## Barrido del tiempo de servicio (S)

**Fecha:** 2 de septiembre de 2026 · **Comando:** `make sweep-service SWEEP_MICROS="0 1000 5000 8000 10000 12000"`

### Por qué este barrido

`OrderBook.match()` cuesta ~13 µs medidos. El PoC no implementa validación, control de riesgo, saldos, tipos de orden, comisiones ni generación de trades. Como en un diseño de **un único escritor** ese costo se serializa, fija el techo del shard: `techo = 1/S`, con `ρ = λ·S`. Medir la capacidad con S de microsegundos mide un `TreeMap`, no un motor — por eso la cifra de «techo > 1.000 ord/s» de F4-explore no es una propiedad del patrón. Sin estimación del costo real, `BusinessLogicModel` lo convierte en parámetro barrido y el entregable pasa de ser un número a ser un **presupuesto**.

### Montaje

Topología N=2 en Docker Compose, fase **F4 en versión corta** (~4,5 min: 30 s @17/s → rampa → 2 min @84/s → bajada → 1 min @17/s) con el **100 % del tráfico en un único símbolo**: todo el pico contractual concentrado en un solo shard, la peor distribución posible. Generador ya corregido (arribo exponencial, 36 símbolos balanceados, umbral de iteraciones descartadas). Modelo de servicio: mezcla de tres clases 90 % ×1 / 9 % ×6 / 1 % ×30, Cs² = 3,34, acotada por construcción en ~17× la media.

### Resultados

| S | ρ | p50 | **p95** | p99 | p99.9 | max | Rechazos | Descartes | Veredicto |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 0,00 | 2,49 ms | **5,93 ms** | 9,35 ms | 15,5 ms | 188 ms | 0 | 0 | ✅ PASA |
| 1.000 µs | 0,08 | 2,84 ms | **7,87 ms** | 18,8 ms | 24,1 ms | 134 ms | 0 | 0 | ✅ PASA |
| 5.000 µs | 0,42 | 4,63 ms | **65,59 ms** | 95,2 ms | 156 ms | 242 ms | 0 | 0 | ✅ PASA |
| 8.000 µs | 0,67 | 9,99 ms | **148,19 ms** | 251 ms | 350 ms | 413 ms | 0 | 0 | ✅ PASA |
| 10.000 µs | 0,84 | 36,7 ms | **346,43 ms** | 521 ms | 676 ms | 754 ms | 0 | 0 | ❌ FALLA |
| 12.000 µs | 1,01 | 1,12 s | **2,68 s** | 3,26 s | 3,42 s | 3,54 s | 0 | **143** | ❌ FALLA |

*(`grpc_req_duration` de k6, extremo a extremo. ρ calculado sobre el pico de 84/s en un solo shard.)*

### El presupuesto

> **≈ 8,5 ms por orden.** Con todo el tráfico del pico contractual cayendo en una sola partición, el patrón LMAX cumple p95 ≤ 200 ms mientras procesar una orden cueste hasta ~8,5 ms.

Acotado por medición —8 ms pasa con 148 ms, 10 ms falla con 346 ms— e interpolado en el cruce. Es el resultado principal del barrido, y es **falsable sin conocer todavía la lógica de negocio real**: cuando exista, se mide su costo y se compara contra este presupuesto. Corolario: **H2b deja de ser un veredicto binario** — la partición caliente amenaza el SLA si y solo si el costo por orden supera ~8,5 ms.

### El mecanismo: servicio contra espera

Percentiles internos del shard, promediando las ventanas de 10 s **del pico** (84/s sostenidos):

| S | espera p50 | espera p95 | servicio p50 | La cola es el… |
|---|---|---|---|---|
| 5.000 µs | 0,1 ms | 49,0 ms | 2,88 ms | 82 % del total |
| 8.000 µs | 6,0 ms | 139,5 ms | 4,60 ms | 91 % |
| 10.000 µs | 59,2 ms | 304,2 ms | 5,75 ms | 96 % |
| 12.000 µs | 1.334 ms | 1.802 ms | 6,90 ms | 99 % |

Todo el argumento en dos columnas: **el servicio crece lineal** (2,88 → 6,90 ms, lo configurado) mientras **la espera crece 13.000×** (0,1 → 1.334 ms). El sistema no se degrada suavemente: cae por un acantilado al acercarse ρ a 1. Es también la utilidad práctica de la descomposición — distingue «hay que abaratar la orden» de «hay que shardear más». A partir de ~5 ms, la respuesta es shardear.

### Validación del modelo en caliente

La mediana teórica de la mezcla es 0,575 × S. Medido dentro del contenedor, bajo carga y en saturación:

| S configurado | servicio p50 predicho | medido |
|---|---|---|
| 5.000 µs | 2.874 µs | 2.880 µs |
| 8.000 µs | 4.598 µs | 4.600 µs |
| 10.000 µs | 5.748 µs | 5.750 µs |
| 12.000 µs | 6.898 µs | 6.900 µs |

Cuatro de cuatro. El modelo entrega exactamente el tiempo que declara.

### Tres hallazgos

**1. El baseline medía transporte, no el patrón.** En `S=0` el motor aporta **0,11 ms** de los 2,49 ms extremo a extremo: el **96 %** es gRPC, router y la red virtualizada de Docker en macOS. Dentro de esos 0,11 ms, la espera (156 µs p95) es el despertar del hilo matcher dormido bajo `BlockingWaitStrategy`, y el trabajo real son 13 µs. Esto recontextualiza el p95 de 4,87 ms de F4: era, mayoritariamente, la latencia de una máquina virtual. También eleva la prioridad de la deuda de decisión sobre la estrategia de espera.

**2. Cero rechazos incluso saturado.** El backpressure no se activó en ningún punto, ni con ρ = 1,01: a ese régimen el déficit es de ~0,7 órdenes/s y llenar un ring de 16.384 tomaría horas. **El sistema se degrada por latencia mucho antes que por rechazo**; el criterio de «0 rechazos» de F1–F3, por sí solo, no protege de nada.

**3. Los 143 descartes en `S=12000`.** Primera activación del umbral `dropped_iterations`. Con respuestas de 1,1 s el generador no pudo sostener la tasa objetivo; sin ese umbral la corrida habría reportado un p95 sobre una carga que nunca se aplicó.

### Limitaciones de este barrido

Es una **cota inferior conservadora**: macOS con Docker en VM y sin `cpuset`, así que el modelo quema CPU compitiendo con k6 y el router en la misma máquina; corridas cortas de 4,5 min en vez de las oficiales de 40 min; y una sola repetición por punto, sin intervalos de confianza. En Linux con núcleos dedicados el presupuesto debería salir mayor. Fijarlo con rigor pertenece al banco de tres nodos (TEC-2).

### Salidas crudas de k6

```text
S=0us      grpc_req_duration: avg=2.9ms   p(50)=2.49ms  p(95)=5.93ms   p(99)=9.35ms   p(99.9)=15.51ms  max=188.37ms
S=1000us   grpc_req_duration: avg=3.68ms  p(50)=2.84ms  p(95)=7.87ms   p(99)=18.76ms  p(99.9)=24.09ms  max=133.88ms
S=5000us   grpc_req_duration: avg=13.03ms p(50)=4.63ms  p(95)=65.59ms  p(99)=95.15ms  p(99.9)=156.33ms max=242.12ms
S=8000us   grpc_req_duration: avg=36.36ms p(50)=9.99ms  p(95)=148.19ms p(99)=250.91ms p(99.9)=350.13ms max=412.98ms
S=10000us  grpc_req_duration: avg=96.21ms p(50)=36.65ms p(95)=346.43ms p(99)=521.1ms  p(99.9)=676.27ms max=753.75ms
S=12000us  grpc_req_duration: avg=1.13s   p(50)=1.12s   p(95)=2.68s    p(99)=3.26s    p(99.9)=3.42s    max=3.54s
                              dropped_iterations=143  (unico punto con descartes)
```

Línea interna del shard (`S=0`, ventana de 10 s), con la descomposición total = espera + servicio:

```text
shard=1 n=168 p50=109us p95=180us p99=230us p99.9=322us max=322us
        | espera   p50=92us p95=163us p99.9=281us max=281us
        | servicio p50=13us p95=34us  p99.9=88us  max=88us
```

## Conclusión del experimento

Las siete corridas (~560.000 órdenes en total, 100 % procesadas, 0 rechazos) forman un patrón coherente: **H1 y H2 confirmadas con márgenes de 20–40×, y H2b refutada en todo el rango explorado** — la partición caliente pasa de "riesgo que amenaza el SLA" a "límite de capacidad medido con holgura mínima de 12×". La comparación N=2 vs N=4 a tasas de estrés se descarta como innecesaria en este PoC: para estresar la topología habría que superar el techo (no hallado) de cada shard, punto en el cual el generador y el host único dejarían de ser instrumentos confiables; la aditividad del throughput entre shards queda argumentada por construcción (no comparten nada) y evidenciada por F2/F4 a tasas contractuales. La profundización del techo pertenece al banco de tres nodos (TEC-2).

**Reencuadre a partir del barrido de tiempo de servicio (02-sep).** La afirmación «H2b refutada» de arriba mide un `match()` de ~13 µs, no un motor de emparejamiento: con el costo por orden como parámetro, el techo de un shard es 1/S y la partición caliente sí rompe el SLA en cuanto S supera ~8,5 ms. La conclusión defendible no es que el riesgo no exista, sino que **queda acotado por un presupuesto medido**: el patrón sostiene ASR-02/03 en la peor distribución posible mientras el costo por orden se mantenga bajo ~8,5 ms. Verificar ese presupuesto contra la lógica de negocio real es el siguiente paso del experimento.

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
