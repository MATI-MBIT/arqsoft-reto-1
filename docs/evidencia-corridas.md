---
title: Evidencia de corridas
nav_order: 4
---

# Evidencia de corridas — Experimento E01

Registro de la ejecución vigente del PoC con sus salidas crudas y su interpretación. Esta página es la **evidencia externa** enlazada desde la pestaña Experiments de Helix (E01 → Links & evidence).

Tres bloques, en orden de importancia:

1. **Serie B** — corrida oficial con el punto de operación declarado (`S = 8 ms` por orden). Es la evidencia que sostiene ASR-02 y ASR-03.
2. **Serie A** — la misma secuencia con la lógica de negocio apagada (`S = 0`). Mide el costo propio del patrón, aislado del trabajo.
3. **Barrido de S** — el presupuesto: cuánto puede costar una orden sin romper el SLA.

> **Ninguna cifra de este PoC se lee sin su `S` al lado.** El motor no implementa la lógica de negocio; su costo por orden es un parámetro declarado del experimento (`BIZ_MICROS`), y de él dependen el techo del shard (`1/S`), el reparto entre motor y transporte, y si la partición caliente amenaza el SLA. El shard publica su punto de operación al arrancar, y el arnés lo estampa en el nombre del directorio de resultados y en `manifiesto.txt`.

**Entorno:** una sola máquina (macOS, Apple Silicon, 14 vCPU), Docker Compose — `ingest-router` + **N=2 shards** LMAX (`RING_SIZE=16384`, `QUEUE_CAPACITY=10000`, ZGC) —, generador k6 ≥ 0.49 con gRPC nativo en el host, tráfico por loopback. **Fechas: Serie A y barridos, 2 de septiembre de 2026; Serie B, 3 de septiembre.** Generador con arribo estocástico (desplazamiento exponencial por iteración, Ca² = 0,89), 36 símbolos que el hash reparte 18/18 con N=2, y umbrales de rechazos, iteraciones descartadas y violaciones de routing. **Cada fase corre sobre una topología recién levantada**, de modo que sus percentiles internos son de esa fase y solo de esa. Limitación declarada en E01: valida el patrón, no el dimensionamiento (sin red real de TEC-2, sin `cpuset`).

## Cómo se calcula cada número

Tres estadísticos distintos, que no son intercambiables:

- **`grpc_req_duration` de k6** — percentiles verdaderos sobre todas las peticiones de la fase, medidos por el generador. Incluyen red, router y motor.
- **`ACUMULADO` del motor** — percentiles verdaderos sobre todas las órdenes de la fase, medidos dentro del shard (arribo → materialización). El shard suma cada ventana a un histograma acumulado y lo publica al recibir `SIGTERM`. **Comparables cifra a cifra con los de k6**: su resta es el costo de transporte.
- **Ventanas de 10 s** — el shard también emite un histograma cada 10 s y lo reinicia. Sirven para ver la *evolución* dentro de una fase (por ejemplo si el backlog drena), y se reportan como **mediana entre ventanas con [mín–máx]**. La mediana de los p95 por ventana **no es** el p95 de la población.

Validación de la contabilidad: las órdenes contadas por el motor coinciden exactamente con las iteraciones de k6 en las seis fases. Límite del instrumento: la latencia interna se registra en microsegundos enteros con piso en 1, así que `1 µs` significa «≤ 1 µs».

## Serie B — punto de operación declarado (`BIZ_MICROS=8000`) · **evidencia principal**

**Fecha:** 3 de septiembre de 2026 · **Comando:** `make e2e BIZ_MICROS=8000` · **Resultados:** `20260902-192250-full-S8000us`

Punto de operación **S = 8 ms por orden**: el escenario **C** de la tabla de escenarios del barrido (más abajo) —riesgo y saldos consultados a un servicio o BD en cada orden—, que es el más exigente que sigue siendo arquitectónicamente plausible. Consume el 63 % del presupuesto de 12,7 ms. Si el ASR se cumple aquí, se cumple también en los escenarios A y B por añadidura.

### Medición de k6, extremo a extremo

