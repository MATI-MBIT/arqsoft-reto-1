---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de la ejecución vigente del PoC con sus salidas crudas y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

**Entorno:** una sola máquina (macOS, Apple Silicon, 14 vCPU), Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 ≥ 0.49 con gRPC nativo en el host, tráfico por loopback. **Fecha: 2 de septiembre de 2026.** Generador con arribo estocástico (desplazamiento exponencial por iteración, Ca² = 0,89), 36 símbolos que el hash reparte 18/18 con N=2, y umbrales de rechazos, iteraciones descartadas y violaciones de routing. **Cada fase corre sobre una topología recién levantada**, de modo que sus percentiles internos son de esa fase y solo de esa. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

## Cómo se calcula cada número

Tres estadísticos distintos, que no son intercambiables:

- **`grpc_req_duration` de k6** — percentiles verdaderos sobre todas las peticiones de la fase, medidos por el generador. Incluyen red, router y motor.
- **`ACUMULADO` del motor** — percentiles verdaderos sobre todas las órdenes de la fase, medidos dentro del shard (arribo → materialización). El shard suma cada ventana a un histograma acumulado y lo publica al recibir `SIGTERM`. **Comparables cifra a cifra con los de k6**: su resta es el costo de transporte.
- **Ventanas de 10 s** — el shard también emite un histograma cada 10 s y lo reinicia. Sirven para ver la *evolución* dentro de una fase (por ejemplo si el backlog drena), y se reportan como **mediana entre ventanas con [mín–máx]**. La mediana de los p95 por ventana **no es** el p95 de la población.

Validación de la contabilidad: las órdenes contadas por el motor coinciden exactamente con las iteraciones de k6 en las seis fases. Límite del instrumento: la latencia interna se registra en microsegundos enteros con piso en 1, así que `1 µs` significa «≤ 1 µs».

## Resumen — medición de k6, extremo a extremo

| Corrida | Perfil | Órdenes | p50 | **p95** | p99 | p99.9 | max | Rechazos | Descartes | Routing | Veredicto |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **F1 — Baseline (oficial)** | 17/s · 12 min · 36 símbolos | 12.240 | 4,23 ms | **7,54 ms** | 10,6 ms | 49,6 ms | 144 ms | 0 | 0 | 0 | ✅ margen ≈ 27× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s · 40 min | 167.429 | 2,27 ms | **4,58 ms** | 7,72 ms | 51,0 ms | 512 ms | 0 | 0 | 0 | ✅ margen ≈ 44× |
| **F4 — Partición caliente** | 84/s en 1 símbolo · 40 min | 167.429 | 2,13 ms | **4,00 ms** | 6,12 ms | 21,2 ms | 290 ms | 0 | 0 | — | sin degradación |
| **F4-explore @250/s** | 1 símbolo · ~5 min | 39.539 | 1,28 ms | **3,54 ms** | 7,65 ms | 29,6 ms | 168 ms | 0 | 0 | — | sin degradación |
| **F4-explore @500/s** | 1 símbolo · ~5 min | 77.038 | 0,91 ms | **2,03 ms** | 6,49 ms | 80,9 ms | 199 ms | 0 | 1 | — | sin degradación |
| **F4-explore @1000/s** | 1 símbolo · ~5 min | 152.039 | 0,63 ms | **1,20 ms** | 3,66 ms | 11,0 ms | 108 ms | 0 | 0 | — | **techo no alcanzado** |

**615.714 órdenes**, 100 % de checks correctos, 0 rechazos, 0 violaciones de routing y 1 sola iteración descartada en toda la serie.

## Percentiles internos del motor — `ACUMULADO`

