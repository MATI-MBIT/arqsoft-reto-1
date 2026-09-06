# Arquitectura Detallada: Load Testing con k6

Análisis profundo a nivel de código del generador de carga k6 para el motor de emparejamiento. Este documento explica la estructura, métodos, flujo de ejecución y estrategia de validación del experimento E01.

---

## Tabla de Contenidos

1. [Introducción y Propósito](#introducción-y-propósito)
2. [Arquitectura General](#arquitectura-general)
3. [Análisis Detallado: poc.js](#análisis-detallado-pocjs)
4. [Análisis Detallado: experimento.sh](#análisis-detallado-experimentosh)
5. [Flujo de Operaciones](#flujo-de-operaciones)
6. [Patrones de Diseño](#patrones-de-diseño)
7. [Validación y Criterios](#validación-y-criterios)

---

## Introducción y Propósito

El **load testing** en este proyecto tiene dos objetivos:

1. **Medir:** Cuantificar latencia, throughput y rechazos del motor bajo diferentes cargas
2. **Validar:** Verificar que el sistema cumple los criterios de desempeño (p95 < 200ms)

### Desafío Fundamental: El Problema de Coordinated Omission

**Contexto:** Un generador de carga típico (modelo cerrado) espera la respuesta de una orden antes de enviar la siguiente. Con 100 clientes virtuales y latencia de 50ms:

```
Cliente 1: ├─ envía orden ─ espera 50ms ─ recibe respuesta ─ envía orden 2
                             ↑
                        Latencia observada: 50ms

Pero si el sistema de atrás tiene acumulo:
Cliente 1: ├─ envía orden ─ espera 50ms ─ recibe respuesta (en la cola hace 500ms)
                             ↑              ↑
                        Cliente ve: 50ms  Motor vio: 550ms
```

**Solución:** Modelo abierto (constant-arrival-rate). Las órdenes se emiten a una tasa fija, independientemente de cuándo llegue la respuesta.

```
Timeline:
t=0ms    ├─ orden 1 emitida
t=58ms   ├─ orden 2 emitida (17 órdenes/seg = 58.8ms entre llegadas)
t=117ms  ├─ orden 3 emitida
         ├─ respuesta orden 1 llega (con latencia real)
```

**Pero:** Con tasa **periódica** (metrónomo perfecto), la varianza de arribo es 0 y el ring buffer nunca acumula → latencias optimistas.

**Corrección:** Añadir jitter estocástico (arribo exponencial) antes de cada orden. Así el generador mide el sistema en verdadera congestión, no un sistema vacío.

---

## Arquitectura General

### Topología de Pruebas

```
┌──────────────────────────────────────────────────────────────────┐
│                         k6 (Generador de carga)                  │
│                                                                  │
│  poc.js (Script k6)                                              │
│  ├─ Lee plan.tsv → qué probar                                    │
│  ├─ Define escenarios (f1, f2, f3, f4)                           │
│  ├─ Configura VUs y tasa de llegada                              │
│  └─ Ejecuta iteraciones: generar orden → gRPC → medir latencia  │
│                                                                  │
│  Iteración de trabajo:                                           │
│  ├─ sleep(exponentialSeconds()) [arribo estocástico]            │
│  ├─ Elige símbolo, precio, cantidad aleatorios                  │
│  ├─ Invoca gRPC: SubmitOrder                                     │
│  ├─ Verifica respuesta: OK, REJECTED, MATCHED, etc.             │
│  └─ k6 registra: latencia (grpc_req_duration), resultado        │
│                                                                  │
│  Métricas recolectadas:                                          │
│  ├─ grpc_req_duration: latencia de cada RPC                     │
│  ├─ orders_rejected_backpressure: rechazos por anillo lleno     │
│  ├─ shard_routing_violations: enrutamiento inconsistente        │
│  ├─ dropped_iterations: iteraciones no emitidas (VUs insuf)    │
│  └─ Prometheus: envía percentiles cada 5 segundos              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              ↓
                    (gRPC :8080 / :9090)
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                    Sistema Bajo Prueba                           │
│                                                                  │
│  ingest-router (puerto 8080)                                     │
│  ├─ Recibe órdenes de k6                                         │
│  ├─ Aplica backpressure (QUEUE_CAPACITY)                        │
│  └─ Reenvía a shards                                             │
│                                                                  │
│  matching-shards (puerto 9090, N=1,2,4)                         │
│  ├─ Procesa matching                                             │
│  ├─ Mide latencia interna (espera, servicio)                    │
│  └─ Expone /metrics (Prometheus)                                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                    Observabilidad                                │
│                                                                  │
│  Prometheus                                                      │
│  ├─ Recibe métricas de k6 (K6_PROMETHEUS_RW_SERVER_URL)        │
│  ├─ Raspa /metrics de shards cada 10s                           │
│  └─ Almacena series temporales                                   │
│                                                                  │
│  Grafana                                                         │
│  └─ Tablero "e01-motor-emparejamiento"                          │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Flujo General

```
plan.tsv (QUÉ ejecutar)
   ↓
experimento.sh (CÓMO ejecutar)
   ├─ levantar(N)        → docker compose up con N shards
   ├─ ejecutar()         → k6 run poc.js
   ├─ registrar()        → extrae y tabula resultados
   └─ perfilar_jfr()     → analiza pausas GC (opcional)
   ↓
resultados.tsv (RESULTADOS)
```

---

## Análisis Detallado: poc.js

### Configuración Global

```javascript
// ═══════════════════════════════════════════════════════════════════
// VARIABLES DE ENTRADA (por línea de comandos)
// ═══════════════════════════════════════════════════════════════════

const TARGET = __ENV.TARGET || 'localhost:8080';
// → Host y puerto del router. Default: localhost:8080
// → Para apuntar a un shard directamente: -e TARGET=localhost:9090

const PHASE = __ENV.PHASE || 'f1';
// → Fase del experimento: f1 (baseline), f2 (pico), f3 (retorno), f4 (hot partition)

const SMOKE = __ENV.SMOKE === '1';
// → Si true: versión corta (~5min) para verificar montaje

const RATE_A = 17;
// → Tasa de línea de base: 17 órdenes/segundo
// → Corresponde a 1000 órdenes/minuto

const RATE_B = Number(__ENV.PEAK || 84);
// → Tasa de pico: 84 órdenes/segundo (default)
// → Corresponde a 5000 órdenes/minuto (5× de baseline)
// → Parametrizable con -e PEAK=N para explorar puntos de quiebre

const PEAK_RATE = PHASE === 'f1' ? RATE_A : RATE_B;
// → Tasa máxima de la fase (usada para calcular jitter)
```

### Arribo Estocástico (Jitter)

Este es el corazón de la estrategia de validez. Sin jitter, el modelo abierto degenera en cerrado.

```javascript
// ═══════════════════════════════════════════════════════════════════
// JITTER: ARRIBO ESTOCÁSTICO BASADO EN DISTRIBUCIÓN EXPONENCIAL
// ═══════════════════════════════════════════════════════════════════

const JITTER_FACTOR = __ENV.JITTER_FACTOR === undefined ? 8 : Number(__ENV.JITTER_FACTOR);
// → Factor multiplicador respecto al espaciado nominal
// → 8 significa: media del jitter = 8 × espaciado
// → Con tasa=17/s, espaciado=58.8ms, media_jitter = 470ms
// → Esto requiere ~8 VUs en régimen (ley de Little: VUs = tasa × duración)

const JITTER_MEAN_SECONDS = JITTER_FACTOR / PEAK_RATE;
// → Media del desplazamiento en segundos
// → Ejemplo: RATE=17, JITTER_FACTOR=8 → 8/17 = 0.47 segundos

function exponentialSeconds(meanSeconds) {
  if (meanSeconds <= 0) {
    return 0;  // Jitter desactivado (JITTER_FACTOR=0)
  }
  // ═════════════════════════════════════════════════════════════
  // TRANSFORMADA INVERSA: Genera exponencial desde uniform [0,1)
  // ═════════════════════════════════════════════════════════════
  //
  // Si U ~ Uniform[0,1), entonces X = -ln(1-U) / λ ~ Exponential(λ)
  //
  // Aquí λ = 1/meanSeconds, así que X = -ln(1-U) × meanSeconds
  //
  // (1-U) ∈ (0,1] porque U ∈ [0,1)
  //   → ln(1-U) ∈ (-∞, 0]
  //   → -ln(1-U) ∈ [0, ∞)
  //   → Nunca evalúa log(0)
  
  return -Math.log(1 - Math.random()) * meanSeconds;
}

// ═════════════════════════════════════════════════════════════════════
// RESERVA DE VUS: PRE_VUS y MAX_VUS
// ═════════════════════════════════════════════════════════════════════

const PRE_VUS = Math.max(60, JITTER_FACTOR * 8);
// → VUs preasignados al startup (rápido)
// → Calculado como JITTER_FACTOR × 8 para garantizar capacidad

const MAX_VUS = Math.max(300, JITTER_FACTOR * 40);
// → Máximo de VUs que k6 puede escalar dinámicamente
// → Límite superior para evitar explosión de recursos

// Explicación:
// - Con arribo exponencial de media 470ms, una orden típica dura ~500ms
// - VUs necesarios = tasa × duración = 17/s × 0.5s = 8.5 VUs en baseline
// - f2 (pico): 84/s × 0.5s = 42 VUs
// - PRE_VUS=60 y MAX_VUS=300 aseguran capacidad con margen
```

### Configuración de Símbolos (Sharding)

```javascript
// ═══════════════════════════════════════════════════════════════════
// SÍMBOLOS: DETERMINAN EL REPARTO ENTRE SHARDS
// ═══════════════════════════════════════════════════════════════════

const SYMBOLS = PHASE === 'f4'
  ? ['HOT']  // F4: Partición caliente (100% del tráfico en un símbolo)
  : [
      // Conjunto de 36 nemotécnicos de la BVC (Bolsa de Valores de Colombia)
      // Cuidadosamente elegidos para repartir EXACTO:
      // - Con N=2: 18/18 (50% / 50%)
      // - Con N=4: 9/9/9/9 (25% / 25% / 25% / 25%)
      //
      // Cálculo: floorMod(String.hashCode(símbolo), N)
      //
      // Ejemplo verificación:
      // 'PROMIGAS'.hashCode() % 2 = 0, % 4 = 0 → va a shard 0
      // 'ECOPETROL'.hashCode() % 2 = 1, % 4 = 2 → va a shard 2
      
      'PROMIGAS', 'PFDAVVNDA', 'GEB', 'ELCONDOR', 'VALOREM',
      'OCCIDENTE', 'PEI', 'ODINSA', 'BIOMAX',
      'ECOPETROL', 'PFGRUPSURA', 'PFCEMARGOS', 'GRUPOARGOS', 'CELSIA',
      'PFCORFICOL', 'DAVIVIENDA', 'GRUPOAVAL', 'BBVACOL',
      'BCOLOMBIA', 'PFBCOLOM', 'GRUPOSURA', 'NUTRESA', 'TERPEL',
      'CORFICOLCF', 'BOGOTA', 'PFAVAL', 'CONCONCRET',
      'ISA', 'CEMARGOS', 'PFGRUPOARG', 'BVC', 'CANACOL',
      'MINEROS', 'ETB', 'FABRICATO', 'ENKA',
    ];

// IMPORTANTE: Cambiar esta lista requiere reverificar el reparto
// └─ El conjunto anterior (6 símbolos) repartía 67%/33% con N=2
//    y dejaba un shard ocioso con N=4
// └─ Eso medía desbalance del conjunto, no capacidad del motor
```

### Métricas Personalizadas

```javascript
// ═══════════════════════════════════════════════════════════════════
// CONTADORES PERSONALIZADOS
// ═══════════════════════════════════════════════════════════════════

const rejected = new Counter('orders_rejected_backpressure');
// → Incrementa cuando el motor responde Status.REJECTED
// → Validación: Si > 0, la corrida NO es válida
// → Causa: Ring buffer lleno (backpressure activada)
// → Interpretación: Sistema insuficiente, no aguanta la carga

const routingViolations = new Counter('shard_routing_violations');
// → Incrementa si un símbolo es procesado por shards distintos
// → Validación: Si > 0, hay BUG en el enrutamiento
// → Causa: Hash inconsistente o reparto incorrecto
// → Este contador por VU (k6 aísla estado de VUs)

const shardBySymbol = {};
// → Registro local (por VU) del shard que procesó cada símbolo
// → Verifica que hash(símbolo) % N siempre retorna el mismo shard
// → Si una orden de 'AAPL' va a shard 0 y otra a shard 1 → violation
```

### Escenarios y Ejecutores

```javascript
// ═══════════════════════════════════════════════════════════════════
// ESCENARIOS: FASES DEL EXPERIMENTO
// ═══════════════════════════════════════════════════════════════════

function escenariosDe(phase) {
  
  // PRECALENTAMIENTO (Común a todas las fases)
  const calentamiento = {
    executor: 'constant-arrival-rate',
    rate: RATE_A,           // 17 órdenes/segundo
    timeUnit: '1s',
    duration: SMOKE ? '30s' : '2m',  // Corto o 2 minutos
    preAllocatedVUs: PRE_VUS,
    maxVUs: MAX_VUS,
  };
  
  // Propósito del precalentamiento:
  // ├─ Calienta la JVM (compilación just-in-time)
  // ├─ Estabiliza métricas (evita outliers de GC inicial)
  // └─ NO se incluye en el veredicto (escenario separado)
  
  // ═════════════════════════════════════════════════════════════
  // FASE F1: LÍNEA DE BASE (Operación normal)
  // ═════════════════════════════════════════════════════════════
  
  if (phase === 'f1') {
    return {
      calentamiento,
      f1: {
        executor: 'constant-arrival-rate',
        rate: RATE_A,                  // 17 órdenes/s (fijo)
        timeUnit: '1s',
        duration: SMOKE ? '1m' : '12m', // 12 minutos en régimen
        startTime: CALENTAMIENTO,       // Inicia después del precalentamiento
        preAllocatedVUs: PRE_VUS,
        maxVUs: MAX_VUS,
      },
    };
  }
  
  // Criterio F1: p95 < 200 ms (sin rechazos ni descartes)
  
  // ═════════════════════════════════════════════════════════════
  // FASE F2 + F3: PICO Y RETORNO
  // ═════════════════════════════════════════════════════════════
  
  // Duraciones (ajustadas por SMOKE)
  const rampa = SMOKE ? '30s' : '2m';    // Ramp-up: 2 minutos
  const pico = SMOKE ? '2m' : '30m';     // Pico sostenido: 30 minutos
  const caida = SMOKE ? '30s' : '1m';    // Ramp-down: 1 minuto
  const drenaje = SMOKE ? '1m' : '5m';   // Drenaje: 5 minutos
  
  // F2: Ramp-up + Pico sostenido
  const f2 = {
    executor: 'ramping-arrival-rate',
    startRate: RATE_A,                  // Inicia en línea de base (17/s)
    timeUnit: '1s',
    startTime: CALENTAMIENTO,
    preAllocatedVUs: Math.max(120, PRE_VUS),
    maxVUs: Math.max(800, MAX_VUS),
    stages: [
      { target: RATE_B, duration: rampa },  // Sube a 84/s en 2 min
      { target: RATE_B, duration: pico },   // Sostiene 84/s por 30 min
      // Nota: ramping-arrival-rate permite múltiples stages
    ],
  };
  
  // F3: Ramp-down + Drenaje (solo si F2)
  // Se encadena después de F2 para responder: ¿Vuelve a régimen?
  const f3 = {
    executor: 'ramping-arrival-rate',
    startRate: RATE_B,                  // Comienza donde F2 terminó (84/s)
    timeUnit: '1s',
    startTime: seg(segundos(CALENTAMIENTO, rampa, pico)),  // Cálculo de tiempo
    preAllocatedVUs: Math.max(120, PRE_VUS),
    maxVUs: Math.max(800, MAX_VUS),
    stages: [
      { target: RATE_A, duration: caida },   // Baja a 17/s en 1 min
      { target: RATE_A, duration: drenaje }, // Sostiene 17/s por 5 min
    ],
  };
  
  // F4: Partición caliente (solo un símbolo, 100% del tráfico)
  if (phase === 'f4') {
    return { calentamiento, f4: f2 };  // F4 usa la misma topología que F2
  }
  
  // Retorna F1+F2+F3
  return {
    calentamiento,
    f2,
    f3,  // Solo para F2, ausente en F1 y F4
  };
}
```

### Umbrales de Validación

```javascript
export const options = {
  scenarios: escenariosDe(PHASE),
  
  thresholds: {
    // ═════════════════════════════════════════════════════════════
    // CRITERIO PRINCIPAL: Latencia por fase
    // ═════════════════════════════════════════════════════════════
    
    [`grpc_req_duration{scenario:${PHASE}}`]: ['p(95)<200'],
    // Métrica: grpc_req_duration = latencia de la llamada gRPC
    // Filtro: por escenario (f1, f2, f3, f4)
    // Criterio: percentil 95 < 200 milisegundos
    // Razón: ASR-02 y ASR-03 exigen p95 < 200ms
    
    // ═════════════════════════════════════════════════════════════
    // CRITERIO SECUNDARIO: Recuperación (F3)
    // ═════════════════════════════════════════════════════════════
    
    ...(PHASE === 'f2' ? { 'grpc_req_duration{scenario:f3}': ['p(95)<200'] } : {}),
    // Solo se aplica si la fase es F2 (que encadena F3)
    // Pregunta: Después del pico, ¿la latencia vuelve al régimen?
    // Respuesta: Sí, si p95_f3 < 200ms (igual al de F1)
    
    // ═════════════════════════════════════════════════════════════
    // CRITERIOS DE VALIDEZ: Toda la corrida
    // ═════════════════════════════════════════════════════════════
    
    orders_rejected_backpressure: ['count==0'],
    // Si hay rechazos por ring_full → backpressure activada
    // Interpretación: Sistema sobrecargado, orden no se procesó
    // Validez: Si count > 0, la corrida es NO_MEDIBLE
    
    shard_routing_violations: ['count==0'],
    // Si un símbolo es procesado por shards distintos
    // Interpretación: Bug en hash o sharding
    // Validez: Si count > 0, la corrida invalida la hipótesis
    
    dropped_iterations: ['count==0'],
    // Si k6 descarta iteraciones (sin VU disponible)
    // Interpretación: El generador no logró emitir todas las órdenes
    // Modelo abierto degenera en cerrado
    // Validez: Si count > 0, p95 reportado es optimista (NO MEDIBLE)
    
    // ═════════════════════════════════════════════════════════════
    // RESUMEN DE PERCENTILES: Qué se imprime
    // ═════════════════════════════════════════════════════════════
  },
  
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'p(99.9)', 'max'],
  // Estos estadísticos se publican en el resumen de k6
  // Usados por experimento.sh para extraer p95, p99, etc.
};
```

### Iteración de Trabajo

```javascript
// ═══════════════════════════════════════════════════════════════════
// FUNCIÓN PRINCIPAL: Ejecutada por cada VU, cada iteración
// ═══════════════════════════════════════════════════════════════════

export default function () {
  // ─────────────────────────────────────────────────────────────
  // FASE 1: CONEXIÓN ÚNICA
  // ─────────────────────────────────────────────────────────────
  
  if (!connected) {
    client.connect(TARGET, { plaintext: true });
    // Conecta una sola vez (por VU) al servidor gRPC
    // plaintext: sin TLS (más rápido para pruebas locales)
    
    connected = true;
  }
  
  // ─────────────────────────────────────────────────────────────
  // FASE 2: ARRIBO ESTOCÁSTICO (Jitter)
  // ─────────────────────────────────────────────────────────────
  
  sleep(exponentialSeconds(JITTER_MEAN_SECONDS));
  // Espera un tiempo exponencial ANTES de emitir
  // Esto genera "llegadas estocásticas" al motor
  //
  // Timing:
  // k6 emite la iteración (metrónomo)
  //   ↓
  // default() inicia
  //   ↓
  // sleep(jitter) espera un tiempo exponencial
  //   ↓
  // invoke() emite el RPC
  //   ↓
  // grpc_req_duration cronometra desde aquí
  //
  // IMPORTANTE: El sleep() NO se mide (está antes del invoke)
  
  // ─────────────────────────────────────────────────────────────
  // FASE 3: GENERACIÓN DE ORDEN
  // ─────────────────────────────────────────────────────────────
  
  const symbol = SYMBOLS[Math.floor(Math.random() * SYMBOLS.length)];
  // Elige símbolo aleatorio del conjunto
  // Distribución: uniforme (cada símbolo igual probabilidad)
  // Repartición: floorMod(hashCode, N) → determinístico
  
  const side = Math.random() < 0.5 ? 'BUY' : 'SELL';
  // Compra o venta: 50% / 50%
  
  const priceCents = 10000 + Math.floor(Math.random() * 21) - 10;
  // Precio en centavos: $99.90 a $100.10 (rango estrecho)
  // Rango = [-10, +10] centavos alrededor de $100.00
  // Razón: Garantiza cruces frecuentes (muchas órdenes se ejecutan)
  // Sin esto, todas las órdenes quedarían RESTING
  
  // ─────────────────────────────────────────────────────────────
  // FASE 4: INVOCACIÓN gRPC
  // ─────────────────────────────────────────────────────────────
  
  const response = client.invoke('matching.v1.MatchingIngest/SubmitOrder', {
    order_id: `${__VU}-${__ITER}`,  // ID único: VU#-iteración#
    symbol: symbol,
    side: side,
    price_cents: priceCents,
    quantity: 1 + Math.floor(Math.random() * 100),  // [1, 100]
    client_ts_nanos: 0,  // No usado (timestamp se toma en el motor)
  });
  
  // k6 AQUÍ cronometra grpc_req_duration (desde invoke hasta respuesta)
  
  // ─────────────────────────────────────────────────────────────
  // FASE 5: VALIDACIÓN Y REGISTRO DE MÉTRICAS
  // ─────────────────────────────────────────────────────────────
  
  const ok = check(response, {
    'status gRPC OK': (r) => r && r.status === grpc.StatusOK,
  });
  // Verifica que la llamada gRPC fue exitosa (no error de transporte)
  // Nota: StatusOK ≠ matching exitoso (puede ser REJECTED o RESTING)
  
  if (ok) {
    // Válida: procesamos la respuesta
    
    if (response.message.status === 'REJECTED') {
      rejected.add(1);
      // Registra rechazo por backpressure
      // Causa: Ring buffer lleno en el motor
    }
    
    const sid = response.message.shardId;
    // ID del shard que procesó la orden
    
    if (sid !== undefined && sid !== null) {
      // Verifica enrutamiento consistente
      
      if (shardBySymbol[symbol] === undefined) {
        shardBySymbol[symbol] = sid;
        // Primera vez que vemos este símbolo → registra el shard
      } else if (shardBySymbol[symbol] !== sid) {
        routingViolations.add(1);
        // Símbolo ya visto pero en un shard distinto → BUG
      }
    }
  }
  
  // k6 AQUÍ termina la iteración
  // Proxima iteración empieza cuando se emite la siguiente (tasa de llegada)
}
```

---

## Análisis Detallado: experimento.sh

### Estructura Global

```bash
#!/usr/bin/env bash
# ==============================================================================
# EL ÚNICO ORQUESTADOR DEL EXPERIMENTO E01
# ==============================================================================
# Antes: 6 scripts separados (uno por pregunta)
# Problema: Lógica duplicada en 6 sitios
#
# Ahora: 1 script + plan.tsv (datos)
# Solución: QUÉ se corre es plan.tsv, CÓMO se corre es este script
# ==============================================================================

# Configuración de rutas y variables globales
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# → Directorio raíz del proyecto

declare -a COMPOSE=(docker compose -f "$ROOT/deploy/docker-compose.yml")
# → Array bash para docker compose
# → Permite manejar espacios en rutas (ver quoting fix anterior)

PLAN="$ROOT/load/plan.tsv"
# → Plan: tabla de qué correr

OUT="${RESULTS_DIR:-$ROOT/load/k6/results/e01-$STAMP}"
# → Directorio de salida: puede reanudarse con RESULTS_DIR

RESULTADOS="$OUT/resultados.tsv"
# → Tabla final con resultados de todas las corridas
```

### Función: levantar()

```bash
# ═══════════════════════════════════════════════════════════════════
# LEVANTA LA TOPOLOGÍA (DOCKER COMPOSE)
# ═══════════════════════════════════════════════════════════════════

levantar() {
  local n="$1"; shift  # Número de shards: 1, 2 o 4
  
  # ─────────────────────────────────────────────────────────────
  # LIMPIEZA: Borra contenedores y volúmenes ANTERIORES
  # ─────────────────────────────────────────────────────────────
  
  "${COMPOSE[@]}" --profile n4 rm -sf $APP >/dev/null 2>&1 || true
  # Borra todos los contenedores (app services)
  # --profile n4: afecta solo el perfil "n4" (para N=4)
  # -sf: sin confirmación, force
  
  for v in journal-0 journal-1 journal-2 journal-3 jfr-0 jfr-1 jfr-2 jfr-3; do
    docker volume rm -f "arqsoft-reto-1_$v" >/dev/null 2>&1 || true
  done
  # Borra volúmenes (bitácoras, JFR recordings)
  # Razón: Una corrida anterior que dejó archivos falsearía esta
  
  # ─────────────────────────────────────────────────────────────
  # LEVANTAMIENTO SEGÚN TOPOLOGÍA
  # ─────────────────────────────────────────────────────────────
  
  case "$n" in
    1) 
      # N=1: Un shard, router, infra
      SHARDS="matching-shard-0:9090" "${COMPOSE[@]}" up -d \
        ingest-router matching-shard-0 prometheus grafana >/dev/null
      ;;
    4)
      # N=4: Cuatro shards completos, router, infra
      SHARDS="$SHARDS_N4" "${COMPOSE[@]}" --profile n4 up -d >/dev/null
      ;;
    *)
      # Default (N=2): Router, 2 shards, infra
      "${COMPOSE[@]}" up -d >/dev/null
      ;;
  esac
  
  sleep 20
  # Espera a que todos los contenedores estén healthy
  # (típicamente basta menos, pero margen de seguridad)
}
```

### Función: metrica()

```bash
# ═══════════════════════════════════════════════════════════════════
# EXTRAE MÉTRICA DEL RESUMEN DE k6
# ═══════════════════════════════════════════════════════════════════

metrica() {
  local archivo="$1"  # k6.txt (resumen de k6)
  local nombre="$2"   # Nombre de la métrica (ej: "grpc_req_duration")
  
  grep -E "^[[:space:]]+$nombre\.+:" "$archivo" \
    | head -1 \
    | grep -oE '[0-9]+' \
    | head -1
  
  # Busca línea con formato: "  grpc_req_duration.:.... 123.45ms"
  # Ancla al inicio (^) para no enganchar valores en la lista de métricas
  # Extrae solo el primer número
}

# Ejemplo de resumen de k6:
# ┌─────────────────────────┐
# │   http.req.duration     │
# │   p50........ 50ms      │
# │   p95........ 150ms     ← busca aquí
# │   p99........ 200ms     │
# └─────────────────────────┘
```

### Función: stat_escenario()

```bash
# ═══════════════════════════════════════════════════════════════════
# EXTRAE ESTADÍSTICO DE UN ESCENARIO ESPECÍFICO
# ═══════════════════════════════════════════════════════════════════

stat_escenario() {
  local f="$1"      # k6.txt
  local fase="$2"   # Escenario: f1, f2, f3, f4
  local cual="$3"   # Estadístico: p(95), p(99), p(99.9)
  
  awk -v fase="$fase" -v cual="$cual" '
    $0 ~ "\\{ scenario:" fase " \\}" {
      # Busca línea con { scenario:f1 } o similar
      
      for (i = 1; i <= NF; i++) {
        if (index($i, cual "=") == 1) {
          # Encuentra el campo cual=VALOR
          
          v = substr($i, length(cual) + 2)
          # Extrae la parte numérica + unidades
          # Ej: "p(95)=150ms" → "150ms"
          
          u = v; gsub(/[0-9.]/, "", u)
          # Extrae unidades: "ms", "us", "s"
          
          gsub(/[^0-9.]/, "", v)
          # Extrae solo la cifra: "150"
          
          # Convierte a milisegundos
          k = (u == "s") ? 1000 : (u == "ms") ? 1 : (u == "us" || u == "\302\265s") ? 0.001 : 0.000001
          
          printf "%.2f", v * k; exit
        }
      }
    }' "$f"
}

# Ejemplo:
# k6 output: "grpc_req_duration{scenario:f1}... p(95)=32.70ms..."
# stat_escenario k6.txt f1 "p(95)" → "32.70"
```

### Función: corrida_valida()

```bash
# ═══════════════════════════════════════════════════════════════════
# VERIFICA SI UNA CORRIDA ES VÁLIDA
# ═══════════════════════════════════════════════════════════════════

corrida_valida() {
  local k6out="$1"      # k6.txt (salida de k6)
  local shardlog="$2"   # shard.log (logs del motor)
  
  # ─────────────────────────────────────────────────────────────
  # CRITERIO 1: Todas las verificaciones exitosas
  # ─────────────────────────────────────────────────────────────
  
  local ok; ok="$(grep -E "^[[:space:]]+checks_succeeded" "$k6out" \
    | grep -oE '[0-9]+\.[0-9]+%' | head -1)"
  
  # checks_succeeded es el contador de validaciones exitosas
  # Si no es 100%, hubo errores gRPC (transporte, etc)
  
  [ "${ok%%.*}" = "100" ] || return 1
  # ${ok%%.*} extrae la parte entera (ej: "100" de "100.00%")
  
  # ─────────────────────────────────────────────────────────────
  # CRITERIO 2: El motor publicó su resumen ACUMULADO
  # ─────────────────────────────────────────────────────────────
  
  grep -q ACUMULADO "$shardlog" 2>/dev/null || return 1
  # Si el motor no llegó a imprimir "ACUMULADO", está muerto
  # Esto detecta crashes silenciosos
  
  return 0  # Corrida válida
}
```

### Función: ejecutar()

```bash
# ═══════════════════════════════════════════════════════════════════
# EJECUTA UNA CORRIDA DEL PLAN
# ═══════════════════════════════════════════════════════════════════

ejecutar() {
  local grupo="$1" id="$2" hip="$3" fase="$4" perfil="$5" n="$6" vars="$7" criterio="$8" pregunta="$9"
  # Variables del plan.tsv
  
  local dir="$OUT/$id"
  
  # ─────────────────────────────────────────────────────────────
  # SALTEA SI YA ESTÁ COMPLETA (reanudación)
  # ─────────────────────────────────────────────────────────────
  
  if [ -f "$dir/k6.txt" ] && grep -q ACUMULADO "$dir/shard.log" 2>/dev/null; then
    echo "  · $id — ya completa, se omite"; return 0
  fi
  mkdir -p "$dir"
  
  # ─────────────────────────────────────────────────────────────
  # LIMPIA Y SETEA VARIABLES DE ENTORNO
  # ─────────────────────────────────────────────────────────────
  
  unset BIZ_MICROS BIZ_DIST JOURNAL SHARD_CPUS SHARD_CPUSET SHARD_MEM JFR_OPTS PEAK JFR
  # Limpia SIEMPRE: un valor heredado de corrida anterior falsearía esta
  
  export RUN_ID="$id"
  # Para que el motor se identifique en logs
  
  export SHARD_CPUS=0 SHARD_CPUSET="" SHARD_MEM=0 JOURNAL=off BIZ_DIST=mezcla JFR_OPTS=""
  # Valores por defecto
  
  local IFS_ANT="$IFS"; IFS=';'
  for kv in $vars; do export "${kv?}"; done
  IFS="$IFS_ANT"
  # Parsea $vars (ej: "BIZ_MICROS=8000;JOURNAL=paralelo")
  # y exporta cada una
  
  # ─────────────────────────────────────────────────────────────
  # LEVANTA TOPOLOGÍA
  # ─────────────────────────────────────────────────────────────
  
  levantar "$n"
  # Levanta N shards
  
  # ─────────────────────────────────────────────────────────────
  # VERIFICA CONFIGURACIÓN DEL MOTOR
  # ─────────────────────────────────────────────────────────────
  
  local real; real="$("${COMPOSE[@]}" logs matching-shard-0 2>/dev/null \
    | grep -m1 'modelo de logica' | sed 's/.*negocio: //')"
  
  echo "  motor: $real"
  
  if [ "${BIZ_MICROS:-0}" != "0" ] && ! grep -q "media=${BIZ_MICROS}us" <<<"$real"; then
    echo "  ✗ ABORTA: se pidió S=${BIZ_MICROS}us y el motor arrancó con: $real"
    echo -e "$id\t$hip\t$grupo\t$fase\t$n\t$vars\t$criterio\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tABORTADA\tno" >> "$RESULTADOS"
    return 1
  fi
  # Verifica que el motor arrancó con los parámetros esperados
  # Si no: ABORTA (la corrida no es válida)
  
  # ─────────────────────────────────────────────────────────────
  # EJECUTA k6
  # ─────────────────────────────────────────────────────────────
  
  ( cd "$ROOT/load/k6" && k6 run $K6_OUT \
      --tag corrida="$id" --tag hipotesis="$hip" \
      $smoke -e PHASE="$fase" -e PEAK="${PEAK:-84}" \
      --summary-export="$dir/k6.json" poc.js ) > "$dir/k6.txt" 2>&1
  
  # Ejecuta k6 en el directorio correcto (con matching.proto)
  # $K6_OUT: salida a Prometheus (K6_PROMETHEUS_RW_SERVER_URL)
  # --tag: agrupa métricas por corrida e hipótesis
  # --summary-export: JSON con resumen (para análisis posterior)
  
  # ─────────────────────────────────────────────────────────────
  # CAPTURA LOGS DEL MOTOR
  # ─────────────────────────────────────────────────────────────
  
  "${COMPOSE[@]}" stop $APP >/dev/null 2>&1 || true
  # Detiene contenedores (permite que terminen limpiamente)
  
  "${COMPOSE[@]}" logs --no-color 2>/dev/null \
    | grep -E "modelo de logica|runtime:|journal:|ACUMULADO|JOURNAL shard" \
    > "$dir/shard.log" || true
  
  # Extrae líneas relevantes de los logs
  # Incluye: configuración inicial, ACUMULADO, JOURNAL (si aplica)
}
```

### Función: registrar()

```bash
# ═══════════════════════════════════════════════════════════════════
# REGISTRA RESULTADOS EN LA TABLA
# ═══════════════════════════════════════════════════════════════════

registrar() {
  local grupo="$1" id="$2" hip="$3" fase="$4" n="$5" vars="$6" criterio="$7" dir="$8"
  local k6="$dir/k6.txt" log="$dir/shard.log"
  
  # ─────────────────────────────────────────────────────────────
  # EXTRAE PERCENTILES DE k6
  # ─────────────────────────────────────────────────────────────
  
  local p95 p99 p999
  p95="$(stat_escenario "$k6" "$fase" 'p(95)')"
  p99="$(stat_escenario "$k6" "$fase" 'p(99)')"
  p999="$(stat_escenario "$k6" "$fase" 'p(99.9)')"
  
  # ─────────────────────────────────────────────────────────────
  # EXTRAE ESTADÍSTICAS GENERALES
  # ─────────────────────────────────────────────────────────────
  
  local ordenes rechazos descartes tasa
  ordenes="$(metrica "$k6" iterations)"
  # Órdenes emitidas y completadas
  
  rechazos="$(metrica "$k6" orders_rejected_backpressure)"
  # Órdenes rechazadas por ring_full
  
  descartes="$(metrica "$k6" dropped_iterations)"
  # Iteraciones que k6 no emitió (sin VU disponible)
  
  tasa="$(grep -E "^[[:space:]]+iterations\.+:" "$k6" \
    | grep -oE '[0-9.]+/s' | head -1)"
  # Tasa lograda (órdenes/segundo)
  
  # ─────────────────────────────────────────────────────────────
  # EXTRAE PERCENTILES DEL MOTOR (máx entre shards)
  # ─────────────────────────────────────────────────────────────
  
  local mp95 ep95 sp50
  read -r mp95 ep95 sp50 <<<"$(awk '
    /ACUMULADO/ {
      # Busca líneas ACUMULADO en los logs
      
      if (match($0, /total p50=[0-9]+us p95=[0-9]+us/)) {
        # Extrae total: p50=... p95=...
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p95=[0-9]+/)) {
          v = substr(t, RSTART + 4, RLENGTH - 4) + 0
          if (v > m) m = v  # Máximo entre shards
        }
      }
      
      if (match($0, /espera p50=[0-9]+us p95=[0-9]+us/)) {
        # Extrae espera: p50=... p95=...
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p95=[0-9]+/)) {
          v = substr(t, RSTART + 4, RLENGTH - 4) + 0
          if (v > e) e = v  # Máximo entre shards
        }
      }
      
      if (match($0, /servicio p50=[0-9]+us/)) {
        # Extrae servicio: p50=...
        t = substr($0, RSTART, RLENGTH)
        if (match(t, /p50=[0-9]+/)) {
          s = substr(t, RSTART + 4, RLENGTH - 4) + 0
        }
      }
    } END { printf "%d %d %d", m, e, s }' "$log")"
  
  # ─────────────────────────────────────────────────────────────
  # JUICIO 1: ¿LATENCIA VÁLIDA?
  # ─────────────────────────────────────────────────────────────
  
  local valida="si" pef="95.0"
  local intentadas=$(( ${ordenes:-0} + ${descartes:-0} ))
  
  if [ "$intentadas" -gt 0 ]; then
    pef="$(echo "scale=2; 95 * ${ordenes:-0} / $intentadas" | bc -l)"
    # Calcula percentil efectivo: p_eff = 95 × (observadas / intentadas)
    
    [ "$(echo "$pef < $PISO_PERCENTIL" | bc -l)" = "1" ] && valida="no"
    # Si p_eff < 94% (default PISO_PERCENTIL), latencia no publicable
  fi
  
  corrida_valida "$k6" "$log" || valida="no"
  # Si hay errores gRPC o el motor no terminó: no válida
  
  # ─────────────────────────────────────────────────────────────
  # JUICIO 2: ¿CUMPLE EL CRITERIO?
  # ─────────────────────────────────────────────────────────────
  
  local veredicto="observa"
  
  if [ "$criterio" = "p95<200" ]; then
    if [ "$valida" = "no" ]; then
      veredicto="NO MEDIBLE"  # Latencia inválida
    elif [ -n "$p95" ] && [ "$(echo "$p95 < 200" | bc -l)" = "1" ]; then
      veredicto="CUMPLE"      # p95 < 200ms
    else
      veredicto="NO CUMPLE"   # p95 >= 200ms
    fi
  fi
  
  # ─────────────────────────────────────────────────────────────
  # REGISTRA EN TABLA
  # ─────────────────────────────────────────────────────────────
  
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$id" "$hip" "$grupo" "$fase" "$n" "$vars" "$criterio" \
    "${p95:--}" "${p99:--}" "${p999:--}" "$mp95" "$ep95" "$sp50" \
    "${tasa:--}" "${ordenes:-0}" "${rechazos:-0}" "${descartes:-0}" "$veredicto" "$valida" \
    >> "$RESULTADOS"
  
  # Columnas:
  # id, hipótesis, grupo, fase, N, vars, criterio,
  # p95_k6(ms), p99_k6(ms), p99.9_k6(ms),
  # p95_motor(us), p95_espera(us), p50_servicio(us),
  # tasa(req/s), órdenes, rechazos, descartes,
  # veredicto, latencia_válida
}
```

---

## Flujo de Operaciones

### Viaje de una Orden (End-to-End)

```
┌──────────────────────────────────────────────────────────────────┐
│ FASE 1: GENERACIÓN EN k6                                         │
└──────────────────────────────────────────────────────────────────┘