| Corrida | Perfil | Órdenes | p50 | **p95** | p99 | p99.9 | max | Rechazos | Descartes | Veredicto |
|---|---|---|---|---|---|---|---|---|---|---|
| **F1 — Baseline (oficial)** | 17/s · 12 min · 36 símbolos | 12.241 | 7,86 ms | **31,51 ms** | 140 ms | 153 ms | 324 ms | 0 | 0 | ✅ margen 6,3× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s · 40 min | 167.429 | 5,61 ms | **74,32 ms** | 141 ms | 231 ms | 534 ms | 0 | 0 | ✅ margen 2,7× |
| **F4 — Partición caliente** | 84/s en 1 símbolo · 40 min | 167.429 | 11,27 ms | **148,09 ms** | 243 ms | 352 ms | 456 ms | 0 | 0 | ⚠️ margen 1,35× |
| **F4-explore @250/s** | 1 símbolo · ~5 min | 23.183 | 6,14 s | **6,97 s** | 7,56 s | 7,86 s | 7,89 s | 0 | 16.356 | ❌ saturado |
| **F4-explore @500/s** | 1 símbolo · ~5 min | 23.983 | 6,24 s | **7,03 s** | 7,58 s | 7,90 s | 7,94 s | 0 | 53.057 | ❌ saturado |
| **F4-explore @1000/s** | 1 símbolo · ~5 min | 24.345 | 6,27 s | **7,03 s** | 7,57 s | 7,89 s | 7,93 s | 0 | 127.694 | ❌ saturado |

**418.610 órdenes**, 100 % de checks correctos, 0 rechazos por backpressure y 0 violaciones de routing. Las dos fases oficiales pasaron sus cuatro umbrales.

### Percentiles internos del motor — `ACUMULADO` (peor shard)

| Corrida | Órdenes | total p95 | total p99 | **espera p95** | **servicio p50** | **servicio p95** | Motor / k6 |
|---|---|---|---|---|---|---|---|
| F1 · 17/s | 12.241 | 27,76 ms | 138,11 ms | 3,79 ms | 4,627 ms | 27,63 ms | **88 %** |
| F2+F3 · pico 84/s | 167.429 | 73,15 ms | 139,13 ms | 50,08 ms | 4,603 ms | 27,60 ms | **98 %** |
| F4 · 84/s en 1 libro | 167.429 | 147,07 ms | 241,41 ms | 137,09 ms | 4,599 ms | 27,60 ms | **99 %** |
| F4-explore @250/s | 23.183 | 6.971 ms | 7.565 ms | 6.963 ms | 4,599 ms | 27,60 ms | ~100 % |
| F4-explore @500/s | 23.983 | 7.037 ms | 7.590 ms | 7.029 ms | 4,599 ms | 27,60 ms | ~100 % |
| F4-explore @1000/s | 24.345 | 7.033 ms | 7.582 ms | 7.029 ms | 4,599 ms | 27,60 ms | ~100 % |

### Lectura de los resultados

**ASR-02 y ASR-03 se validan con lógica de negocio encendida.** F1 con p95 = 31,51 ms (margen 6,3×) y F2+F3 con p95 = 74,32 ms (margen 2,7×), sobre 179.670 órdenes y con un costo por orden de 8 ms. Es una afirmación de otra naturaleza que la de la Serie A: allí el margen de 44× se medía contra un `match()` de 13 µs sobre un `TreeMap`.

**El motor explica la latencia, no el transporte.** Pasa del 88 % en F1 al 99 % en F4. La conclusión de la Serie A —«el 96 % es transporte»— queda confinada al caso `S = 0`.

#### Servicio y espera se separan limpiamente

`servicio p95` vale **27,60 ms en las seis fases**, con la carga variando de 17 a 1.000 órd/s y la distribución pasando de 36 símbolos a uno solo. Toda la degradación entra por la cola:

| Fase | Carga · distribución | espera p95 | servicio p95 |
|---|---|---|---|
| F1 | 17/s · repartida | 3,79 ms | 27,60 ms |
| F2+F3 | 84/s · repartida | 50,08 ms | 27,60 ms |
| F4 | 84/s · **1 partición** | 137,09 ms | 27,60 ms |
| explore @1000/s | 1.000/s · 1 partición | 7.029 ms | 27,60 ms |

El tiempo de servicio es propiedad del **trabajo**; la espera es propiedad de la **carga**. Es lo que permite decidir entre abaratar la orden y agregar particiones sin adivinar.