| Corrida | Órdenes | total p50 | **total p95** | total p99 | total p99.9 | espera p95 | **servicio p50** | servicio p95 | servicio max |
|---|---|---|---|---|---|---|---|---|---|
| F1 · 17/s · 18 libros por shard | 12.240 | 131 µs | **272 µs** | 548 µs | 1,60 ms | 207 µs | **27 µs** | 84 µs | 17,2 ms |
| F2+F3 · pico 84/s · 18 libros | 167.429 | 77 µs | **174 µs** | 330 µs | 1,74 ms | 148 µs | **10 µs** | 35 µs | **300 ms** |
| F4 · 84/s · 1 libro | 167.429 | 69 µs | **149 µs** | 244 µs | 640 µs | 133 µs | **6 µs** | 18 µs | 22,9 ms |
| F4-explore @250/s | 39.539 | 46 µs | **127 µs** | 228 µs | 573 µs | 110 µs | **2 µs** | 15 µs | 2,54 ms |
| F4-explore @500/s | 77.038 | 32 µs | **73 µs** | 160 µs | 423 µs | 67 µs | **≤1 µs** | 7 µs | 3,37 ms |
| F4-explore @1000/s | 152.039 | 22 µs | **46 µs** | 108 µs | 305 µs | 43 µs | **≤1 µs** | 3 µs | 2,02 ms |

## Lectura de los resultados

**F1 valida ASR-02** con p95 = 7,54 ms contra 200 ms de presupuesto (margen ≈ 27×) y **F2+F3 valida ASR-03** con p95 = 4,58 ms (margen ≈ 44×). Las dos fases oficiales pasaron sus cuatro umbrales.

**El aislamiento del sharding queda demostrado empíricamente.** `shard_routing_violations = 0` sobre 179.669 órdenes en F1 y F2: cada símbolo fue respondido siempre por el mismo shard. Es la recomendación 2 de la retroalimentación del profesor, que antes se sostenía solo por el argumento matemático. En F1 el reparto fue 6.131/6.109 órdenes — 50,1 % / 49,9 %, el balance que los 36 símbolos fueron elegidos para producir.

**La partición caliente, demostrada por ausencia.** En F4 solo el shard 1 emitió línea `ACUMULADO`, con las 167.429 órdenes; el shard 0 no emitió ninguna porque no procesó ni una. Un único hilo absorbió todo el pico contractual con `servicio p50 = 6 µs` y `total p95 = 149 µs`.

### El patrón aporta el 3,7 % del tiempo, en toda la distribución

Con los dos relojes midiendo el mismo estadístico, la resta es una atribución limpia:

| Fase | k6 p95 | Motor p95 | Motor / total |
|---|---|---|---|
| F1 | 7,54 ms | 272 µs | 3,6 % |
| F2+F3 | 4,58 ms | 174 µs | 3,8 % |
| F4 | 4,00 ms | 149 µs | 3,7 % |
| explore @250/s | 3,54 ms | 127 µs | 3,6 % |
| explore @500/s | 2,03 ms | 73 µs | 3,6 % |
| explore @1000/s | 1,20 ms | 46 µs | 3,8 % |

**El 96 % del tiempo que ve el cliente es transporte** —gRPC, el salto por el router y la red virtualizada de Docker en macOS—, y la proporción se mantiene constante en las seis fases. Los valores absolutos extremo a extremo miden sobre todo el montaje; lo que se sostiene del patrón es su contribución propia y el presupuesto que deja libre.

### El costo por orden cae con la carga

```
servicio p50:   27 µs → 10 µs →  6 µs →  2 µs → ≤1 µs → ≤1 µs
servicio p95:   84 µs → 35 µs → 18 µs → 15 µs →  7 µs →  3 µs
                17/s    84/s    84/s    250/s   500/s   1000/s
                18 libros ────┘ └──── 1 libro ───────────────
```

**Al menos 27× más barato procesar una orden** —28× mirando el p95—, sin cambiar una línea de código. El trabajo es el mismo, un cruce sobre un `TreeMap`; lo que cambia es que a mayor tasa y con menos libros los datos permanecen calientes en la caché del núcleo y el Disruptor procesa lotes más grandes por pasada. Es la *mechanical sympathy* que el diseño declara como mecanismo del patrón, aislada en el componente en vez de inferida de los números extremo a extremo. En los dos puntos más rápidos el `servicio p50` toca el piso del instrumento, así que la caída real es mayor que la medida.

