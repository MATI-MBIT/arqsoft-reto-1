// Generador de carga del PoC E01 — modelo abierto de tasa de llegada
// (constant/ramping-arrival-rate) para evitar coordinated omission.
//
// Fases (env PHASE): f1 = baseline ASR-02 · f2 = rampa+pico+retorno ASR-03 (incluye F3)
//                    f4 = partición caliente (exploratoria)
// Ejemplos:
//   k6 run -e PHASE=f1 poc.js
//   k6 run -e PHASE=f2 -e SHARDS=2 poc.js
//   k6 run -e PHASE=f2 -e SMOKE=1 poc.js          # versión corta para probar el montaje
//   k6 run -e PHASE=f4 poc.js                      # 100 % del tráfico en un solo símbolo
//
// Requiere k6 >= 0.49 (gRPC unario nativo en k6/net/grpc, sin xk6).
import grpc from 'k6/net/grpc';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const TARGET = __ENV.TARGET || 'localhost:8080';
const PHASE = __ENV.PHASE || 'f1';
const SMOKE = __ENV.SMOKE === '1';

// 1.000 emp/min ≈ 17 req/s (Ambiente A) · 5.000 emp/min ≈ 84 req/s (Ambiente B)
const RATE_A = 17;
// PEAK permite explorar más allá del pico contractual (p. ej. buscar el punto
// de quiebre real de un shard en F4): k6 run -e PHASE=f4 -e PEAK=500 poc.js
const RATE_B = Number(__ENV.PEAK || 84);

// Símbolos: repartidos (≥3 activos) o concentrados (partición caliente, F4).
const SYMBOLS = PHASE === 'f4'
  ? ['HOT']
  : ['ECOPETROL', 'BANCOLOMBIA', 'ISA', 'GRUPOSURA', 'NUTRESA', 'CEMARGOS'];

const rejected = new Counter('orders_rejected_backpressure');

// Verificación empírica del aislamiento del sharding (retroalimentación 01-sep):
// cada respuesta trae el shard_id que la procesó; comprobamos que un mismo símbolo
// sea respondido SIEMPRE por el mismo shard. El mapa es por VU (los VUs de k6 no
// comparten estado), pero como el enrutamiento es determinístico, una sola
// violación en cualquier VU basta para delatar un reparto inconsistente.
const routingViolations = new Counter('shard_routing_violations');
const shardBySymbol = {};

function scenarioFor(phase) {
  if (phase === 'f1') {
    return {
      executor: 'constant-arrival-rate',
      rate: RATE_A,
      timeUnit: '1s',
      duration: SMOKE ? '1m' : '12m',
      preAllocatedVUs: 60,
      maxVUs: 300,
    };
  }
  // f2 y f4: precalentamiento → rampa corta (evento de mercado, no crecimiento
  // gradual) → pico sostenido (ventana ≤ 30 min) → retorno a régimen (F3).
  return {
    executor: 'ramping-arrival-rate',
    startRate: RATE_A,
    timeUnit: '1s',
    preAllocatedVUs: 120,
    maxVUs: 800,
    stages: SMOKE
      ? [
          { target: RATE_A, duration: '30s' },
          { target: RATE_B, duration: '30s' },
          { target: RATE_B, duration: '2m' },
          { target: RATE_A, duration: '30s' },
          { target: RATE_A, duration: '1m' },
        ]
      : [
          { target: RATE_A, duration: '2m' },   // precalentamiento medido aparte
          { target: RATE_B, duration: '2m' },   // rampa del evento de mercado
          { target: RATE_B, duration: '30m' },  // pico sostenido (Ambiente B)
          { target: RATE_A, duration: '1m' },   // caída
          { target: RATE_A, duration: '5m' },   // F3: retorno a régimen, drenar backlog
        ],
  };
}

export const options = {
  scenarios: { [PHASE]: scenarioFor(PHASE) },
  thresholds:
    PHASE === 'f4'
      ? {} // F4 es exploratoria: busca el punto de quiebre, no un aprobado/reprobado
      : {
          // Criterio de éxito de E01: p95 ≤ 200 ms (p99/p99.9 se observan, no deciden)
          grpc_req_duration: ['p(95)<200'],
          orders_rejected_backpressure: ['count==0'],
          // Aislamiento del sharding: cada símbolo, siempre el mismo shard
          shard_routing_violations: ['count==0'],
        },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
};

const client = new grpc.Client();
client.load(['../../services/common-proto/src/main/proto'], 'matching.proto');

let connected = false;

export default function () {
  if (!connected) {
    client.connect(TARGET, { plaintext: true });
    connected = true;
  }

  const symbol = SYMBOLS[Math.floor(Math.random() * SYMBOLS.length)];
  const side = Math.random() < 0.5 ? 'BUY' : 'SELL';
  // Precios alrededor de 100.00 con dispersión pequeña: garantiza cruces frecuentes.
  const priceCents = 10000 + Math.floor(Math.random() * 21) - 10;

  const response = client.invoke('matching.v1.MatchingIngest/SubmitOrder', {
    order_id: `${__VU}-${__ITER}`,
    symbol: symbol,
    side: side,
    price_cents: priceCents,
    quantity: 1 + Math.floor(Math.random() * 100),
    client_ts_nanos: 0,
  });

  const ok = check(response, {
    'status gRPC OK': (r) => r && r.status === grpc.StatusOK,
  });

  if (ok) {
    if (response.message.status === 'REJECTED') {
      rejected.add(1);
    }
    const sid = response.message.shardId;
    if (sid !== undefined && sid !== null) {
      if (shardBySymbol[symbol] === undefined) {
        shardBySymbol[symbol] = sid;
      } else if (shardBySymbol[symbol] !== sid) {
        routingViolations.add(1);
      }
    }
  }
}