#### El modelo reproduce su distribución clase por clase

Con `unit = 8.000/1,74 = 4.598 µs`, la mezcla 90/9/1 debería aparecer en tres percentiles distintos del tiempo de servicio, y aparece:

| Percentil | Clase | Predicho | Medido (F1) |
|---|---|---|---|
| p50 | 90 % · ×1 | 4.598 µs | **4.627 µs** |
| p95 | 9 % · ×6 | 27.586 µs | **27.615 µs** |
| p99 | 1 % · ×30 | 137.931 µs | **138.111 µs** |

Tres órdenes de magnitud, tres aciertos. El modelo no solo entrega la media que declara: entrega la distribución.

Consecuencia práctica: **la clase pesada del 1 % cuesta 138 ms de servicio ella sola**, el 69 % del presupuesto en una sola orden y sin nada de cola. Por eso el p99 extremo a extremo se pega a 140 ms en F1 y F2 aunque el p95 esté en 31 y 74 ms. Si el ASR pidiera p99 ≤ 200 ms en vez de p95, S = 8 ms estaría al borde.

#### H2b se manifestó: la partición caliente duplica el p95

Misma tasa, mismo S; lo único que cambia es la distribución de símbolos:

| | F2+F3 · repartida 18/18 | F4 · todo en 1 símbolo | |
|---|---|---|---|
| k6 p95 | 74,32 ms | **148,09 ms** | ×2,0 |
| espera p95 | 50,08 ms | **137,09 ms** | ×2,7 |
| servicio p95 | 27,60 ms | 27,60 ms | invariante |

En la Serie A, F4 salía **más rápida** que F2 (4,00 contra 4,58 ms) y se concluyó que H2b «no se manifestó». Con lógica realista la hipótesis de mayor riesgo del experimento pasa de no observarse a estar **medida: ×2,0 en p95 y ×2,7 en espera**. Sigue cumpliendo el ASR, pero con 1,35× de margen en lugar de los 50× que aparentaba.

#### El techo de un shard es 1/S, y ahora es medible

Con S = 8 ms el techo teórico de una partición es **125 órd/s**. Las tres exploraciones lo confirman por saturación: se ofrecieron 250, 500 y 1.000 órd/s y el motor entregó **23.183, 23.983 y 24.345** órdenes — prácticamente lo mismo. Cuadruplicar la carga ofrecida entregó apenas un 5 % más de trabajo; solo multiplicó los descartes del generador (16.356 → 53.057 → 127.694). Es la firma canónica de un servidor saturado.

| | Serie A (`S=0`) | Serie B (`S=8 ms`) |
|---|---|---|
| Techo de un shard | «> 1.000 órd/s», no alcanzado | **125 órd/s** |
| Pico contractual sobre el techo | irrelevante | **67 %** (84 de 125) |

La cifra de «techo no alcanzado» de la Serie A era una propiedad del `TreeMap`. El techo real depende del costo por orden, y con el pico contractual ocupando el 67 % de una sola partición, el margen de dimensionamiento es mucho más estrecho de lo que sugería.

#### Se degrada por latencia, nunca por rechazo

**0 rechazos por backpressure en las seis fases**, incluso con la cola en 7 segundos y ρ = 8. Lo que delata la saturación son los descartes del generador, no el motor. El criterio de «0 rechazos» de F1–F3, por sí solo, no protege de nada — confirma el hallazgo 4 del barrido en una corrida larga.

#### El perfil corto replica al oficial

F4 de esta serie dio **148,09 ms**; el punto `S=8000` del barrido corto de partición caliente había dado **148,19 ms** — con 14.600 órdenes contra 167.429, 4,5 min contra 40, y en instancias de contenedor distintas. La coincidencia está más cerca de lo que la varianza entre corridas justifica, así que hay algo de suerte; pero desmiente la limitación declarada de que el perfil corto fuera solo una cota inferior. Para esta medición no sesga.

### Desviaciones declaradas de esta corrida

Mismo entorno y limitaciones que la Serie A (macOS, Docker en VM, sin `cpuset`, sin red real de TEC-2). Dos específicas:

- **El p99.9 excede el SLA en el pico**: 231 ms en F2+F3 y 352 ms en F4, contra 200 ms. El umbral contractual es sobre p95 y se cumple, pero una de cada mil órdenes lo excede en el pico. Viene de la clase pesada del modelo (138 ms de servicio) sumada a la cola.
- **S = 8 ms es una hipótesis, no una medición.** Es el escenario C estimado, no el costo de una lógica de negocio real, que el PoC no implementa. Lo que la corrida demuestra es que *si* el costo por orden fuera de 8 ms, el ASR se cumple; el número contra el que hay que verificarlo cuando la lógica exista sigue siendo el presupuesto de 12,7 ms.

### Salidas crudas

Directorio: `load/k6/results/20260902-192250-full-S8000us` · `manifiesto.txt`: `biz_micros=8000`, `commit=d5f1dae`, `k6 v2.2.0`.

```text
F1 · PHASE=f1 (oficial)
  ✓ p(95)<200 → p(95)=31.51ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100% (12.241)
  grpc_req_duration: avg=12.83ms p(50)=7.86ms p(95)=31.51ms p(99)=139.77ms p(99.9)=152.9ms max=324.15ms
  ACUMULADO shard=1 n=6145 total p50=4715us p95=27743us p99=138111us p99.9=142719us max=153087us
            | espera p50=75us p95=3549us p99.9=129215us max=148479us | servicio p50=4627us p95=27615us p99.9=138111us max=139519us
  ACUMULADO shard=0 n=6096 total p50=4719us p95=27759us p99=138111us p99.9=141567us max=152831us
            | espera p50=78us p95=3787us p99.9=128255us max=138495us | servicio p50=4627us p95=27631us p99.9=138111us max=138239us
  ← reparto 6.145/6.096 = 50,2 %/49,8 %, el balance que los 36 símbolos producen

F2+F3 · PHASE=f2 (oficial)
  ✓ p(95)<200 → p(95)=74.32ms · ✓ rechazos=0 · ✓ descartes=0 · ✓ routing=0 · checks 100% (167.429)
  grpc_req_duration: avg=16.56ms p(50)=5.61ms p(95)=74.32ms p(99)=140.67ms p(99.9)=230.87ms max=534.19ms
  ACUMULADO shard=1 n=83702 total p50=4635us p95=73151us p99=139135us p99.9=208255us max=315391us
            | espera p50=28us p95=50079us p99.9=181119us max=310783us | servicio p50=4603us p95=27599us p99.9=137983us max=138239us
  ACUMULADO shard=0 n=83727 total p50=4635us p95=72255us p99=138751us p99.9=220287us max=366335us
            | espera p50=27us p95=48671us p99.9=197375us max=332543us | servicio p50=4603us p95=27599us p99.9=137983us max=139519us
  ← el p99.9 (208-220 ms interno, 231 ms extremo a extremo) excede el SLA; el p95 no

F4 · PHASE=f4 (partición caliente, exploratoria)
  grpc_req_duration: avg=37.12ms p(50)=11.27ms p(95)=148.09ms p(99)=242.91ms p(99.9)=351.74ms max=456.1ms
  iterations: 167429 · 0 rechazos · 0 descartes
  ACUMULADO shard=1 n=167429 total p50=10367us p95=147071us p99=241407us p99.9=349951us max=455423us
            | espera p50=3967us p95=137087us p99.9=339967us max=439039us | servicio p50=4599us p95=27599us p99.9=137983us max=138623us
  (shard=0 no emitió línea: no procesó ninguna orden — el 100 % del tráfico cayó en shard=1)
  ← misma tasa que F2 y mismo S; solo cambia la distribución: espera 50→137 ms, servicio idéntico

F4-explore · techo de un shard (1/S = 125 órd/s)
  @250/s   grpc_req_duration: avg=5.15s p(50)=6.14s p(95)=6.97s p(99.9)=7.86s max=7.89s   n=23183  descartes=16356
           ACUMULADO shard=1 n=23183  total p50=6152191us p95=6971391us | espera p95=6963199us | servicio p50=4599us p95=27599us
  @500/s   grpc_req_duration: avg=5.48s p(50)=6.24s p(95)=7.03s p(99.9)=7.9s  max=7.94s   n=23983  descartes=53057
           ACUMULADO shard=1 n=23983  total p50=6250495us p95=7036927us | espera p95=7028735us | servicio p50=4599us p95=27599us
  @1000/s  grpc_req_duration: avg=5.65s p(50)=6.27s p(95)=7.03s p(99.9)=7.89s max=7.93s   n=24345  descartes=127694
           ACUMULADO shard=1 n=24345  total p50=6275071us p95=7032831us | espera p95=7028735us | servicio p50=4599us p95=27599us
  ← cuadruplicar la carga ofrecida entrega un 5 % más de trabajo: el shard está saturado
  ← `servicio p50/p95` idéntico en las seis fases: el tiempo de servicio no se contamina con la carga
```