La espera acompaña (207 → 43 µs): a tasa baja el hilo matcher se duerme y casi toda la espera es el costo de despertarlo bajo `BlockingWaitStrategy` — a 17/s son **207 de 272 µs, el 76 % de la latencia interna**. Es la palanca de latencia más grande que queda en el motor, y confirma la deuda de decisión sobre la estrategia de espera.

### F3: el backlog drena

Criterio de F3: la latencia vuelve al valor de F1. Separando las ventanas de 10 s de F2 por régimen (mediana entre ventanas, con rango):

| Ventana | Ventanas | total p95 | espera p95 |
|---|---|---|---|
| F1 baseline (referencia) | 144 | 256 µs [166–716] | 203 µs [102–586] |
| F2 pico 84/s sostenido | 378 | 157 µs [111–396] | 138 µs [92–375] |
| **F3 retorno a régimen** | 24 | **149 µs** [113–1975] | **137 µs** [95–550] |

La espera vuelve a 137 µs contra los 203 µs de F1: no solo drena, queda por debajo. El criterio se cumple con evidencia propia; antes solo existía el p95 agregado de F2+F3.

### Atascos aislados de cientos de milisegundos

El acumulado revela eventos que ninguna ventana individual mostraba:

```
F2+F3   servicio max = 300 ms      espera max = 375 ms
F1      servicio max =  17 ms
F4      servicio max =  23 ms
```

En F2 una sola orden tardó **300 ms** en procesarse y otra esperó **375 ms** en el ring buffer. Contra un SLA de 200 ms, un solo evento así lo incumple por sí mismo. Son rarísimos —el p99.9 se queda en 1,74 ms— pero existen.

No son pausas normales de ZGC, que promete sub-milisegundo. Los sospechosos son compilación del JIT, carga de clases, o que el sistema operativo desprograme el contenedor mientras k6 compite por CPU en la misma máquina. **No se puede distinguir sin JFR**, que está declarado en el diseño y no implementado: esto convierte esa carencia de casilla vacía en herramienta necesaria. Que F4 —con un shard ocioso, es decir un núcleo libre— registre un máximo 13× menor apoya la hipótesis de contención en el host, pero con una sola corrida por fase no se puede afirmar.

### El generador sostuvo 1.000 órdenes/s

En la corrida anterior el punto de 1.000/s descartó 337 iteraciones. Repetido sobre topología limpia: **0 descartes, 152.039 órdenes**, y el motor registrando su mejor `total p95` de la serie (46 µs). El techo de un shard sigue sin alcanzarse, y esta vez tampoco lo alcanzó el instrumento. La diferencia con la corrida previa es que allí las tres exploraciones compartían una topología que llevaba más de una hora en pie.

## Desviaciones declaradas de esta corrida

- **El ciclo se ejecutó fase por fase.** `make e2e` requiere ~2 h y el entorno corta las tareas largas; como cada fase levanta su propia topología, ejecutarlas por separado es equivalente al ciclo completo.
- **Cada fase arranca con la JVM fría.** Es el precio de que el `ACUMULADO` sea de una sola fase. F2 y F4 tienen 2 min de precalentamiento en el perfil; F1 no, y se nota en su cola (p99.9 = 49,6 ms).
- Una sola repetición por fase, sin intervalos de confianza entre corridas.

## Salidas crudas

