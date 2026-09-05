---
title: Experimento E01 (hipótesis reformuladas)
nav_order: 2.7
---

# Las hipótesis reformuladas — apuesta de diseño sin repetir el requisito

Este documento reformula las tres hipótesis del experimento E01 (H1, H2, H2b) como "apuestas de diseño", respondiendo a retroalimentación de experto que señaló que las hipótesis originales repetían el requisito de calidad en vez de focalizarse en el mecanismo propuesto. La versión técnica completa está en [Experimento E01](experimento-e01.html); las versiones intermedias en [Experimento E01 v2](experimento-e01_v2.html).

---

## Nivel 2 — Para equipos técnicos nuevos en el proyecto

### El error original: repetir el requisito en la hipótesis

La retroalimentación señaló que las hipótesis iniciales cometían un error de estructura: al formularlas, se transcribía el requisito de calidad dentro de la apuesta, confundiendo la petición (lo que se pide) con la apuesta (cómo se propone lograrlo).

**Ejemplo de lo que NO hay que hacer:**
- H1 original: "Si usamos LMAX, entonces se cumple p95 ≤ 200 ms a 1.000 emp/min."
- El problema: repite la medida del ASR dentro de la hipótesis.

**Lo correcto:**
- H1 reformulada: "Si implementamos un libro de órdenes en memoria con un único escritor por partición, alimentado por un ring buffer sin locks, entonces se cumple el requisito de latencia [enlazado al escenario de calidad], porque el procesamiento secuencial elimina la contención entre escritores."
- Lo que importa: la estructura "si [patrón], entonces [requisito], porque [mecanismo]" deja claro qué está siendo propuesto (el patrón), qué debe cumplirse (el requisito, que vive en otro documento), y por qué se espera que funcione (el mecanismo).

### H1 — Latencia: procesamiento en memoria sin contención

**Apuesta de diseño:**

Si el libro de órdenes vive en memoria y es modificado por un único hilo escritor por partición, alimentado por un ring buffer preasignado y sin locks (patrón LMAX tipo Disruptor), con journaling y notificaciones movidos fuera del camino crítico, **entonces se cumplirá el requisito de latencia** (p95 ≤ 200 ms a 1.000 emp/min, según el [escenario de calidad ASR-02](experimento-e01.html)), **porque** el procesamiento secuencial en memoria elimina la espera que normalmente introducen múltiples escritores compitiendo por el mismo recurso.

**Por qué se espera que funcione:**
- Sin locks: nadie espera a que otro hilo libere un recurso.
- Secuencial: el evento se procesa en el orden de llegada, predecible.
- En memoria: no hay operaciones de entrada/salida en el camino crítico.

**Lo que se midió para validarla:** latencia de cliente (p95 = 31,51 ms) contra el criterio de 200 ms, a 17 órdenes/s repartidas entre 36 símbolos durante 12 minutos. Resultado: margen 6,3×.

**Limitación de la validación:** el journaling asíncrono no se implementó en el prototipo — la cláusula de mantenerlo fuera del camino crítico no se puso a prueba. El trabajo futuro debe validarla.

### H2 — Escalabilidad: sharding sin contención entre particiones

**Apuesta de diseño:**

Si la ingesta gRPC enruta cada orden usando una función determinística (`hash(símbolo) % N`) hacia N particiones independientes, cada una con su único escritor, y mantiene una cola acotada que amortigua ráfagas (rechazando en lugar de acumular sin límite), **entonces se cumplirá el requisito de escalabilidad transitoria** (rampa de 1.000 a 5.000 emp/min, sostenida 30 min, p95 ≤ 200 ms, según el [escenario de calidad ASR-03](experimento-e01.html)), **porque** el throughput total crece agregando particiones, y cada una procesa de forma aislada — no hay contención entre escritores porque cada partición tiene el suyo propio.

**Por qué se espera que funcione:**
- Determinístico: cada símbolo cae siempre en la misma partición (sin rehashing).
- Aislado: las particiones no comparten datos — no hay locks entre ellas.
- Escalable: `N particiones × throughput_por_partición = throughput_total`.

**La pregunta de fondo que el experimento debe responder:** no solo "¿funciona con N=2?", sino **¿cuál es el N mínimo que satisface el contrato?** — un número que no se conocía de antemano.

