# arqsoft-reto-1 — Experimento Motor de Emparejamiento

Monorepo del **PoC del experimento E01** (Reto 1, ARTI4109): validar el patrón **LMAX** (libro de órdenes en memoria, un único escritor por partición) con **sharding por activo** e ingesta **gRPC**, contra los dos ASR críticos:

- **ASR-02 · Latencia (Critical):** emparejamiento p95 ≤ 200 ms a 1.000 emp/min (Ambiente A).
- **ASR-03 · Escalabilidad transitoria (Critical):** rampa de 1.000 → 5.000 emp/min sostenida hasta 30 min con p95 ≤ 200 ms (Ambiente B).

## Documentación

📖 **Sitio de documentación (GitHub Pages):** <https://mati-mbit.github.io/arqsoft-reto-1/> — se publica automáticamente desde `docs/` con Jekyll (tema *just-the-docs*, con búsqueda y diagramas Mermaid). Para previsualizar en local: `make docs-serve`.

| Documento | Contenido |
|---|---|
| [`docs/experimento.md`](docs/experimento.md) | La apuesta: hipótesis H1/H2/H2b, escenarios vinculados, fases F1–F4, métricas y criterios de éxito |
| [`docs/implementacion.md`](docs/implementacion.md) | Cómo funciona el prototipo: viaje de una orden, de la táctica al código, configuración, medición y límites |
| [`docs/evidencia-corridas.md`](docs/evidencia-corridas.md) | Los resultados, cómo se leen los números, los hallazgos y las salidas crudas |
| [`docs/construccion-componentes.md`](docs/construccion-componentes.md) | Con qué está construida cada pieza del monorepo y qué decisión hay detrás |
| [`load/README.md`](load/README.md) | Detalle de las corridas de carga con k6 |

## Estructura del monorepo

```
├── services/
│   ├── common-proto/      Contrato gRPC/Protobuf (matching.proto) y stubs generados
│   ├── ingest-router/     Ingesta gRPC · sharding hash(símbolo) % N · cola acotada (backpressure)
│   └── matching-engine/   Shard LMAX: ring buffer (Disruptor) + libro en memoria + HdrHistogram
├── deploy/
│   ├── Dockerfile         Multi-etapa (Gradle+JDK 21 → Temurin 21 JRE), un servicio por build-arg
│   ├── docker-compose.yml Router + N particiones + Prometheus + Grafana
│   └── observabilidad/    Config de Prometheus y tablero de Grafana aprovisionado
├── load/
│   ├── k6/poc.js          Generador: calentamiento + F1 / F2 / F3 / F4 en modelo abierto
│   ├── run-e2e.sh         El ciclo oficial completo en un comando
│   └── *.sh               Los cuatro estudios (presupuesto, CPU, bitácora, JFR)
├── docs/                  Documentación del experimento y de la implementación
└── Makefile               Los comandos del proyecto (make help)
```

## Requisitos