t=0ms ├─ VU inicia iteración (k6 metrónomo: 17/s en F1)
      ├─ sleep(exponentialSeconds(0.47)) → jitter
      │  └─ 470ms promedio (colas exponencial)
      │     (pero algunas veces < 1ms, otras > 1s)
      
t=470ms (aprox) ├─ Genera orden:
                │  symbol: "ECOPETROL"
                │  side: "BUY"
                │  price_cents: 10000 (exacto)
                │  quantity: 45
                
                ├─ client.invoke('MatchingIngest/SubmitOrder')
                │  [gRPC conecta al router puerto 8080]
                │  [k6 COMIENZA a contar latencia]
                │  t_k6_start = ahora

┌──────────────────────────────────────────────────────────────────┐
│ FASE 2: TRÁNSITO POR ROUTER                                      │
└──────────────────────────────────────────────────────────────────┘

t_k6_start + Δ ├─ RouterService.submitOrder()
               │  ├─ Semaphore.tryAcquire() [QUEUE_CAPACITY=10000]
               │  │  → OK: hay permiso
               │  ├─ shard = floorMod(ECOPETROL.hashCode(), 2) = 1
               │  │  → Va al shard 1
               │  └─ gRPC call asincrónico a shard-1:9090

┌──────────────────────────────────────────────────────────────────┐
│ FASE 3: PROCESAMIENTO EN EL MOTOR                                │
└──────────────────────────────────────────────────────────────────┘

