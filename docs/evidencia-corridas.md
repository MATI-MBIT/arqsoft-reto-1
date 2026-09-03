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

Punto de operación **S = 8 ms por orden**: el escenario C de la [tabla de escenarios](#por-qué-este-barrido) —riesgo y saldos consultados a un servicio o BD en cada orden—, que es el más exigente que sigue siendo arquitectónicamente plausible. Consume el 63 % del presupuesto de 12,7 ms. Si el ASR se cumple aquí, se cumple también en los escenarios A y B por añadidura.

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

## Serie A — lógica de negocio APAGADA (`BIZ_MICROS=0`) · referencia

> **Qué mide esta serie.** Con `S=0` el motor solo ejecuta el `match()` de juguete, así que estas cifras miden **el patrón LMAX aislado y el transporte**, no un motor con lógica de negocio. Sus márgenes contra los 200 ms no son extrapolables — la Serie B los mide con el punto de operación declarado. Se conserva porque sigue siendo la mejor medición disponible del **costo propio del patrón**: 272 µs de p95 interno en F1, de los que el 76 % es despertar un hilo dormido.

### Resumen — medición de k6, extremo a extremo

| Corrida | Perfil | Órdenes | p50 | **p95** | p99 | p99.9 | max | Rechazos | Descartes | Routing | Veredicto |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **F1 — Baseline (oficial)** | 17/s · 12 min · 36 símbolos | 12.240 | 4,23 ms | **7,54 ms** | 10,6 ms | 49,6 ms | 144 ms | 0 | 0 | 0 | ✅ margen ≈ 27× |
| **F2+F3 — Rampa, pico 30 min y retorno (oficial)** | 17→84/s · 40 min | 167.429 | 2,27 ms | **4,58 ms** | 7,72 ms | 51,0 ms | 512 ms | 0 | 0 | 0 | ✅ margen ≈ 44× |
| **F4 — Partición caliente** | 84/s en 1 símbolo · 40 min | 167.429 | 2,13 ms | **4,00 ms** | 6,12 ms | 21,2 ms | 290 ms | 0 | 0 | — | sin degradación |
| **F4-explore @250/s** | 1 símbolo · ~5 min | 39.539 | 1,28 ms | **3,54 ms** | 7,65 ms | 29,6 ms | 168 ms | 0 | 0 | — | sin degradación |
| **F4-explore @500/s** | 1 símbolo · ~5 min | 77.038 | 0,91 ms | **2,03 ms** | 6,49 ms | 80,9 ms | 199 ms | 0 | 1 | — | sin degradación |
| **F4-explore @1000/s** | 1 símbolo · ~5 min | 152.039 | 0,63 ms | **1,20 ms** | 3,66 ms | 11,0 ms | 108 ms | 0 | 0 | — | **techo no alcanzado** |

**615.714 órdenes**, 100 % de checks correctos, 0 rechazos, 0 violaciones de routing y 1 sola iteración descartada en toda la serie.

### Percentiles internos del motor — `ACUMULADO`

| Corrida | Órdenes | total p50 | **total p95** | total p99 | total p99.9 | espera p95 | **servicio p50** | servicio p95 | servicio max |
|---|---|---|---|---|---|---|---|---|---|
| F1 · 17/s · 18 libros por shard | 12.240 | 131 µs | **272 µs** | 548 µs | 1,60 ms | 207 µs | **27 µs** | 84 µs | 17,2 ms |
| F2+F3 · pico 84/s · 18 libros | 167.429 | 77 µs | **174 µs** | 330 µs | 1,74 ms | 148 µs | **10 µs** | 35 µs | **300 ms** |
| F4 · 84/s · 1 libro | 167.429 | 69 µs | **149 µs** | 244 µs | 640 µs | 133 µs | **6 µs** | 18 µs | 22,9 ms |
| F4-explore @250/s | 39.539 | 46 µs | **127 µs** | 228 µs | 573 µs | 110 µs | **2 µs** | 15 µs | 2,54 ms |
| F4-explore @500/s | 77.038 | 32 µs | **73 µs** | 160 µs | 423 µs | 67 µs | **≤1 µs** | 7 µs | 3,37 ms |
| F4-explore @1000/s | 152.039 | 22 µs | **46 µs** | 108 µs | 305 µs | 43 µs | **≤1 µs** | 3 µs | 2,02 ms |

### Lectura de los resultados

**F1 valida ASR-02** con p95 = 7,54 ms contra 200 ms de presupuesto (margen ≈ 27×) y **F2+F3 valida ASR-03** con p95 = 4,58 ms (margen ≈ 44×). Las dos fases oficiales pasaron sus cuatro umbrales.

**El aislamiento del sharding queda demostrado empíricamente.** `shard_routing_violations = 0` sobre 179.669 órdenes en F1 y F2: cada símbolo fue respondido siempre por el mismo shard. Es la recomendación 2 de la retroalimentación del profesor, que antes se sostenía solo por el argumento matemático. En F1 el reparto fue 6.131/6.109 órdenes — 50,1 % / 49,9 %, el balance que los 36 símbolos fueron elegidos para producir.

**La partición caliente, demostrada por ausencia.** En F4 solo el shard 1 emitió línea `ACUMULADO`, con las 167.429 órdenes; el shard 0 no emitió ninguna porque no procesó ni una. Un único hilo absorbió todo el pico contractual con `servicio p50 = 6 µs` y `total p95 = 149 µs`.

#### El patrón aporta el 3,7 % del tiempo — pero solo con `S=0`

Con los dos relojes midiendo el mismo estadístico, la resta es una atribución limpia:

| Fase | k6 p95 | Motor p95 | Motor / total |
|---|---|---|---|
| F1 | 7,54 ms | 272 µs | 3,6 % |
| F2+F3 | 4,58 ms | 174 µs | 3,8 % |
| F4 | 4,00 ms | 149 µs | 3,7 % |
| explore @250/s | 3,54 ms | 127 µs | 3,6 % |
| explore @500/s | 2,03 ms | 73 µs | 3,6 % |
| explore @1000/s | 1,20 ms | 46 µs | 3,8 % |

**Con la lógica apagada, el 96 % del tiempo que ve el cliente es transporte** —gRPC, el salto por el router y la red virtualizada de Docker en macOS—, y la proporción se mantiene constante en las seis fases. Los valores absolutos extremo a extremo miden sobre todo el montaje; lo que se sostiene del patrón es su contribución propia y el presupuesto que deja libre.

#### El costo por orden cae con la carga

```
servicio p50:   27 µs → 10 µs →  6 µs →  2 µs → ≤1 µs → ≤1 µs
servicio p95:   84 µs → 35 µs → 18 µs → 15 µs →  7 µs →  3 µs
                17/s    84/s    84/s    250/s   500/s   1000/s
                18 libros ────┘ └──── 1 libro ───────────────
```

**Al menos 27× más barato procesar una orden** —28× mirando el p95—, sin cambiar una línea de código. El trabajo es el mismo, un cruce sobre un `TreeMap`; lo que cambia es que a mayor tasa y con menos libros los datos permanecen calientes en la caché del núcleo y el Disruptor procesa lotes más grandes por pasada. Es la *mechanical sympathy* que el diseño declara como mecanismo del patrón, aislada en el componente en vez de inferida de los números extremo a extremo. En los dos puntos más rápidos el `servicio p50` toca el piso del instrumento, así que la caída real es mayor que la medida.

La espera acompaña (207 → 43 µs): a tasa baja el hilo matcher se duerme y casi toda la espera es el costo de despertarlo bajo `BlockingWaitStrategy` — a 17/s son **207 de 272 µs, el 76 % de la latencia interna**. Es la palanca de latencia más grande que queda en el motor, y confirma la deuda de decisión sobre la estrategia de espera.

#### F3: el backlog drena

Criterio de F3: la latencia vuelve al valor de F1. Separando las ventanas de 10 s de F2 por régimen (mediana entre ventanas, con rango):

| Ventana | Ventanas | total p95 | espera p95 |
|---|---|---|---|
| F1 baseline (referencia) | 144 | 256 µs [166–716] | 203 µs [102–586] |
| F2 pico 84/s sostenido | 378 | 157 µs [111–396] | 138 µs [92–375] |
| **F3 retorno a régimen** | 24 | **149 µs** [113–1975] | **137 µs** [95–550] |

La espera vuelve a 137 µs contra los 203 µs de F1: no solo drena, queda por debajo. El criterio se cumple con evidencia propia; antes solo existía el p95 agregado de F2+F3.

#### Atascos aislados de cientos de milisegundos

El acumulado revela eventos que ninguna ventana individual mostraba:

```
F2+F3   servicio max = 300 ms      espera max = 375 ms
F1      servicio max =  17 ms
F4      servicio max =  23 ms
```

En F2 una sola orden tardó **300 ms** en procesarse y otra esperó **375 ms** en el ring buffer. Contra un SLA de 200 ms, un solo evento así lo incumple por sí mismo. Son rarísimos —el p99.9 se queda en 1,74 ms— pero existen.

No son pausas normales de ZGC, que promete sub-milisegundo. Los sospechosos son compilación del JIT, carga de clases, o que el sistema operativo desprograme el contenedor mientras k6 compite por CPU en la misma máquina. **No se puede distinguir sin JFR**, que está declarado en el diseño y no implementado: esto convierte esa carencia de casilla vacía en herramienta necesaria. Que F4 —con un shard ocioso, es decir un núcleo libre— registre un máximo 13× menor apoya la hipótesis de contención en el host, pero con una sola corrida por fase no se puede afirmar.

#### El generador sostuvo 1.000 órdenes/s

En la corrida anterior el punto de 1.000/s descartó 337 iteraciones. Repetido sobre topología limpia: **0 descartes, 152.039 órdenes**, y el motor registrando su mejor `total p95` de la serie (46 µs). El techo de un shard sigue sin alcanzarse, y esta vez tampoco lo alcanzó el instrumento. La diferencia con la corrida previa es que allí las tres exploraciones compartían una topología que llevaba más de una hora en pie.

### Desviaciones declaradas de esta corrida

- **El ciclo se ejecutó fase por fase.** `make e2e` requiere ~2 h y el entorno corta las tareas largas; como cada fase levanta su propia topología, ejecutarlas por separado es equivalente al ciclo completo.
- **Cada fase arranca con la JVM fría.** Es el precio de que el `ACUMULADO` sea de una sola fase. F2 y F4 tienen 2 min de precalentamiento en el perfil; F1 no, y se nota en su cola (p99.9 = 49,6 ms).
- Una sola repetición por fase, sin intervalos de confianza entre corridas.

### Salidas crudas

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

**Tres conclusiones de la Serie A quedaron corregidas** al encender la lógica de negocio:

| Afirmación con `S = 0` | Con `S = 8 ms` |
|---|---|
| «El 96 % del tiempo es transporte; el motor aporta el 3,7 %» | El motor aporta del **88 % al 99 %**. El transporte es ruido. |
| «H2b no se manifestó: la partición caliente no degradó el servicio» | **Se manifestó: ×2,0 en p95 y ×2,7 en espera** frente a la carga repartida. |
| «El techo de un shard no se alcanzó ni a 1.000 órd/s» | El techo es `1/S` = **125 órd/s**. El pico contractual ocupa el 67 % de una partición. |

Ninguna era un error de medición: las tres eran correctas para lo que se midió, y ninguna era extrapolable a un motor con lógica de negocio. Es el argumento de por qué `BIZ_MICROS` es hoy un parámetro obligatorio y registrado de cada corrida.

**Un resultado colateral sobre el sharding.** Repartir el mismo pico entre 2 particiones sube el presupuesto de 8,5 a 12,7 ms: **1,49×**, no el 2× que predice el modelo de colas. Las particiones queman núcleo de verdad y compiten entre sí, con el router y con el generador, dentro de la misma VM. Shardear rinde menos de lo prometido mientras las particiones compartan núcleos — lo que convierte a `cpuset` y al banco TEC-2 de nota al pie en condición de la medición.

**Frentes abiertos.** Los atascos aislados **exigen JFR** para atribuirse a GC, JIT o contención del host; la cláusula de H2 sobre no exigir más de un núcleo por partición sigue **sin evidencia** porque no se midió CPU por proceso — y el hallazgo de 1,49× la vuelve urgente; la de H1 sobre journaling fuera del camino crítico no se probó porque **no hay journaling** en el PoC. El p99.9 excede los 200 ms en el pico (231 ms en F2+F3, 352 ms en F4): si el contrato se endureciera a p99, S = 8 ms no alcanzaría. Verificar el presupuesto contra la lógica de negocio real y repetir en el banco de tres nodos siguen siendo los siguientes pasos.
