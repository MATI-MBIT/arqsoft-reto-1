---
title: Experimento E01
nav_order: 2
---

# E01 — Validar el patrón LMAX (motor en memoria con un único escritor) para el emparejamiento

**Reto 1: Desempeño · ARTI4109 · Pestaña Experiments de Helix**
Estado: **Ejecutado y cerrado** · Espejo de Helix actualizado el 1 de septiembre de 2026 (corridas del 30 de agosto).

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
    F1 --> V1(["✅ Confirmada\np95 = 9,64 ms · margen 20×"])
    F2 --> V2(["✅ Confirmada\np95 = 4,91 ms · margen 40×"])
    F4 --> V3(["❌ Refutada hasta 12× el pico:\ntecho > 1.000 órdenes/s por shard"])
```

---

## Pestaña Planning

### Design Hypothesis

**H1 — Latencia (ASR-02):** si el motor de emparejamiento implementa el patrón LMAX —libro de órdenes en memoria por activo, un único hilo escritor por partición (single writer) alimentado por un ring buffer (Disruptor), con journaling y notificación asíncronos fuera del camino crítico—, entonces la latencia de emparejamiento se mantendrá p95 ≤ 200 ms bajo 1.000 emparejamientos/min con arribo estocástico (Ambiente A), porque el procesamiento secuencial en memoria elimina bloqueos y contención y deja el costo por evento en el orden de microsegundos.

**H2 — Escalabilidad transitoria (ASR-03):** si la ingesta gRPC enruta cada orden por sharding determinístico (hash del símbolo % N) hacia N shards LMAX independientes, con cola acotada como amortiguación de ráfagas, entonces el sistema sostendrá la rampa de 1.000 a 5.000 emparejamientos/min por ventanas de hasta 30 minutos con p95 ≤ 200 ms, siempre que la carga se reparta entre varios activos, porque el throughput total crece agregando shards sin exigir más de un núcleo por partición.

**H2b — Partición caliente (exploratoria, subordinada a H2):** si el pico se concentra al 100 % en un solo activo, se espera que el p95 se degrade antes de llegar a 5.000/min, porque el techo de un shard es un solo núcleo por diseño; la Fase 4 busca el punto de quiebre real, no un aprobado/reprobado.

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
      B0["Libro BANCOLOMBIA"]
      B1["Libro ISA"]
      B2["Libro NUTRESA"]
    end
    subgraph S1["matching-shard-1 · 1 hilo escritor"]
      B3["Libro ECOPETROL"]
      B4["Libro GRUPOSURA"]
      B5["Libro CEMARGOS"]
    end
    O["Orden: symbol = ISA"] --> R{"router: hash % 2"}
    R -- "BANCOLOMBIA · ISA · NUTRESA" --> S0
    R -- "ECOPETROL · GRUPOSURA · CEMARGOS" --> S1
``` Tácticas de latencia: mantener los datos del camino crítico en memoria, reducir overhead evitando bloqueos y contención, mover journaling y notificación a etapas asíncronas. Tácticas de escalabilidad: particionamiento por activo (el throughput total escala agregando shards) y cola acotada con backpressure en la ingesta (se prefiere frenar la entrada antes que prometer una latencia incumplible). Alternativas descartadas: pool de workers con colas bloqueantes (reintroduce la contención), locks de grano fino por nivel de precio (deadlocks y latencia impredecible), PostgreSQL con SELECT FOR UPDATE (se mantiene como línea base de comparación), modelo de actores (overhead de mailbox), bloqueo distribuido (salto de red en el camino crítico).

### Experiment Design

PoC mínimo en una sola máquina (mínimo 8 vCPU/16 GB, ideal 12+/32), todo Java 21 sobre Docker Compose —sin Kubernetes ni broker—: generador k6 + xk6-grpc (modelo abierto de tasa de llegada, evita coordinated omission) → servicio de ingesta gRPC/Protobuf con router de sharding hash(símbolo) % N y cola acotada → N motores LMAX (Disruptor 4.x, libro en memoria por activo, journaling asíncrono a archivo). Aislamiento por cpuset: núcleos dedicados al motor, separados del generador, para no contaminar los percentiles. Precalentamiento sin medir (estabilizar JIT y GC).

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