Shard-1 └─ IngestGrpcService.submitOrder()
           ├─ t0 = System.nanoTime() [MARCA: arribo al motor]
           ├─ sequence = ringBuffer.tryNext()
           │  → OK, secuencia 12345
           ├─ event = ringBuffer.get(12345)
           │  ├─ event.symbol = "ECOPETROL"
           │  ├─ event.priceCents = 10000
           │  ├─ event.quantity = 45
           │  ├─ event.arrivalNanos = t0
           │  └─ event.responseObserver = <callback>
           ├─ ringBuffer.publish(12345) [MEMORY BARRIER]
           │  └─ Evento visible a MatchingHandler

           ├─ [Espera en anillo ~ 1-5ms típico]

           ├─ MatchingHandler.onEvent()
           │  ├─ t_start = System.nanoTime()
           │  ├─ espera = t_start - t0
           │  ├─ OrderBook["ECOPETROL"].match(BUY, 10000, 45)
           │  │  ├─ Busca ASKs ≤ 10000
           │  │  ├─ Encuentra 3 vendedores: 30+10+5 acciones
           │  │  └─ status=MATCHED, qty=45 ejecutadas
           │  ├─ BusinessLogicModel.costForOrder(45)
           │  │  ├─ Ejemplo: mezcla 90% → 8000µs
           │  │  └─ cpuBurn(8000) [consume CPU]
           │  ├─ t_end = System.nanoTime()
           │  ├─ Registra en histogramas
           │  └─ responseObserver.onNext(MatchingResponse)
           │     ├─ status=MATCHED
           │     ├─ materializedQty=45
           │     ├─ engineLatencyMicros=8001
           │     └─ shard=1

           ├─ [Si JOURNAL=paralelo: JournalHandler escribe en background]

           └─ CleanupHandler.onEvent()
              └─ event.reset() [basura del GC]

