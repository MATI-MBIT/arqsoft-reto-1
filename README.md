# arqsoft-reto-1 — Experimento Motor de Emparejamiento

Monorepo del **PoC del experimento E01** (Reto 1, ARTI4109): validar el patrón **LMAX** (libro de órdenes en memoria, un único escritor por partición) con **sharding por activo** e ingesta **gRPC**, contra los dos ASR críticos:

- **ASR-02 · Latencia (Critical):** emparejamiento p95 ≤ 200 ms a 1.000 emp/min (Ambiente A).
- **ASR-03 · Escalabilidad transitoria (Critical):** rampa de 1.000 → 5.000 emp/min sostenida hasta 30 min con p95 ≤ 200 ms (Ambiente B).

La ficha completa del experimento (hipótesis H1/H2/H2b, fases, métricas y criterios) vive en la pestaña **Experiments de Helix** y en [`docs/experimento-e01.md`](docs/experimento-e01.md).

## Estructura del monorepo

```
├── services/
│   ├── common-proto/      Contrato gRPC/Protobuf (matching.proto) y stubs generados
│   ├── ingest-router/     Ingesta gRPC · sharding hash(símbolo) % N · cola acotada (backpressure)
│   └── matching-engine/   Shard LMAX: ring buffer (Disruptor) + libro en memoria + HdrHistogram
├── deploy/                Dockerfile multi-etapa + docker-compose (router + N shards)
├── load/k6/               Script de carga k6 (fases F1, F2+F3, F4) en modelo abierto
└── docs/                  Ficha del experimento E01 (espejo de Helix)
```

## Requisitos

Java 21 (solo si compilas fuera de Docker), Docker + Docker Compose, y [k6](https://k6.io) ≥ 0.49 (`brew install k6`). Todo de licencia abierta (TEC-3/4); despliegue sobre contenedores (TEC-5); JVM/Java 21 (TEC-1).

## Quickstart

```bash
./gradlew build                                        # compila los 3 módulos y genera stubs
docker compose -f deploy/docker-compose.yml up --build # router :8080 + 2 shards
cd load/k6
k6 run -e PHASE=f1 -e SMOKE=1 poc.js                   # humo de 1 min para verificar el montaje
```

Corridas oficiales del experimento (ver `load/README.md`): `PHASE=f1` (baseline ASR-02), `PHASE=f2` (rampa + pico 30 min + retorno, ASR-03), `PHASE=f4` (partición caliente, exploratoria). Para N=4 shards: `docker compose --profile n4 up` y añadir los shards 2 y 3 a la variable `SHARDS` del router en el compose.

## Cómo se mide

k6 mide la latencia extremo a extremo del RPC (modelo abierto de llegada, sin *coordinated omission*) con umbral `p(95)<200`; cada shard registra internamente arribo → materialización en HdrHistogram y loguea p50/p95/p99/p99.9 cada 10 s para contrastar. Un `status=REJECTED` es la señal de backpressure de la cola acotada — en F1–F3 el criterio exige 0 rechazos.

## Limitaciones declaradas del PoC

Una sola máquina por loopback: no representa la red de 1 Gbps del banco de pruebas (TEC-2) ni alta disponibilidad — valida el patrón, no el dimensionamiento. El `cpuset` de aislamiento solo aplica en hosts Linux (en macOS, Docker corre en una VM). Quedan fuera por no incidir en ASR-02/03: fan-out de notificaciones, proyecciones CQRS, persistencia, broker y autoescalado. Deuda registrada en E01: la estrategia de espera del Disruptor (Blocking en el PoC) se re-evaluará con datos.
