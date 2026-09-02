---
title: Experimento E01
nav_order: 2
---

# E01 — Validar el patrón LMAX (motor en memoria con un único escritor) para el emparejamiento

**Reto 1: Desempeño · ARTI4109 · Pestaña Experiments de Helix**
Estado: **Ejecutado** · Espejo de Helix actualizado el 2 de septiembre de 2026.

> Las corridas F1–F4 se repitieron el 2 de septiembre con el generador corregido —arribo estocástico (Ca² = 0,89) y 36 símbolos balanceados— y con verificación en vivo del aislamiento del sharding. Las corridas del 30 de agosto quedaron superadas. Queda declarado que el techo por shard se midió con un `match()` de ~13 µs: la conclusión de capacidad es un **presupuesto de tiempo de servicio**, no un número de órdenes/s (refinamiento 3).

## El experimento de un vistazo

```mermaid
flowchart LR
    subgraph ASRs["ASR críticos"]
      A2["ASR-02 · Latencia\np95 ≤ 200 ms @ 1.000 emp/min"]
      A3["ASR-03 · Escalabilidad\n1.000→5.000 emp/min · 30 min"]
    end
    subgraph Hipotesis["Hipótesis"]
      H1["H1: LMAX mantiene el p95\ncon un solo escritor en memoria"]
      H2["H2: sharding por activo\nabsorbe el pico 5×"]
      H2b["H2b: la partición caliente\ndegrada antes del pico"]
    end
    subgraph Fases["Fases"]
      F1["F1 · Baseline 17/s × 12 min"]
      F2["F2+F3 · Rampa, pico 30 min\ny retorno"]
      F4["F4 · 100 % en un símbolo\n+ exploración 250/500/1000 por s"]
    end
    A2 --> H1 --> F1
    A3 --> H2 --> F2
    H2 -.-> H2b --> F4
    F1 --> V1(["✅ Confirmada\np95 = 7,55 ms · margen 26×"])
    F2 --> V2(["✅ Confirmada\np95 = 4,61 ms · margen 43×"])
    F4 --> V3(["🔶 No se manifestó a tasas contractuales;\nreformulada como presupuesto: S ≤ ~8,5 ms"])
```

---

## Pestaña Planning

### Design Hypothesis

*Redacción ajustada tras la retroalimentación del 01-sep: la hipótesis es la **apuesta de diseño** — la medida exigida vive en el escenario de calidad enlazado y no se transcribe aquí.*

**H1 — Latencia (ASR-02):** si el motor de emparejamiento implementa el patrón LMAX —libro de órdenes en memoria por activo, un único hilo escritor por partición (single writer) alimentado por un ring buffer (Disruptor), con journaling y notificación asíncronos fuera del camino crítico—, entonces se cumplirá la medida del escenario Critical de latencia enlazado abajo, bajo la carga de su Ambiente A, porque el procesamiento secuencial en memoria elimina bloqueos y contención y deja el costo por evento en el orden de microsegundos.

*La mecánica de H1: el camino crítico es una línea recta en memoria — nadie espera un lock, y lo lento (persistir, notificar) sale del camino:*

```mermaid
flowchart LR
    subgraph CC["Camino crítico: todo en memoria, cero locks"]
      T["hilos gRPC\npublican concurrente"] --> RB["ring buffer\nDisruptor, preasignado"] --> W["ÚNICO hilo escritor\nprocesa secuencial"] --> L["libro en memoria\nmatching precio-tiempo"]
    end
    L --> Rta["respuesta\n⏱ p95 ≤ 200 ms"]
    W -.->|"asíncrono, fuera\ndel camino crítico"| J["journaling +\nnotificación"]
```