┌──────────────────────────────────────────────────────────────────┐
│ FASE 4: RESPUESTA A k6                                           │
└──────────────────────────────────────────────────────────────────┘

t_k6_end ├─ Cliente (k6) recibe respuesta gRPC
         │  [k6 AQUÍ termina de contar grpc_req_duration]
         │
         ├─ latencia_total = t_k6_end - t_k6_start
         │  Típico: ~8-10ms
         │  [includes: router + ringbuffer wait + matching + jfr]
         │
         └─ k6 registra:
            ├─ grpc_req_duration: ~9000 µs
            ├─ scenario: f1
            ├─ order_status: MATCHED
            └─ Suma a histograma (ventana + acumulado)

┌──────────────────────────────────────────────────────────────────┐
│ FASE 5: OBSERVABILIDAD                                           │
└──────────────────────────────────────────────────────────────────┘

Cada 10 segundos (MatricsReporter) ├─ Shard log:
                                    │  "VENTANA: p50=1234µs p95=8500µs..."
                                    │  Reseteándose...

Cada 5 segundos (k6) ├─ Prometheus push:
                     │  grpc_req_duration{scenario:f1} p(95)=8.5ms
                     │  ...

Fin de fase ├─ Shard log:
            │  "ACUMULADO: p50=1200µs p95=8600µs..."
            │  [AQUÍ se valida si la corrida es correcta]
