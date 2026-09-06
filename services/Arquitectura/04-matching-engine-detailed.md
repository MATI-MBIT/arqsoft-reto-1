# Arquitectura Detallada: matching-engine

Documentación código-nivel del motor de emparejamiento. Explica la estructura, flujo de ejecución, patrones de concurrencia y medición.

---

## Índice

1. [Visión General](#visión-general)
2. [Estructura de Clases](#estructura-de-clases)
3. [Flujo de Ejecución](#flujo-de-ejecución)
4. [Patrones de Concurrencia](#patrones-de-concurrencia)
5. [Configuración](#configuración)
6. [Medición y Observabilidad](#medición-y-observabilidad)

---

## Visión General

El **matching-engine** es una partición independiente de un motor de emparejamiento de órdenes. Implementa el patrón LMAX Disruptor: un único hilo escritor que procesa eventos secuencialmente desde un anillo (ring buffer) sin bloqueos.

```
┌─────────────────────────────────────────────────────────────┐
│                     matching-engine                         │
│                                                             │
│  gRPC Input (puerto 9090)                                  │
│       ↓                                                     │
│  IngestGrpcService  [multithread, t0 timestamp]            │
│       ↓                                                     │
│  Disruptor Ring Buffer (16384 casillas)                    │
│       ↓                                                     │
│  MatchingHandler [ÚNICO ESCRITOR, sin locks]               │
│       ├─→ OrderBook (TreeMap + ArrayDeque)                 │
│       ├─→ BusinessLogicModel (costo por orden)             │
│       └─→ HdrHistogram (espera, servicio, total)           │
│       ↓                                                     │
│  JournalHandler [paralelo o serie, fsync por lote]         │
│       ↓                                                     │
│  Cleanup [vacía casillas para reciclado]                   │
│       ↓                                                     │
│  gRPC Response → Cliente                                   │
│                                                             │
│  /metrics (puerto 9095) → Prometheus                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Estructura de Clases

### 1. EngineMain

**Responsabilidad:** Inicialización del motor, construcción del Disruptor y cadena de consumidores.

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/EngineMain.java`

**Ciclo de vida:**

```java
public static void main(String[] args) {
  // 1. Lee variables de entorno
  String shardId = System.getenv("SHARD_ID");        // "0", "1", ...
  int port = Integer.parseInt(
      System.getenv("PORT") != null ? System.getenv("PORT") : "9090"
  );
  int ringSize = Integer.parseInt(
      System.getenv("RING_SIZE") != null ? System.getenv("RING_SIZE") : "16384"
  );
  
  // 2. Crea el Disruptor (ProducerType.MULTI: múltiples threads publican)
  Disruptor<OrderEvent> disruptor = 
    new Disruptor<>(
      OrderEvent::new,
      ringSize,          // Potencia de 2, mín 16384
      Executors.newFixedThreadPool(1, r -> {
        Thread t = new Thread(r, "MatchingHandler");
        t.setPriority(Thread.MAX_PRIORITY);  // Maximizar CPU
        return t;
      }),
      ProducerType.MULTI,  // gRPC puede publicar desde varios threads
      new BusySpinWaitStrategy()  // Sin sleeps, latencia mínima
    );
  
  // 3. Cablea los consumidores según JOURNAL mode
  if ("paralelo".equals(journalMode)) {
    // MatchingHandler y JournalHandler avanzan independientemente
    disruptor.handleEventsWith(matchingHandler)
            .then(cleanupHandler);
    disruptor.handleEventsWith(journalHandler);
  } else if ("serie".equals(journalMode)) {
    // JournalHandler → MatchingHandler → Cleanup (en orden)
    disruptor.handleEventsWith(journalHandler)
            .then(matchingHandler)
            .then(cleanupHandler);
  } else {
    // "off": solo MatchingHandler
    disruptor.handleEventsWith(matchingHandler)
            .then(cleanupHandler);
  }
  
  // 4. Inicia el anillo
  RingBuffer<OrderEvent> ringBuffer = disruptor.start();
  
  // 5. Publica punto de operación (logaritmo)
  logger.info("matching-engine shard={} escuchando gRPC en :{} (ring={})",
              shardId, port, ringSize);
  
  // 6. Levanta servidor gRPC
  Server server = ServerBuilder.forPort(port)
    .addService(new IngestGrpcService(ringBuffer))
    .addService(new MetricsService(histograms))
    .build()
    .start();
  
  // 7. Hilo de reporte cada 10 segundos
  Thread reporter = new Thread(() -> {
    while (!Thread.currentThread().isInterrupted()) {
      Thread.sleep(10_000);
      reportMetrics(histograms);  // Percentiles p50, p95, p99
    }
  }, "MetricsReporter");
  reporter.start();
  
  // 8. Espera a apagado (SIGTERM)
  server.awaitTermination();
  
  // 9. Publica ACUMULADO y cierra
  reportAccumulated(histograms);
  disruptor.shutdown();
}
```

**Decisiones arquitectónicas:**

- `ProducerType.MULTI`: Permite que múltiples threads gRPC publiquen sin sincronización explícita.
- `BusySpinWaitStrategy`: El escritor espera en un busy-loop (CPU = 100%, latencia mínima).
- `Thread.MAX_PRIORITY`: Asegura que el escritor no sea desalojado.
- Reporte cada 10 s: Ventanas lo suficientemente grandes para que los percentiles sean estables.

---

### 2. OrderEvent

**Responsabilidad:** Contenedor del evento (order) que circula en el anillo.

**Campos clave:**

```java
public class OrderEvent {
  public String symbol;           // "AAPL", "MSFT", ...
  public long price_cents;        // 12950 = $129.50
  public long quantity;           // 100
  public long arrivalNanos;       // t0: cuando entra al motor
  public Status status;           // MATCHED, PARTIALLY_MATCHED, RESTING
  public long materializedQty;    // Cuánto se ejecutó
  
  public long espera_micros;      // t_start - arrivalNanos
  public long servicio_micros;    // t_end - t_start
  
  // Para respuesta gRPC
  public MatchingResponse response;
}
```

**Ciclo de vida de una casilla:**

```
[EMPTY] → [PUBLISHED por IngestGrpcService]
       → [CLAIMED por MatchingHandler: comienza espera]
       → [SERVICED por MatchingHandler: comienza servicio]
       → [CLAIMED por JournalHandler (si paralelo)]
       → [EMPTIED por CleanupHandler: vuelve a EMPTY]
```

---

### 3. IngestGrpcService

**Responsabilidad:** Borde gRPC → anillo. Captura `t0` (timestamp de arribo) y publica el evento.

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/IngestGrpcService.java`

**Operación crítica:**

```java
@Override
public void submitOrder(SubmitOrderRequest req, StreamObserver<MatchingResponse> resp) {
  // t0: captura el timestamp de arribo al motor
  long t0 = System.nanoTime();
  
  try {
    // Intenta publicar en el anillo sin bloquear
    long sequence = ringBuffer.tryNext();
    
    if (sequence == -1) {
      // Anillo lleno: responde REJECTED inmediato
      MatchingResponse response = MatchingResponse.newBuilder()
        .setStatus(Status.REJECTED)
        .setReason("RING_FULL")
        .build();
      resp.onNext(response);
      resp.onCompleted();
      recordRejection("ring_full");
      return;
    }
    
    try {
      // Publica el evento con t0
      OrderEvent event = ringBuffer.get(sequence);
      event.symbol = req.getSymbol();
      event.price_cents = req.getPriceCents();
      event.quantity = req.getQuantity();
      event.arrivalNanos = t0;  // ← Marca de tiempo
      event.responseObserver = resp;  // Respuesta asincrónica
    } finally {
      ringBuffer.publish(sequence);  // Hace el evento visible al escritor
    }
  } catch (Exception e) {
    logger.error("Error en ingesta", e);
    resp.onError(e);
  }
}
```

**Características:**

- `t0 = System.nanoTime()`: Marca nanosegundos (resolución máxima en JVM).
- `tryNext()`: No bloquea si el anillo está lleno; devuelve -1.
- `ringBuffer.publish()`: Hace el evento visible al escritor (memory barrier).
- Respuesta asincrónica: El cliente espera mientras MatchingHandler procesa.

---

### 4. MatchingHandler

**Responsabilidad:** ÚNICO ESCRITOR. Procesa eventos secuencialmente: consulta el libro de órdenes, ejecuta el cruce y actualiza histogramas.

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/MatchingHandler.java`

**Estructura:**

```java
public class MatchingHandler implements EventHandler<OrderEvent> {
  private final Map<String, OrderBook> books;  // Un libro por símbolo
  private final HdrHistogram histogram;        // Latencia total
  private final HdrHistogram esperaHistogram;  // Espera en anillo
  private final BusinessLogicModel bizModel;
  
  @Override
  public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
    // 1. Captura t_start (antes de servicio)
    long t_start = System.nanoTime();
    long espera_nanos = t_start - event.arrivalNanos;
    
    // 2. Obtén o crea el OrderBook del símbolo
    OrderBook book = books.computeIfAbsent(
      event.symbol,
      k -> new OrderBook()
    );
    
    // 3. Ejecuta el cruce de órdenes (sin locks, única lectura/escritura)
    MatchResult result = book.match(
      event.symbol,
      event.price_cents,
      event.quantity,
      event.isBid()
    );
    event.materializedQty = result.executedQty;
    event.status = result.status;  // MATCHED, PARTIALLY_MATCHED, RESTING
    
    // 4. Aplica modelo de negocio (costo de CPU por orden)
    long costMicros = bizModel.costForOrder(event.quantity);
    cpuBurn(costMicros);  // Consume CPU para simular trabajo
    
    // 5. Captura t_end y registra tiempos
    long t_end = System.nanoTime();
    long servicio_nanos = t_end - t_start;
    long total_nanos = t_end - event.arrivalNanos;
    
    // Convierte a microsegundos (µs)
    event.espera_micros = espera_nanos / 1000;
    event.servicio_micros = servicio_nanos / 1000;
    
    // 6. Registra en histogramas
    histogram.recordValue(total_nanos / 1000);     // total en µs
    esperaHistogram.recordValue(espera_nanos / 1000);
    
    // 7. Construye respuesta gRPC
    MatchingResponse response = MatchingResponse.newBuilder()
      .setStatus(event.status)
      .setMaterializedQty(event.materializedQty)
      .setEngineLatencyMicros(event.espera_micros + event.servicio_micros)
      .setShard(shardId)
      .build();
    
    // 8. Envía respuesta al cliente (callback)
    event.responseObserver.onNext(response);
    event.responseObserver.onCompleted();
  }
  
  private void cpuBurn(long targetMicros) {
    long startNanos = System.nanoTime();
    long targetNanos = targetMicros * 1000;
    
    // Busy-loop: consume CPU hasta alcanzar el costo objetivo
    while (System.nanoTime() - startNanos < targetNanos) {
      // CPU intenso: cálculo trivial que no se optimiza
      Math.sqrt(Math.random() * Math.random());
    }
  }
}
```

**Garantías de seguridad:**

- **Único escritor:** Solo este thread modifica `books` y `histogram`.
- **Sin locks:** `books.computeIfAbsent()` es thread-safe porque solo se llama desde aquí.
- **No modifica event:** Los tiempos se copian a campos que lee JournalHandler, pero no modifica la casilla después de `onEvent()` completar.

---

### 5. OrderBook

**Responsabilidad:** Libro de órdenes en memoria. Mantiene bids (compra) y asks (venta) por precio, FIFO dentro de cada nivel.

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/OrderBook.java`

**Estructura:**

```java
public class OrderBook {
  // Bids: precio DESCENDENTE (mayor precio primero)
  private final TreeMap<Long, ArrayDeque<OrderLevel>> bids = 
    new TreeMap<>(Comparator.reverseOrder());
  
  // Asks: precio ASCENDENTE (menor precio primero)
  private final TreeMap<Long, ArrayDeque<OrderLevel>> asks = 
    new TreeMap<>();
  
  public MatchResult match(String symbol, long price, long qty, boolean isBid) {
    long executedQty = 0;
    long remainingQty = qty;
    
    if (isBid) {
      // Orden de compra: busca asks que cumplen (precio ≤ price)
      var it = asks.entrySet().iterator();
      
      while (it.hasNext() && remainingQty > 0) {
        Map.Entry<Long, ArrayDeque<OrderLevel>> entry = it.next();
        long askPrice = entry.getKey();
        
        if (askPrice > price) break;  // Ningún ask más cumple
        
        ArrayDeque<OrderLevel> levels = entry.getValue();
        while (!levels.isEmpty() && remainingQty > 0) {
          OrderLevel level = levels.peek();
          long crossQty = Math.min(remainingQty, level.qty);
          
          executedQty += crossQty;
          remainingQty -= crossQty;
          level.qty -= crossQty;
          
          if (level.qty == 0) levels.poll();  // FIFO: extrae cuando vacío
        }
        
        if (levels.isEmpty()) it.remove();
      }
      
      // Si quedan órdenes sin ejecutar, reposa en bids
      if (remainingQty > 0) {
        bids.computeIfAbsent(price, k -> new ArrayDeque<>())
            .offer(new OrderLevel(symbol, remainingQty));
      }
    } else {
      // Orden de venta: análogo con bids
      // ... (simetría invertida)
    }
    
    return new MatchResult(
      executedQty,
      remainingQty == 0 ? Status.MATCHED : Status.PARTIALLY_MATCHED
    );
  }
}

record OrderLevel(String symbol, long qty) { }
```

**Invariantes:**

- **TreeMap ordena por precio:** bids descendent, asks ascendente.
- **ArrayDeque mantiene FIFO:** Primera en entrar, primera en salir dentro del precio.
- **Sin threads múltiples:** Solo el escritor accede, sin candados.

---

### 6. BusinessLogicModel

**Responsabilidad:** Simula el costo de procesamiento de una orden (consumo de CPU).

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/BusinessLogicModel.java`

**Modelos de distribución:**

```java
public class BusinessLogicModel {
  private final String distributionShape;  // "mezcla" o "lognormal"
  private final long meanMicros;           // Media de la distribución
  private final Random random;
  
  public long costForOrder(long quantity) {
    if (meanMicros == 0) return 0;  // Desactivado
    
    if ("mezcla".equals(distributionShape)) {
      return costMezcla();
    } else if ("lognormal".equals(distributionShape)) {
      return costLognormal();
    }
    return meanMicros;
  }
  
  private long costMezcla() {
    // Distribución discreta: 90% × 1×mean, 9% × 6×mean, 1% × 30×mean
    double r = random.nextDouble();
    
    if (r < 0.90) {
      return meanMicros;  // 90% de las órdenes cuestan mean
    } else if (r < 0.99) {
      return meanMicros * 6;  // 9% cuestan 6×mean
    } else {
      return meanMicros * 30;  // 1% cuestan 30×mean
    }
  }
  
  private long costLognormal() {
    // Distribución continua sin cota (modelada con Box-Muller)
    double u1 = random.nextDouble();
    double u2 = random.nextDouble();
    double z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
    
    // Transforma a lognormal: exp(µ + σ×z)
    double mu = Math.log(meanMicros);  // Parámetro log-space
    double sigma = 1.2;  // Desviación estándar log-space
    
    return Math.round(Math.exp(mu + sigma * z));
  }
}
```

**Parámetros:**

| Parámetro | Mezcla | Lognormal |
|-----------|--------|-----------|
| Media | 8000 µs | 8000 µs |
| Cs² (coef. variación²) | 3.34 | 3.34 |
| Forma | 3 clases discretas | Continua, sin cota |

Ambas tienen la misma media y varianza para que la comparación aísle el efecto de la forma.

---

### 7. JournalHandler

**Responsabilidad:** Bitácora de solo-anexado. Persiste órdenes en un archivo para durabilidad o auditoría.

**Ubicación:** `services/matching-engine/src/main/java/co/mati/engine/JournalHandler.java`

**Modos de operación:**

```java
public class JournalHandler implements EventHandler<OrderEvent> {
  private final JournalMode mode;  // OFF, PARALELO, SERIE
  private final FileChannel channel;  // Archivo de bitácora
  private final int batchSize;  // Fsync cada N eventos
  private int eventsSinceFsync = 0;
  
  @Override
  public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
    if (mode == JournalMode.OFF) return;
    
    // Serializa el evento a bytes (protobuf)
    byte[] record = serializeEvent(event);
    
    // Escribe en buffer (sin fsync aún)
    channel.write(ByteBuffer.wrap(record));
    eventsSinceFsync++;
    
    // Fsync una vez al lote (cada 10 eventos)
    if (endOfBatch || eventsSinceFsync >= batchSize) {
      channel.force(false);  // Fsync a disco
      eventsSinceFsync = 0;
    }
  }
}
```

**Modos:**

| Modo | Descripción | Latencia Cliente | Durabilidad | Ubicación en Cadena |
|------|-------------|-----------------|-------------|-------------------|
| `OFF` | Desactivado | No afectada | ❌ | N/A |
| `PARALELO` | Consumidor paralelo al cruce | No afectada | ✓ (eventual) | Paralelo a MatchingHandler |
| `SERIE` | Encadenado antes del cruce | ✓ Afectada (fsync en camino crítico) | ✓ (inmediata) | Antes de MatchingHandler |

---

### 8. MetricsHandler (Limpeza)

**Responsabilidad:** Vacía la casilla después de que todos los consumidores pasaron.

```java
public class CleanupHandler implements EventHandler<OrderEvent> {
  @Override
  public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
    // Limpia la casilla para que pueda reciclarse
    event.symbol = null;
    event.responseObserver = null;
    // Disruptor reutiliza la casilla en la siguiente vuelta
  }
}
```

**¿Por qué aquí y no en el escritor?**

Cuando hay dos consumidores en paralelo (MatchingHandler + JournalHandler), **ninguno puede modificar el evento** hasta que ambos pasaron. El Disruptor garantiza que CleanupHandler solo corre después de que todos los consumidores anteriores completaron.

---

## Flujo de Ejecución

Viaje completo de una orden:

```
1. Cliente (k6) emite gRPC submitOrder(symbol="AAPL", price=12950, qty=100)
   └─ Timestamp externo: t_client_start

2. Router (ingest-router)
   ├─ Semaphore.tryAcquire()  [fila con límite]
   └─ Reenvía a shard según hash(symbol)

3. IngestGrpcService.submitOrder()
   ├─ t0 = System.nanoTime()  [arribo al motor]
   ├─ ringBuffer.tryNext()    [no bloquea si lleno]
   └─ ringBuffer.publish()    [hace visible el evento]

4. MatchingHandler.onEvent()  [ÚNICO ESCRITOR, sin locks]
   ├─ t_start = System.nanoTime()
   ├─ espera = t_start - t0
   ├─ OrderBook.match()  [TreeMap + ArrayDeque]
   │  ├─ Busca asks/bids que cumplen el precio
   │  └─ Actualiza cantidades (FIFO dentro de precio)
   ├─ BusinessLogicModel.cpuBurn()  [simula costo]
   ├─ t_end = System.nanoTime()
   ├─ servicio = t_end - t_start
   ├─ HdrHistogram.recordValue()
   └─ response.onNext(MatchingResponse)  [callback]

5. JournalHandler.onEvent()  [paralelo o serie]
   ├─ Serializa evento
   └─ channel.write() + fsync por lote

6. CleanupHandler.onEvent()
   └─ event.clear()  [recicla la casilla]

7. Cliente recibe MatchingResponse
   └─ Timestamp externo: t_client_end
       latencia_total = t_client_end - t_client_start
```

---

## Patrones de Concurrencia

### LMAX Disruptor Pattern

```
[gRPC Thread 1] \
[gRPC Thread 2] →→ Ring Buffer → [MatchingHandler]  →  [Cleanup]
[gRPC Thread 3] /        (ProducerType.MULTI)      (single writer)
                     ↓
                [JournalHandler] (si PARALELO)
```

**Ventajas:**

1. **Sin locks:** El escritor solo modifica su propia estructura de datos.
2. **CPU affinity:** El escritor corre en un thread dedicado, nunca desalojado.
3. **Latencia predecible:** No hay garbage collection en el camino crítico (preasignación).
4. **High throughput:** Desacoplamiento productor-consumidor con cola acotada.

**Desventajas:**

- CPU at 100% (busy-wait strategy).
- Solo un shard puede escribir; escalabilidad = particionamiento.

---

## Configuración

**Variables de entorno:**

| Variable | Servicio | Default | Significado |
|----------|---------|---------|-----------|
| `SHARD_ID` | motor | 0 | ID de esta partición (0, 1, 2, 3) |
| `PORT` | motor | 9090 | Puerto gRPC |
| `RING_SIZE` | motor | 16384 | Tamaño ring buffer (potencia de 2). Derivado: 2^14 = 16384 es la menor potencia de 2 > QUEUE_CAPACITY_router(10000). Colchón ~6384 casillas absorbe picos sin rechazos locales |
| `METRICS_PORT` | motor | 9095 | Puerto endpoint /metrics |
| `BIZ_MICROS` | motor | 0 (apagado) | Costo MEDIO por orden (µs) |
| `BIZ_DIST` | motor | mezcla | Forma distribución (mezcla\|lognormal) |
| `JOURNAL` | motor | off | Modo journaling (off\|paralelo\|serie) |
| `JOURNAL_DIR` | motor | /var/lib/engine/journal | Directorio bitácoras |
| `RUN_ID` | motor | sin-id | ID de la corrida (para métricas) |

**Ejemplo en Docker Compose:**

```yaml
services:
  matching-shard-0:
    image: arqsoft-reto-1-matching-shard:latest
    ports:
      - "9090:9090"
      - "9095:9095"
    environment:
      SHARD_ID: "0"
      RING_SIZE: "16384"
      BIZ_MICROS: "8000"
      BIZ_DIST: "mezcla"
      JOURNAL: "paralelo"
      JAVA_OPTS: "-XX:+UseZGC -XX:+ZGenerational -Xms256m -Xmx512m"
    volumes:
      - journal-0:/var/lib/engine/journal
```

---

## Medición y Observabilidad

### HdrHistogram: Dual-Level

El motor mide en **dos niveles**:

1. **Ventana de 10 segundos:** Histogram que se resetea cada 10 s (útil para ver evolución en tiempo real).
2. **Acumulado:** Histogram global que acumula todas las ventanas (usado para percentiles finales).

```java
private void reportMetrics(HdrHistogram windowHistogram) {
  long p50 = windowHistogram.getValueAtPercentile(50.0);
  long p95 = windowHistogram.getValueAtPercentile(95.0);
  long p99 = windowHistogram.getValueAtPercentile(99.0);
  
  logger.info(
    "VENTANA: p50={} µs, p95={} µs, p99={} µs",
    p50, p95, p99
  );
  
  // Resets la ventana para la próxima
  windowHistogram.reset();
}

private void reportAccumulated() {
  long p50 = accumulatedHistogram.getValueAtPercentile(50.0);
  long p95 = accumulatedHistogram.getValueAtPercentile(95.0);
  long p99 = accumulatedHistogram.getValueAtPercentile(99.0);
  
  logger.info(
    "ACUMULADO: p50={} µs, p95={} µs, p99={} µs",
    p50, p95, p99
  );
}
```

### Descomposición de Latencia

```
Latencia total = Espera + Servicio

  Espera (esperaHistogram):     t_start - t0
  └─ Tiempo en la cola del anillo (cuándo tarda en ser procesado)
  
  Servicio (servicioHistogram): t_end - t_start
  └─ Tiempo de ejecución (cruce + modelo de negocio)
```

**Interpretación:**

- **Espera alta:** El anillo está congestionado, hay backlog.
- **Servicio alta:** El modelo de negocio es costoso (BIZ_MICROS grande).

### Prometheus Metrics

```
# HELP engine_latency_total Latencia total (µs)
# TYPE engine_latency_total histogram
engine_latency_total_bucket{shard="0",le="1000"} 100
engine_latency_total_bucket{shard="0",le="10000"} 5000
...

# HELP engine_wait_latency Latencia de espera (µs)
# TYPE engine_wait_latency histogram
engine_wait_latency_bucket{shard="0",le="100"} 200
...
```

Prometheus raspa cada 10 segundos. Grafana grafica estas métricas en tiempo real.

---

## Logs Representativos

### Arranque

```
[main] INFO EngineMain - matching-engine shard=0 escuchando gRPC en :9090 (ring=16384)
[main] INFO EngineMain - BIZ_MICROS=8000, BIZ_DIST=mezcla
[main] INFO EngineMain - JOURNAL=paralelo
[main] INFO EngineMain - Disruptor iniciado con BusySpinWaitStrategy
```

### Operación

```
[MetricsReporter] INFO EngineMain - VENTANA (10s) [shard=0]:
  p50=1234 µs, p95=27743 µs, p99=89234 µs
  espera_p95=1837 µs, servicio_p95=25906 µs
  órdenes=14281, rechazos=0

[gRPC-NIO] WARN IngestGrpcService - Rechazo: RING_FULL (sequence=-1)
```

### Apagado

```
[main] INFO EngineMain - Apagando el motor...
[main] INFO EngineMain - ACUMULADO [shard=0]:
  p50=1100 µs, p95=28500 µs, p99=90000 µs
  total_órdenes=143250, total_rechazos=12
[main] INFO EngineMain - Disruptor shutdown completado
```

---

## Resumen

| Aspecto | Decisión |
|---------|----------|
| **Patrón** | LMAX Disruptor (único escritor, sin locks) |
| **Concurrencia** | ProducerType.MULTI → RingBuffer → MatchingHandler |
| **Ring Buffer** | 16384 casillas (2^14, > QUEUE_CAPACITY_router) |
| **Wait Strategy** | BusySpinWaitStrategy (latencia mínima, CPU=100%) |
| **Almacenamiento** | HashMap de OrderBooks + TreeMap/ArrayDeque por precio |
| **Durabilidad** | JournalHandler (fsync por lote, OFF/PARALELO/SERIE) |
| **Medición** | HdrHistogram dual-level (ventana + acumulado) |
| **CPU Model** | BusinessLogicModel (mezcla discreta o lognormal) |

El diseño prioriza **latencia baja y predecible** sobre throughput máximo, típico de trading/clearing systems donde el 95to percentil importa más que el promedio.