**H2 — Escalabilidad transitoria (ASR-03):** si la ingesta gRPC enruta cada orden por sharding determinístico (hash del símbolo % N) hacia N shards LMAX independientes, con cola acotada como amortiguación de ráfagas, entonces se cumplirá la medida del escenario Critical de escalabilidad enlazado abajo durante toda la ventana de pico de su Ambiente B —siempre que la carga se reparta entre varios activos—, porque el throughput total crece agregando shards sin exigir más de un núcleo por partición. La pregunta de fondo que este experimento debe responder no es solo "¿funciona con el N elegido?" sino **cuál es el N mínimo de shards** que satisface el contrato — un número que no se sabe de antemano y se halla con las corridas.

*La mecánica de H2: el pico 5× se divide entre N shards que no comparten nada — cada uno recibe ~1/N de la carga, y si el pico creciera, la respuesta es sumar shards, no acelerar uno:*

```mermaid
flowchart TB
    P["Pico 5×: 5.000 emp/min\nrepartidos entre varios activos"] --> Q["cola acotada\namortigua la ráfaga\n(exceso → REJECTED, no espera infinita)"] --> RT{"hash % N"}
    RT -->|"~1/N de la carga"| SA["shard-0\n≤ 1 núcleo"]
    RT -->|"~1/N de la carga"| SB["shard-1\n≤ 1 núcleo"]
    RT -->|"~1/N de la carga"| SC["shard-N…\n+ shards = + throughput"]
```

**H2b — Partición caliente (exploratoria, subordinada a H2):** si el pico se concentra al 100 % en un solo activo, se espera que la medida del escenario enlazado deje de cumplirse antes de alcanzar el pico de Ambiente B, porque el techo de un shard es un solo núcleo por diseño; la Fase 4 busca ese punto de quiebre real, no un aprobado/reprobado.

*La mecánica de H2b — el caso donde el sharding no ayuda: un solo símbolo tiene un solo libro dueño, así que todo el pico cae en un shard y los demás miran. Como el libro es indivisible, ese único núcleo es el techo, y F4 pregunta a qué tasa se alcanza:*

```mermaid
flowchart TB
    P["Pico concentrado:\n100 % del tráfico en UN símbolo"] --> RT{"hash % N"}
    RT ==>|"TODO el tráfico"| S0["shard dueño del símbolo\n1 libro · 1 hilo · 1 núcleo\n← ¿a qué tasa se quiebra?"]
    RT -.->|"nada"| S1["shard-1 ocioso"]
    RT -.->|"nada"| S2["shard-N… ocioso"]
```

*(Resultado adelantado: la degradación esperada nunca llegó — el techo de ese único núcleo resultó estar por encima de 12× el pico contractual; ver Results.)*

### Linked Quality Scenarios

| Escenario | Atributo | ASR |
|---|---|---|
| Materializar una orden de compra mediante emparejamiento | Latency · **Critical** · p95 ≤ 200 ms (Ambiente A) | ASR-02 |
| Materializar una orden de compra mediante emparejamiento | Scalability · **Critical** · ramp-up 1 min, p95 ≤ 200 ms (Ambiente B) | ASR-03 |

*Son los dos únicos escenarios con prioridad Critical del árbol de Requirements & Quality: el experimento cubre exactamente los ASR críticos (uno de latencia, uno de escalabilidad).*

### Tactics and Patterns

Patrón LMAX Architecture (Disruptor): procesador de eventos secuencial con libro de órdenes en memoria y un único escritor lógico por partición de activo, entrada por ring buffer sin bloqueos (mechanical sympathy: los datos del activo permanecen calientes en la caché del núcleo asignado). Sharding por activo: enrutamiento determinístico hash(símbolo) % N desde el servicio de ingesta gRPC/Protobuf hacia N shards independientes; la exclusión mutua queda garantizada por construcción —no por locks— y aporta de paso la garantía de no doble-materialización.

**Cómo reparte el sharding** — no hay un shard por símbolo: hay N shards fijos y cada uno es dueño de *varios* símbolos (con un libro por símbolo). El invariante es que todas las órdenes de un mismo símbolo caen siempre en el mismo shard, así el único escritor del shard es, transitivamente, el único escritor de cada uno de sus libros:

```mermaid
flowchart LR
    subgraph S0["matching-shard-0 · 1 hilo escritor"]
      B0["Libro BCOLOMBIA"]
      B1["Libro NUTRESA"]
      B2["Libro PROMIGAS"]
    end
    subgraph S1["matching-shard-1 · 1 hilo escritor"]
      B3["Libro ECOPETROL"]
      B4["Libro ISA"]
      B5["Libro CEMARGOS"]
    end
    O["Orden: symbol = ISA"] --> R{"router: hash % 2"}
    R -- "18 símbolos: BCOLOMBIA · NUTRESA · PROMIGAS …" --> S0
    R -- "18 símbolos: ECOPETROL · ISA · CEMARGOS …" --> S1
```
> *Nota sobre el diagrama de sharding:* el reparto mostrado es el que produce realmente `floorMod(String.hashCode(símbolo), 2)` sobre los 36 nemotécnicos del generador, verificado con el hash (18/18 con N=2, 9/9/9/9 con N=4). Una versión anterior de este diagrama ubicaba tres símbolos en el shard equivocado.

Tácticas de latencia: mantener los datos del camino crítico en memoria, reducir overhead evitando bloqueos y contención, mover journaling y notificación a etapas asíncronas. Tácticas de escalabilidad: particionamiento por activo (el throughput total escala agregando shards) y cola acotada con backpressure en la ingesta (se prefiere frenar la entrada antes que prometer una latencia incumplible). Alternativas descartadas: pool de workers con colas bloqueantes (reintroduce la contención), locks de grano fino por nivel de precio (deadlocks y latencia impredecible), PostgreSQL con SELECT FOR UPDATE (se mantiene como línea base de comparación), modelo de actores (overhead de mailbox), bloqueo distribuido (salto de red en el camino crítico).

### Experiment Design

PoC mínimo en una sola máquina (mínimo 8 vCPU/16 GB, ideal 12+/32), todo Java 21 sobre Docker Compose —sin Kubernetes ni broker—: generador k6 con gRPC nativo (`k6/net/grpc`, k6 ≥ 0.49 — no requiere xk6), en modelo abierto de tasa de llegada con desplazamiento exponencial por iteración → servicio de ingesta gRPC/Protobuf con router de sharding hash(símbolo) % N y cola acotada → N motores LMAX (Disruptor 4.0.0, libro en memoria por activo). Precalentamiento sin medir (estabilizar JIT y GC).

**Diferencias entre el diseño y lo construido** — declaradas para no atribuir al PoC alcance que no tiene:

| Elemento del diseño | Estado en el PoC |
|---|---|
| Journaling asíncrono a archivo | ❌ **no implementado**: no hay journaling de ningún tipo. La cláusula de H1 sobre sacarlo del camino crítico **no fue puesta a prueba** |
| Aislamiento por `cpuset` | ❌ **no aplicado**: las líneas están comentadas en el compose y en macOS Docker corre en una VM. Con ello, la «mechanical sympathy» de datos calientes en un núcleo dedicado tampoco se verificó |
| JFR para pausas de GC | ❌ no configurado: `JAVA_OPTS` solo lleva ZGC y heap |
| CPU por proceso | ❌ no se recolecta |
| Exportación a Prometheus/Grafana | ❌ no implementada: las curvas salen de la salida de k6 y del log del motor |

El camino de una orden a través del montaje (los dos relojes de la medición marcados):

```mermaid
sequenceDiagram
    participant K as k6 (generador)
    participant R as ingest-router
    participant G as gRPC del shard
    participant M as single writer (matcher)
    K->>R: SubmitOrder ⏱ inicia reloj externo
    R->>R: Semaphore.tryAcquire (cola acotada)
    Note over R: sin cupo → REJECTED (backpressure)
    R->>G: reenvío al shard dueño (hash % N)
    G->>G: t0 = nanoTime ⏱ reloj interno
    G->>M: publica en ring buffer (tryNext)
    Note over G: ring lleno → REJECTED
    M->>M: matching precio-tiempo en el libro
    M-->>G: latencia = now − t0 → HdrHistogram
    G-->>R: OrderResponse
    R-->>K: respuesta ⏱ cierra grpc_req_duration
```