```

### Ciclo Completo de Experimento

```
1. plan.tsv (datos: qué correr)
   └─ Filas: [id, hipótesis, grupo, fase, perfil, N, vars, criterio, pregunta]

2. experimento.sh (orquestador)
   └─ Lee plan.tsv línea por línea

3. Para cada línea:

   a) ejecutar()
      ├─ levantar(N)          → docker compose up con N shards
      ├─ Exporta variables    → BIZ_MICROS, JOURNAL, etc.
      ├─ Verifica montaje     → grep logs
      └─ k6 run poc.js        → genera carga por 15-45 min

   b) Captura artefactos
      ├─ k6.txt              → resumen de k6
      ├─ k6.json             → JSON detallado
      ├─ shard.log           → logs del motor
      └─ pausas.txt (opt)     → JFR analysis

   c) registrar()
      ├─ Extrae p95, p99, p99.9 de k6
      ├─ Extrae p95 del motor (espera + servicio)
      ├─ Calcula validez      → descartes, rechazos, ACUMULADO
      ├─ Compara criterio     → p95 < 200ms?
      └─ Registra en resultados.tsv

4. Resultado: tabla con 40+ corridas

5. Grafana dashboard mostrando evolución en tiempo real
```

---

## Patrones de Diseño

### 1. Modelo Abierto (Open Model)

```
CERRADO (típico):                ABIERTO (correcto):
┌─────────────────────────┐      ┌──────────────────────────┐
│  Clientes = 100         │      │  Tasa = 17 órdenes/seg   │
│                         │      │                          │
│  ├─ Emite orden         │      │  k6 emite cada 58.8ms    │
│  ├─ Espera respuesta    │      │  (+ jitter exponencial)  │
│  ├─ Emite siguiente     │      │                          │
│  └─ Latencia percibida: │      │  Si la respuesta tarda   │
│     L = (100 × T) / X   │      │  mucho, el generador     │
│                         │      │  sigue emitiendo igual   │
│     donde X = throughput│      │                          │
│                         │      │  → Acumulo en el ring    │
│     PROBLEMA:           │      │  → Latencia real medida  │
│     Si X baja, L sube   │      │                          │
│     pero no por el      │      │  Validación correcta:    │
│     sistema, sino por   │      │  - p95 mide en congestión│
│     el generador        │      │  - Rechazos registrados  │
│                         │      │  - Backpressure activa   │
└─────────────────────────┘      └──────────────────────────┘
```

### 2. Jitter Estocástico (Arrival Randomness)

```
SIN JITTER (Periódico):          CON JITTER (Poisson):
─────────────────────────────    ──────────────────────────
t=0ms     ├─ orden 1             t=0ms     ├─ orden 1
t=58.8ms  ├─ orden 2             t=3.2ms   ├─ orden 2
t=117.6ms ├─ orden 3             t=61.5ms  ├─ orden 3
t=176.4ms ├─ orden 4             t=110.2ms ├─ orden 4
          │                                  │
          Varianza = 0            Ca² ≈ 0.89 (Poisson=1)
          Ring nunca acumula      Ring acumula realísticamente
          p95 = ~2ms (fake!)      p95 = ~8ms (real)