- **F1 — Baseline (ASR-02):** 1.000 emp/min estocásticos (≈17/s) repartidos en ≥3 activos, 10–15 min; criterio p95 ≤ 200 ms.
- **F2 — Rampa transitoria (ASR-03):** rampa de 1.000 a 5.000 emp/min en pocos minutos y sostenida hasta 30 min repartida entre activos, corrida con N=2 y N=4 shards; criterio: p95 ≤ 200 ms durante toda la ventana y backlog de la cola sin crecimiento descontrolado.
- **F3 — Retorno a régimen:** bajar a 1.000/min y verificar que el backlog drena y el p95 vuelve al valor de F1 (la escalabilidad exigida es transitoria, no permanente).
- **F4 — Partición caliente (exploratoria, sin criterio binario):** mismo perfil de F2 con el 100 % del tráfico en un solo activo, para encontrar el punto de quiebre de un shard.

El perfil de F2+F3 (el mismo que usa F4, cambiando solo la distribución de símbolos):

```mermaid
flowchart LR
    P["2 min\n17/s\nprecalentamiento"] --> RA["2 min\nrampa 17→84/s\nevento de mercado"] --> PK["30 min\n84/s sostenidos\npico Ambiente B"] --> D["1 min\nrampa 84→17/s"] --> F3["5 min\n17/s\nF3: drenar y volver a régimen"]
```

Métricas: latencia arribo→materialización p50/p95/p99/p99.9 medida en el generador y contrastada con HdrHistogram interno del motor; throughput real vs. objetivo; profundidad de cola/backlog; tasa de rechazo (backpressure); pausas de GC (JFR); CPU por proceso. Los thresholds de k6 marcan la corrida como fallida si p95 > 200 ms en vivo.

Limitación declarada: el tráfico corre por loopback —no representa la red de 1 Gbps de TEC-2 ni alta disponibilidad—; el PoC valida el patrón, no el dimensionamiento final.

### Experiment planning

**Required resources:** Java 21 + LMAX Disruptor 4.x + gRPC/Protobuf; Docker Compose (sin Kubernetes ni broker); k6 con extensión xk6-grpc (compilado con xk6) como generador de carga en modelo abierto, con thresholds en vivo y exportación a Prometheus/Grafana para las curvas del informe; HdrHistogram y JFR para percentiles y pausas de GC; 1 máquina de 8 vCPU/16 GB (ideal 12 vCPU/32 GB) con núcleos aislados por cpuset; scripts de orquestación y análisis.

**Architecture elements involved:** Servicio de ingesta gRPC con router de sharding por símbolo (hash % N) y cola acotada con backpressure; N shards del motor de emparejamiento (LMAX, libro en memoria por activo, un escritor por partición); journaling asíncrono (stub a archivo); generador de carga externo. Excluidos por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado (declarados como limitación del PoC). Vistas afectadas: funcional y concurrencia.

**Estimated effort:** 2 personas × 1 semana (≈ 40 horas-persona): 2 días ingesta gRPC + router de sharding + motor LMAX; 1 día generador k6 e instrumentación; 1 día corridas F1–F4; 1 día análisis, informe y decisión (Paso 8).

---

## Pestaña Results & analysis

**Results** (~560.000 órdenes en 7 corridas, 100 % procesadas, 0 rechazos — detalle y salidas crudas en la [evidencia de corridas](evidencia-corridas.html)):

| Corrida | Carga | p95 | Veredicto |
|---|---|---|---|
| F1 baseline | 17/s repartidos | 9,64 ms | ✅ margen ≈ 20× |
| F2+F3 rampa+pico+retorno | 17→84/s repartidos | 4,91 ms | ✅ margen ≈ 40× |
| F4 contractual | 84/s en 1 símbolo | 4,87 ms | sin degradación |
| F4-explore | 250 / 500 / 1000 por s en 1 símbolo | 3,63 / 2,40 / 1,11 ms | **techo no alcanzado** |