```text
F1 · PHASE=f1 (oficial)
  ✓ p(95)<200 → p(95)=7.54ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100%
  grpc_req_duration: avg=4.48ms p(50)=4.23ms p(95)=7.54ms p(99)=10.59ms p(99.9)=49.58ms max=143.78ms
  ACUMULADO shard=0 n=6131 total p50=131us p95=274us p99=581us p99.9=1655us max=18799us
            | espera p50=97us p95=209us p99.9=1168us max=5099us | servicio p50=28us p95=84us p99.9=1231us max=13703us
  ACUMULADO shard=1 n=6109 total p50=131us p95=269us p99=514us p99.9=1545us max=19599us
            | espera p50=100us p95=205us p99.9=951us max=3855us | servicio p50=26us p95=85us p99.9=1124us max=17151us

F2+F3 · PHASE=f2 (oficial)
  ✓ p(95)<200 → p(95)=4.58ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100%
  grpc_req_duration: avg=2.7ms p(50)=2.27ms p(95)=4.58ms p(99)=7.72ms p(99.9)=50.96ms max=511.94ms
  iterations: 167429  69.753876/s (= teórico del perfil)
  ACUMULADO shard=1 n=83811 total p50=77us p95=174us p99=330us p99.9=1550us max=191103us
            | espera p50=64us p95=148us p99.9=1189us max=189311us | servicio p50=10us p95=35us p99.9=403us max=179455us
  ACUMULADO shard=0 n=83618 total p50=78us p95=173us p99=329us p99.9=1932us max=374783us
            | espera p50=66us p95=147us p99.9=1737us max=374783us | servicio p50=10us p95=34us p99.9=353us max=300031us

F4 · PHASE=f4 (partición caliente, exploratoria)
  grpc_req_duration: avg=2.38ms p(50)=2.13ms p(95)=4ms p(99)=6.12ms p(99.9)=21.17ms max=290.33ms
  iterations: 167429  69.761023/s · 0 rechazos · 0 descartes
  ACUMULADO shard=1 n=167429 total p50=69us p95=149us p99=244us p99.9=640us max=41663us
            | espera p50=60us p95=133us p99.9=592us max=41663us | servicio p50=6us p95=18us p99.9=128us max=22911us
  (shard=0 no emitió línea: no procesó ninguna orden — el 100 % del tráfico cayó en shard=1)

F4-explore · techo de un shard
  @250/s   grpc_req_duration: avg=1.76ms p(50)=1.28ms p(95)=3.54ms p(99.9)=29.55ms max=167.94ms  n=39539  descartes=0
           ACUMULADO shard=1 n=39539 total p50=46us p95=127us p99.9=573us | servicio p50=2us p95=15us
  @500/s   grpc_req_duration: avg=1.27ms p(50)=909µs p(95)=2.03ms p(99.9)=80.88ms max=199.38ms  n=77038  descartes=1
           ACUMULADO shard=1 n=77038 total p50=32us p95=73us p99.9=423us | servicio p50=1us p95=7us
  @1000/s  grpc_req_duration: avg=776µs p(50)=632µs p(95)=1.2ms p(99.9)=11ms max=108.36ms  n=152039  descartes=0
           ACUMULADO shard=1 n=152039 total p50=22us p95=46us p99.9=305us | servicio p50=1us p95=3us
           ← el motor sostuvo 1.000 ord/s con su mejor p95 interno de toda la serie
```

## Barrido del tiempo de servicio (S)

**Fecha:** 2 de septiembre de 2026 · **Comando:** `make sweep-service SWEEP_MICROS="0 1000 5000 8000 10000 12000"`

> Este barrido es **anterior** al cambio que hizo al motor publicar percentiles acumulados, así que sus cifras internas son medias entre ventanas de 10 s, no percentiles de población — quedan etiquetadas como tales abajo. Sus cifras de k6, que son las que fijan el presupuesto, sí son percentiles verdaderos y no están afectadas.

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

Cifras internas del shard, **media entre las ventanas de 10 s del pico** (84/s sostenidos) — no percentiles de población; sirven para comparar entre sí porque las cuatro se calculan igual:

| S | espera p50 | espera p95 | servicio p50 | La cola es el… |
|---|---|---|---|---|
| 5.000 µs | 0,1 ms | 49,0 ms | 2,88 ms | 82 % del total |
| 8.000 µs | 6,0 ms | 139,5 ms | 4,60 ms | 91 % |
| 10.000 µs | 59,2 ms | 304,2 ms | 5,75 ms | 96 % |
| 12.000 µs | 1.334 ms | 1.802 ms | 6,90 ms | 99 % |

Todo el argumento en dos columnas: **el servicio crece lineal** (2,88 → 6,90 ms, lo configurado) mientras **la espera crece 13.000×** (0,1 → 1.334 ms). El sistema no se degrada suavemente: cae por un acantilado al acercarse ρ a 1. Es también la utilidad práctica de la descomposición — distingue «hay que abaratar la orden» de «hay que shardear más». A partir de ~5 ms, la respuesta es shardear.

### Validación del modelo en caliente

La mediana teórica de la mezcla es 0,575 × S. Medido dentro del contenedor, bajo carga y en saturación (media entre ventanas del pico):

| S configurado | servicio p50 predicho | medido |
|---|---|---|
| 5.000 µs | 2.874 µs | 2.880 µs |
| 8.000 µs | 4.598 µs | 4.600 µs |
| 10.000 µs | 5.748 µs | 5.750 µs |
| 12.000 µs | 6.898 µs | 6.900 µs |

Cuatro de cuatro. El modelo entrega exactamente el tiempo que declara.

### Tres hallazgos

**1. El baseline medía transporte, no el patrón.** En `S=0` el motor aporta **0,11 ms** de los 2,49 ms extremo a extremo: el **96 %** es gRPC, router y la red virtualizada de Docker en macOS. Dentro de esos 0,11 ms, la espera (156 µs p95) es el despertar del hilo matcher dormido bajo `BlockingWaitStrategy`, y el trabajo real son 13 µs. El mismo reparto se confirmó en la corrida completa (F1: 272 µs de motor acumulado sobre 7,54 ms extremo a extremo — el 3,6 %): los p95 reportados miden, mayoritariamente, la latencia de una máquina virtual, no el patrón. También eleva la prioridad de la deuda de decisión sobre la estrategia de espera.

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

Seis corridas, 615.714 órdenes, 100 % procesadas, 0 rechazos, 0 violaciones de routing y una sola iteración descartada. **H1 y H2 se cumplen** con márgenes de 27× y 44× bajo arribo estocástico, con el sharding balanceado y verificado en vivo; **F3 confirma que la escalabilidad exigida es transitoria** — el backlog drena y la latencia vuelve por debajo del baseline.

El patrón aporta el **3,7 %** de la latencia que ve el cliente, proporción constante en las seis fases: los valores absolutos miden sobre todo el montaje, no el motor. Lo que sí se sostiene del patrón es su contribución propia (272 µs de p95 en F1, de los que 76 % es despertar un hilo dormido) y el presupuesto que deja libre.

**H2b no se refuta: se reformula.** La partición caliente absorbió las 167.429 órdenes del pico contractual en un solo hilo sin degradarse, y el techo de un shard no se alcanzó ni a 1.000 órdenes/s. Pero ese techo es 1/S y estas corridas lo midieron con un `match()` de microsegundos. El barrido de tiempo de servicio acota el resultado a un **presupuesto**: el patrón sostiene el ASR con todo el pico en una sola partición mientras el costo por orden se mantenga bajo **~8,5 ms**. Por encima, H2b se manifiesta.

Tres frentes abiertos: los atascos aislados de 300 ms **exigen JFR** para atribuirse a GC, JIT o contención del host; la cláusula de H2 sobre no exigir más de un núcleo por partición sigue **sin evidencia** porque no se midió CPU por proceso; y la de H1 sobre journaling fuera del camino crítico no se probó porque **no hay journaling** en el PoC. Verificar el presupuesto contra la lógica de negocio real y repetir en el banco de tres nodos (TEC-2) son los siguientes pasos.
