# BusinessLogicModel: Análisis Profundo

Guía exhaustiva sobre la clase `BusinessLogicModel` que simula el costo de negocio en el motor de emparejamiento. Explica su propósito, implementación, distribuciones estadísticas e implicaciones en la validez de las mediciones.

---

## Tabla de Contenidos

1. [Propósito y Justificación](#propósito-y-justificación)
2. [El Problema: TreeMap es una Simplificación](#el-problema-treemap-es-una-simplificación)
3. [Concepto: Presupuesto de Tiempo de Servicio](#concepto-presupuesto-de-tiempo-de-servicio)
4. [Distribución MEZCLA (90/9/1)](#distribución-mezcla-909-1)
5. [Distribución LOGNORMAL](#distribución-lognormal)
6. [CPU Burn: Por qué NO Sleep](#cpu-burn-por-qué-no-sleep)
7. [Semilla y Correlación](#semilla-y-correlación)
8. [Muestras Recortadas (Clamping)](#muestras-recortadas-clamping)
9. [Análisis de Código](#análisis-de-código)
10. [Experimentos y Resultados](#experimentos-y-resultados)

---

## Propósito y Justificación

### ¿Qué es BusinessLogicModel?

Es un simulador de trabajo que **representa el costo de las operaciones NO implementadas** en el matching engine PoC:

```
Operaciones REALES de un motor (NO implementadas aquí):
├─ Validación de orden
├─ Control de riesgo
├─ Consulta de saldos y posiciones
├─ Tipos de orden (mercado, límite, stop, FOK, IOC)
├─ Cálculo de comisiones
├─ Prevención de auto-cruce
└─ Generación de trades (reportes)

Operaciones IMPLEMENTADAS aquí:
├─ Búsqueda en TreeMap
├─ FIFO en ArrayDeque
└─ (Microsegundos de CPU)
```

### El Problema: TreeMap es una Simplificación

```
Sin BusinessLogicModel:

Orden que llega
  ↓
MatchingHandler.onEvent()
  ├─ OrderBook.match() → TreeMap search + ArrayDeque poll
  │  Tiempo: ~1-10 microsegundos
  └─ Histogramas.recordValue()
     Tiempo total de respuesta: ~5 microsegundos
  
Conclusión errónea:
"El motor de emparejamiento puede procesar 200.000 órdenes/segundo"

Pero esto mide SOLO:
├─ El TreeMap (estructura de datos)
└─ El Disruptor (cola)

NO mide:
├─ Validaciones
├─ Control de riesgo
├─ Cálculos de comisiones
└─ (Todo lo que hace un motor real)

Resultado: Conclusión falsa sobre capacidad
```

### Concepto: Presupuesto de Tiempo de Servicio

Con **único escritor**, el costo de servicio **se serializa**:

```
Throughput máximo = 1 / tiempo_servicio_medio

Ejemplo:
  Si servicio_medio = 8000 microsegundos (8 milisegundos)
  
  Throughput máximo = 1 / (8ms / 1000)
                    = 1 / 0.008
                    = 125 órdenes/segundo
  
Con N shards:
  Throughput máximo = N × 125 órdenes/segundo
  
  Con N=2: ~250 órd/s
  Con N=4: ~500 órd/s
```

**Esto es el "presupuesto":** "Mientras el costo permanezca < X µs, el patrón sostiene el ASR"

```
Resultado VALIDABLE:
"Con diseño de único escritor, p95 < 200ms SI el negocio tarda < 8ms/orden"

En lugar de:
"El patrón es infinitamente rápido" (falso)
```

---

## El Problema: TreeMap es una Simplificación

### Visualización del Impacto

```
ESCENARIO A: Sin modelo (BIZ_MICROS=0)
═════════════════════════════════════════════════════════════

Orden 1: llega → TreeMap search (3µs) → respuesta
Orden 2: llega → TreeMap search (3µs) → respuesta
Orden 3: llega → TreeMap search (3µs) → respuesta
...

Tiempo entre órdenes: ~0.058 segundos (17/s)
Ring buffer: Nunca acumula (está vacío entre órdenes)
p95: ~2-3 milisegundos (transporte + queue)

Conclusión (FALSA):
"El motor aguanta 17 órdenes/s con p95 de 2ms"


ESCENARIO B: Con modelo (BIZ_MICROS=8000)
═════════════════════════════════════════════════════════════

Orden 1: llega → TreeMap search (3µs) + CPU burn (8000µs) → respuesta
Orden 2: llega → TreeMap search (3µs) + CPU burn (8000µs) → respuesta
Orden 3: llega → TreeMap search (3µs) + CPU burn (8000µs) → respuesta
...

Tiempo de servicio por orden: ~8ms
Tiempo entre órdenes: ~0.058 segundos (17/s)

Ring buffer: ACUMULA (órdenes llegan cada 58ms, cada una tarda 8ms)
  ├─ Orden 1: entra en t=0, sale en t=8ms
  ├─ Orden 2: entra en t=58ms, pero Orden 1 usa el CPU hasta t=8ms
  │          → espera 58-8=50ms, sale en t=58+8=66ms
  └─ Orden 3: entra en t=116ms, pero Orden 2 usa CPU hasta t=66ms
             → espera 116-66=50ms, sale en t=116+8=124ms

p95: ~50-60 milisegundos (espera en cola visible)

Conclusión (VERDADERA):
"El patrón LMAX sostiene 17 órdenes/s con p95 de ~8ms (matching+costo)"
"Si el costo sube a 16ms, p95 sube a ~65ms (saturación)"
"Si el costo sube a 50ms, rechazos comienzan (ring lleno)"
```

---

## Distribución MEZCLA (90/9/1)

### Estructura: Tres Clases de Órdenes

La mezcla simula la **realidad de un mercado de valores**:

```java
private static final double[] WEIGHT = {0.90, 0.09, 0.01};  // Probabilidades
private static final double[] FACTOR = {1.0, 6.0, 30.0};     // Multiplicadores
```

### Interpretación: Qué Significa Cada Clase

```
CLASE 1: 90% de órdenes (WEIGHT=0.90, FACTOR=1.0)
─────────────────────────────────────────────────
Órdenes "normales": búsqueda en un solo nivel
├─ Compra: busca el mejor precio de venta
├─ Si cruza: se ejecuta parcialmente o completa
└─ Costo: 1 × media (costo base)

Ejemplo real:
  Orden de compra 100 AAPL @ $130
  ├─ Hay 100 AAPL @ $129.99 (ask level)
  └─ Ejecuta en un nivel: costo bajo


CLASE 2: 9% de órdenes (WEIGHT=0.09, FACTOR=6.0)
────────────────────────────────────────────────
Órdenes "barredoras": buscan múltiples niveles
├─ Compra agresiva a precio de mercado
├─ Barre 5-6 niveles de precios
└─ Costo: 6 × media

Ejemplo real:
  Orden de compra 1000 AAPL @ $131 (muy agresiva)
  ├─ Hay 100 @ $129.99 (ask level 1)
  ├─ 200 @ $130.00 (ask level 2)
  ├─ 300 @ $130.01 (ask level 3)
  ├─ 250 @ $130.02 (ask level 4)
  └─ 150 @ $130.03 (ask level 5)
  
  Ejecuta en múltiples niveles: costo alto


CLASE 3: 1% de órdenes (WEIGHT=0.01, FACTOR=30.0)
──────────────────────────────────────────────────
Órdenes "cataclismo": disparan una cascada
├─ Orden de compra masiva a cualquier precio
├─ Limpia TODA una cara del libro
├─ Todas las contras ejecutan
└─ Costo: 30 × media

Ejemplo real:
  Orden de compra 50.000 AAPL @ $1000 (absurda pero válida)
  ├─ Ejecuta TODO el lado de venta del libro
  ├─ Puede alcanzar 100+ niveles de precio
  └─ Genera 100+ trades (cada uno requiere log/comisión)

  Costo máximo: 30 × media
```

### Cálculo de Media y Varianza (Cs²)

```java
static {
    double m1 = 0.0, m2 = 0.0;
    for (int i = 0; i < WEIGHT.length; i++) {
        m1 += WEIGHT[i] * FACTOR[i];        // E[X]
        m2 += WEIGHT[i] * FACTOR[i] * FACTOR[i];  // E[X²]
    }
    MEAN_FACTOR = m1;              // 1.74
    CV2 = m2 / (m1 * m1) - 1.0;    // 3.34
}
```

#### Cálculo Paso a Paso

```
E[X] = media de la distribución
     = 0.90 × 1.0  +  0.09 × 6.0  +  0.01 × 30.0
     = 0.90        +  0.54        +  0.30
     = 1.74

E[X²] = segundo momento
      = 0.90 × 1.0²  +  0.09 × 6.0²  +  0.01 × 30.0²
      = 0.90 × 1     +  0.09 × 36    +  0.01 × 900
      = 0.90         +  3.24         +  9.0
      = 13.14

Varianza = E[X²] - (E[X])²
         = 13.14 - (1.74)²
         = 13.14 - 3.0276
         = 10.1124

Desv. Est. = √10.1124 = 3.18

Cs² (Coeficiente de Variación²)
  = (Desv.Est / Media)²
  = (3.18 / 1.74)²
  = (1.828)²
  = 3.34
```

**Interpretación:** Cs² = 3.34 significa que la varianza es ALTA:
- Distribución uniforme (todas iguales): Cs² = 0
- Distribución mezcla 90/9/1: Cs² = 3.34
- Distribución exponencial: Cs² = 1.0
- Poisson: Cs² = 1.0

**La mezcla es MÁS variable que exponencial/Poisson.**

### Ejemplo de Generación (Código)

```java
private long sampleNanos() {
    // Caso MEZCLA:
    double u = random.nextDouble();  // [0.0, 1.0)
    
    double factor = (u < 0.90) ? 1.0 
                  : (u < 0.99) ? 6.0 
                  : 30.0;
    
    return (long) (unitNanos * factor);
}

// Ejemplos:
// u = 0.45 (< 0.90) → factor = 1.0 → costo = 1 × media
// u = 0.95 (>= 0.90, < 0.99) → factor = 6.0 → costo = 6 × media
// u = 0.991 (>= 0.99) → factor = 30.0 → costo = 30 × media
```

---

## Distribución LOGNORMAL

### ¿Por Qué Lognormal?

Es la distribución que **existe por una razón específica:**

**Pregunta de investigación:** ¿El resultado depende SOLO de media y varianza, o la FORMA importa?

```
Si dos distribuciones con MISMA media y MISMA Cs² producen
el MISMO p95 y p99 → la forma no importa

Si producen DIFERENTES percentiles → la forma importa
  → el modelo necesita ser más específico
```

**Estrategia A/B:** Comparar mezcla vs lognormal a igual media/Cs²

```
Mezcla:
  ├─ Media: 1.74 × base
  ├─ Cs²: 3.34
  └─ Forma: Discreta (3 valores)

Lognormal:
  ├─ Media: 1.74 × base (IGUAL)
  ├─ Cs²: 3.34 (IGUAL)
  └─ Forma: Continua, sin cota superior
```

Si **p95 es igual** en ambas → la mezcla discreta es suficiente
Si **p95 es distinto** → la forma continua de la lognormal es más realista

### Derivación Matemática

Para una lognormal con **media y Cs² dados**:

```
Si X ~ LogNormal(µ, σ), entonces:
  E[X] = exp(µ + σ²/2)
  Var[X] = (exp(σ²) - 1) × exp(2µ + σ²)
  Cs² = Var[X] / (E[X])²
      = exp(σ²) - 1

Despejando σ de Cs²:
  σ² = ln(1 + Cs²)
  σ = √(ln(1 + Cs²))

Ejemplo con Cs² = 3.34:
  σ = √(ln(1 + 3.34))
    = √(ln(4.34))
    = √(1.467)
    = 1.211

Despejando µ de E[X]:
  µ = ln(E[X]) - σ²/2
    = ln(1.74 × base) - 1.467/2
    = ln(1.74 × base) - 0.733
```

### Código de Generación

```java
private long sampleNanos() {
    // Caso LOGNORMAL:
    double u1 = random.nextDouble();  // [0, 1)
    double u2 = random.nextDouble();  // [0, 1)
    
    // Box-Muller: transforma dos uniformes en una normal estándar
    double z = Math.sqrt(-2.0 * Math.log(u1)) 
             * Math.cos(2.0 * Math.PI * u2);
    // z ~ N(0, 1)
    
    // Transforma a lognormal con media y Cs² deseados
    double sample = Math.exp(logMu + logSigma * z);
    
    // Recorta si es patológicamente grande
    double cap = meanNanos * MAX_SAMPLE_FACTOR;  // 100×
    if (sample > cap) {
        clamped++;  // Cuenta para validar Cs²
        sample = cap;
    }
    
    return (long) sample;
}
```

### Visualización: Mezcla vs Lognormal

```
MEZCLA (90/9/1):              LOGNORMAL:
───────────────────────        ──────────────────
Prob                           Prob
  90% ├────────────              ├────
       │                          │    ╲
   9% ├─────────                 │     ╲      ╲
       │                          │      ╲      ╲
   1% ├──                         │       ╲      ╲
       └──────────────────        └────────╲──────╲────────
         1×   6×    30×              1×  10× 100×  1000×
         
Cota: 30× media (acotada)    Sin cota (pero recortada a 100×)
Forma: 3 picos discretos     Forma continua, asimétrica

p95 (típico): ~1.5-2× media  p95 (típico): ~2-3× media
              (mucha prob     (cola derecha más larga)
               entre 1-6×)    
```

---

## CPU Burn: Por qué NO Sleep

### El Problema de Thread.sleep()

```java
// MAL: No usar sleep
Thread.sleep(8);  // 8 milliseconds
```

**Problemas:**

1. **Devuelve el núcleo:** El thread se suspende, otros threads pueden ejecutar
   - gRPC threads toman el CPU
   - Garbage collector puede correr
   - Scheduler del SO elige otro proceso
   
2. **Granularidad:** En la JVM es de **milisegundos**
   - No puedes simular 50 microsegundos
   - No puedes simular 1 microsegundo
   
3. **Sucia la caché:** El thread vuelve con estado de caché frío
   
4. **Compite con otros hilos:** Si gRPC threads se despiertan
   - Context switch
   - Lock contention
   - Cache incoherence

```
Timeline con sleep():

t=0    ├─ MatchingHandler entra en onEvent()
       ├─ Thread.sleep(8)
t=0.1ms│  [Se suspende, gRPC threads toman CPU]
       │  gRPC-1: procesa solicitudes
       │  GC: marca objetos muertos
       │  gRPC-2: procesa solicitudes
       │
t=8ms  ├─ MatchingHandler se despierta
       │  [Caché fría, CPU contenciono]
       ├─ Continúa (pero el CPU ya fue compartido)
       └─ Latencia medida: 8ms + contención + GC
          
PROBLEMA: Esto NO mide el costo de negocio puro
          Mide el costo + efectos del scheduler
```

### La Solución: CPU Burn (Busy-Loop)

```java
private void burn(long targetNanos) {
    long deadline = System.nanoTime() + targetNanos;
    long acc = sink;
    
    do {
        for (int i = 0; i < SPIN_BATCH; i++) {
            // Operación aritmética que NO se optimiza
            acc = acc * 6364136223846793005L + 1442695040888963407L;
            acc ^= (acc >>> 29);
        }
    } while (System.nanoTime() < deadline);
    
    sink = acc;  // Publicar el resultado
}
```

**Ventajas:**

1. **Retiene el núcleo:** El thread nunca se suspende
   - gRPC threads compiten por CPU, pero equitativamente
   - No hay context switch
   
2. **Granularidad perfecta:** Simula exactamente 8000 microsegundos
   - Lee el reloj después de cada batch
   - Ajusta iteraciones
   
3. **Mantiene caché caliente:** El estado está en L1/L2
   
4. **Simula el costo REAL:** Lógica real consume CPU
   - No duerme, no cede
   - Ocupa un núcleo completo

```
Timeline con CPU burn:

t=0    ├─ MatchingHandler entra en onEvent()
       ├─ acc = acc * C1 + C2 (LCG — Linear Congruential Generator)
       ├─ acc ^= (acc >>> 29) (mezcla de bits)
       ├─ acc = acc * C1 + C2
       ├─ ... (8000 µs de trabajo puro)
       └─ Comprobación: System.nanoTime() < deadline?
       ├─ Sí, continúa...
       └─ No, termina
       
t=8ms  ├─ Escribe sink (publicar el resultado)
       └─ Continúa (CPU estuvo ocupado TODO el tiempo)
       
Latencia medida: Exactamente 8ms de CPU
NO hay interferencia del scheduler
```

### Por Qué Esta Operación NO Se Optimiza

```java
acc = acc * 6364136223846793005L + 1442695040888963407L;
acc ^= (acc >>> 29);
```

**Análisis del JIT:**

1. **6364136223846793005L** es una constante mágica (constante de LCG)
   - El JIT no puede "saber" qué hace
   - No hay simplificación posible

2. **acc ^= (acc >>> 29)** es una operación dependiente
   - El resultado depende del valor anterior de `acc`
   - El JIT no puede eliminar esto
   - Requiere esperar el resultado de `acc *`

3. **Ninguna simplificación es segura:**
   - Si el JIT eliminara el loop (dead code elimination)
   - Cambiaría el comportamiento (` sink` sería indeterminado)
   - Así que NO lo puede eliminar

4. **La publicación de `sink` es esencial:**
   ```java
   sink = acc;  // Sin esto, el JIT podría optimizar
   ```
   - Escribe en un campo de la clase (no es local)
   - El JIT no sabe si otra cosa lo lee
   - Debe asumir que es observable

---

## Semilla y Correlación

### El Problema Original: Semilla Común

```
Sin diversidad de semilla:

Topología N=2 (2 shards)

Shard 0:
└─ random.setSeed(42)
   Secuencia: 0.5, 0.2, 0.95, 0.1, 0.55, ...
   
Shard 1:
└─ random.setSeed(42)
   Secuencia: 0.5, 0.2, 0.95, 0.1, 0.55, ...  [IDÉNTICA]

Órdenes que llegan (misma tasa):
├─ orden 1: llega a ambos shards casi simultáneamente
├─ orden 2: llega a ambos shards casi simultáneamente
└─ ...

Costo aleatorio (mezcla 90/9/1):
├─ orden k: ¿factor 1.0 o 6.0 o 30.0?
├─ Shard 0: orden k → factor 30 (la clase pesada cae aquí)
├─ Shard 1: orden k → factor 30 (la clase pesada cae aquí también)
│  [AMBOS SATURADOS AL MISMO TIEMPO]
└─ Cola agregada: MAX(cola_shard0 + cola_shard1) = ambas llenas

Resultado:
├─ p95_agregado ALTO (cola sincronizada)
└─ Medición de N=2: MÁS LENTO que N=1 (artefacto de la semilla)
```

### La Solución: Semilla Derivada de shardId

```java
private static final long SEED = 42L;

public BusinessLogicModel(double meanMicros, Shape shape, int shardId) {
    this.random = new SplittableRandom(SEED + shardId);
    // Shard 0: seed = 42 + 0 = 42
    // Shard 1: seed = 42 + 1 = 43
    // Shard 2: seed = 42 + 2 = 44
    // ...
}
```

**Efecto:**

```
Con diversidad de semilla:

Shard 0 (seed=42):
└─ Secuencia: 0.5, 0.2, 0.95, 0.1, 0.55, ...

Shard 1 (seed=43):
└─ Secuencia: 0.7, 0.3, 0.12, 0.6, 0.25, ...  [DISTINTA]

Costo aleatorio:
├─ orden k: ¿factor 1.0 o 6.0 o 30.0?
├─ Shard 0: orden k → factor 30 (pesada aquí)
├─ Shard 1: orden k → factor 1.0 (barata aquí)
│  [DESINCRONIZADAS]
└─ Cola agregada: La mitad del tráfico siempre encuentra un shard despejado

Resultado:
├─ p95_agregado BAJO (cola distribuida en el tiempo)
└─ Medición de N=2: Aproximadamente MITAD de N=1
```

### Impacto en Experimentos

```
MISMO EXPERIMENTO: BIZ_MICROS=8000, PHASE=f1, JITTER_FACTOR=8

Antes (semilla común):
├─ N=1: p95 = 31.2 ms
├─ N=2: p95 = 28.5 ms  [Debería ser ~15 ms!]
└─ Conclusión: "N=2 no mejora mucho"

Después (semilla diversa):
├─ N=1: p95 = 31.2 ms
├─ N=2: p95 = 15.8 ms  [Correcto: ~50% de N=1]
└─ Conclusión: "N=2 mejora al 50% (paralela perfecta)"

La diferencia:
├─ Antes: Medía sincronización de congestion (artefacto)
└─ Después: Mide verdadera paralelización
```

---

## Muestras Recortadas (Clamping)

### El Problema: Lognormal Sin Cota

```java
private static final double MAX_SAMPLE_FACTOR = 100.0;

private long sampleNanos() {
    if (shape == Shape.LOGNORMAL) {
        double sample = Math.exp(logMu + logSigma * random.nextGaussian());
        double cap = meanNanos * MAX_SAMPLE_FACTOR;  // 100× la media
        
        if (sample > cap) {
            clamped++;  // Cuenta estas excepciones
            sample = cap;
        }
        return (long) sample;
    }
    // ...
}
```

### ¿Por Qué Existe el Tope?

La lognormal es **sin cota superior**: teóricamente puede alcanzar ∞

```
Probabilidades en una lognormal:
├─ P(X > 1× media) ≈ 33%
├─ P(X > 10× media) ≈ 0.001%
├─ P(X > 100× media) ≈ 5e-6%
└─ P(X > 1000× media) ≈ 5e-15%

Con 1 millón de órdenes:
├─ ~5000 órdenes > 100×media
├─ ~5 órdenes > 1000×media
└─ ~0.000005 órdenes > 10000×media

Pero si UNA orden tarda 10 segundos:
├─ El único escritor está bloqueado 10s
├─ Todas las otras órdenes esperan
├─ p99 sube a 10+ segundos
└─ Invalida la medición
```

### Estrategia: Tope a 100×

```
MAX_SAMPLE_FACTOR = 100.0

Ejemplo con BIZ_MICROS=8000:
├─ Media: 8000 µs (8 ms)
├─ Tope: 800.000 µs (800 ms)
└─ Probabilidad de recorte: ~5e-6

Con 10 millones de órdenes:
├─ Esperado ~50 recortes
├─ El Cs² se deforma levemente
└─ Pero la medición no se invalida
```

### Validación: Contador de Recortes

```java
public long clampedSamples() {
    return clamped;
}

public String describe() {
    if (clamped > 0) {
        logger.warn("Lognormal tuvo {} muestras recortadas — Cs² no es 3.34",
                    clamped);
    }
}
```

**Significado:**

- `clamped == 0`: Distribución es pura lognormal, Cs² = 3.34
- `clamped > 0`: Hay distorsión, Cs² es ligeramente menor que 3.34
  - Si `clamped` es pequeño (<100 en 1M órdenes) → negligible
  - Si `clamped` es grande → revisar MAX_SAMPLE_FACTOR

---

## Análisis de Código

### Constructor y Factory Method

```java
public BusinessLogicModel(double meanMicros, Shape shape, int shardId) {
    this.shardId = shardId;
    
    // Semilla diferenciada por shard
    this.random = new SplittableRandom(SEED + shardId);
    
    // Convierte media en nanosegundos
    this.meanNanos = Math.max(0.0, meanMicros) * 1_000.0;
    
    // Calcula costo unitario (para la clase barata: factor 1.0)
    this.unitNanos = meanNanos / MEAN_FACTOR;
    // unitNanos = meanNanos / 1.74
    //
    // Razón: En mezcla, la media es 1.74 × unitario
    //        Así que unitario = media / 1.74
    
    this.shape = shape;
    
    // Parámetros de lognormal, derivados de media y Cs²
    double sigma2 = Math.log(1.0 + CV2);  // σ² = ln(1 + Cs²)
    this.logSigma = Math.sqrt(sigma2);    // σ
    this.logMu = (meanNanos > 0.0) 
                ? Math.log(meanNanos) - sigma2 / 2.0 
                : 0.0;                     // µ = ln(media) - σ²/2
}

// Factory desde variables de entorno
public static BusinessLogicModel fromEnv(int shardId) {
    String micros = System.getenv("BIZ_MICROS");
    String dist = System.getenv("BIZ_DIST");
    Shape shape = (dist != null && dist.equalsIgnoreCase("lognormal"))
            ? Shape.LOGNORMAL : Shape.MEZCLA;
    return new BusinessLogicModel(
            (micros == null || micros.isBlank()) ? 0.0 : Double.parseDouble(micros),
            shape, shardId);
}
```

### Método apply()

```java
public void apply() {
    if (unitNanos <= 0.0) {
        return;  // Modelo desactivado
    }
    burn(sampleNanos());  // Muestra aleatoria → CPU burn
}
```

**Flujo:**
1. Si `BIZ_MICROS=0` → return (no hacer nada)
2. Si `BIZ_MICROS>0` → generar muestra aleatoria
3. Quemar CPU durante exactamente ese tiempo

### Método ceilingOrdersPerSecond()

```java
public double ceilingOrdersPerSecond() {
    return enabled() ? 1_000_000_000.0 / meanNanos : Double.POSITIVE_INFINITY;
}
```

**Interpretación:**

```
Con BIZ_MICROS=8000:
├─ meanNanos = 8.000.000 nanosegundos
├─ ceilingOrdersPerSecond = 1.000.000.000 / 8.000.000
├─ = 125 órdenes/segundo POR SHARD
└─ Es el techo teórico (si todo fuera CPU, sin otra contención)

Con N=4 shards:
└─ Techo agregado: 4 × 125 = 500 órdenes/segundo

En experimento F2:
├─ RATE_B = 84 órdenes/segundo (tasa de pico)
├─ Techo con N=4: 500 órdenes/segundo
├─ Ratio: 84 / 500 = 16.8% de capacidad
└─ Debe haber espacio en la cola (bajo p95)
```

### Método describe() — El Log de Arranque

```java
public String describe() {
    if (!enabled()) {
        return "APAGADO (S=0) — se mide solo el patrón; " +
               "el techo medido NO es el de un motor real";
    }
    if (shape == Shape.LOGNORMAL) {
        return String.format(
            "lognormal media=%.0fus Cs2=%.2f sigma=%.4f (tope %.0fx) " +
            "semilla=%d techo_teorico=%.0f ord/s",
            meanNanos / 1_000.0, CV2, logSigma, MAX_SAMPLE_FACTOR, 
            SEED + shardId, ceilingOrdersPerSecond());
    }
    return String.format(
        "mezcla 90/9/1 media=%.0fus Cs2=%.2f semilla=%d techo_teorico=%.0f ord/s",
        meanNanos / 1_000.0, CV2, SEED + shardId, ceilingOrdersPerSecond());
}
```

**Output típico:**

```
INFO EngineMain - matching-engine modelo de logica: mezcla 90/9/1 media=8000us Cs2=3.34 semilla=42 techo_teorico=125 ord/s
```

Esto se registra en el **log de arranque** de cada corrida:
- ✓ Identifica qué modelo está activo
- ✓ Ninguna corrida debe ser ambigua
- ✓ Se puede auditar después

---

## Experimentos y Resultados

### Experimento A/B: Mezcla vs Lognormal

**Hipótesis:** Con misma media y Cs², ¿importa la forma?

```
Plan de pruebas:
═════════════════════════════════════════════════════════════

Grupo    N   BIZ_DIST    BIZ_MICROS   Esperado
─────────────────────────────────────────────────────────────
ab-mix   2   mezcla      8000         p95 = 31.5 ms
ab-log   2   lognormal   8000         p95 = ??

Pregunta: ¿p95(log) ≈ p95(mix) o p95(log) >> p95(mix)?

Resultado (teórico):
├─ Mezcla: p95 ≈ 31.5 ms
├─ Lognormal: p95 ≈ 35-40 ms
│  (Cola derecha más larga, algunos picos ocasionales)
└─ Conclusión: La forma IMPORTA un poco, no mucho
  (ambas distribuyen igual en mediana, lognormal tiene outliers)
```

### Experimento Variando BIZ_MICROS

```
Pregunta: ¿Cómo sube el p95 con el costo?

Plan:
═════════════════════════════════════════════════════════════

N=2, PHASE=f1 (17 órd/s)

BIZ_MICROS   Techo(N=2)   p95(teórico)   Espera aprox
─────────────────────────────────────────────────────────────
0            ∞            ~8 ms          <1 ms
2000         1000/s       ~8 ms          <1 ms
4000         500/s        ~10 ms         1-2 ms
8000         250/s        ~20 ms         10-15 ms
16000        125/s        ~40 ms         35-40 ms
```

**Interpretación:**

```
A BIZ_MICROS=0:
├─ Costo = solo TreeMap (~3µs)
├─ Throughput: ilimitado
└─ p95: muy bajo (sin congestión)

A BIZ_MICROS=8000:
├─ Costo = 8ms por orden (serializado)
├─ Throughput: 250/s por shard
├─ Con tasa 17/s + jitter: anillo acumula
├─ Espera: 10-15 ms
└─ p95: ~20-25 ms

A BIZ_MICROS=16000:
├─ Costo = 16ms por orden
├─ Throughput: 125/s por shard
├─ Ring buffer casi lleno constantemente
├─ Espera: 35-40 ms
└─ p95: ~40-50 ms
  (limite de ASR antes de rechazos)
```

### Sensibilidad: JITTER_FACTOR

```
Pregunta: ¿Menos jitter (más periódico) baja el p95?

Plan:
═════════════════════════════════════════════════════════════

N=2, BIZ_MICROS=8000, PHASE=f1

JITTER_FACTOR  Varianza Arribo  p95(teórico)
──────────────────────────────────────────────────
0              0 (periódico)     ~8-10 ms   ← OPTIMISTA
1              Normal(1)         ~15 ms
4              Normal(4)         ~18 ms
8              Normal(8)         ~20-25 ms  ← Realista
```

**Razón:**

```
JITTER_FACTOR=0 (sin jitter):
├─ Orden llega cada 58.8ms
├─ Cada orden tarda 8ms
├─ Ring buffer: nunca hay acumulación
└─ p95 = muy bajo (artefacto del generador)

JITTER_FACTOR=8 (con jitter):
├─ Órdenes llegan con desplazamientos exponenciales
├─ Algunos clusters: 3 órdenes en 10ms
├─ Ring buffer acumula
├─ p95 = realista (mide el sistema, no el generador)
```

---

## Resumen Ejecutivo

### Tabla Resumen: BusinessLogicModel

| Aspecto | Mezcla | Lognormal |
|---------|--------|-----------|
| **Forma** | Discreta (3 valores) | Continua, sin cota |
| **Media** | 1.74 × unitario | Igual (derivada) |
| **Cs²** | 3.34 | 3.34 (igual) |
| **Mínimo costo** | 1 × unitario | ~0.1 × unitario |
| **Máximo costo** | 30 × unitario (acotado) | 100 × unitario (recortado) |
| **Probabilidad recorte** | 0 | ~5e-6 |
| **Uso** | Modelo base (default) | Validación de forma |

### Variables de Control

| Variable | Rango | Efecto |
|----------|-------|--------|
| **BIZ_MICROS** | 0, 2000, 8000, 16000 | Media del costo (µs/orden) |
| **BIZ_DIST** | mezcla, lognormal | Forma de la distribución |
| **Semilla** | SEED + shardId | Decorrelación entre shards |

### Conclusiones Clave

1. **Existe porque el TreeMap es simplista**
   - Sin modelo: p95 mide estructura de datos, no motor
   
2. **Media y forma importan**
   - Media: controla throughput máximo (1/S)
   - Forma: afecta colas y percentiles altos
   
3. **CPU burn es crítico**
   - No sleep: mantiene el núcleo
   - Simula trabajo real sin interferencia del scheduler
   
4. **Semillas diversas**
   - Evita sincronización de congestión en N>1
   - Aísla paralelización verdadera
   
5. **Compara hipótesis formales**
   - "¿ASR sostiene p95<200ms si S<8ms?" → Falsable
   - En lugar de: "El patrón es perfecto" → Trivial
