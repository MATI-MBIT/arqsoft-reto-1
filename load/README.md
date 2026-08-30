# Generación de carga — PoC E01

Requiere [k6](https://k6.io) ≥ 0.49 (trae gRPC unario nativo en `k6/net/grpc`; no hace falta compilar xk6). Instalación en macOS: `brew install k6`.

Con la topología arriba (`docker compose -f deploy/docker-compose.yml up --build`):

| Fase | Comando | Valida | Criterio |
|---|---|---|---|
| F1 baseline | `k6 run -e PHASE=f1 poc.js` | ASR-02 | p95 < 200 ms |
| F2+F3 rampa, pico 30 min y retorno | `k6 run -e PHASE=f2 poc.js` | ASR-03 | p95 < 200 ms toda la ventana, 0 rechazos |
| F4 partición caliente | `k6 run -e PHASE=f4 poc.js` | exploratoria (H2b) | sin criterio binario: buscar punto de quiebre |

`-e SMOKE=1` corre una versión de ~5 min para verificar el montaje antes de la corrida oficial.
`-e TARGET=host:puerto` apunta a otro router. Los percentiles del generador se contrastan con los que cada shard loguea cada 10 s (HdrHistogram interno).

El modelo de carga es **abierto** (tasa de llegada objetivo), no N usuarios esperando respuesta: el modelo cerrado subestima el p95/p99 bajo saturación (*coordinated omission*).
