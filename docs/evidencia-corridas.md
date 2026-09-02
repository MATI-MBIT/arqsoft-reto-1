---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de la ejecución vigente del PoC con sus salidas crudas y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

Las corridas del 30 de agosto quedaron **superadas** y se retiraron de esta página: se ejecutaron con arribo equiespaciado (Ca² = 0) y con seis símbolos que repartían 67 %/33 % entre dos shards, de modo que sus percentiles eran cotas optimistas. Siguen en el historial de git.

**Entorno:** una sola máquina (macOS, Apple Silicon, 14 vCPU), topología en Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 ≥ 0.49 con gRPC nativo en el host, tráfico por loopback. **Fecha: 2 de septiembre de 2026.** Generador con arribo estocástico (desplazamiento exponencial por iteración, Ca² = 0,89), 36 símbolos que el hash reparte 18/18 con N=2, y umbrales de rechazos, iteraciones descartadas y violaciones de routing. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

## Resumen

| Corrida | Perfil | Órdenes | p50 | **p95** | p99.9 | max | Rechazos | Descartes | Routing | Veredicto |
|---|---|---|---|---|---|---|---|---|---|---|
| **F1 — Baseline (oficial)** | 17/s · 12 min · 36 símbolos | 12.241 | 4,41 ms | **7,55 ms** | 19,2 ms | 199 ms | 0 | 0 | 0 | ✅ margen ≈ 26× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s · 40 min | 167.429 | 2,23 ms | **4,61 ms** | 14,9 ms | 413 ms | 0 | 0 | 0 | ✅ margen ≈ 43× |
| **F4 — Partición caliente** | 84/s en 1 símbolo · 29 min | 134.687 | 2,00 ms | **3,30 ms** | 9,5 ms | 72,9 ms | 0 | 0 | — | sin degradación |
| **F4-explore @250/s** | 1 símbolo · ~5 min | 39.539 | 1,36 ms | **2,90 ms** | 9,9 ms | 47,5 ms | 0 | 0 | — | sin degradación |
| **F4-explore @500/s** | 1 símbolo · ~5 min | 77.039 | 0,94 ms | **2,17 ms** | 8,2 ms | 119 ms | 0 | 0 | — | sin degradación |
| **F4-explore @1000/s** | 1 símbolo · ~5 min | 151.702 | 0,61 ms | **1,43 ms** | 447 ms | 777 ms | 0 | **337** | — | **el generador se quedó atrás** |

*(`grpc_req_duration` de k6, extremo a extremo. 582.637 órdenes en total, 100 % de checks correctos.)*

**Percentiles internos del motor** (HdrHistogram del shard, promedio de las ventanas de 10 s de mayor carga). La descomposición `total = espera + servicio` separa el tiempo en cola del costo de procesar:

| Corrida | Órdenes/ventana | total p95 | espera p95 | **servicio p50** |
|---|---|---|---|---|
| F1 · 17/s · 18 libros por shard | 85 | 272 µs | 200 µs | **90 µs** |
| F2 · pico 84/s · 18 libros | 418 | 174 µs | 153 µs | **25 µs** |
| F4 · 84/s · 1 libro | 829 | 127 µs | 117 µs | **13 µs** |
| F4-explore @250/s | 2.383 | 93 µs | 86 µs | **9 µs** |
| F4-explore @500/s | 4.758 | 58 µs | 55 µs | **4 µs** |
| F4-explore @1000/s | 9.481 | 44 µs | 42 µs | **2 µs** |

## Lectura de los resultados

**F1 valida ASR-02.** A la tasa de Ambiente A con arribo estocástico y símbolos balanceados, p95 = 7,55 ms contra 200 ms de presupuesto — margen ≈ 26×. Los cuatro umbrales pasan.

**F2+F3 valida ASR-03 con N=2 shards.** Rampa a 5.000 emp/min, pico contractual sostenido 30 min y retorno a régimen: 167.429 órdenes, 100 % OK, p95 = 4,61 ms (margen ≈ 43×).

**F3 queda evidenciado con número propio**, por primera vez. Su criterio es que el backlog drene y la latencia vuelva al valor de F1; separando las ventanas internas del shard por régimen:

| Ventana | Órdenes/10 s | total p95 | espera p95 |
|---|---|---|---|
| F1 baseline (referencia) | 85 | 272 µs | 200 µs |
| F2 pico 84/s sostenido | 416 | 174 µs | 153 µs |
| **F3 retorno a régimen** | 85 | **173 µs** | **138 µs** |

La espera vuelve a 138 µs contra los 200 µs de F1: no solo drena, queda por debajo. Antes solo existía el p95 agregado de F2+F3 y el criterio de F3 no tenía evidencia separada.

**El aislamiento del sharding queda demostrado empíricamente.** `shard_routing_violations = 0` en F1 y F2: cada símbolo fue respondido siempre por el mismo shard, sobre 179.670 órdenes. Es la recomendación 2 de la retroalimentación del profesor, que antes se sostenía solo por el argumento matemático.

### El hallazgo central: el costo por orden cae con la carga

Misma máquina, misma corrida, mismo código. Solo cambian la tasa y cuántos libros toca cada shard:

```
servicio p50:   90 µs → 25 µs → 13 µs → 9 µs → 4 µs → 2 µs
                17/s    84/s    84/s    250/s  500/s  1000/s
                18 libros ────┘ └──── 1 libro ──────────────
```

**45× más barato procesar una orden**, sin cambiar una línea de código. El trabajo es el mismo —un cruce sobre un `TreeMap`—; lo que cambia es que a mayor tasa y con menos libros los datos permanecen calientes en la caché del núcleo y el Disruptor procesa lotes más grandes por pasada. Es la *mechanical sympathy* que el diseño declara como mecanismo del patrón, aislada por primera vez en el componente en vez de inferida de los números extremo a extremo. Los 13 µs de F4 replican de forma independiente los 13 µs medidos en el punto `S=0` del barrido de tiempo de servicio.

La espera acompaña (200 → 42 µs): a tasa baja el hilo matcher se duerme y casi toda la espera es el costo de despertarlo bajo `BlockingWaitStrategy`, no encolamiento. Eso eleva la prioridad de la deuda de decisión sobre la estrategia de espera: a 17/s, **el 74 % de la latencia interna es despertar un hilo**.

### A 1.000 órdenes/s el instrumento satura antes que el motor

`F4-explore @1000/s` es el primer punto donde el generador **no sostuvo la tasa**: 337 iteraciones descartadas, p99.9 de 447 ms y max de 777 ms. Pero los percentiles internos del motor en esa misma corrida son los mejores de toda la serie (total p95 = 44 µs, servicio p50 = 2 µs).

La lectura correcta no es que el motor se degrade, sino que **k6 y el host dejaron de ser instrumentos confiables a esa tasa**: con el arribo estocástico el generador necesita más VUs concurrentes y compite por CPU con los shards en la misma máquina. El techo del shard **sigue sin alcanzarse**, y ahora hay evidencia directa de dónde está el límite del montaje. Sin el umbral `dropped_iterations` esto habría pasado inadvertido y la corrida habría reportado un p95 de 1,43 ms sobre una carga que nunca se aplicó por completo.

## Desviaciones declaradas de esta corrida

- **El ciclo se ejecutó por tramos.** `make e2e` requiere ~1h50m y el entorno de ejecución corta las tareas largas. F1 y F2 corrieron dentro del ciclo original; F4 y F4-explore se reanudaron sobre la misma topología, ya caliente, sin reiniciar contenedores.
- **F4 corrió 29 de los 40 minutos** previstos (73 %): cubrió el precalentamiento, la rampa y 25 de los 30 minutos de pico sostenido. La ventana de pico —lo que la fase busca— está cubierta.
- **El libro de `HOT` no arrancó vacío en F4**: conserva el residuo de un intento previo de 4m25s (~10.200 órdenes) sobre el mismo símbolo.
- Una sola repetición por fase, sin intervalos de confianza entre corridas.

## Salidas crudas de k6