Corridas:

- **F1 — Baseline (ASR-02):** 1.000 emp/min (≈17/s) con **arribo estocástico** —tiempo entre llegadas exponencial, no equiespaciado— repartidos en 36 activos que el hash del router balancea 18/18 (N=2) y 9/9/9/9 (N=4), 10–15 min; criterio p95 ≤ 200 ms, 0 rechazos y 0 iteraciones descartadas.
- **F2 — Rampa transitoria (ASR-03):** rampa de 1.000 a 5.000 emp/min en pocos minutos y sostenida hasta 30 min repartida entre activos; prevista con N=2 y N=4 shards, **ejecutada solo con N=2** (la comparación se descartó razonadamente, ver Results; `make compare-sharding` la deja disponible). Criterio: p95 ≤ 200 ms durante toda la ventana y backlog de la cola sin crecimiento descontrolado.
- **F3 — Retorno a régimen:** bajar a 1.000/min y verificar que el backlog drena y el p95 vuelve al valor de F1 (la escalabilidad exigida es transitoria, no permanente).
- **F4 — Partición caliente (exploratoria, sin criterio binario):** mismo perfil de F2 con el 100 % del tráfico en un solo activo, para encontrar el punto de quiebre de un shard.

El perfil de F2+F3 (el mismo que usa F4, cambiando solo la distribución de símbolos):

```mermaid
flowchart LR
    P["2 min\n17/s\nprecalentamiento"] --> RA["2 min\nrampa 17→84/s\nevento de mercado"] --> PK["30 min\n84/s sostenidos\npico Ambiente B"] --> D["1 min\nrampa 84→17/s"] --> F3["5 min\n17/s\nF3: drenar y volver a régimen"]
```

Métricas: latencia arribo→materialización p50/p95/p99/p99.9 medida en el generador y contrastada con HdrHistogram interno del motor; throughput real vs. objetivo; **descomposición de la latencia interna en espera (cola del ring buffer) y servicio (matching + modelo de negocio)**, que distingue «shardear más» de «abaratar la orden»; tasa de rechazo (backpressure); iteraciones descartadas por el generador. *No recolectadas pese a estar previstas: pausas de GC (JFR) y CPU por proceso* — su ausencia deja sin evidencia directa la cláusula de H2 sobre no exigir más de un núcleo por partición. Los thresholds de k6 marcan la corrida como fallida si p95 > 200 ms en vivo.

Limitación declarada — **el techo de un shard depende del costo por orden**: `OrderBook.match()` es un cruce sobre un `TreeMap` (~13 µs medidos) y el PoC no implementa validación, riesgo, tipos de orden, comisiones ni generación de trades. Como en un único escritor ese costo se serializa (techo = 1/S), cualquier cifra de capacidad medida con S de microsegundos es un artefacto del juguete. El experimento lo trata como parámetro barrido (`BusinessLogicModel` + `make sweep-service`) y reporta un **presupuesto**: el patrón sostiene el ASR en la peor distribución mientras S ≤ ~8,5 ms.

Limitación declarada: el tráfico corre por loopback —no representa la red de 1 Gbps de TEC-2 ni alta disponibilidad—; el PoC valida el patrón, no el dimensionamiento final.

### Experiment planning

**Required resources** *(lo efectivamente usado; entre paréntesis lo previsto que no se usó)*: Java 21 + LMAX Disruptor 4.0.0 + gRPC/Protobuf; Docker Compose (sin Kubernetes ni broker); **k6 ≥ 0.49 con gRPC nativo** —no hizo falta compilar xk6— como generador en modelo abierto con thresholds en vivo; HdrHistogram para los percentiles internos del motor; 1 máquina de 8 vCPU/16 GB o más; `Makefile` + `run-e2e.sh` como orquestación. *(Previstos y no usados: exportación a Prometheus/Grafana —las curvas salen de la salida de k6 y del log del motor—, JFR para pausas de GC, y núcleos aislados por cpuset.)*