El hallazgo central en un gráfico — **la latencia mejora al subir la carga** (efecto de lote del Disruptor: más ráfaga → más eventos por pasada del único escritor → menor costo amortizado por evento; lo contrario de un sistema con locks):

```mermaid
xychart-beta
    title "p95 (ms) según la tasa de llegada — menor es mejor · presupuesto: 200 ms"
    x-axis ["17/s", "84/s", "84/s (1 símbolo)", "250/s (1 símbolo)", "500/s (1 símbolo)", "1000/s (1 símbolo)"]
    y-axis "p95 en ms" 0 --> 11
    bar [9.64, 4.91, 4.87, 3.63, 2.40, 1.11]
```

**Analysis of results:** el patrón es coherente en las siete corridas: latencia decreciente con la carga, backpressure jamás activado (0 rechazos), máximos aislados explicados por el arranque en frío (JIT), y doble medición k6/HdrHistogram sin divergencias relevantes. Validez: host único por loopback — los valores absolutos no se extrapolan a TEC-2; el patrón de comportamiento y los órdenes de magnitud de los márgenes sí. La comparación N=2 vs N=4 bajo estrés se descartó razonadamente: exigiría superar el techo (no hallado) de cada shard, punto donde el host único deja de ser instrumento confiable; la aditividad entre shards queda argumentada por construcción (no comparten nada).

**Links & evidence:** [Repositorio](https://github.com/MATI-MBIT/arqsoft-reto-1) · [Sitio de documentación](https://mati-mbit.github.io/arqsoft-reto-1/) · [Evidencia de corridas](https://mati-mbit.github.io/arqsoft-reto-1/evidencia-corridas.html) (resumen + salidas crudas de k6).

**Conclusion:** **H1 y H2 confirmadas** con márgenes de 20–40×; **H2b refutada en todo el rango explorado** — la partición caliente, la hipótesis de mayor riesgo del diseño y criterio de parada de la iteración, no degrada el servicio ni a 12× el pico contractual concentrado en una sola partición: pasa de "amenaza al SLA" a "límite de capacidad medido" (techo > 1.000 órdenes/s por shard como cota inferior).

**Architectural Decision (Paso 8 de ADD):** **ADOPTAR** LMAX (libro en memoria, único escritor por partición sobre ring buffer) + sharding determinístico por activo + cola acotada con backpressure como arquitectura del motor. La Iteración 1 cierra: su criterio de parada quedó resuelto afirmativamente. Deuda y trabajo futuro: repetir el diseño en el banco de 3 nodos (TEC-2) con red real; re-evaluar la estrategia de espera del Disruptor (Blocking en el PoC) con datos; profundizar el techo del shard solo si el negocio proyecta volúmenes de otro orden de magnitud; siguiente experimento candidato: E02 — fan-out de notificaciones (ASR-04).

---

## Notas de trazabilidad para la validación

- El criterio de éxito quedó unificado en **p95 ≤ 200 ms** en todo E01 (hipótesis, fases, thresholds y decisión anticipada), consistente con la medida de los escenarios en Helix; p99/p99.9 se registran como métricas observadas.
- Del documento del compañero (*Escenario de Pruebas PoC ASR-02/ASR-03*) se conservaron: hipótesis H1/H2/H2b, las 4 fases con precalentamiento, el modelo abierto de llegada (coordinated omission), el aislamiento por cpuset, la doble medición generador/motor, las alternativas descartadas y la limitación de validez del host único.
- Se recortó para viabilidad: Kubernetes (k3d), Redpanda, HPA, StatefulSets y gateway Spring Boot. La amortiguación por log se reemplazó por cola acotada con backpressure en el router; broker y autoescalado quedan declarados como limitación.
- Pendiente del equipo: el documento del compañero cita decisiones D-01…D-10 de un archivo `Decisiones-Arquitectura-Intermedia_ok.md` que no está en Helix ni en el proyecto; conviene registrarlas como ADRs en el modo Razonamiento del diagrama.
