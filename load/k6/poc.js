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
//   k6 run -e PHASE=f1 -e JITTER_FACTOR=0 poc.js   # arribo periódico: comparación A/B
//
// Requiere k6 >= 0.49 (gRPC unario nativo en k6/net/grpc, sin xk6).
import grpc from 'k6/net/grpc';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const TARGET = __ENV.TARGET || 'localhost:8080';
const PHASE = __ENV.PHASE || 'f1';
const SMOKE = __ENV.SMOKE === '1';

// 1.000 emp/min ≈ 17 req/s (Ambiente A) · 5.000 emp/min ≈ 84 req/s (Ambiente B)
const RATE_A = 17;
// PEAK permite explorar más allá del pico contractual (p. ej. buscar el punto
// de quiebre real de un shard en F4): k6 run -e PHASE=f4 -e PEAK=500 poc.js
const RATE_B = Number(__ENV.PEAK || 84);

// Tasa más alta que alcanza la fase: define el espaciado nominal entre llegadas.
const PEAK_RATE = PHASE === 'f1' ? RATE_A : RATE_B;

// ---------------------------------------------------------------------------
// Arribo estocástico (H1 exige "arribo estocástico", no una tasa constante)
// ---------------------------------------------------------------------------
// Los executors de tasa de llegada de k6 NO lo dan por sí solos: su documentación
// especifica que "iteration starts are fractionally spaced" — a 17/s, una orden
// cada 58,8 ms exactos. Eso es un metrónomo: predecible y periódico.
//
// El problema no es de realismo sino de validez. Con llegadas deterministas la
// varianza del arribo es 0 y, por Kingman, la espera en cola se desploma: el ring
// buffer nunca acumula, el backpressure jamás se activa y el p95/p99 sale
// optimista. El criterio se cumpliría sin someter la hipótesis a su propia condición.
//
// Corrección: desplazar cada iteración un tiempo exponencial independiente antes
// de emitir el RPC. Por Palm–Khintchine la superposición converge a un proceso de
// Poisson conservando la tasa media. Medido sobre 200.000 llegadas simuladas, Ca²
// pasa de 0,00 a 0,89 (Poisson = 1) sin desviar la tasa.
//
// La media del desplazamiento se fija en JITTER_FACTOR veces el espaciado nominal:
// así el costo en VUs (ley de Little: VUs ≈ tasa × duración ≈ JITTER_FACTOR) no
// depende de la tasa. JITTER_FACTOR=0 restaura el arribo periódico para comparar.
const JITTER_FACTOR =
  __ENV.JITTER_FACTOR === undefined ? 8 : Number(__ENV.JITTER_FACTOR);
const JITTER_MEAN_SECONDS = JITTER_FACTOR / PEAK_RATE;

/** Tiempo entre llegadas exponencial, por transformada inversa. */
function exponentialSeconds(meanSeconds) {
  if (meanSeconds <= 0) {
    return 0;
  }
  // Math.random() ∈ [0,1) ⇒ (1 − r) ∈ (0,1]: nunca se evalúa log(0).
  return -Math.log(1 - Math.random()) * meanSeconds;
}

// Con el desplazamiento la iteración dura ~JITTER_MEAN + el RPC, así que por Little
// hacen falta ~JITTER_FACTOR VUs en régimen; se preasigna con holgura para la cola
// exponencial. Si faltaran, el umbral dropped_iterations lo delata.
const PRE_VUS = Math.max(60, JITTER_FACTOR * 8);
const MAX_VUS = Math.max(300, JITTER_FACTOR * 40);

// Símbolos: el sharding es floorMod(String.hashCode(símbolo), N), así que el
// conjunto de prueba decide el balance. Los 6 anteriores repartían 67 %/33 % con
// N=2 y dejaban un shard OCIOSO con N=4 — eso mide el desbalance del conjunto, no
// el patrón. Estos 36 nemotécnicos de la BVC reparten exacto: 18/18 (N=2) y
// 9/9/9/9 (N=4). Al cambiar la lista hay que reverificar el reparto.
const SYMBOLS = PHASE === 'f4'
  ? ['HOT']
  : [
      'PROMIGAS', 'PFDAVVNDA', 'GEB', 'ELCONDOR', 'VALOREM',
      'OCCIDENTE', 'PEI', 'ODINSA', 'BIOMAX',
      'ECOPETROL', 'PFGRUPSURA', 'PFCEMARGOS', 'GRUPOARGOS', 'CELSIA',
      'PFCORFICOL', 'DAVIVIENDA', 'GRUPOAVAL', 'BBVACOL',
      'BCOLOMBIA', 'PFBCOLOM', 'GRUPOSURA', 'NUTRESA', 'TERPEL',
      'CORFICOLCF', 'BOGOTA', 'PFAVAL', 'CONCONCRET',
      'ISA', 'CEMARGOS', 'PFGRUPOARG', 'BVC', 'CANACOL',
      'MINEROS', 'ETB', 'FABRICATO', 'ENKA',
    ];

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
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
    };
  }
  // f2 y f4: precalentamiento → rampa corta (evento de mercado, no crecimiento
  // gradual) → pico sostenido (ventana ≤ 30 min) → retorno a régimen (F3).
  return {
    executor: 'ramping-arrival-rate',
    startRate: RATE_A,
    timeUnit: '1s',
    preAllocatedVUs: Math.max(120, PRE_VUS),
    maxVUs: Math.max(800, MAX_VUS),
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
          // k6 descarta una iteración cuando no tiene un VU libre. Eso es carga que
          // NUNCA se aplicó: la tasa real quedó por debajo de la objetivo y el p95
          // resultante subestima al sistema. Exigir 0 impide que el generador se
          // vuelva el cuello de botella sin avisar.
          dropped_iterations: ['count==0'],
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

  // Arribo estocástico: la iteración arranca equiespaciada (k6), pero la orden sale
  // desplazada. Va ANTES del invoke a propósito — grpc_req_duration solo cronometra
  // el RPC, así que esta espera no contamina la medición.
  sleep(exponentialSeconds(JITTER_MEAN_SECONDS));

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