Java 21 (solo si compilas fuera de Docker), Docker + Docker Compose, `make`, y [k6](https://k6.io) ≥ 0.49 (`brew install k6`). Todo de licencia abierta (TEC-3/4); despliegue sobre contenedores (TEC-5); JVM/Java 21 (TEC-1).

## Quickstart

```bash
make build                    # compila los 3 módulos y genera los stubs
make up BIZ_MICROS=8000       # router :8080 + 2 particiones + Prometheus + Grafana
make smoke                    # humo de ~1,5 min para verificar el montaje
make tablero                  # abre la evidencia en vivo en Grafana
```

`BIZ_MICROS` es el costo medio por orden en µs. **No tiene default útil:** en 0 la
lógica de negocio está apagada y el p95 que salga no es el de un motor real.

## Comandos (`make help` los agrupa por sección)

Un comando existe si produce evidencia que la documentación cita, o si es parte
del ciclo diario. Lo que solo parametriza a otro comando se pasa como variable:
`make f4 PEAK=500`, no un comando por tasa.

| Comando | Qué hace |
|---|---|
| **`make e2e BIZ_MICROS=8000`** | **El ciclo oficial en un comando** (~1h40m): F1 → F2+F3 → F4 → exploración del quiebre. Archiva salida cruda y JSON por fase en `load/k6/results/<timestamp>/`, alimenta el tablero, y **sale con error si alguna fase oficial incumple** |
| **`make e2e-smoke`** | El mismo ciclo en corto (~25 min): la regresión a correr tras cada cambio |
| `make build` / `test` / `clean` | Ciclo Gradle. `clean` borra también los volúmenes, incluido el histórico de Prometheus |
| `make up` / `up-n4` | Topología con 2 o 4 particiones, más Prometheus y Grafana |
| `make down` / `ps` / `logs` | Operación. `down` conserva el histórico de Prometheus |
| **`make tablero`** | Abre el tablero de Grafana con la evidencia en vivo |
| **`make verify-limits`** | Lee el cgroup real y lo contrasta con lo declarado. `deploy.resources` se ignora en silencio fuera de Swarm, así que el YAML no prueba nada |
| `make smoke` | Verificación de ~1,5 min del montaje completo |
| `make f1` / `f2` / `f4` | Las fases sueltas. F1 y F2 traen criterio ejecutable; F4 es exploratoria (`make f4 PEAK=500`) |
| **`make sweep-service`** | Barre el costo por orden y produce el **presupuesto**: el mayor S con el que el patrón aún cumple. Medido: **12,4 ms/orden** con N=2 |
| `make sweep-hot` | El mismo barrido con todo el pico en una sola partición: **8,5 ms/orden** |
| `make compare-cpus` | Confina cada partición a 0 / 2 / 1 / 0,5 núcleos y mide el efecto. Con un núcleo el p95 no cambia; con medio se degrada un 72 % |
| `make compare-journal` | Bitácora `off` / `paralelo` / `serie`: prueba la cláusula de H1 sobre mantenerla fuera del camino crítico |
| `make profile-jfr` | Perfila una fase con Java Flight Recorder para atribuir los atascos aislados a GC, JIT o safepoints |

## Cómo se mide

k6 mide la latencia extremo a extremo del RPC con umbral `p(95)<200`, en modelo abierto de llegada para evitar *coordinated omission*. Cada partición mide por dentro el arribo → materialización con HdrHistogram.

**El calentamiento es un escenario aparte y no entra en el criterio.** El umbral se aplica por escenario (`grpc_req_duration{scenario:f1}`), así que una JVM que todavía está compilando no decide el veredicto. F3 —el retorno a régimen— también es escenario propio: la ficha le pide comparar su latencia contra la de F1, y dentro de F2 quedaba promediada con la del pico.

**Las dos mitades de la medición viven en la misma línea de tiempo.** Prometheus raspa cada 10 s el `/metrics` de las particiones y del router, y k6 escribe ahí sus métricas por escritura remota. El tablero de Grafana (`make tablero`, aprovisionado desde `deploy/observabilidad/`) los cruza: la resta entre el reloj del cliente y el del motor es el costo del transporte, y el panel la dibuja en vez de calcularla a mano.

El shard publica ventanas de 10 s para ver la evolución, y un `ACUMULADO` de toda la fase al cerrar. Solo el acumulado es comparable cifra a cifra con k6, y su resta es el costo de transporte. Un `status=REJECTED` es la señal de backpressure de la cola acotada — en F1–F3 el criterio exige 0 rechazos.

El motor **registra cada orden** en un journal de solo-anexado cuando `JOURNAL=paralelo` o `serie`, y admite **cuotas de CPU** por partición (`SHARD_CPUS`) y **grabación con JFR** (`make profile-jfr`).

**Ninguna cifra se lee sin su `S` al lado**: el PoC no implementa la lógica de negocio, y ese costo por orden gobierna el techo del shard (`1/S`), el reparto motor/transporte y si la partición caliente amenaza el SLA. Se declara con `BIZ_MICROS`. Detalle completo en [`docs/implementacion.md`](docs/implementacion.md) y resultados en [`docs/evidencia-corridas.md`](docs/evidencia-corridas.md).

## Limitaciones declaradas del PoC

Una sola máquina por loopback: no representa la red de 1 Gbps del banco de pruebas (TEC-2) ni alta disponibilidad — valida el patrón, no el dimensionamiento. El `cpuset` de aislamiento solo aplica en hosts Linux (en macOS, Docker corre en una VM). Quedan fuera por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado. Deuda registrada en E01: la estrategia de espera del Disruptor (Blocking en el PoC) se re-evaluará con datos.