**Architecture elements involved:** Servicio de ingesta gRPC con router de sharding por símbolo (hash % N) y cola acotada con backpressure; N shards del motor de emparejamiento (LMAX, libro en memoria por activo, un escritor por partición); generador de carga externo. **El journaling asíncrono forma parte del diseño pero no del PoC** (ver la tabla de diferencias arriba). Excluidos por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado (declarados como limitación del PoC). Vistas afectadas: funcional y concurrencia.

**Estimated effort:** 2 personas × 1 semana (≈ 40 horas-persona): 2 días ingesta gRPC + router de sharding + motor LMAX; 1 día generador k6 e instrumentación; 1 día corridas F1–F4; 1 día análisis, informe y decisión (Paso 8).

---

## Pestaña Results & analysis

**Results** (582.637 órdenes en 6 corridas del 2 de septiembre, 100 % procesadas, 0 rechazos — detalle y salidas crudas en la [evidencia de corridas](evidencia-corridas.html)):

| Corrida | Carga | p95 | Veredicto |
|---|---|---|---|
| F1 baseline | 17/s repartidos en 36 símbolos | 7,55 ms | ✅ margen ≈ 26× |
| F2+F3 rampa+pico+retorno | 17→84/s repartidos | 4,61 ms | ✅ margen ≈ 43× |
| F4 contractual | 84/s en 1 símbolo | 3,30 ms | sin degradación |
| F4-explore | 250 / 500 / 1000 por s en 1 símbolo | 2,90 / 2,17 / 1,43 ms | **techo no alcanzado** |

Las fases oficiales pasaron sus cuatro umbrales: p95, 0 rechazos, **0 iteraciones descartadas** y **0 violaciones de routing** sobre 179.670 órdenes — esto último demuestra empíricamente el aislamiento del sharding (recomendación 2). **F3 quedó evidenciado con número propio**: la espera interna del motor vuelve a 138 µs contra los 200 µs de F1, es decir el backlog drena por debajo del baseline.

El hallazgo central en un gráfico — **la latencia mejora al subir la carga** (más ráfaga → más eventos por pasada del único escritor y datos calientes en caché → menor costo amortizado por evento; lo contrario de un sistema con locks):

```mermaid
xychart-beta
    title "p95 (ms) según la tasa de llegada — menor es mejor · presupuesto: 200 ms"
    x-axis ["17/s", "84/s", "84/s (1 símbolo)", "250/s (1 símbolo)", "500/s (1 símbolo)", "1000/s (1 símbolo)"]
    y-axis "p95 en ms" 0 --> 8
    bar [7.55, 4.61, 3.30, 2.90, 2.17, 1.43]
```

Y el mecanismo, aislado por primera vez **dentro del motor** gracias a la descomposición `total = espera + servicio` — el costo de procesar una orden cae 45× sin cambiar una línea de código:

```mermaid
xychart-beta
    title "Costo por orden dentro del shard (servicio p50, µs) — mechanical sympathy medida"
    x-axis ["17/s · 18 libros", "84/s · 18 libros", "84/s · 1 libro", "250/s", "500/s", "1000/s"]
    y-axis "servicio p50 en µs" 0 --> 95
    bar [90, 25, 13, 9, 4, 2]
```

**Analysis of results:** el patrón es coherente en las seis corridas: latencia decreciente con la carga, backpressure jamás activado (0 rechazos), y la doble medición k6/HdrHistogram ahora sí registrada en ambos relojes. Esa doble medición arroja el dato que recontextualiza todo lo demás: **en F1 el motor aporta 272 µs de los 7.550 µs que ve el cliente** — el 96 % del tiempo es transporte (gRPC, router y la red virtualizada de Docker en macOS), no el patrón. Los valores absolutos, por tanto, miden sobre todo el montaje; el comportamiento del patrón y los órdenes de magnitud de los márgenes sí se sostienen.