```

### 3. Separación de Escenarios

```
INCORRECTO (todo en uno):        CORRECTO (escenarios separados):
┌─────────────────────────────┐  ┌──────────────────────────────┐
│ Escenario único:            │  │ Escenario 1: calentamiento   │
│ ├─ 2m calentamiento (JIT)   │  │ └─ 2m @ 17/s (no medido)    │
│ ├─ 12m regimen (medido)     │  │                              │
│ └─ p95 = 5.5ms (JIT en mix) │  │ Escenario 2: f1             │
│                             │  │ └─ 12m @ 17/s (medido)      │
│ PROBLEMA:                   │  │    p95 = 8.1ms (puro)       │
│ El calentamiento (JIT       │  │                              │
│ spikes) contamina el p95    │  │ BENEFICIO:                  │
│ → mide JVM, no sistema      │  │ Percentiles por escenario   │
│                             │  │ k6 solo suma el medido      │
└─────────────────────────────┘  │ (calentamiento excluido)    │
                                 └──────────────────────────────┘
```

### 4. Validación Multinivel

```
Nivel 1: Transporte (gRPC)
├─ checks_succeeded = 100%
└─ Si < 100% → corrida inválida

Nivel 2: Generador
├─ dropped_iterations = 0
└─ Si > 0 → p95 es en realidad p<95 (percentil efectivo)

