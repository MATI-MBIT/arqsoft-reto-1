# E01 — Validar el patrón LMAX (motor en memoria con un único escritor) para el emparejamiento

**Reto 1: Desempeño · ARTI4109 · Pestaña Experiments de Helix**
Estado: **Planned** · Extraído de Helix el 30 de agosto de 2026 para validación del equipo.

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

Patrón LMAX Architecture (Disruptor): procesador de eventos secuencial con libro de órdenes en memoria y un único escritor lógico por partición de activo, entrada por ring buffer sin bloqueos (mechanical sympathy: los datos del activo permanecen calientes en la caché del núcleo asignado). Sharding por activo: enrutamiento determinístico hash(símbolo) % N desde el servicio de ingesta gRPC/Protobuf hacia N shards independientes; la exclusión mutua queda garantizada por construcción —no por locks— y aporta de paso la garantía de no doble-materialización. Tácticas de latencia: mantener los datos del camino crítico en memoria, reducir overhead evitando bloqueos y contención, mover journaling y notificación a etapas asíncronas. Tácticas de escalabilidad: particionamiento por activo (el throughput total escala agregando shards) y cola acotada con backpressure en la ingesta (se prefiere frenar la entrada antes que prometer una latencia incumplible). Alternativas descartadas: pool de workers con colas bloqueantes (reintroduce la contención), locks de grano fino por nivel de precio (deadlocks y latencia impredecible), PostgreSQL con SELECT FOR UPDATE (se mantiene como línea base de comparación), modelo de actores (overhead de mailbox), bloqueo distribuido (salto de red en el camino crítico).

### Experiment Design

PoC mínimo en una sola máquina (mínimo 8 vCPU/16 GB, ideal 12+/32), todo Java 21 sobre Docker Compose —sin Kubernetes ni broker—: generador k6 + xk6-grpc (modelo abierto de tasa de llegada, evita coordinated omission) → servicio de ingesta gRPC/Protobuf con router de sharding hash(símbolo) % N y cola acotada → N motores LMAX (Disruptor 4.x, libro en memoria por activo, journaling asíncrono a archivo). Aislamiento por cpuset: núcleos dedicados al motor, separados del generador, para no contaminar los percentiles. Precalentamiento sin medir (estabilizar JIT y GC).

Corridas:

- **F1 — Baseline (ASR-02):** 1.000 emp/min estocásticos (≈17/s) repartidos en ≥3 activos, 10–15 min; criterio p95 ≤ 200 ms.
- **F2 — Rampa transitoria (ASR-03):** rampa de 1.000 a 5.000 emp/min en pocos minutos y sostenida hasta 30 min repartida entre activos, corrida con N=2 y N=4 shards; criterio: p95 ≤ 200 ms durante toda la ventana y backlog de la cola sin crecimiento descontrolado.
- **F3 — Retorno a régimen:** bajar a 1.000/min y verificar que el backlog drena y el p95 vuelve al valor de F1 (la escalabilidad exigida es transitoria, no permanente).
- **F4 — Partición caliente (exploratoria, sin criterio binario):** mismo perfil de F2 con el 100 % del tráfico en un solo activo, para encontrar el punto de quiebre de un shard.

Métricas: latencia arribo→materialización p50/p95/p99/p99.9 medida en el generador y contrastada con HdrHistogram interno del motor; throughput real vs. objetivo; profundidad de cola/backlog; tasa de rechazo (backpressure); pausas de GC (JFR); CPU por proceso. Los thresholds de k6 marcan la corrida como fallida si p95 > 200 ms en vivo.

Limitación declarada: el tráfico corre por loopback —no representa la red de 1 Gbps de TEC-2 ni alta disponibilidad—; el PoC valida el patrón, no el dimensionamiento final.

### Experiment planning

**Required resources:** Java 21 + LMAX Disruptor 4.x + gRPC/Protobuf; Docker Compose (sin Kubernetes ni broker); k6 con extensión xk6-grpc (compilado con xk6) como generador de carga en modelo abierto, con thresholds en vivo y exportación a Prometheus/Grafana para las curvas del informe; HdrHistogram y JFR para percentiles y pausas de GC; 1 máquina de 8 vCPU/16 GB (ideal 12 vCPU/32 GB) con núcleos aislados por cpuset; scripts de orquestación y análisis.

**Architecture elements involved:** Servicio de ingesta gRPC con router de sharding por símbolo (hash % N) y cola acotada con backpressure; N shards del motor de emparejamiento (LMAX, libro en memoria por activo, un escritor por partición); journaling asíncrono (stub a archivo); generador de carga externo. Excluidos por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado (declarados como limitación del PoC). Vistas afectadas: funcional y concurrencia.

**Estimated effort:** 2 personas × 1 semana (≈ 40 horas-persona): 2 días ingesta gRPC + router de sharding + motor LMAX; 1 día generador k6 e instrumentación; 1 día corridas F1–F4; 1 día análisis, informe y decisión (Paso 8).

---

## Pestaña Results & analysis

**Results:** Pendiente: se diligencia tras ejecutar las corridas.

**Analysis of results:** *(vacío — se diligencia con las corridas)*

**Links & evidence:** sin evidencia aún. Campos disponibles: Code repository, External report, Evidence (enlaces a gráficas, dashboards o corridas).

**Conclusion:** *(vacío — se diligencia con las corridas)*

**Architectural Decision:** Pendiente. Criterios anticipados: si p95 ≤ 200 ms se sostiene en F1–F3 y el punto de quiebre de F4 queda por encima de la carga plausible de un solo activo, adoptar LMAX + sharding por activo para el motor; si solo falla la partición caliente, decidir explícitamente entre sub-particionar el libro, rebalancear o aceptar un SLA distinto para picos concentrados en un único símbolo (Paso 8 de ADD); si falla en general, evaluar sharding con múltiples escritores y comparar contra la línea base transaccional (PostgreSQL con SELECT FOR UPDATE).

---

## Notas de trazabilidad para la validación

- El criterio de éxito quedó unificado en **p95 ≤ 200 ms** en todo E01 (hipótesis, fases, thresholds y decisión anticipada), consistente con la medida de los escenarios en Helix; p99/p99.9 se registran como métricas observadas.
- Del documento del compañero (*Escenario de Pruebas PoC ASR-02/ASR-03*) se conservaron: hipótesis H1/H2/H2b, las 4 fases con precalentamiento, el modelo abierto de llegada (coordinated omission), el aislamiento por cpuset, la doble medición generador/motor, las alternativas descartadas y la limitación de validez del host único.
- Se recortó para viabilidad: Kubernetes (k3d), Redpanda, HPA, StatefulSets y gateway Spring Boot. La amortiguación por log se reemplazó por cola acotada con backpressure en el router; broker y autoescalado quedan declarados como limitación.
- Pendiente del equipo: el documento del compañero cita decisiones D-01…D-10 de un archivo `Decisiones-Arquitectura-Intermedia_ok.md` que no está en Helix ni en el proyecto; conviene registrarlas como ADRs en el modo Razonamiento del diagrama.
