# Arquitectura Detallada: Matching Engine

Análisis profundo a nivel de código del motor de emparejamiento de órdenes. Este documento explica la estructura, clases, métodos relevantes, flujo de ejecución y operaciones internas.

---

## Tabla de Contenidos

1. [Introducción y Propósito](#introducción-y-propósito)
2. [Arquitectura General](#arquitectura-general)
3. [Análisis Detallado de Clases](#análisis-detallado-de-clases)
4. [Flujo de Operaciones](#flujo-de-operaciones)
5. [Patrones de Diseño](#patrones-de-diseño)
6. [Medición y Observabilidad](#medición-y-observabilidad)

---

## Introducción y Propósito

El **matching-engine** es un servicio Java 21 que implementa un motor de emparejamiento de órdenes (order matching) usando el patrón **LMAX Disruptor**. Su objetivo es procesar órdenes de compra/venta de instrumentos financieros con **latencia ultra-baja y predecible**, sin bloqueos ni garbage collection en la ruta crítica.

### Características Clave

- **Único escritor:** Un solo thread procesa todas las órdenes secuencialmente
- **Sin locks:** Garantías de seguridad por diseño, no por sincronización
- **Ring buffer:** Anillo circular de 16384 casillas para desacoplamiento productor-consumidor
- **Dual-level metrics:** Histogramas por ventana (10s) y acumulado
- **Durabilidad opcional:** Bitácora de solo-anexado con tres modos (OFF, PARALELO, SERIE)

---

## Arquitectura General

### Topología de Sistema

```
┌──────────────────────────────────────────────────────────────────┐
│                        matching-engine (shard)                   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  gRPC Input Layer (múltiples threads)                      │ │
│  │  Puerto: 9090                                              │ │
│  │  Servicio: matching.v1.MatchingIngest/SubmitOrder          │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  IngestGrpcService                                         │ │
│  │  - Captura timestamp t0 (arribo al motor)                  │ │
│  │  - tryNext() → obtiene secuencia del anillo               │ │
│  │  - Publica evento sin bloquear (no-wait)                  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Disruptor Ring Buffer (16384 casillas, potencia de 2)    │ │
│  │  ProducerType: MULTI (múltiples productores)               │ │
│  │  WaitStrategy: BusySpinWaitStrategy (sin sleep)            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  MatchingHandler [ÚNICO ESCRITOR]                          │ │
│  │  Thread: "MatchingHandler" (MAX_PRIORITY)                  │ │
│  │  Responsabilidad:                                          │ │
│  │  - Procesa eventos secuencialmente                         │ │
│  │  - Consulta/actualiza OrderBooks por símbolo              │ │
│  │  - Ejecuta matching algoritmo                              │ │
│  │  - Aplica costo de negocio (CPU burn)                      │ │
│  │  - Registra latencias en histogramas                       │ │
│  │  - Responde al cliente (callback)                          │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  [Modo PARALELO]           [Modo SERIE]                   │ │
│  │  JournalHandler ∥ Cleanup   JournalHandler →  MatchingH. │ │
│  │                                                             │ │
│  │  JournalHandler:                                           │ │
│  │  - Serializa evento a bytes                                │ │
│  │  - Escribe en archivo (append-only)                        │ │
│  │  - Fsync por lote (cada 10 eventos)                        │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  CleanupHandler                                            │ │
│  │  - Vacía casilla (null fields)                             │ │
│  │  - Permite reciclado por Disruptor                         │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  gRPC Response (callback asincrónico)                      │ │
│  │  MatchingResponse incluye:                                 │ │
│  │  - Status (MATCHED, PARTIALLY_MATCHED, RESTING)            │ │
│  │  - Cantidad ejecutada                                      │ │
│  │  - Latencia del motor (µs)                                 │ │
│  │  - ID del shard                                            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                            ↓                                     │
│  Cliente recibe respuesta (gRPC completa)                        │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Observabilidad (cada 10 segundos)                         │ │
│  │  - MetricsReporter extrae p50, p95, p99 de histogramas    │ │
│  │  - Expone endpoint /metrics (Puerto 9095)                  │ │
│  │  - Prometheus raspa cada 10s                               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Análisis Detallado de Clases

### 1. EngineMain

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/EngineMain.java`

**Propósito:** Punto de entrada. Inicializa el Disruptor, cablea consumidores, levanta servidor gRPC y gestiona ciclo de vida.

#### Método main() - Análisis Línea por Línea

```java
public static void main(String[] args) throws Exception {
  // ═══════════════════════════════════════════════════════════════════
  // FASE 1: LEE CONFIGURACIÓN DEL AMBIENTE
  // ═══════════════════════════════════════════════════════════════════
  
  final String shardId = System.getenv("SHARD_ID") != null 
    ? System.getenv("SHARD_ID") 
    : "0";
  // → Identifica esta partición (0, 1, 2, 3...)
  
  final int port = Integer.parseInt(
    System.getenv("PORT") != null ? System.getenv("PORT") : "9090"
  );
  // → Puerto gRPC. Default 9090 permite que múltiples shards corra en localhost
  
  final int ringSize = Integer.parseInt(
    System.getenv("RING_SIZE") != null ? System.getenv("RING_SIZE") : "16384"
  );
  // → Tamaño anillo Disruptor
  // IMPORTANTE: Debe ser potencia de 2
  // Derivación: 2^14 = 16384 > QUEUE_CAPACITY_router (10000)
  // Proporciona colchón de ~6384 casillas para absorber picos
  
  final long bizMicros = Long.parseLong(
    System.getenv("BIZ_MICROS") != null ? System.getenv("BIZ_MICROS") : "0"
  );
  // → Costo MEDIO por orden en microsegundos
  // 0 = desactivado (solo latencia de matching)
  // 8000 = 8ms por orden (simula procesamiento costoso)
  
  final String bizDist = System.getenv("BIZ_DIST") != null 
    ? System.getenv("BIZ_DIST") 
    : "mezcla";
  // → Forma de distribución del costo: "mezcla" o "lognormal"
  // Ambas tienen misma media y varianza → compara efecto de forma
  
  final String journalMode = System.getenv("JOURNAL") != null 
    ? System.getenv("JOURNAL") 
    : "off";
  // → Durabilidad: "off" (sin bitácora), "paralelo", "serie"
  
  final String journalDir = System.getenv("JOURNAL_DIR") != null 
    ? System.getenv("JOURNAL_DIR") 
    : "/var/lib/engine/journal";
  // → Directorio donde se persisten las órdenes (si aplica)
  
  logger.info("═══════════════════════════════════════════════════════════");
  logger.info("matching-engine INICIANDO");
  logger.info("  shardId={}, port={}, ringSize={}", shardId, port, ringSize);
  logger.info("  bizMicros={}, bizDist={}", bizMicros, bizDist);
  logger.info("  journalMode={}, journalDir={}", journalMode, journalDir);
  logger.info("═══════════════════════════════════════════════════════════");

  // ═══════════════════════════════════════════════════════════════════
  // FASE 2: CREA DISRUPTOR CON CONFIGURACIÓN OPTIMIZADA PARA LATENCIA
  // ═══════════════════════════════════════════════════════════════════
  
  // Crea una factory de eventos que reutiliza instancias (sin GC)
  EventFactory<OrderEvent> factory = OrderEvent::new;
  // → Disruptor crea ringSize instancias una sola vez
  // → Las reutiliza sin garbage collection
  
  // ExecutorService con un único thread dedicado
  Executor executor = Executors.newFixedThreadPool(1, r -> {
    Thread t = new Thread(r, "MatchingHandler");
    t.setPriority(Thread.MAX_PRIORITY);  // ← CRÍTICO: máxima prioridad
    // Impide desalojo del thread por scheduler del SO
    return t;
  });
  
  Disruptor<OrderEvent> disruptor = new Disruptor<>(
    factory,
    ringSize,                           // Potencia de 2
    executor,                           // Un thread dedicado
    ProducerType.MULTI,                 // Múltiples productores (gRPC threads)
    new BusySpinWaitStrategy()          // Sin sleep, latencia mínima
  );
  
  // ProducerType.MULTI permite que múltiples threads gRPC publiquen
  // sin sincronización explícita (Disruptor maneja CAS atomics)
  
  // BusySpinWaitStrategy: el escritor corre en busy-loop
  // ├─ CPU = 100% (consume un núcleo completo)
  // ├─ Latencia = mínima (sin context switch)
  // └─ Predecible (sin jitter del scheduler)
  
  // ═══════════════════════════════════════════════════════════════════
  // FASE 3: CABLEA CADENA DE CONSUMIDORES (DEPENDE DE JOURNAL_MODE)
  // ═══════════════════════════════════════════════════════════════════
  
  MatchingHandler matchingHandler = new MatchingHandler(shardId, bizMicros, bizDist);
  // → Único escritor del patrón LMAX
  // → Procesa eventos en orden de llegada
  // → Sin locks: solo él modifica OrderBooks y histogramas
  
  CleanupHandler cleanupHandler = new CleanupHandler();
  // → Vacía casilla después de que todos pasaron
  // → Siempre va al final de la cadena
  
  if ("paralelo".equalsIgnoreCase(journalMode)) {
    // Modo PARALELO: Bitácora corre en paralelo al cruce
    // ├─ No afecta latencia del cliente (respuesta después de cruce, no después de fsync)
    // └─ Durabilidad eventual (fsync cada N eventos)
    
    JournalHandler journalHandler = new JournalHandler(journalDir, "paralelo");
    
    // Cadena: MatchingHandler → Cleanup
    disruptor.handleEventsWith(matchingHandler)
             .then(cleanupHandler);
    
    // Paralelo: JournalHandler avanza independientemente
    disruptor.handleEventsWith(journalHandler);
    
  } else if ("serie".equalsIgnoreCase(journalMode)) {
    // Modo SERIE: Bitácora va antes del cruce
    // ├─ Afecta latencia (durabilidad inmediata antes de responder)
    // └─ Fsync en camino crítico
    
    JournalHandler journalHandler = new JournalHandler(journalDir, "serie");
    
    // Cadena: JournalHandler → MatchingHandler → Cleanup (orden secuencial)
    disruptor.handleEventsWith(journalHandler)
             .then(matchingHandler)
             .then(cleanupHandler);
    
  } else {
    // Modo OFF: Sin bitácora
    // Cadena: MatchingHandler → Cleanup
    disruptor.handleEventsWith(matchingHandler)
             .then(cleanupHandler);
  }

  // ═══════════════════════════════════════════════════════════════════
  // FASE 4: INICIA DISRUPTOR
  // ═══════════════════════════════════════════════════════════════════
  
  RingBuffer<OrderEvent> ringBuffer = disruptor.start();
  // → Crea las instancias de OrderEvent (ringSize de ellas)
  // → Inicia el thread MatchingHandler
  // → Ring está listo para recibir eventos
  
  // ═══════════════════════════════════════════════════════════════════
  // FASE 5: LEVANTA SERVIDOR gRPC
  // ═══════════════════════════════════════════════════════════════════
  
  Server server = ServerBuilder.forPort(port)
    .addService(new IngestGrpcService(ringBuffer, shardId))
    .addService(new MetricsService(matchingHandler.getHistograms()))
    .build()
    .start();
  
  logger.info("matching-engine shard={} escuchando gRPC en :{}", shardId, port);
  
  // IngestGrpcService:
  // ├─ Implementa MatchingIngest.SubmitOrder
  // └─ Publica órdenes en ringBuffer con tryNext() (no-wait)
  
  // MetricsService:
  // ├─ Expone endpoint /metrics para Prometheus
  // └─ Contiene histogramas de latencia

  // ═══════════════════════════════════════════════════════════════════
  // FASE 6: INICIA THREAD DE REPORTES CADA 10 SEGUNDOS
  // ═══════════════════════════════════════════════════════════════════
  
  Thread metricsReporter = new Thread(() -> {
    while (!Thread.currentThread().isInterrupted()) {
      try {
        Thread.sleep(10_000);  // Cada 10 segundos
        
        // Extrae percentiles de la ventana actual
        long p50 = matchingHandler.getWindowHistogram().getValueAtPercentile(50.0);
        long p95 = matchingHandler.getWindowHistogram().getValueAtPercentile(95.0);
        long p99 = matchingHandler.getWindowHistogram().getValueAtPercentile(99.0);
        
        logger.info("VENTANA [{}]: p50={} µs, p95={} µs, p99={} µs",
          shardId, p50, p95, p99);
        
        // Resetea la ventana para la próxima medición
        matchingHandler.resetWindowHistogram();
        
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
  }, "MetricsReporter");
  
  metricsReporter.setDaemon(false);
  metricsReporter.start();

  // ═══════════════════════════════════════════════════════════════════
  // FASE 7: ESPERA A APAGADO (SIGTERM)
  // ═══════════════════════════════════════════════════════════════════
  
  server.awaitTermination();
  // → Bloquea hasta que reciba señal de apagado (Ctrl+C o SIGTERM)

  // ═══════════════════════════════════════════════════════════════════
  // FASE 8: APAGADO ORDENADO
  // ═══════════════════════════════════════════════════════════════════
  
  logger.info("Apagando engine shard={}...", shardId);
  
  // Publica percentiles acumulados (población entera)
  long p50 = matchingHandler.getAccumulatedHistogram().getValueAtPercentile(50.0);
  long p95 = matchingHandler.getAccumulatedHistogram().getValueAtPercentile(95.0);
  long p99 = matchingHandler.getAccumulatedHistogram().getValueAtPercentile(99.0);
  long p999 = matchingHandler.getAccumulatedHistogram().getValueAtPercentile(99.9);
  
  logger.info("ACUMULADO [{}]: p50={} µs, p95={} µs, p99={} µs, p99.9={} µs",
    shardId, p50, p95, p99, p999);
  
  long totalOrders = matchingHandler.getTotalOrders();
  long totalRejections = matchingHandler.getTotalRejections();
  
  logger.info("Estadísticas: órdenes={}, rechazos={}, tasa_rechazo={}%",
    totalOrders, totalRejections, 
    (100.0 * totalRejections / Math.max(totalOrders, 1)));
  
  // Detiene el Disruptor
  disruptor.shutdown();
  
  // Detiene el servidor gRPC
  server.shutdown();
  server.awaitTermination();
  
  metricsReporter.interrupt();
  
  logger.info("matching-engine shard={} DETENIDO", shardId);
}
```

#### Decisiones Arquitectónicas en EngineMain

| Decisión | Razón | Impacto |
|----------|-------|--------|
| **ProducerType.MULTI** | Múltiples threads gRPC publican sin sincronización explícita | Throughput alto sin contención |
| **BusySpinWaitStrategy** | No sleep, solo busy-wait | CPU=100%, latencia mínima |
| **MAX_PRIORITY** | Impide desalojo del escritor | Latencia predecible |
| **Dual histogramas** | Ventana (10s) + acumulado | Evolución en tiempo real + percentiles finales |
| **Reporte cada 10s** | Coincide con ventana de agregación | Muestra estado real |

---

### 2. OrderEvent

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/OrderEvent.java`

**Propósito:** Contenedor que circula en el anillo. Reutilizado sin garbage collection.

```java
public class OrderEvent {
  // ═══════════════════════════════════════════════════════════════════
  // DATOS DE ENTRADA (Escritos por IngestGrpcService)
  // ═══════════════════════════════════════════════════════════════════
  
  public String symbol;              // "AAPL", "MSFT", etc. (clave de partición)
  public long priceCents;            // 12950 = $129.50
  public long quantity;              // 100 acciones
  public boolean isBid;              // true=compra, false=venta
  public long arrivalNanos;          // t0: System.nanoTime() cuando llega
  
  // ═══════════════════════════════════════════════════════════════════
  // DATOS CALCULADOS POR MATCHINGHANDLER
  // ═══════════════════════════════════════════════════════════════════
  
  public Status status;              // MATCHED, PARTIALLY_MATCHED, RESTING
  public long materializedQty;       // Cantidad ejecutada
  public long esperaMicros;          // Tiempo en cola: (t_start - arrivalNanos) / 1000
  public long servicioMicros;        // Tiempo de cruce: (t_end - t_start) / 1000
  
  // ═══════════════════════════════════════════════════════════════════
  // COMUNICACIÓN GRRPC (Respuesta asincrónica)
  // ═══════════════════════════════════════════════════════════════════
  
  public StreamObserver<MatchingResponse> responseObserver;
  // → Callback para responder al cliente
  // → Llamado desde MatchingHandler después de procesar
  
  // ═══════════════════════════════════════════════════════════════════
  // MÉTODOS AUXILIARES
  // ═══════════════════════════════════════════════════════════════════
  
  public void reset() {
    // Llamado por CleanupHandler para reciclar la casilla
    symbol = null;
    responseObserver = null;
    // Disruptor reutiliza esta instancia en la siguiente vuelta
  }
}
```

**Ciclo de Vida de una Casilla:**

```
[VACIA]
  ↓
IngestGrpcService publica evento
  ├─ arrivalNanos = t0
  ├─ symbol, price, qty populados
  └─ responseObserver = callback
  ↓
MatchingHandler.onEvent()
  ├─ Espera desde arrivalNanos hasta ahora: esperaMicros
  ├─ Consulta OrderBook[symbol]
  ├─ Ejecuta matching
  ├─ Aplicamodelo de negocio
  ├─ servicioMicros = tiempo consumido
  ├─ Histogramas.recordValue()
  └─ responseObserver.onNext() → cliente responde
  ↓
JournalHandler.onEvent() (si aplica)
  ├─ Lee evento (no modifica)
  └─ Serializa y escribe archivo
  ↓
CleanupHandler.onEvent()
  ├─ reset() → nulifica referencias
  └─ Casilla lista para reciclado
```

---

### 3. IngestGrpcService

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/IngestGrpcService.java`

**Propósito:** Implementa MatchingIngest gRPC. Punto de entrada de órdenes al anillo.

#### Método submitOrder() - Análisis Profundo

```java
@Override
public void submitOrder(SubmitOrderRequest req, 
                       StreamObserver<MatchingResponse> responseObserver) {
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 1: CAPTURA TIMESTAMP DE ARRIBO (t0)
  // ═══════════════════════════════════════════════════════════════════
  
  long t0 = System.nanoTime();
  // → Nanosegundos desde un punto arbitrario fijo
  // → Resolución máxima disponible en JVM (~microsegundos en práctica)
  // → CRÍTICO: Se toma ANTES de tryNext() para incluir latencia de cola
  
  try {
    // ═══════════════════════════════════════════════════════════════════
    // PASO 2: INTENTA PUBLICAR EN ANILLO (NO-WAIT)
    // ═══════════════════════════════════════════════════════════════════
    
    long sequence = ringBuffer.tryNext();
    // → Obtiene una secuencia del anillo
    // → Si lleno, devuelve -1 (no bloquea)
    // → Este es el desacoplamiento clave: no bloquea el thread gRPC
    
    if (sequence == -1) {
      // ANILLO LLENO: Rechaza inmediatamente (backpressure)
      
      logger.warn("Rechazo RING_FULL: no hay casillas disponibles");
      
      MatchingResponse response = MatchingResponse.newBuilder()
        .setStatus(Status.REJECTED)
        .setReason("RING_FULL_backpressure")
        .build();
      
      responseObserver.onNext(response);
      responseObserver.onCompleted();
      
      // Registra rechazo para métricas
      recordRejection("ring_full");
      return;
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // PASO 3: PUBLICA EVENTO EN LA CASILLA
    // ═══════════════════════════════════════════════════════════════════
    
    try {
      OrderEvent event = ringBuffer.get(sequence);
      // → Obtiene la referencia a la casilla [sequence]
      // → Esta es la MISMA instancia siempre (reutilizada)
      
      // Copia datos de la solicitud gRPC
      event.symbol = req.getSymbol();
      // → Validar que coincida con esta partición:
      // → floorMod(symbol.hashCode(), N) == shardId
      
      event.priceCents = req.getPriceCents();
      // → Precio en centavos, sin aritmética flotante
      
      event.quantity = req.getQuantity();
      event.isBid = req.getIsBid();
      
      event.arrivalNanos = t0;
      // → MARCA DE TIEMPO: cuándo llegó
      
      event.responseObserver = responseObserver;
      // → Callback para responder cuando MatchingHandler termine
      
      event.status = null;          // Se pone en MatchingHandler
      event.materializedQty = 0;    // Se pone en MatchingHandler
      
    } finally {
      // ═══════════════════════════════════════════════════════════════════
      // PASO 4: PUBLICA LA CASILLA (MEMORY BARRIER)
      // ═══════════════════════════════════════════════════════════════════
      
      ringBuffer.publish(sequence);
      // → Hace el evento visible al escritor MatchingHandler
      // → Es un memory barrier: garantiza que todos los campos se escribieron
      // → Disruptor sabe que puede procesar events[sequence] ahora
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // PASO 5: RETORNA AL CLIENTE INMEDIATAMENTE
    // ═══════════════════════════════════════════════════════════════════
    
    // El cliente espera la respuesta
    // Pero MatchingHandler la enviará asincrónica (cuando termine)
    // Esto es por design: el cliente no espera el matching, espera gRPC
    
  } catch (Exception e) {
    logger.error("Error en submitOrder", e);
    
    MatchingResponse response = MatchingResponse.newBuilder()
      .setStatus(Status.REJECTED)
      .setReason("INTERNAL_ERROR: " + e.getMessage())
      .build();
    
    responseObserver.onNext(response);
    responseObserver.onCompleted();
  }
}

// ═══════════════════════════════════════════════════════════════════
// MÉTODO AUXILIAR: Registra rechazos en métricas
// ═══════════════════════════════════════════════════════════════════

private void recordRejection(String reason) {
  synchronized (rejectionMetrics) {  // Una sola métrica global por razón
    rejectionMetrics.merge(reason, 1L, Long::sum);
  }
  // → Usado para alertas y debugging
  // → Si RING_FULL crece mucho → escalabilidad insuficiente
}
```

#### Garantías de Seguridad

- **No bloquea:** `tryNext()` devuelve -1 si lleno, sin esperar
- **Respuesta asincrónica:** Cliente recibe callback cuando MatchingHandler termine
- **Memory barrier:** `publish()` garantiza visibilidad
- **Multi-productor:** Varios threads gRPC publican sin sincronización explícita

---

### 4. MatchingHandler

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/MatchingHandler.java`

**Propósito:** ÚNICO ESCRITOR del patrón LMAX. Procesa eventos secuencialmente, ejecuta matching, aplica costo y responde.

#### Método onEvent() - Análisis Línea por Línea

```java
@Override
public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
  // ═══════════════════════════════════════════════════════════════════
  // PASO 1: CAPTURA INICIO DE SERVICIO (t_start)
  // ═══════════════════════════════════════════════════════════════════
  
  long t_start = System.nanoTime();
  // → Marca el inicio del procesamiento
  // → Diferencia (t_start - event.arrivalNanos) = latencia de espera
  
  long esperaNanos = t_start - event.arrivalNanos;
  // → Tiempo que esperó en la cola del anillo
  // → Espera baja → anillo no congestión
  // → Espera alta → hay backlog
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 2: OBTIENE O CREA ORDERBOOK DEL SÍMBOLO
  // ═══════════════════════════════════════════════════════════════════
  
  OrderBook book = books.computeIfAbsent(event.symbol, k -> {
    logger.info("Creando nuevo OrderBook para símbolo={}", event.symbol);
    return new OrderBook();
  });
  
  // books es un HashMap<String, OrderBook>
  // ├─ Un OrderBook por símbolo (ej: AAPL, MSFT)
  // ├─ Cada OrderBook contiene su propia estructura (TreeMap + ArrayDeque)
  // └─ Sin locks: solo este thread accede
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 3: EJECUTA MATCHING (núcleo del algoritmo)
  // ═══════════════════════════════════════════════════════════════════
  
  OrderBook.MatchResult result = book.match(
    event.symbol,
    event.priceCents,
    event.quantity,
    event.isBid
  );
  
  event.materializedQty = result.executedQty;
  event.status = result.status;
  
  // match() retorna:
  // ├─ executedQty: cuánto se ejecutó
  // └─ status: MATCHED, PARTIALLY_MATCHED, o RESTING
  
  // Ejemplos de resultados:
  // ├─ Orden de compra 100 AAPL @ $100, hay 50 @ $99.50
  //    → Ejecuta 50, status=PARTIALLY_MATCHED, qty_resting=50
  // ├─ No hay órdenes que cumplan
  //    → status=RESTING (se queda en el libro esperando)
  // └─ Hay exactamente 100 @ precio ≤ $100
  //    → status=MATCHED
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 4: APLICA COSTO DE NEGOCIO (CPU BURN)
  // ═══════════════════════════════════════════════════════════════════
  
  if (bizMicros > 0) {
    // Simula procesamiento de la orden (validación, comisiones, etc)
    long costMicros = bizModel.costForOrder(event.quantity);
    // ├─ Si BIZ_DIST="mezcla": 90% × mean, 9% × 6×mean, 1% × 30×mean
    // └─ Si BIZ_DIST="lognormal": distribución continua sin cota
    
    cpuBurn(costMicros);  // Consume CPU para simular trabajo
    // └─ Busy-loop que consume exactamente costMicros microsegundos
  }
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 5: CAPTURA FIN DE SERVICIO (t_end) Y CALCULA LATENCIAS
  // ═══════════════════════════════════════════════════════════════════
  
  long t_end = System.nanoTime();
  
  long servicioNanos = t_end - t_start;
  // → Tiempo consumido en matching + modelo de negocio
  
  long totalNanos = t_end - event.arrivalNanos;
  // → Latencia completa de motor: espera + servicio
  
  // Convierte a microsegundos (µs) para histogramas
  event.esperaMicros = esperaNanos / 1000;
  event.servicioMicros = servicioNanos / 1000;
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 6: REGISTRA LATENCIAS EN HISTOGRAMAS
  // ═══════════════════════════════════════════════════════════════════
  
  // VENTANA ACTUAL (resetea cada 10s)
  windowHistogram.recordValue(totalNanos / 1000);      // Total
  windowEsperaHistogram.recordValue(esperaNanos / 1000);
  windowServicioHistogram.recordValue(servicioNanos / 1000);
  
  // ACUMULADO (nunca resetea)
  accumulatedHistogram.recordValue(totalNanos / 1000);
  accumulatedEsperaHistogram.recordValue(esperaNanos / 1000);
  accumulatedServicioHistogram.recordValue(servicioNanos / 1000);
  
  // HdrHistogram tiene resolución variable:
  // ├─ Rango: 1 µs a segundos
  // ├─ Precisión: configurable (típica: 2 dígitos significativos)
  // └─ Sin GC: buckets pre-alocados
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 7: CONSTRUYE RESPUESTA gRPC
  // ═══════════════════════════════════════════════════════════════════
  
  MatchingResponse response = MatchingResponse.newBuilder()
    .setStatus(event.status)                // MATCHED, etc.
    .setMaterializedQty(event.materializedQty)
    .setEngineLatencyMicros(totalNanos / 1000)
    .setShard(this.shardId)                 // Qué shard procesó
    .build();
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 8: ENVÍA RESPUESTA AL CLIENTE (CALLBACK ASINCRÓNICO)
  // ═══════════════════════════════════════════════════════════════════
  
  event.responseObserver.onNext(response);
  event.responseObserver.onCompleted();
  
  // → El cliente recibe la respuesta gRPC aquí
  // → No espera más desde submitOrder()
  
  // ═══════════════════════════════════════════════════════════════════
  // PASO 9: ACTUALIZA CONTADORES GLOBALES
  // ═══════════════════════════════════════════════════════════════════
  
  totalOrdersProcessed++;
  if (event.status != Status.MATCHED && event.status != Status.PARTIALLY_MATCHED) {
    totalOrdersResting++;
  }
}

// ═══════════════════════════════════════════════════════════════════
// MÉTODO AUXILIAR: CPU BURN (Simula Costo de Negocio)
// ═══════════════════════════════════════════════════════════════════

private void cpuBurn(long targetMicros) {
  long startNanos = System.nanoTime();
  long targetNanos = targetMicros * 1000;  // Convierte a nanos
  
  // Busy-loop que consume CPU hasta alcanzar el tiempo objetivo
  while (System.nanoTime() - startNanos < targetNanos) {
    // Operación CPU-intensiva que NO se optimiza (compilador no la elimina)
    double dummy = Math.sqrt(Math.random() * Math.random());
  }
  
  // ├─ Sin Thread.sleep() (contexto switch, GC)
  // ├─ Sin volatiles (innecesarios)
  // └─ CPU = 100% durante targetMicros microsegundos
}
```

#### Garantías de Seguridad (Patrón LMAX)

| Garantía | Mecanismo | Resultado |
|----------|-----------|----------|
| **Único escritor** | Un solo thread llama onEvent() | No hay race conditions |
| **Sin locks** | OrderBooks solo accesibles desde MatchingHandler | Sin deadlock, sin contención |
| **Seguridad de tipos** | HashMap y TreeMap no son sincronizados, pero... | Solo el MatchingHandler los lee/escribe |
| **Visibilidad de memoria** | Disruptor publica() antes de onEvent() | Cambios en evento son visibles |

---

### 5. OrderBook

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/OrderBook.java`

**Propósito:** Libro de órdenes en memoria. Estructura: bids (compra) y asks (venta), ordenados por precio, FIFO dentro de cada nivel.

#### Estructura de Datos

```java
public class OrderBook {
  // ═══════════════════════════════════════════════════════════════════
  // BIDS: Órdenes de COMPRA (precio DESCENDENTE)
  // ═══════════════════════════════════════════════════════════════════
  
  private final TreeMap<Long, ArrayDeque<Order>> bids = 
    new TreeMap<>(Comparator.reverseOrder());
  
  // Estructura visual:
  // bids = {
  //   10050: [Order(qty=50, t=100), Order(qty=30, t=101)],  // Precio $100.50
  //   10040: [Order(qty=100, t=99)],                         // Precio $100.40
  //   10030: [Order(qty=75, t=98)],                          // Precio $100.30
  // }
  
  // TreeMap con reverseOrder():
  // ├─ Itera desde mayor precio a menor
  // ├─ Para matching de compra: busca seller más barato primero
  // └─ Complejidad: O(log N) para insert/remove por precio
  
  // ArrayDeque por precio:
  // ├─ FIFO: Primera en entrar, primera en salir (por tiempo)
  // ├─ No necesario ordenar por tiempo (ya está en orden de llegada)
  // └─ Complejidad: O(1) amortizado para poll/offer
  
  // ═══════════════════════════════════════════════════════════════════
  // ASKS: Órdenes de VENTA (precio ASCENDENTE)
  // ═══════════════════════════════════════════════════════════════════
  
  private final TreeMap<Long, ArrayDeque<Order>> asks = 
    new TreeMap<>();  // Orden natural: menor precio primero
  
  // Estructura visual:
  // asks = {
  //   10020: [Order(qty=40, t=90), Order(qty=20, t=91)],   // Precio $100.20
  //   10030: [Order(qty=60, t=92)],                         // Precio $100.30
  //   10040: [Order(qty=110, t=93)],                        // Precio $100.40
  // }
  
  // TreeMap natural order:
  // ├─ Itera desde menor precio a mayor
  // ├─ Para matching de venta: busca buyer más rico primero
  // └─ Complejidad: O(log N)
}
```

#### Método match() - Algoritmo Completo

```java
public MatchResult match(String symbol, long price, long qty, boolean isBid) {
  // Implementa matching price-time priority (PTP)
  // ├─ Price: se ejecuta al mejor precio disponible
  // └─ Time: entre órdenes al mismo precio, gana quien llegó primero (FIFO)
  
  long executedQty = 0;
  long remainingQty = qty;
  
  // ═══════════════════════════════════════════════════════════════════
  // RAMA 1: ORDEN DE COMPRA (BID)
  // ═══════════════════════════════════════════════════════════════════
  
  if (isBid) {
    // Buyer quiere comprar a máximo 'price'
    // Busca sellers con precio ≤ price (empezando por el más barato)
    
    var askIterator = asks.entrySet().iterator();
    
    while (askIterator.hasNext() && remainingQty > 0) {
      Map.Entry<Long, ArrayDeque<Order>> entry = askIterator.next();
      
      long askPrice = entry.getKey();
      // ├─ Precio de venta
      // └─ asks está ordenado: primero los más baratos
      
      if (askPrice > price) {
        // No hay más sellers que cumplan el precio del buyer
        break;
      }
      
      // Este precio SÍ cumple: askPrice ≤ price
      ArrayDeque<Order> ordersAtPrice = entry.getValue();
      
      while (!ordersAtPrice.isEmpty() && remainingQty > 0) {
        Order sellerOrder = ordersAtPrice.peek();
        // ├─ Primer seller en este precio level (FIFO)
        // ├─ Llegó primero → tiene prioridad
        // └─ peek() no remove, solo consulta
        
        long crossQty = Math.min(remainingQty, sellerOrder.qty);
        
        // EJECUCIÓN DE CRUCE
        executedQty += crossQty;
        remainingQty -= crossQty;
        sellerOrder.qty -= crossQty;
        
        if (sellerOrder.qty == 0) {
          // Seller fue completamente ejecutado
          ordersAtPrice.poll();  // Extrae de la cola
          // ├─ Libera memoria
          // └─ Prepara para la siguiente orden en este precio
        }
      }
      
      if (ordersAtPrice.isEmpty()) {
        // No hay más órdenes en este precio level
        askIterator.remove();  // Borra el price level del árbol
        // └─ Optimización: no guarda niveles vacíos
      }
    }
    
    // ÓRDENES SIN EJECUTAR: Se quedan esperando en bids
    if (remainingQty > 0) {
      bids.computeIfAbsent(price, k -> new ArrayDeque<>())
          .offer(new Order(symbol, remainingQty));
      // ├─ Agrega al final de la cola (FIFO)
      // └─ Espera a que lleguen sellers
    }
    
  } else {
    // ═══════════════════════════════════════════════════════════════════
    // RAMA 2: ORDEN DE VENTA (ASK) - Análogo simétrico
    // ═══════════════════════════════════════════════════════════════════
    
    // Seller quiere vender a mínimo 'price'
    // Busca buyers con precio ≥ price (empezando por el más rico)
    
    var bidIterator = bids.entrySet().iterator();
    
    while (bidIterator.hasNext() && remainingQty > 0) {
      Map.Entry<Long, ArrayDeque<Order>> entry = bidIterator.next();
      
      long bidPrice = entry.getKey();
      // ├─ bids está en orden descendente (reverseOrder())
      // └─ Primero se prueban los precios más altos
      
      if (bidPrice < price) {
        // No hay más buyers que cumplan el precio del seller
        break;
      }
      
      // Este precio SÍ cumple: bidPrice ≥ price
      ArrayDeque<Order> ordersAtPrice = entry.getValue();
      
      while (!ordersAtPrice.isEmpty() && remainingQty > 0) {
        Order buyerOrder = ordersAtPrice.peek();
        
        long crossQty = Math.min(remainingQty, buyerOrder.qty);
        
        executedQty += crossQty;
        remainingQty -= crossQty;
        buyerOrder.qty -= crossQty;
        
        if (buyerOrder.qty == 0) {
          ordersAtPrice.poll();
        }
      }
      
      if (ordersAtPrice.isEmpty()) {
        bidIterator.remove();
      }
    }
    
    if (remainingQty > 0) {
      asks.computeIfAbsent(price, k -> new ArrayDeque<>())
          .offer(new Order(symbol, remainingQty));
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════
  // RETORNA RESULTADO
  // ═══════════════════════════════════════════════════════════════════
  
  Status status;
  if (executedQty == qty) {
    status = Status.MATCHED;  // Todo se ejecutó
  } else if (executedQty > 0) {
    status = Status.PARTIALLY_MATCHED;  // Se ejecutó parcialmente
  } else {
    status = Status.RESTING;  // Nada se ejecutó (espera en libro)
  }
  
  return new MatchResult(executedQty, status);
}
```

#### Complejidad y Garantías

| Operación | Complejidad | Razón |
|-----------|-------------|-------|
| **Buscar nivel de precio** | O(log N) | TreeMap.entrySet() |
| **FIFO dentro de precio** | O(1) amortizado | ArrayDeque.poll() |
| **Remover nivel vacío** | O(log N) | TreeMap.remove() |
| **Insertar orden resting** | O(log N) | TreeMap.computeIfAbsent() |
| **Peor caso (orden grande)** | O(N) | Si cruza todas las órdenes del otro lado |

---

### 6. BusinessLogicModel

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/BusinessLogicModel.java`

**Propósito:** Simula costo de negocio con distribuciones configurables.

```java
public class BusinessLogicModel {
  private final String distributionShape;  // "mezcla" o "lognormal"
  private final long meanMicros;          // Media de la distribución
  private final Random random;            // Generador de aleatoriedad
  
  // ═══════════════════════════════════════════════════════════════════
  // MÉTODO PRINCIPAL: Elige distribución y calcula costo
  // ═══════════════════════════════════════════════════════════════════
  
  public long costForOrder(long quantity) {
    if (meanMicros == 0) {
      return 0;  // Modelo desactivado
    }
    
    if ("mezcla".equalsIgnoreCase(distributionShape)) {
      return costMezcla();
    } else if ("lognormal".equalsIgnoreCase(distributionShape)) {
      return costLognormal();
    }
    
    return meanMicros;
  }
  
  // ═══════════════════════════════════════════════════════════════════
  // DISTRIBUCIÓN 1: MEZCLA DISCRETA (3 clases)
  // ═══════════════════════════════════════════════════════════════════
  
  private long costMezcla() {
    // Distribución discreta de costo:
    // ├─ 90% de órdenes: costo = 1 × mean = mean µs
    // ├─ 9% de órdenes:  costo = 6 × mean = 6 × mean µs
    // └─ 1% de órdenes:  costo = 30 × mean = 30 × mean µs
    
    // Parámetros:
    // ├─ Media = 0.90×mean + 0.09×(6×mean) + 0.01×(30×mean)
    // │        = 0.90×mean + 0.54×mean + 0.30×mean
    // │        = 1.74 × mean
    // └─ Cs² = 3.34 (coeficiente de variación al cuadrado)
    
    double random_value = random.nextDouble();  // [0.0, 1.0)
    
    if (random_value < 0.90) {
      // 90% → costo bajo
      return meanMicros;
    } else if (random_value < 0.99) {
      // 9% → costo medio (6×)
      return meanMicros * 6;
    } else {
      // 1% → costo alto (30×)
      return meanMicros * 30;
    }
  }
  
  // Visualización de la distribución (BIZ_MICROS=8000):
  // Costo (µs)  | Probabilidad | Cantidad
  // ────────────────────────────────────
  // 8000        | 90%          | 9000 órdenes
  // 48000       | 9%           | 900 órdenes
  // 240000      | 1%           | 100 órdenes
  // ────────────────────────────────────
  // Media: ~13920 µs (8000×1.74)
  
  // ═══════════════════════════════════════════════════════════════════
  // DISTRIBUCIÓN 2: LOGNORMAL (continua, sin cota)
  // ═══════════════════════════════════════════════════════════════════
  
  private long costLognormal() {
    // Distribución continua log-normal
    // Forma: no está acotada (puede haber valores muy altos)
    
    // Método de Box-Muller para generar normal estándar Z
    double u1 = random.nextDouble();  // [0.0, 1.0)
    double u2 = random.nextDouble();  // [0.0, 1.0)
    
    double z = Math.sqrt(-2.0 * Math.log(u1)) 
             * Math.cos(2.0 * Math.PI * u2);
    // z ~ N(0, 1) distribución normal estándar
    
    // Transforma a log-normal:
    // X = exp(µ + σ × z)  donde µ=log(mean), σ=1.2
    
    double mu = Math.log(meanMicros);  // Logaritmo de la media
    double sigma = 1.2;                // Desviación estándar en log-space
    
    double x = Math.exp(mu + sigma * z);
    
    return Math.round(x);
    
    // Propiedades:
    // ├─ Media ≈ meanMicros × factor (factor ≈ 1.74 con σ=1.2)
    // ├─ Cs² ≈ 3.34 (misma varianza que mezcla)
    // ├─ Asimetría positiva (cola derecha larga)
    // └─ Rango: [0, ∞) (sin cota superior)
  }
  
  // Comparación visual (BIZ_MICROS=8000):
  
  // MEZCLA (3 valores discretos):
  // Prob
  //  90% ├────────────
  //      │
  //   9% ├─────────
  //      │
  //   1% ├──
  //      └─────────────────────────
  //        8K  48K     240K
  
  // LOGNORMAL (continua):
  // Prob
  //      ├────
  //      │    ╲
  //      │     ╲      ╲
  //      │      ╲      ╲
  //      │       ╲      ╲
  //      └────────╲──────╲────────
  //             10K  100K  1M  10M
  
  // El punto: misma media y varianza, pero formas distintas
  // Permite aislar el efecto de la variabilidad
}
```

---

### 7. JournalHandler

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/JournalHandler.java`

**Propósito:** Persistencia de órdenes. Tres modos: OFF, PARALELO, SERIE.

```java
public class JournalHandler implements EventHandler<OrderEvent> {
  
  private final JournalMode mode;      // OFF, PARALELO, SERIE
  private final FileChannel channel;   // Archivo de solo-anexado
  private final ByteBuffer buffer;     // Buffer para serialización
  private int eventsSinceFsync = 0;
  private final int batchSize = 10;    // Fsync cada N eventos
  
  @Override
  public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
    if (mode == JournalMode.OFF) {
      return;  // Sin persistencia
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // SERIALIZA EVENTO A BYTES
    // ═══════════════════════════════════════════════════════════════════
    
    byte[] serialized = serializeEvent(event);
    // → Convierte event a formato binario (protobuf)
    // → Incluye: símbolo, precio, cantidad, status, resultado
    
    // ═══════════════════════════════════════════════════════════════════
    // ESCRIBE EN BUFFER (SIN FSYNC AÚN)
    // ═══════════════════════════════════════════════════════════════════
    
    buffer.clear();
    buffer.put(serialized);
    buffer.flip();
    
    channel.write(buffer);
    // ├─ Escribe en buffer del kernel (Linux page cache)
    // ├─ Aún no está en disco
    // └─ No afecta latencia en modo PARALELO
    
    eventsSinceFsync++;
    
    // ═══════════════════════════════════════════════════════════════════
    // FSYNC POR LOTE (CADA 10 EVENTOS O FIN DE BATCH)
    // ═══════════════════════════════════════════════════════════════════
    
    if (endOfBatch || eventsSinceFsync >= batchSize) {
      channel.force(false);  // Fsync a disco
      // ├─ false = no sincroniza metadatos (solo datos)
      // ├─ true  = sincroniza también metadatos (más lento)
      // └─ Costo: típicamente 1-5ms por fsync
      
      eventsSinceFsync = 0;
    }
  }
}
```

#### Tres Modos Explicados

```
┌──────────────────────────────────────────────────────────────────┐
│ MODO 1: OFF                                                      │
├──────────────────────────────────────────────────────────────────┤
│  Diagrama:                                                       │
│    MatchingHandler → responde al cliente                         │
│    JournalHandler: (no existe)                                   │
│                                                                  │
│  Latencia cliente:  p95 ≈ 30ms (solo matching)                   │
│  Durabilidad:      ❌ (no hay registro)                          │
│  Caso de uso:      Pruebas, desarrollo                           │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ MODO 2: PARALELO                                                 │
├──────────────────────────────────────────────────────────────────┤
│  Diagrama:                                                       │
│    MatchingHandler  ──┐                                          │
│                       ├─→ responde al cliente                    │
│    JournalHandler  ──┘    (en paralelo, asincrónico)            │
│                                                                  │
│    Orden de tiempo:                                              │
│    t0 ─ Cliente entra                                            │
│    t1 ─ MatchingHandler procesa                                  │
│    t1+ε ─ Cliente recibe respuesta (MatchingHandler terminó)     │
│    t1+ε~ε2 ─ JournalHandler escribe (en paralelo)               │
│    t1+ε2 ─ JournalHandler fsync (cliente ya tiene respuesta)    │
│                                                                  │
│  Latencia cliente:  p95 ≈ 30ms (no afectada por fsync)          │
│  Durabilidad:      ✓ Eventual (fsync cada 10 eventos)            │
│                    Riesgo: si crash entre respuesta y fsync,    │
│                    se pierde la orden pero cliente ya respondió  │
│  Caso de uso:      Tolerancia a pérdidas ocasionales             │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ MODO 3: SERIE                                                    │
├──────────────────────────────────────────────────────────────────┤
│  Diagrama:                                                       │
│    JournalHandler (escribe y fsync)                             │
│         ↓                                                        │
│    MatchingHandler (procesa matching)                           │
│         ↓                                                        │
│    responde al cliente                                          │
│                                                                  │
│    Orden de tiempo:                                              │
│    t0 ─ Cliente entra                                            │
│    t1 ─ JournalHandler escribe                                   │
│    t1+1ms ─ JournalHandler fsync (ESPERA)                       │
│    t2 ─ MatchingHandler procesa                                  │
│    t2+ε ─ Cliente recibe respuesta                               │
│                                                                  │
│  Latencia cliente:  p95 ≈ 30ms + 1-5ms (fsync en ruta crítica)  │
│  Durabilidad:      ✓ Inmediata (fsync antes de responder)        │
│                    Garantía: si client recibe OK, está en disco  │
│  Caso de uso:      Requisitos de durabilidad estrictos           │
└──────────────────────────────────────────────────────────────────┘
```

---

## Flujo de Operaciones

### Viaje Completo de una Orden

```
FASE 1: INGESTA (Cliente → Router → MatchingEngine)
═══════════════════════════════════════════════════════════════

1. Cliente (k6) emite gRPC:
   submitOrder(symbol="AAPL", price=12950, qty=100, isBid=true)
   
   t_client_start = System.currentTimeMillis()

2. Router (ingest-router) recibe:
   - Calcula hash(symbol) % N_shards
   - Semaphore.tryAcquire() → verifica fila (QUEUE_CAPACITY=10000)
   - Si fila llena: responde REJECTED
   - Si hay cupo: reenvía gRPC a matching-shard

3. MatchingEngine IngestGrpcService.submitOrder():
   
   t0 = System.nanoTime()  [MARCA: arribo al motor]
   
   sequence = ringBuffer.tryNext()
   if (sequence == -1) {
     responde REJECTED (ring lleno)
     return
   }
   
   event = ringBuffer.get(sequence)
   event.symbol = "AAPL"
   event.priceCents = 12950
   event.quantity = 100
   event.isBid = true
   event.arrivalNanos = t0
   event.responseObserver = <callback para responder>
   
   ringBuffer.publish(sequence)  [MEMORY BARRIER]
   
   ╔═════════════════════════════════════════════════════════════╗
   ║ Orden ahora está en el anillo, visible para MatchingHandler ║
   ╚═════════════════════════════════════════════════════════════╝


FASE 2: PROCESAMIENTO EN ANILLO (MatchingHandler)
═══════════════════════════════════════════════════════════════

4. MatchingHandler thread lee evento:
   
   t_start = System.nanoTime()
   esperaNanos = t_start - event.arrivalNanos
   
   esperaMicros = esperaNanos / 1000
   [Si esperaMicros ~ 1000 µs → hay backlog]
   [Si esperaMicros ~ 100 µs → anillo poco congestionado]

5. Consulta OrderBook["AAPL"]:
   
   book = books.get("AAPL")  // O crea nuevo si no existe
   
   states:
   
   bids = {
     12960: [Order(qty=50, t=100), Order(qty=30, t=101)],
     12950: [Order(qty=75, t=102)],
     ...
   }
   
   asks = {
     12940: [Order(qty=200, t=98)],
     12930: [Order(qty=100, t=97)],
     ...
   }
   
   Nueva orden: BID 100 @ 12950

6. Ejecuta matching (algoritmo PTP):
   
   Busca en asks (venden a precio ≤ 12950):
   
   ├─ Price level 12940 → cumple (12940 ≤ 12950)
   │  ├─ Order #1: qty=200 @ 12940
   │  │  Cruza 100 (tamaño del buyer)
   │  │  Order #1 qty → 200-100=100 (sigue en libro)
   │  │  Cross: 100 @ 12940
   │  │  ejecutedQty = 100
   │  │  remainingQty = 0
   │  └─ Terminó → status = MATCHED
   
   Resultado: MATCHED, 100 shares ejecutadas @ 12940

7. Aplica costo de negocio:
   
   if (bizMicros > 0) {
     costMicros = bizModel.costForOrder(100)
     // Si "mezcla", 90% probabilidad: costMicros = 8000 µs
     cpuBurn(8000)  // Busy-loop consume CPU por 8ms
   }

8. Registra latencias:
   
   t_end = System.nanoTime()
   servicioNanos = t_end - t_start
   totalNanos = t_end - event.arrivalNanos
   
   event.servicioMicros = servicioNanos / 1000  [típico: ~8000 µs]
   
   windowHistogram.recordValue(totalNanos / 1000)
   accumulatedHistogram.recordValue(totalNanos / 1000)

9. Construye respuesta:
   
   response = MatchingResponse.newBuilder()
     .setStatus(MATCHED)
     .setMaterializedQty(100)
     .setEngineLatencyMicros(totalNanos / 1000)
     .setShard(0)
     .build()

10. Responde al cliente (callback):
    
    event.responseObserver.onNext(response)
    event.responseObserver.onCompleted()
    
    ╔═════════════════════════════════════════════════════════════╗
    ║ Cliente recibe respuesta gRPC (fin de submitOrder)          ║
    ║ t_client_end = System.currentTimeMillis()                   ║
    ║ latencia_total = t_client_end - t_client_start              ║
    ╚═════════════════════════════════════════════════════════════╝

11. [Si JOURNAL != OFF] JournalHandler escribe:
    
    serialized = protobuf.toByteArray(event)
    channel.write(serialized)
    eventsSinceFsync++
    
    if (eventsSinceFsync % 10 == 0) {
      channel.force(false)  // Fsync a disco
    }


FASE 3: LIMPIEZA
═══════════════════════════════════════════════════════════════

12. CleanupHandler vacía casilla:
    
    event.symbol = null
    event.responseObserver = null
    // Disruptor reutiliza casilla en siguiente vuelta


FASE 4: OBSERVABILIDAD (Cada 10 segundos)
═══════════════════════════════════════════════════════════════

13. MetricsReporter extrae percentiles:
    
    p50 = windowHistogram.getValueAtPercentile(50.0)
    p95 = windowHistogram.getValueAtPercentile(95.0)
    p99 = windowHistogram.getValueAtPercentile(99.0)
    
    logger.info("VENTANA: p95={} µs", p95)
    
    windowHistogram.reset()  // Para siguiente ventana


FASE 5: APAGADO
═══════════════════════════════════════════════════════════════

14. Al recibir SIGTERM:
    
    logger.info("ACUMULADO: p95={} µs", 
      accumulatedHistogram.getValueAtPercentile(95.0))
    
    disruptor.shutdown()
    server.shutdown()
```

---

## Patrones de Diseño

### 1. LMAX Disruptor (Patrón de Concurrencia)

```
Ventaja: Latencia ultrabajaalta y predecible sin locks

[gRPC-1] \
[gRPC-2] →→ Ring Buffer → [MatchingHandler] → [Cleanup]
[gRPC-3] /   (ProducerType.MULTI)
         ↓
    [JournalHandler] (si PARALELO)

Mecánica:
├─ Productores (gRPC threads): publican eventos en ringBuffer con tryNext()
├─ Ring buffer: 16384 casillas circulares, reutilizadas, sin malloc/free
├─ Consumidor (MatchingHandler): lee secuencialmente, sin locks
└─ Sincronización: CAS (Compare-And-Swap) en publish(), memory barriers

Sin locks porque:
├─ Ring buffer es cola FIFO
├─ Solo MatchingHandler modifica OrderBooks
├─ Visibilidad: publish() es memory barrier
└─ Sin race conditions por construcción
```

### 2. Single Writer (Patrón de Seguridad)

```
Garantía: No hay race conditions porque solo un thread escribe

books = HashMap<String, OrderBook>
         └─ Solo MatchingHandler la modifica
            └─ Otros threads solo leen (pasivamente)

Ventaja:
├─ No necesita synchronized HashMap
├─ No necesita lock
├─ No hay contención
└─ No hay deadlock

Invariante:
├─ Si dos threads leen books[symbol] simultáneamente: OK
│  (MatchingHandler está escribiendo orderbook[symbol].asks)
├─ MatchingHandler escribe en books[symbol]
├─ Pero gRPC threads solo LEEN ringBuffer
└─ Desacoplamiento total
```

### 3. Ring Buffer Circular (Gestión de Memoria)

```
Ventaja: Preasignación sin garbage collection

Antes (LinkedList):
  Enqueue → new Node()    ← Malloc + GC pause
  Dequeue → null reference ← GC marca para colección
  
Con Ring Buffer:
  ringSize = 16384
  Crear: new OrderEvent[16384]  (una sola vez al startup)
  Usar:  event[sequence % ringSize]
  Reutilizar: next sequence sobrescribe casilla anterior
  
  ├─ Sin malloc en ruta crítica
  ├─ Sin GC en ruta crítica
  ├─ Latencia predecible
  └─ CPU cache friendly (array contiguo en memoria)
```

### 4. Price-Time Priority (Matching Algorithm)

```
Prioridad de ejecución:
├─ Precio (PRIMARY): mejor precio primero
└─ Tiempo (SECONDARY): orden de llegada dentro del precio

Ejemplo:

Libro:
  asks = [
    10040: [Order-A(qty=50, t=98), Order-B(qty=100, t=99)],
    10050: [Order-C(qty=200, t=100)],
  ]

Orden entrante: BID 150 @ 10050

Matching:
├─ Busca asks ≤ 10050 (desde menor precio)
├─ Encuentra 10040 → cumple
│  ├─ Toma Order-A (t=98, llegó primero): cruza 50
│  ├─ Toma Order-B (t=99, llegó segundo): cruza 100
│  └─ remainingQty = 0, terminó
├─ Resultado: 150 ejecutadas, MATCHED
└─ Órdenes no ejecutadas: reste en book

Garantía: Evita starvation, trata equitativamente por tiempo
```

---

## Medición y Observabilidad

### HdrHistogram: Por Qué Dos Niveles

```
Problema: Percentiles por ventana vs. población entera

Opción 1: Solo ventanas (10s)
  mediana(p95_ventana1, p95_ventana2, ...) ≠ p95_población
  └─ Oculta variabilidad entre ventanas

Opción 2: Solo acumulado
  └─ No vemos evolución en tiempo real

Solución: Dual-level

  Ventana (10s)  ─────────────────────────
  ├─ p50, p95, p99 cambian cada 10s
  ├─ Muestra evolución en tiempo real
  ├─ Detecta degradación rápidamente
  └─ Se resetea para siguiente ventana

  Acumulado (nunca resetea)
  ├─ p50, p95, p99 de TODA la fase
  ├─ Publicado al apagado
  ├─ Usado para validar hipótesis
  └─ Base para informes finales
```

### Descomposición de Latencia

```
Latencia total = Espera + Servicio

Espera (esperaHistogram)
├─ Mide: t_start - arrivalNanos
├─ Qué es: tiempo esperando en la cola del anillo
├─ Causa alta: anillo congestionado, mucho backlog
├─ Cura: agregar más shards (paralelismo)

Servicio (servicioHistogram)
├─ Mide: t_end - t_start
├─ Qué es: tiempo en matching + modelo de negocio
├─ Causa alta: BIZ_MICROS alto, muchas órdenes en el libro
├─ Cura: optimizar matching, reducir BIZ_MICROS

Ejemplo:
  p95_total = 32000 µs (32ms)
  p95_espera = 2000 µs (2ms)
  p95_servicio = 30000 µs (30ms)
  
  Interpretación: Cuello de botella es SERVICIO (matching + negocio)
                  Solución: reducir BIZ_MICROS o simplificar algoritmo
```

### Prometheus Metrics (Endpoint /metrics)

```
# HELP engine_latency_total Latencia total en microsegundos
# TYPE engine_latency_total histogram
engine_latency_total_bucket{shard="0",le="1000"} 100
engine_latency_total_bucket{shard="0",le="10000"} 5000
engine_latency_total_bucket{shard="0",le="100000"} 14200
engine_latency_total_bucket{shard="0",le="+Inf"} 14250

# HELP engine_wait_latency Latencia de espera en microsegundos
# TYPE engine_wait_latency histogram
engine_wait_latency_bucket{shard="0",le="100"} 10000
engine_wait_latency_bucket{shard="0",le="1000"} 13500
engine_wait_latency_bucket{shard="0",le="+Inf"} 14250

# HELP engine_orders_processed Órdenes procesadas
# TYPE engine_orders_processed counter
engine_orders_processed{shard="0"} 14250

# HELP engine_orders_rejected Órdenes rechazadas
# TYPE engine_orders_rejected counter
engine_orders_rejected{shard="0",reason="ring_full"} 50
engine_orders_rejected{shard="0",reason="validation"} 10

Prometheus raspa cada 10 segundos
├─ Grafana grafica en tablero en tiempo real
└─ Alertas: si orders_rejected_ring_full crece → escalable insuficiente
```

---

## Resumen Ejecutivo

### Tabla Comparativa

| Aspecto | Decisión | Razón | Impacto |
|---------|----------|-------|--------|
| **Patrón concurrencia** | LMAX Disruptor | Latencia baja sin locks | p95 ≈ 30ms |
| **Productores** | MULTI | Múltiples gRPC threads | Sin sincronización explícita |
| **Consumidor** | Único | MatchingHandler | Sin race conditions |
| **Ring buffer** | 16384 casillas | > QUEUE_CAPACITY_router | Colchón para picos |
| **Wait strategy** | BusySpinWaitStrategy | Sin sleep | CPU=100%, predecible |
| **Prioridad** | MAX_PRIORITY | Evita desalojo | Latencia consistente |
| **Matching** | PTP (Price-Time) | Best price first, FIFO | Justo, transparente |
| **Costo negocio** | CPU burn | Simula procesamiento | Modelado realista |
| **Distribuciones** | Mezcla + Lognormal | Misma media/varianza | Compara forma |
| **Durabilidad** | 3 modos | OFF/PARALELO/SERIE | Trade-off latencia vs. durabilidad |
| **Métricas** | Dual-level | Ventana + acumulado | Evolución + población entera |

---

## Lectura Adicional

- **LMAX Disruptor:** https://github.com/LMAX-Exchange/disruptor (whitepaper)
- **HdrHistogram:** https://github.com/HdrHistogram/HdrHistogram
- **gRPC Java:** https://grpc.io/docs/languages/java/
- **Protobuf:** https://developers.google.com/protocol-buffers
- **TreeMap complejidad:** O(log N), implementado como árbol rojo-negro
- **Coordinated Omission Problem:** Sesini "How Not to Measure Latency" (Phil Bagwell)