Nivel 3: Sistema
├─ orders_rejected_backpressure = 0
└─ Si > 0 → backpressure activada, sistema saturado

Nivel 4: Sharding
├─ shard_routing_violations = 0
└─ Si > 0 → hash inconsistente, bug en reparto

Nivel 5: Motor
├─ ACUMULADO en logs
└─ Si ausente → motor crasheó o no terminó

Resultado: VÁLIDA = todos los niveles OK
           NO_MEDIBLE = algún nivel falló
```

---

## Validación y Criterios

### Cálculo del Percentil Efectivo

```
Problema: k6 pierde iteraciones (dropped_iterations > 0)
          → El p95 reportado es optimista

Solución: Calcular percentil efectivo

Formula:
  p_eff = 95 × (órdenes_emitidas / órdenes_intentadas)
        = 95 × (órdenes / (órdenes + descartes))

Ejemplo:
  Intentadas:  100.000 órdenes
  Emitidas:     99.950 órdenes
  Descartes:         50 órdenes
  
  p_eff = 95 × (99.950 / 100.000)
        = 95 × 0.9995
        = 94.95%  ← El p95 reportado es en realidad un p94.95
  
  Es indistinguible de p95 (diferencia < 0.05%)
  
Otro ejemplo:
  Intentadas:  100.000 órdenes
  Emitidas:     74.000 órdenes
  Descartes:    26.000 órdenes
  
  p_eff = 95 × (74.000 / 100.000)
        = 95 × 0.74
        = 70.3%  ← El p95 reportado es en realidad un p70
  
  Completamente distinto: NO PUBLICABLE (validez=no)
  └─ La corrida medía el generador agotado, no el sistema