*(En F4 y las exploraciones k6 omite del resumen los contadores que nunca se incrementaron; su ausencia significa cero. En F1 y F2 aparecen explícitos porque llevan umbral asociado.)*


## Serie A — lógica de negocio APAGADA (`BIZ_MICROS=0`) · referencia

**Fecha:** 2 de septiembre de 2026 · **Comando:** `make e2e` (con `BIZ_MICROS` sin propagar, el defecto que motivó la Serie B)

> **Qué mide.** Con `S = 0` el motor solo ejecuta el `match()` de juguete, así que estas cifras miden **el costo propio del patrón LMAX y el transporte**, no un motor con lógica de negocio. Sus márgenes contra los 200 ms no son extrapolables. Se conserva porque el contraste con la Serie B es en sí un resultado, y porque sigue siendo la mejor medición disponible de lo que cuesta el patrón por sí solo.

| Corrida | Órdenes | p95 (k6) | Motor p95 | espera p95 | servicio p50 |
|---|---|---|---|---|---|
| F1 · 17/s · 36 símbolos | 12.240 | 7,54 ms | 272 µs | 207 µs | 27 µs |
| F2+F3 · pico 84/s | 167.429 | 4,58 ms | 174 µs | 148 µs | 10 µs |
| F4 · 84/s en 1 símbolo | 167.429 | 4,00 ms | 149 µs | 133 µs | 6 µs |
| F4-explore @250/s | 39.539 | 3,54 ms | 127 µs | 110 µs | 2 µs |
| F4-explore @500/s | 77.038 | 2,03 ms | 73 µs | 67 µs | ≤1 µs |
| F4-explore @1000/s | 152.039 | 1,20 ms | 46 µs | 43 µs | ≤1 µs |

615.714 órdenes, 0 rechazos, **0 violaciones de routing** sobre las 179.669 de F1 y F2 —el aislamiento del sharding verificado en vivo, recomendación 2 del profesor— y una sola iteración descartada.

### Los tres resultados de la Serie A que siguen en pie

**El costo propio del patrón es de microsegundos, y tres cuartas partes son despertar un hilo.** A 17/s, 207 de los 272 µs de p95 interno (**76 %**) son el costo de despertar el hilo matcher dormido bajo `BlockingWaitStrategy`; el trabajo real son 13 µs. Eso convierte la deuda de decisión sobre la estrategia de espera en la mayor palanca de latencia que queda en el motor **cuando la lógica de negocio es barata** — con S = 8 ms la espera de despertar es ruido frente a los 4.598 µs de servicio.

**F3 quedó evidenciado con número propio.** La espera interna vuelve a 137 µs contra los 203 µs de F1: el backlog no solo drena, drena por debajo del baseline. La escalabilidad que ASR-03 exige es transitoria y el sistema la absorbe sin dejar deuda.

**Atascos aislados de cientos de milisegundos.** En F2 una orden tardó 300 ms en procesarse y otra esperó 375 ms en el ring buffer, cuando el p99.9 de la fase se queda en 1,74 ms. Un solo evento así incumple el SLA por sí mismo, y **no se pueden atribuir a GC, JIT o contención del host sin JFR**, declarado en el diseño y no implementado.

### Lo que la Serie A hizo creer