**Qué se midió para validarla:** 
- Latencia de cliente (p95 = 74,32 ms) durante rampa a 84 órd/s sostenida 30 min, con N=2 particiones. Resultado: margen 2,7×.
- Aislamiento verificado empíricamente: se agregó un contador en k6 que correlaciona símbolo con shard respondiente. Sobre 167.429 órdenes de F2+F3, cada símbolo fue respondido siempre por el mismo shard — 0 violaciones.
- N mínimo: F4 (concentración al 100 % en un símbolo, equivalente a N=1 para ese símbolo) pasó con p95 = 148,09 ms (margen 1,35×). Esto demuestra que N=1 es suficiente para el contrato repartido; N=2 es redundancia.

**Limitación de la validación:** solo una máquina, sin la red real de TEC-2 — valida el patrón de aislamiento, no el dimensionamiento en una infraestructura de producción.

### H2b — La partición caliente: dónde termina la utilidad del sharding

**Apuesta exploratoria (no binaria):**

Si el pico se concentra al 100 % en un solo símbolo, se espera que la degradación sea visible — el libro de ese símbolo es indivisible, así que todo el tráfico cae en una sola partición — **pero no necesariamente rompe el requisito**, porque el presupuesto de latencia tiene margen. El objetivo de esta hipótesis no es un aprobado/reprobado, sino medir dónde ocurre la degradación real y encontrar el techo de una partición.

**Por qué se espera degradación:**
- Un símbolo → un shard → un único escritor → un solo núcleo.
- Cuando todo el tráfico se concentra en uno, los otros shards quedan ociosos.
- La latencia debe crecer (más espera en cola) aunque el throughput esté acotado por ese único núcleo.

**Qué se midió para validarla:**
- Latencia de cliente (p95 = 148,09 ms) cuando el 100 % de las 84 órd/s caen en un solo símbolo. Comparado con el caso repartido (p95 = 74,32 ms), la degradación es ×2,0.
- Descomposición interna: la espera en cola creció de 50,08 ms a 137,09 ms, mientras el tiempo de servicio se mantuvo idéntico (27,60 ms). Esto muestra que la degradación vino de la cola, no del procesamiento.
- Techo de una partición: exploración a 250/500/1.000 órd/s en un símbolo mostró saturación — el motor entregó ~24.000 órdenes de 250.000 ofrecidas, confirmando que el techo es aproximadamente 1/S, donde S es el costo por orden (8 ms = 125 órd/s).

**Resultado:** H2b se confirmó: la partición caliente **sí degrada**, pero **no rompe el contrato** — mantiene margen positivo aunque menor que el caso repartido.

---

## Nivel 3 — Para quien implementa o decide

### H1 reformulada: LMAX + Disruptor + single-writer

**Estructura:**
- **Si:** `OrderBook` (en memoria) + `MatchingHandler` (único consumidor del Disruptor) + `Disruptor<OrderSlot>` (ring buffer preasignado, `ProducerType.MULTI` en ingesta, un solo consumidor interno).
- **Entonces:** requisito de latencia de ASR-02 (p95 ≤ 200 ms @ 1.000 emp/min).
- **Porque:** en `MatchingHandler`, sin sincronización: cada orden se procesa en orden de llegada (`while (next event) { match(); histograma.record(delta) }`) sobre un mapa de `HashMap<String, OrderBook>`. Cero locks, cero espera por contención. El Disruptor preasigna `OrderSlot` para no generar basura en régimen. `BlockingWaitStrategy` está documentado como deuda de decisión: es amable con máquina compartida pero es la mayor palanca de latencia cuando S ≈ 0 (muestra que 76 % de 272 µs es despertar el hilo, no el trabajo real).

**Medido:**
- F1: p95_cliente = 31,51 ms (k6 sobre 12.241 órdenes), p95_motor = 27,76 ms (HdrHistogram acumulado del motor).
- Motor explica 88 % de la latencia extremo a extremo (diferencia ~1 ms es transporte).
- Margen: 200 ms / 31,51 ms = 6,3×.

**No probado en este PoC:**
- Journaling: parte del diseño pero no implementado. La cláusula "sin exigir más de un núcleo" se valida en H2, no aquí.
- Notificación asíncrona: excluida del alcance.

---

### H2 reformulada: hash % N + bounded queue + N independent shards

**Estructura:**
- **Si:** `RouterService.floorMod(symbol.hashCode(), N)` + `Semaphore(QUEUE_CAPACITY)` en `RouterService` + N procesos independientes de `EngineMain`, cada uno es un Disruptor independiente sin compartir estado con los demás.
- **Entonces:** requisito de escalabilidad de ASR-03 (rampa 1.000→5.000 emp/min, pico 30 min @ 84 órd/s, p95 ≤ 200 ms durante la ventana).
- **Porque:** `hash % N` es determinístico (especificación de Java: `String.hashCode` es invariante); cada partición procesa su subconjunto de símbolos sin saber de las demás. El throughput total = sum de throughputs por partición. La cola acotada con `Semaphore.tryAcquire` sin bloqueo lo rechaza todo el trabajo que no entra, frenando la entrada antes de prometer latencia incumplible.