```

### Matriz de Validez

```
                    errors_gRPC  dropped_ites  ACUMULADO  latencia_válida
╔═══════════════════════════════════════════════════════════════════════════╗
║ Corrida 1       100%            0              SÍ         SÍ             ║
║ Veredicto: CUMPLE (p95=31ms < 200ms)                                    ║
╠═══════════════════════════════════════════════════════════════════════════╣
║ Corrida 2       100%           50 (> piso)    SÍ         NO             ║
║ Veredicto: NO MEDIBLE (p95=32ms es realidad p94.7%)                     ║
╠═══════════════════════════════════════════════════════════════════════════╣
║ Corrida 3        95%            0              SÍ         NO             ║
║ Veredicto: NO MEDIBLE (errores gRPC)                                     ║
╠═══════════════════════════════════════════════════════════════════════════╣
║ Corrida 4       100%            0              NO         NO             ║
║ Veredicto: ABORTADA (motor crasheó)                                      ║
╠═══════════════════════════════════════════════════════════════════════════╣
║ Corrida 5       100%            0              SÍ         SÍ             ║
║ Veredicto: NO CUMPLE (p95=205ms > 200ms)                                ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

---

## Resumen Ejecutivo

### Tabla Comparativa: k6 vs Motor

| Métrica | k6 (Generador) | Motor (Sistema) |
|---------|---|---|
| **Punto de medición** | Antes de router | Dentro del motor |
| **Qué incluye** | Red + router + anillo + matching | Anillo + matching + negocio |
| **Latencia típica** | 8-10ms (p95 en f1) | 27-30ms (p95 en f1) |
| **Percentiles** | p50, p95, p99, p99.9 | p50, p95 (por ventana + acumulado) |
| **Validación** | grpc_req_duration, checks_succeeded | ACUMULADO log, espera/servicio |
| **Uso** | Validar criterio (p95<200ms) | Diagnosticar cuello de botella |

### Variables de Control en plan.tsv

| Variable | Rango | Efecto |
|----------|-------|--------|
| **N** | 1, 2, 4 | Número de shards (paralelismo) |
| **BIZ_MICROS** | 0, 2000, 8000 | Costo de negocio simulado (µs) |
| **BIZ_DIST** | mezcla, lognormal | Forma de distribución del costo |
| **JOURNAL** | off, paralelo, serie | Durabilidad (latencia tradeoff) |
| **PEAK** | 84, 200, 500 | Tasa de pico en F2/F4 (órdenes/s) |

### Tabla de Resultados (resultados.tsv)

```
id          hipótesis  fase  k6_p95  motor_p95  espera_p95  veredicto
of-f1-n2    H1        f1    32.70   27743      1837        CUMPLE
of-f2-n2    H1        f2    42.50   35000      2500        NO CUMPLE
...
```

Columnas clave:
- **k6_p95:** Latencia de k6 (cliente percibida)
- **motor_p95:** Latencia del motor (interno)
- **espera_p95:** Tiempo en cola del anillo
- **veredicto:** CUMPLE, NO CUMPLE, NO MEDIBLE, ABORTADA

---

## Lectura Adicional

- **k6 Documentation:** https://k6.io/docs/
- **gRPC:** https://grpc.io/
- **Coordinated Omission:** "How Not to Measure Latency" - Gil Tene
- **Queueing Theory:** Kingman formula, Little's law
- **Load Testing Patterns:** Model open vs. closed, arrival processes