```text
F1 · make e2e (PHASE=f1, oficial)
  scenarios: f1: 17.00 iterations/s for 12m0s
  ✓ p(95)<200 → p(95)=7.55ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100% (12241)
  grpc_req_duration: avg=4.51ms p(50)=4.41ms p(95)=7.55ms p(99)=10.03ms p(99.9)=19.22ms max=199.42ms
  iterations: 12241  16.960762/s

F2+F3 · make e2e (PHASE=f2, oficial)
  scenarios: f2: Up to 84.00 iterations/s for 40m0s over 5 stages
  ✓ p(95)<200 → p(95)=4.61ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100% (167429)
  grpc_req_duration: avg=2.53ms p(50)=2.23ms p(95)=4.61ms p(99)=7.83ms p(99.9)=14.94ms max=413.16ms
  iterations: 167429  69.7628/s (= teórico del perfil)

F4 · partición caliente (exploratoria) — 29m07s de 40m
  grpc_req_duration: avg=2.07ms p(50)=2ms p(95)=3.3ms p(99)=4.15ms p(99.9)=9.51ms max=72.92ms
  iterations: 134687  77.091808/s · checks 100% · 0 rechazos · 0 descartes

F4-explore · techo de un shard
  @250/s   grpc_req_duration: avg=1.58ms p(50)=1.36ms p(95)=2.9ms  p(99.9)=9.91ms  max=47.48ms   n=39539   descartes=0
  @500/s   grpc_req_duration: avg=1.1ms  p(50)=942µs  p(95)=2.17ms p(99.9)=8.21ms  max=118.81ms  n=77039   descartes=0
  @1000/s  grpc_req_duration: avg=2.47ms p(50)=612µs  p(95)=1.43ms p(99.9)=446.51ms max=776.62ms n=151702  descartes=337
           ← el generador no sostuvo la tasa; el motor midió su mejor total p95 (44us) en esta misma corrida
```

Línea interna del shard, con la descomposición `total = espera + servicio`:

```text
shard=1 n=829 p50=63us p95=127us p99=190us p99.9=280us max=280us
        | espera   p50=52us p95=117us p99.9=266us
        | servicio p50=13us p95=28us  p99.9=71us
```

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

**1. El baseline medía transporte, no el patrón.** En `S=0` el motor aporta **0,11 ms** de los 2,49 ms extremo a extremo: el **96 %** es gRPC, router y la red virtualizada de Docker en macOS. Dentro de esos 0,11 ms, la espera (156 µs p95) es el despertar del hilo matcher dormido bajo `BlockingWaitStrategy`, y el trabajo real son 13 µs. El mismo reparto se confirmó en la corrida del 02-sep (F1: 272 µs de motor sobre 7,55 ms extremo a extremo): los p95 reportados miden, mayoritariamente, la latencia de una máquina virtual, no el patrón. También eleva la prioridad de la deuda de decisión sobre la estrategia de espera.

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

Seis corridas, 582.637 órdenes, 100 % procesadas, 0 rechazos y 0 violaciones de routing. **H1 y H2 se cumplen** con márgenes de 26× y 43× bajo arribo estocástico y con el sharding balanceado y verificado en vivo; **F3 confirma que la escalabilidad exigida es transitoria** — el backlog drena y la latencia vuelve por debajo del baseline.

**H2b no se refuta: se reformula.** La partición caliente no degradó el servicio ni a 12× el pico contractual, pero el techo de un shard es 1/S y estas corridas lo midieron con un `match()` de 13 µs. El barrido de tiempo de servicio acota el resultado a un **presupuesto**: el patrón sostiene el ASR con todo el pico en una sola partición mientras el costo por orden se mantenga bajo **~8,5 ms**. Por encima, H2b se manifiesta. La hipótesis de mayor riesgo pasa de "amenaza al SLA" a "condición verificable contra la lógica de negocio real".

Dos claims del diseño siguen **sin evidencia** y así están declarados en la ficha: la cláusula de H2 sobre no exigir más de un núcleo por partición (no se midió CPU por proceso) y la de H1 sobre journaling fuera del camino crítico (no hay journaling en el PoC). Verificar el presupuesto contra la lógica de negocio real y repetir en el banco de tres nodos (TEC-2) son los siguientes pasos.