| Afirmación con `S = 0` | Con `S = 8 ms` (Serie B) |
|---|---|
| «El 96 % del tiempo es transporte; el motor aporta el 3,7 %» | El motor aporta del **88 % al 99 %**; el transporte es ruido. |
| «H2b no se manifestó: F4 (4,00 ms) salió más rápida que F2 (4,58 ms)» | **Se manifestó: ×2,0 en p95 y ×2,7 en espera.** |
| «El techo de un shard no se alcanzó ni a 1.000 órd/s» | El techo es `1/S` = **125 órd/s**; el pico contractual ocupa el 67 % de una partición. |
| «La latencia mejora al subir la carga» (7,54 → 1,20 ms) | Solo con trabajo despreciable por evento; con S realista crece (31,5 → 148,1 ms). |

El efecto de la última fila es real y tiene mecanismo —más ráfaga significa más eventos por pasada del único escritor y datos calientes en caché, lo contrario de un sistema con locks—, pero queda sepultado por el término de encolamiento en cuanto el trabajo por evento deja de ser despreciable.

Ninguna de las cuatro era un error de medición: las cuatro eran correctas para lo que se midió, y ninguna era extrapolable a un motor con lógica de negocio.

## Barrido del tiempo de servicio (S) — el presupuesto

**Fecha:** 2 de septiembre de 2026 · **Comandos:** `make sweep-service` (perfil oficial) y `make sweep-hot` (peor caso)

### Por qué este barrido

`OrderBook.match()` cuesta ~13 µs medidos. El PoC no implementa validación, control de riesgo, saldos, tipos de orden, comisiones ni generación de trades. Como en un diseño de **un único escritor** ese costo se serializa, fija el techo del shard: `techo = 1/S`, con `ρ = λ·S`. Medir la capacidad con S de microsegundos mide un `TreeMap`, no un motor. Sin estimación del costo real, `BusinessLogicModel` lo convierte en parámetro barrido y el entregable deja de ser un p95 para pasar a ser un **presupuesto**: *cuánta lógica de negocio cabe en el margen*.

El costo depende de dónde viva la lógica, y por eso el presupuesto se contrasta contra tres escenarios:

| Escenario | Qué hace por orden | S estimado |
|---|---|---|
| **A · en proceso** | validación, riesgo, saldos y libro en memoria; sin I/O en el camino crítico — lo que el patrón LMAX propone | ~0,2 ms |
| **B · con durabilidad** | A + journaling del evento antes de responder (la cláusula de H1) | ~1 ms |
| **C · con I/O remoto** | riesgo y saldos consultados a un servicio o BD **por orden** | ~8 ms |

### Perfil oficial (ASR-03) — el presupuesto que rige

Topología N=2, fase F2 corta (~4,5 min), 84 órd/s del pico contractual repartidas 18/18 por el hash. `ρ` calculado sobre las 42 órd/s que recibe cada partición.

| S | ρ | k6 p95 | Motor p95 (`ACUMULADO`) | Espera p95 | Servicio p50 | Motor / k6 | Rechazos | Descartes | Veredicto |
|---|---|---|---|---|---|---|---|---|---|
| 0 | ~0 | **6,31 ms** | 239 µs | 187 µs | 19 µs | **3,8 %** | 0 | 0 | ✅ PASA |
| 5.000 µs | 0,21 | **25,48 ms** | 22,45 ms | 13,69 ms | 2,88 ms | **88 %** | 0 | 0 | ✅ PASA |
| 10.000 µs | 0,42 | **126,65 ms** | 126,46 ms | 101,06 ms | 5,75 ms | **~100 %** | 0 | 0 | ✅ PASA |
| 15.000 µs | 0,63 | **264,78 ms** | 266,75 ms | 246,02 ms | 8,63 ms | ~100 % | 0 | 0 | ❌ FALLA |
| 20.000 µs | 0,84 | **676,59 ms** | 717,31 ms | 692,22 ms | 11,50 ms | ~100 % | 0 | 0 | ❌ FALLA |
| 25.000 µs | 1,05 | **5,48 s** | 6,11 s | 6,08 s | 14,38 ms | ~100 % | 0 | **365** | ❌ FALLA |

*(El p95 del motor supera levemente al de k6 en los puntos altos porque es el del **peor shard**, mientras que el de k6 agrega los dos.)*

> **Presupuesto ≈ 12,7 ms por orden.** Con el pico contractual repartido entre 2 particiones, el patrón LMAX cumple p95 ≤ 200 ms mientras procesar una orden cueste hasta ~12,7 ms. Los tres escenarios caben: A consume el 1,6 % del presupuesto, B el 8 %, C el 63 %.