**Pregunta de fondo:** ¿Cuál es el N_min que satisface el contrato? Medido: N_min = 1 (demostrado en F4).

**Medido:**
- F2+F3: p95_cliente = 74,32 ms (k6 sobre 167.429 órdenes), p95_motor = 73,15 ms.
- Motor explica 98 % de la latencia.
- Aislamiento verificado: `shard_routing_violations == 0` sobre 167.429 órdenes de F1+F2.
- CPU: shard-0 promedio 23,6 % de un núcleo, máximo 58,3 % durante el pico. Extrapolando al techo teórico de 125 órd/s con S = 8 ms: 125 × 8 ms = 1.000 ms de trabajo por segundo = 100 % de un núcleo.
- Margen: 200 ms / 74,32 ms = 2,7×.

**Reparto equilibrado (validado):**
- N=2: 36 símbolos → 18/18 por hash. Medido: 83.702 / 83.727 órdenes procesadas (50,2 % / 49,8 %).
- N=1 (F4): mismo costo de procesamiento por orden (S = 8 ms), todo el tráfico en un shard → degradación predecible (×2,0 en p95).

---

### H2b reformulada: partición caliente como N=1 para un símbolo

**Estructura:**
- **Si:** todo el tráfico de la fase (84 órd/s de pico) cae sobre un único símbolo.
- **Entonces:** el hash asigna todo a un shard → es funcionalmente N=1 para ese símbolo → debe haber degradación medible.
- **Porque:** un símbolo = un libro = un hilo escritor = un núcleo. No hay paralelismo disponible.

**Medido:**
- F4 (84 órd/s en 1 símbolo): p95_cliente = 148,09 ms (sobre 167.429 órdenes).
- Comparado con F2+F3 (84 órd/s repartida): ×2,0 en p95 (148,09 / 74,32).
- Descomposición: espera p95 pasó de 50,08 ms a 137,09 ms; servicio p95 se mantuvo en 27,60 ms (invariante, porque S es por orden y es independiente de la carga).
- Techo confirmado por saturación: F4-explore a 250/500/1.000 órd/s entregó ~24k órdenes en cada caso (23.183, 23.983, 24.345), saturación del ~125 órd/s predicho por 1/S.
- Pico contractual = 84 órd/s = 67,2 % del techo de una partición.
- Margen: 200 ms / 148,09 ms = 1,35×.

**Confirmación:** H2b se manifestó (con S = 0 no se veía degradación); ahora sí es medible.

---

## Qué cambió en la reformulación

| Aspecto | Antes | Ahora |
|---|---|---|
| **Estructura de H1/H2/H2b** | Repetía el ASR en la apuesta | Separa "si [patrón]" de "entonces [requisito enlazado]" |
| **Pregunta de H2** | "¿Funciona con N=2?" | "¿Cuál es N_min que satisface el contrato?" |
| **Aislamiento del sharding** | Matemático: `hash % N es determinístico` | Empírico: `shard_routing_violations == 0` sobre 167.429 órdenes |
| **Techo de una partición** | No declarado con S realista | Medido: 125 órd/s cuando S = 8 ms |
| **Degradación H2b** | No visible con S ≈ 0 | Confirmada: ×2,0 en p95 con S = 8 ms |

---

## Rastreabilidad de cada afirmación

- **p95_cliente = 31,51 ms (F1):** [Evidencia de corridas, corrida oficial, F1](evidencia-corridas.html#corrida-oficial-s-8-ms)
- **Aislamiento = 0 violaciones:** [Evidencia de corridas, sección 5.7](evidencia-corridas.html#verificación-del-aislamiento)
- **Techo = 125 órd/s:** Calculado como 1/S donde S = 8 ms; confirmado en [F4-explore](evidencia-corridas.html#exploratoria-techo-de-una-partición)
- **CPU por shard = 23,6 % promedio:** [Evidencia de corridas, sección 5.6](evidencia-corridas.html#una-partición-nunca-pidió-más-de-un-núcleo)

---

*¿Quieres las cifras exactas con contexto completo? [Evidencia de corridas](evidencia-corridas.html). ¿La ficha técnica? [Experimento E01](experimento-e01.html).*
