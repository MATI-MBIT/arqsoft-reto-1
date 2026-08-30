# arqsoft-reto-1 — Experimento Motor de Emparejamiento

Monorepo del **PoC del experimento E01** (Reto 1, ARTI4109): validar el patrón **LMAX** (libro de órdenes en memoria, un único escritor por partición) con **sharding por activo** e ingesta **gRPC**, contra los dos ASR críticos:

- **ASR-02 · Latencia (Critical):** emparejamiento p95 ≤ 200 ms a 1.000 emp/min (Ambiente A).
- **ASR-03 · Escalabilidad transitoria (Critical):** rampa de 1.000 → 5.000 emp/min sostenida hasta 30 min con p95 ≤ 200 ms (Ambiente B).

## Documentación

📖 **Sitio de documentación (GitHub Pages):** <https://mati-mbit.github.io/arqsoft-reto-1/> — se publica automáticamente desde `docs/` con Jekyll (tema *just-the-docs*, con búsqueda y diagramas Mermaid). Para previsualizar en local: `make docs-serve`.

| Documento | Contenido |
|---|---|
| [`docs/experimento-e01.md`](docs/experimento-e01.md) | Ficha del experimento (espejo de Helix): hipótesis H1/H2/H2b, escenarios vinculados, fases, métricas y criterios |
| [`docs/implementacion.md`](docs/implementacion.md) | Cómo está implementado el PoC: componentes, flujo de una orden, mapeo táctica → código, configuración, medición y limitaciones |
| [`load/README.md`](load/README.md) | Detalle de las corridas de carga con k6 |

## Estructura del monorepo

```
├── services/
│   ├── common-proto/      Contrato gRPC/Protobuf (matching.proto) y stubs generados
│   ├── ingest-router/     Ingesta gRPC · sharding hash(símbolo) % N · cola acotada (backpressure)
│   └── matching-engine/   Shard LMAX: ring buffer (Disruptor) + libro en memoria + HdrHistogram
├── deploy/                Dockerfile multi-etapa + docker-compose (router + N shards)
├── load/k6/               Script de carga k6 (fases F1, F2+F3, F4) en modelo abierto
├── docs/                  Documentación del experimento y de la implementación
└── Makefile               Todos los comandos del proyecto (make help)
```

## Requisitos

Java 21 (solo si compilas fuera de Docker), Docker + Docker Compose, `make`, y [k6](https://k6.io) ≥ 0.49 (`brew install k6`). Todo de licencia abierta (TEC-3/4); despliegue sobre contenedores (TEC-5); JVM/Java 21 (TEC-1).

## Quickstart

```bash
make build     # compila los 3 módulos y genera los stubs
make up        # levanta router :8080 + 2 shards LMAX
make smoke     # humo de ~1 min para verificar el montaje
```

## Comandos (`make help` para la lista completa)

| Comando | Qué hace |
|---|---|
| `make build` / `make test` / `make clean` | Ciclo Gradle |
| `make up` / `make up-n4` | Topología con 2 o 4 shards |
| `make smoke` / `make smoke-f2` | Verificaciones cortas del montaje |
| `make f1` | F1 — baseline ASR-02 (12 min, p95 < 200 ms) |
| `make f2` | F2+F3 — rampa, pico de 30 min y retorno a régimen (ASR-03) |
| `make f4` | F4 — partición caliente al pico contractual (exploratoria, sin criterio binario) |
| `make f4-explore` / `make f4-peak PEAK=n` | Busca el punto de quiebre de un shard (corridas cortas a 250/500/1000/s o tasa libre) |
| `make compare-sharding PEAK=n` | Corre la misma carga repartida sobre N=2 y luego N=4: evidencia de escalamiento por sharding |
| `make experimento` | Secuencia oficial completa: `up` → F1 → F2+F3 → F4 |
| `make logs` / `make ps` / `make down` | Operación de la topología |
| `make run-shard` / `make run-router` | Correr un servicio local sin Docker |

## Cómo se mide

k6 mide la latencia extremo a extremo del RPC (modelo abierto de llegada, sin *coordinated omission*) con umbral `p(95)<200`; cada shard registra internamente arribo → materialización en HdrHistogram y loguea p50/p95/p99/p99.9 cada 10 s para contrastar. Un `status=REJECTED` es la señal de backpressure de la cola acotada — en F1–F3 el criterio exige 0 rechazos. Detalle completo en [`docs/implementacion.md`](docs/implementacion.md).

## Limitaciones declaradas del PoC

Una sola máquina por loopback: no representa la red de 1 Gbps del banco de pruebas (TEC-2) ni alta disponibilidad — valida el patrón, no el dimensionamiento. El `cpuset` de aislamiento solo aplica en hosts Linux (en macOS, Docker corre en una VM). Quedan fuera por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado. Deuda registrada en E01: la estrategia de espera del Disruptor (Blocking en el PoC) se re-evaluará con datos.