Acotado por medición —10 ms pasa con 127 ms, 15 ms falla con 265 ms— e interpolado en el cruce.

### Peor caso: todo el pico en una sola partición (F4)

Mismo pico de 84 órd/s, pero el 100 % del tráfico en un único símbolo: la peor distribución posible.

| S | ρ | k6 p95 | Veredicto |
|---|---|---|---|
| 0 | 0,00 | **5,93 ms** | ✅ PASA |
| 1.000 µs | 0,08 | **7,87 ms** | ✅ PASA |
| 5.000 µs | 0,42 | **65,59 ms** | ✅ PASA |
| 8.000 µs | 0,67 | **148,19 ms** | ✅ PASA |
| 10.000 µs | 0,84 | **346,43 ms** | ❌ FALLA |
| 12.000 µs | 1,01 | **2,68 s** | ❌ FALLA (143 descartes) |

> **Presupuesto en partición caliente ≈ 8,5 ms por orden.**

### Cuatro hallazgos

**1. «El 96 % del tiempo es transporte» era un artefacto de medir con la lógica apagada.** Esa conclusión —publicada antes en esta misma página— solo vale en `S=0`. Con lógica de negocio realista el motor pasa de aportar el **3,8 %** de la latencia extremo a extremo a explicarla **prácticamente toda**: ya en S=5 ms son el 88 %, y desde S=10 ms el transporte es ruido. La lectura correcta se invierte: *con la lógica apagada se mide la VM de Docker; con lógica realista se mide el patrón.* Ninguna cifra de capacidad de este PoC debe leerse sin su S al lado — por eso el motor publica su punto de operación al arrancar y el arnés lo estampa en el nombre del directorio y en `manifiesto.txt`.

**2. Shardear compra menos de lo que la teoría promete.** Repartir el mismo pico entre 2 particiones sube el presupuesto de 8,5 ms a 12,7 ms: **1,49×**, no el 2× que predice el modelo de colas. La diferencia es contención: con S≠0 las particiones queman núcleo de verdad y compiten entre sí, con el router y con k6 dentro de la misma VM de Docker. El modelo supone servidores independientes; en este montaje no lo son. Es evidencia cuantificada a favor de `cpuset` y del banco TEC-2, que hasta ahora eran una nota al pie.

**3. El acantilado, en dos columnas.** El servicio crece **lineal** con S (19 µs → 14,4 ms, exactamente lo configurado); la espera en cola crece **32.500×** (187 µs → 6,08 s). El sistema no se degrada suavemente: cae por un precipicio al acercarse ρ a 1. Es también la utilidad práctica de la descomposición espera/servicio — distingue «hay que abaratar la orden» de «hay que shardear más». Por debajo de ~5 ms la respuesta es abaratar; por encima, shardear.

**4. Se degrada por latencia, nunca por rechazo.** Cero rechazos por backpressure en los doce puntos de ambos barridos, incluso con ρ = 1,05 y un p95 de 5,48 s. A ese régimen el déficit es de ~2 órd/s y llenar un ring de 16.384 tomaría horas. **El criterio de «0 rechazos» de F1–F3, por sí solo, no protege de nada**; lo que delata la saturación son los descartes del generador (365 en S=25 ms), no el backpressure del motor.

### Validación del modelo en caliente

La mediana teórica de la mezcla 90/9/1 es 0,575 × S. Medida dentro del contenedor, bajo carga y en saturación:

| S configurado | servicio p50 predicho | medido |
|---|---|---|
| 5.000 µs | 2.875 µs | 2.883 µs |
| 10.000 µs | 5.750 µs | 5.751 µs |
| 15.000 µs | 8.625 µs | 8.631 µs |
| 20.000 µs | 11.500 µs | 11.503 µs |
| 25.000 µs | 14.375 µs | 14.375 µs |

Cinco de cinco. El modelo entrega exactamente el tiempo que declara.

### Tres defectos de instrumentación corregidos

Encontrados al montar este barrido; los tres afectaban a la evidencia previa:

1. **`run-e2e.sh` nunca definía `BIZ_MICROS`**, así que Compose usaba su default `0`: las seis fases de la serie anterior corrieron con la lógica de negocio **apagada**. Ahora es un parámetro explícito, va en el nombre del directorio de resultados y en `manifiesto.txt`, y la corrida avisa si se ejecuta en `0`.
2. **La captura de logs descartaba la línea de provenance.** El motor la emite justamente para que ninguna corrida sea ambigua, y el `grep` de captura la filtraba: la evidencia publicada no podía demostrar con qué S se midió.
3. **El extractor de métricas de k6 leía siempre `0`** en rechazos y descartes. El patrón no estaba anclado y enganchaba la lista de nombres de métricas del encabezado —donde aparecen sin valor— en vez de la línea del resumen. Los 365 descartes de `S=25000` se habrían reportado como cero.

### Limitaciones de estos barridos

Es una **cota inferior conservadora**: macOS con Docker en VM y sin `cpuset`; corridas cortas de 4,5 min en vez de las oficiales de 40 min, con solo 2 min de pico sostenido —lo que hace el p95 algo optimista, porque el 44 % de la corrida transcurre a 17/s—; y una sola repetición por punto, sin intervalos de confianza. En Linux con núcleos dedicados el presupuesto debería salir mayor, y el hallazgo 2 predice que la mejora sería mayor en N=4 que aquí. Fijarlo con rigor pertenece al banco de tres nodos (TEC-2).

## Conclusión del experimento

**Con el punto de operación declarado en 8 ms por orden, H1 y H2 se cumplen:** ASR-02 con p95 = 31,51 ms (margen 6,3×) y ASR-03 con p95 = 74,32 ms (margen 2,7×), sobre 418.610 órdenes bajo arribo estocástico, con el sharding balanceado y verificado en vivo, 0 rechazos y 0 violaciones de routing. **F3 confirma que la escalabilidad exigida es transitoria**: el backlog drena y la latencia vuelve al régimen base.

**El entregable no es un p95: es un presupuesto.** El PoC no implementa la lógica de negocio, y como en un único escritor su costo se serializa, ese costo gobierna todo lo demás. La conclusión falsable es:

> Con el pico contractual repartido entre 2 particiones, el patrón LMAX sostiene p95 ≤ 200 ms mientras **procesar una orden cueste hasta 12,7 ms**; con todo el pico en una sola partición, hasta **8,5 ms**.

Cuando la lógica de negocio real exista, se mide su costo y se compara contra esas dos cifras. No hace falta re-ejecutar el experimento para saber si la arquitectura sirve.

**Cuatro conclusiones de la Serie A quedaron corregidas** al encender la lógica de negocio: el reparto motor/transporte, el veredicto sobre H2b, el techo de un shard y la dirección en que la latencia responde a la carga (tabla en «Lo que la Serie A hizo creer»). Ninguna era un error de medición: las cuatro eran correctas para lo que se midió, y ninguna era extrapolable a un motor con lógica de negocio. Es el argumento de por qué `BIZ_MICROS` es hoy un parámetro obligatorio y registrado de cada corrida.

**Un resultado colateral sobre el sharding.** Repartir el mismo pico entre 2 particiones sube el presupuesto de 8,5 a 12,7 ms: **1,49×**, no el 2× que predice el modelo de colas. Las particiones queman núcleo de verdad y compiten entre sí, con el router y con el generador, dentro de la misma VM. Shardear rinde menos de lo prometido mientras las particiones compartan núcleos — lo que convierte a `cpuset` y al banco TEC-2 de nota al pie en condición de la medición.

**Frentes abiertos.** Los atascos aislados **exigen JFR** para atribuirse a GC, JIT o contención del host; la cláusula de H2 sobre no exigir más de un núcleo por partición sigue **sin evidencia** porque no se midió CPU por proceso — y el hallazgo de 1,49× la vuelve urgente; la de H1 sobre journaling fuera del camino crítico no se probó porque **no hay journaling** en el PoC. El p99.9 excede los 200 ms en el pico (231 ms en F2+F3, 352 ms en F4): si el contrato se endureciera a p99, S = 8 ms no alcanzaría. Verificar el presupuesto contra la lógica de negocio real y repetir en el banco de tres nodos siguen siendo los siguientes pasos.