Dentro del motor, la espera domina sobre el trabajo a tasa baja: a 17/s, 200 de los 272 µs (**74 %**) son el costo de despertar el hilo matcher dormido bajo `BlockingWaitStrategy`. Eso convierte la deuda de decisión sobre la estrategia de espera en la palanca de latencia más grande que queda en el motor.

A **1.000 órdenes/s el instrumento saturó antes que el motor**: el generador descartó 337 iteraciones mientras el shard registraba su mejor total p95 de toda la serie (44 µs). El techo del shard sigue sin alcanzarse, y ahora hay evidencia directa de dónde está el límite del montaje. La comparación N=2 vs N=4 bajo estrés se descartó razonadamente por la misma razón; la aditividad entre shards queda argumentada por construcción (no comparten nada) y el aislamiento, ahora, verificado en vivo.

**Links & evidence:** [Repositorio](https://github.com/MATI-MBIT/arqsoft-reto-1) · [Sitio de documentación](https://mati-mbit.github.io/arqsoft-reto-1/) · [Evidencia de corridas](https://mati-mbit.github.io/arqsoft-reto-1/evidencia-corridas.html) (resumen + salidas crudas de k6).

**Conclusion:** **H1 y H2 se cumplen con márgenes amplios** en las corridas ejecutadas — con la salvedad de que esas corridas usaron arribo uniforme y son cotas optimistas (refinamiento 5), y de que ninguna evidencia respalda todavía la cláusula «sin exigir más de un núcleo por partición» de H2, porque no se midió CPU por proceso.

**H2b no se refuta: se reformula.** La partición caliente no degradó el servicio a tasas contractuales, pero el techo de un shard es 1/S y las corridas lo midieron con un `match()` de ~13 µs. Con el costo por orden como parámetro, el barrido del 2 de septiembre acota el resultado a un **presupuesto**: el patrón sostiene el ASR con todo el pico en una sola partición mientras el costo por orden se mantenga **bajo ~8,5 ms**; por encima, H2b se manifiesta. La hipótesis de mayor riesgo pasa de "amenaza al SLA" a **"condición verificable contra la lógica de negocio real"**.

**Architectural Decision (Paso 8 de ADD):** **ADOPTAR** LMAX (libro en memoria, único escritor por partición sobre ring buffer) + sharding determinístico por activo + cola acotada con backpressure como arquitectura del motor. La Iteración 1 **no cierra todavía**: la decisión de adoptar es firme por el mecanismo y los órdenes de magnitud, pero el criterio de parada queda condicionado a (a) repetir F1–F4 con el generador corregido y (b) verificar el presupuesto de ~8,5 ms contra el costo real de la lógica de negocio. Deuda y trabajo futuro: repetir el diseño en el banco de 3 nodos (TEC-2) con red real; re-evaluar la estrategia de espera del Disruptor (Blocking en el PoC) con datos; profundizar el techo del shard solo si el negocio proyecta volúmenes de otro orden de magnitud; siguiente experimento candidato: E02 — fan-out de notificaciones (ASR-04).

---

## Refinamientos tras la retroalimentación (sesión 01-sep-2026)

De la revisión de experimentos con el profesor salieron cinco ajustes; su estado:

1. **Hipótesis sin transcribir el ASR** *(directo al grupo)* — ✅ aplicado: H1/H2/H2b reformuladas como apuestas de diseño que referencian el escenario enlazado; la medida vive en el escenario.
2. **Demostrar empíricamente el aislamiento del sharding** *(directo al grupo: "correlacionen IDs de entrada y salida, no solo el argumento matemático")* — ✅ instrumentado: cada respuesta gRPC trae `shard_id`, y el script k6 ahora verifica en vivo que cada símbolo sea respondido siempre por el mismo shard (contador `shard_routing_violations`, threshold `count==0` en las fases oficiales). **Verificado en la corrida del 02-sep: `shard_routing_violations = 0` sobre 179.670 órdenes en F1 y F2.** El invariante deja de sostenerse solo por el argumento matemático (`floorMod(hashCode, N)` es determinístico) y pasa a estar demostrado con los IDs de entrada y salida correlacionados en vivo.
3. **Hallar el N mínimo de shards, no solo validar el N elegido** *(recomendación general más fuerte de la sesión)* — 🔶 en curso, **con una advertencia**: el techo por shard de F4-explore (> 1.000 órdenes/s) se midió con `OrderBook.match()`, que cuesta ~13 µs. Como el techo es 1/S, esa cifra es una propiedad del `TreeMap`, no del motor: con un costo por orden realista el techo cae proporcionalmente y con él el N mínimo. La conclusión defendible es un **presupuesto** (≈ 8,5 ms por orden con todo el pico en una partición; ver el barrido en `evidencia-corridas.md`), no un N. Predice **N mínimo = 1** para el contrato; queda pendiente la corrida de evidencia directa `make f2-n1` (perfil F2 corto sobre un solo shard). Con ella, la conclusión de escalabilidad se reformula: N=1 basta para el contrato, N=2 es margen y N se dimensiona con el techo medido.
4. **Protocolo explícito y repeticiones** *(a otros grupos)* — 🔶 parcial: el protocolo es ejecutable (`Makefile` + `run-e2e.sh`, resultados versionables por corrida); la significancia se sustenta en el volumen intra-corrida (12k–167k muestras por fase). La repetición de F1 (3–5 corridas para variabilidad entre corridas) queda como decisión abierta del equipo.
5. **Arribo verdaderamente estocástico** *(a otros grupos, aplicable)* — ✅ **implementado** (02-sep): los ejecutores `*-arrival-rate` de k6 espacian los arribos de forma uniforme (a 17/s, uno cada ~59 ms), así que el generador desplaza cada iteración un tiempo **exponencial** independiente antes de emitir el RPC; por Palm–Khintchine la superposición converge a Poisson conservando la tasa media. Medido sobre 200.000 llegadas simuladas, **Ca² pasa de 0,00 a 0,89** (Poisson = 1) sin desviar la tasa. `JITTER_FACTOR=0` restaura el arribo periódico para la comparación A/B.

   El argumento previo de que «con márgenes de 20–40× la sensibilidad al patrón de llegada es baja» **quedó refutado por medición**: en un A/B sobre el mismo shard, la espera en cola p99.9 pasó de 83–303 µs (periódico) a 1.409–4.375 µs (estocástico) —de 10 a 30 veces—. Con arribo uniforme no hay aglomeración, el ring buffer no acumula y esa cola simplemente no se medía. **F1–F4 se repitieron el 02-sep con el generador corregido** y son las corridas vigentes; las del 30-ago se retiraron de la evidencia.

## Notas de trazabilidad para la validación

- El criterio de éxito quedó unificado en **p95 ≤ 200 ms** en todo E01 (hipótesis, fases, thresholds y decisión anticipada), consistente con la medida de los escenarios en Helix; p99/p99.9 se registran como métricas observadas.
- Del documento del compañero (*Escenario de Pruebas PoC ASR-02/ASR-03*) se conservaron: hipótesis H1/H2/H2b, las 4 fases con precalentamiento, el modelo abierto de llegada (coordinated omission), el aislamiento por cpuset, la doble medición generador/motor, las alternativas descartadas y la limitación de validez del host único.
- Se recortó para viabilidad: Kubernetes (k3d), Redpanda, HPA, StatefulSets y gateway Spring Boot. La amortiguación por log se reemplazó por cola acotada con backpressure en el router; broker y autoescalado quedan declarados como limitación.
- Pendiente del equipo: el documento del compañero cita decisiones D-01…D-10 de un archivo `Decisiones-Arquitectura-Intermedia_ok.md` que no está en Helix ni en el proyecto; conviene registrarlas como ADRs en el modo Razonamiento del diagrama.
