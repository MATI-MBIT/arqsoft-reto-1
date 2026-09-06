# Documentación de Arquitectura - Motor de Emparejamiento

Guía completa de la arquitectura del sistema de emparejamiento de órdenes. Incluye documentación conceptual, análisis código-nivel, y explicaciones detalladas de cada componente.

---

## 📋 Índice de Documentos

### **Visión General**

- **`index.md`** — Vista panorámica del sistema (3 servicios + 1 instrumento)
- **`README.md`** — Este archivo (guía de navegación)

---

## 🏗️ Documentación Detallada Creada Recientemente

Nuevos documentos código-nivel con análisis exhaustivo:

### 1. **`01-arquitectura-matching-engine.md`** (75 KB)
   
   **Cobertura completa del motor de emparejamiento**
   
   - Visión general y topología del sistema
   - Análisis línea por línea de **EngineMain**
     - Inicialización del Disruptor
     - Configuración de consumidores
     - Ciclo de vida completo
   - Detalles de **OrderEvent** (ciclo de vida de casillas)
   - Análisis profundo de **IngestGrpcService**
     - Captura de timestamp (t0)
     - Publicación no-bloqueante (tryNext)
     - Memory barriers
   - **MatchingHandler** línea por línea
     - Latencia de espera + servicio
     - Algoritmo de matching
     - Histogramas duales (ventana + acumulado)
   - **OrderBook** con ejemplos visuales
     - TreeMap price-ordered
     - ArrayDeque FIFO
     - Algoritmo Price-Time Priority
   - **BusinessLogicModel** (simulación de costo)
   - **JournalHandler** (tres modos: OFF, PARALELO, SERIE)
   - Flujo de ejecución end-to-end (14 fases)
   - Patrones LMAX Disruptor, Single Writer, Ring Buffer

---

### 2. **`02-arquitectura-load-testing.md`** (63 KB)
   
   **Análisis profundo de k6 y el generador de carga**
   
   - Introducción: problema de Coordinated Omission
   - Por qué modelo abierto vs cerrado es crítico
   - Topología k6 ↔ router ↔ shards
   - **Análisis detallado de `poc.js`**
     - Configuración global (RATE_A, RATE_B, PHASE)
     - Función `exponentialSeconds()` (transformada inversa)
     - Arribo estocástico (jitter para Poisson)
     - Símbolos (36 nemotécnicos BVC con reparto verificable)
     - Métricas personalizadas (rejected, routing_violations)
     - Escenarios (f1, f2, f3, f4) con umbrales
     - Iteración default() línea por línea
   - **Análisis detallado de `experimento.sh`**
     - Función `levantar()` (topología Docker)
     - Función `metrica()` y `stat_escenario()` (extracción de datos)
     - Función `corrida_valida()` (validación)
     - Función `ejecutar()` (orquestación)
     - Función `registrar()` (cálculo de percentil efectivo)
   - Flujo end-to-end de una orden
   - Patrones: modelo abierto, jitter estocástico, separación de escenarios
   - Validación multinivel y matriz de criterios
   - Cálculo de percentil efectivo cuando hay dropped_iterations

---

### 3. **`03-businesslogic-model-detallado.md`** (28 KB)
   
   **Análisis exhaustivo de la clase BusinessLogicModel**
   
   - Propósito: por qué existe (TreeMap es simplificación)
   - Concepto: presupuesto de tiempo de servicio
   - **Distribución MEZCLA (90/9/1)**
     - Estructura: 3 clases de órdenes (normal, barredor, cataclismo)
     - Interpretación real (qué significa cada clase)
     - Cálculo matemático de media (1.74) y Cs² (3.34)
     - Ejemplos de generación aleatoria
   - **Distribución LOGNORMAL**
     - Por qué existe (test A/B puro de forma)
     - Derivación matemática completa
     - Parámetros µ y σ
     - Método Box-Muller
     - Visualización comparativa (discreta vs continua)
   - **CPU Burn vs Thread.sleep()**
     - Problema de sleep() (devuelve núcleo, granularidad ms, sucia caché)
     - Solución: busy-loop aritmético
     - LCG + operaciones dependientes
     - Por qué el JIT NO lo optimiza
   - **Semilla y Correlación**
     - Problema original: semilla común sincroniza congestión
     - Solución: seed = SEED + shardId
     - Impacto en N>1 (artefacto vs verdadera paralelización)
   - **Muestras Recortadas (Clamping)**
     - Por qué lognormal necesita tope (MAX_SAMPLE_FACTOR=100×)
     - Probabilidades patológicas
     - Contador `clamped` para validación
   - Análisis de código (constructor, factory, apply, métodos)
   - Experimentos A/B y resultados

---

### 4. **`04-matching-engine-detailed.md`** (25 KB)
   
   **Documentación original detallada (creada previamente)**
   
   - Arquitectura general con diagrama
   - Clases y métodos relevantes
   - Flujo de operaciones
   - Patrones de diseño
   - Medición y observabilidad

---

## 📚 Documentación Existente

Documentos anteriores que siguen siendo válidos:

- **`common-proto.md`** — Contrato gRPC (matching.proto)
- **`ingest-router.md`** — Servicio de enrutamiento
- **`matching-engine.md`** — Motor (versión previa a detallada)
- **`k6.md`** — Load testing (versión previa a detallada)

---

## 🎯 Cómo Usar Esta Documentación

### Para Entender el Sistema Completo

1. **Primero:** `index.md` — Visión panorámica del sistema
2. **Luego:** `01-arquitectura-matching-engine.md` — Corazón del sistema (motor, Disruptor, clases)
3. **Después:** `02-arquitectura-load-testing.md` — Cómo se mide (k6, validación, criterios)
4. **Finalmente:** `03-businesslogic-model-detallado.md` — Detalles críticos (distribuiciones, costo)

### Para Buscar Respuestas Específicas

| Pregunta | Documento | Sección |
|----------|-----------|---------|
| ¿Cómo funciona el Disruptor? | **01** | "Análisis Detallado: EngineMain" (FASE 1-8) |
| ¿Qué es OrderEvent? | **01** | "Análisis Detallado de Clases" → OrderEvent |
| ¿Cómo funciona IngestGrpcService? | **01** | "Análisis Detallado de Clases" → IngestGrpcService |
| ¿Qué es MatchingHandler? | **01** | "Análisis Detallado de Clases" → MatchingHandler |
| ¿Cómo funciona OrderBook? | **01** | "Análisis Detallado de Clases" → OrderBook |
| ¿Qué es BusinessLogicModel? | **03** | "Propósito y Justificación" |
| ¿Por qué jitter estocástico? | **02** | "Introducción y Propósito" → Desafío Fundamental |
| ¿Cómo funciona poc.js? | **02** | "Análisis Detallado: poc.js" (completo) |
| ¿Cómo funciona experimento.sh? | **02** | "Análisis Detallado: experimento.sh" (completo) |
| ¿Cómo se calcula p95? | **02** | "Validación y Criterios" → Percentil Efectivo |
| ¿Mezcla vs Lognormal? | **03** | "Distribución MEZCLA" + "Distribución LOGNORMAL" |
| ¿CPU burn vs sleep? | **03** | "CPU Burn: Por qué NO Sleep" |
| ¿Cómo se valida una corrida? | **02** | "Validación y Criterios" (completo) |
| ¿Cómo funciona semilla y correlación? | **03** | "Semilla y Correlación" |
| ¿Qué es clamping? | **03** | "Muestras Recortadas (Clamping)" |
| Flujo end-to-end de una orden | **01** | "Flujo de Operaciones" → Viaje Completo |
| Flujo k6 y medición | **02** | "Flujo de Operaciones" (completo) |

---

## 🔍 Búsqueda Rápida por Tema

### Patrón LMAX y Concurrencia
- **LMAX Disruptor:** 01 → "Análisis Detallado: EngineMain" (construcción + configuración)
- **Single Writer:** 01 → "Análisis Detallado: MatchingHandler" (garantías de seguridad)
- **Ring Buffer:** 01 → "Análisis Detallado: OrderEvent" (ciclo de vida de casillas)
- **ProducerType.MULTI:** 01 → "Análisis Detallado: EngineMain" (FASE 2)
- **BusySpinWaitStrategy:** 01 → "Análisis Detallado: EngineMain" (decisiones arquitectónicas)
- **Memory Barriers:** 01 → "Análisis Detallado: IngestGrpcService" (publish)

### Algoritmos y Estructuras de Datos
- **Price-Time Priority:** 01 → "Análisis Detallado: OrderBook" (método match)
- **Matching Algorithm:** 01 → "Análisis Detallado: OrderBook" (rama compra/venta)
- **TreeMap + ArrayDeque:** 01 → "Análisis Detallado: OrderBook" (estructura de datos)
- **FIFO (First-In-First-Out):** 01 → "Análisis Detallado: OrderBook" (garantía de fairness)

### Estadística y Distribuciones
- **Mezcla 90/9/1:** 03 → "Distribución MEZCLA" (3 clases de órdenes)
- **Lognormal:** 03 → "Distribución LOGNORMAL" (Box-Muller, derivación)
- **Media y Cs²:** 03 → "Cálculo de Media y Varianza" (fórmulas, ejemplos)
- **Percentil Efectivo:** 02 → "Validación y Criterios" (con dropped_iterations)

### Load Testing y Validación
- **Modelo Abierto:** 02 → "Introducción y Propósito" (coordinated omission)
- **Jitter Estocástico:** 02 → "Arribo Estocástico" (exponentialSeconds)
- **Arribo Poisson:** 02 → "Arribo Estocástico" (superposición)
- **Escenarios:** 02 → "Análisis Detallado: poc.js" → "Escenarios y Ejecutores" (f1, f2, f3, f4)
- **Umbrales:** 02 → "Análisis Detallado: poc.js" → "Umbrales de Validación"
- **Validación Multinivel:** 02 → "Validación y Criterios" (5 niveles)

### Costo de Negocio y Simulación
- **BusinessLogicModel:** 03 → "Propósito y Justificación" (por qué existe)
- **CPU Burn:** 03 → "CPU Burn: Por qué NO Sleep" (busy-loop aritmético)
- **Semilla Diversa:** 03 → "Semilla y Correlación" (SEED + shardId)
- **Clamping:** 03 → "Muestras Recortadas (Clamping)" (MAX_SAMPLE_FACTOR=100×)

### Medición y Observabilidad
- **HdrHistogram Dual-Level:** 01 → "Medición y Observabilidad" (ventana + acumulado)
- **Descomposición Latencia:** 01 → "Medición y Observabilidad" (espera + servicio)
- **Prometheus Metrics:** 01 → "Medición y Observabilidad" (endpoint /metrics)
- **Extracción de Métricas:** 02 → "Análisis Detallado: experimento.sh" → "stat_escenario()"

### Implementación Específica
- **EngineMain:** 01 → "Análisis Detallado: EngineMain" (línea por línea, decisiones)
- **IngestGrpcService:** 01 → "Análisis Detallado: IngestGrpcService" (5 pasos)
- **MatchingHandler:** 01 → "Análisis Detallado: MatchingHandler" (9 pasos)
- **OrderBook:** 01 → "Análisis Detallado: OrderBook" (compra + venta)
- **BusinessLogicModel:** 03 → "Análisis de Código" (constructor, apply, métodos)
- **JournalHandler:** 01 → "Análisis Detallado de Clases" → JournalHandler (3 modos)

### Orquestación y Experimentos
- **levantar():** 02 → "Análisis Detallado: experimento.sh" → "Función: levantar()"
- **ejecutar():** 02 → "Análisis Detallado: experimento.sh" → "Función: ejecutar()"
- **registrar():** 02 → "Análisis Detallado: experimento.sh" → "Función: registrar()"
- **poc.js Iteración:** 02 → "Análisis Detallado: poc.js" → "Iteración de Trabajo"
- **Experimento A/B:** 03 → "Experimentos y Resultados" (mezcla vs lognormal)

---

## 📊 Estadísticas de Documentación

| Archivo | Tamaño | Líneas | Tópicos |
|---------|--------|--------|---------|
| 01-arquitectura-matching-engine.md | 75 KB | ~1800 | Motor, Disruptor, clases |
| 02-arquitectura-load-testing.md | 63 KB | ~1500 | k6, poc.js, experimento.sh |
| 03-businesslogic-model-detallado.md | 28 KB | ~900 | Distribuciones, CPU burn |
| 04-matching-engine-detailed.md | 25 KB | ~800 | Arquitectura general |
| **TOTAL** | **191 KB** | **~5000** | Sistema completo |

---

## 🔗 Relaciones Entre Documentos

```
01 (Motor) ←→ 03 (BusinessLogicModel)
     ↕
02 (Load Testing)
     ↕
04 (Referencia)
```

**Flujo recomendado:**
1. 01 → Entender el motor
2. 03 → Entender por qué el costo importa
3. 02 → Entender cómo se mide
4. 04 → Referencia rápida

---

## ✅ Cobertura de Tópicos

- ✅ Patrón LMAX Disruptor (completo)
- ✅ Single Writer (completo)
- ✅ Ring Buffer (completo)
- ✅ Matching Algorithm (completo)
- ✅ Distribuciones estadísticas (completo)
- ✅ CPU Burn (completo)
- ✅ Load Testing (completo)
- ✅ Validación (completo)
- ✅ Observabilidad (completo)
- ✅ Análisis código-nivel (línea por línea)

---

## 🔗 Referencias Cruzadas

### Desde 01-arquitectura-matching-engine.md
- Usa **03** para entender por qué `BusinessLogicModel` es crítico
- Usa **02** para ver cómo se miden los tiempos (espera + servicio)
- Usa **04** como referencia rápida de conceptos

### Desde 02-arquitectura-load-testing.md
- Usa **01** para entender el sistema que se está midiendo
- Usa **03** para entender qué es el costo que se mide
- Usa **04** para diagrama de topología

### Desde 03-businesslogic-model-detallado.md
- Usa **01** para ver dónde se `apply()` el modelo en `MatchingHandler`
- Usa **02** para ver cómo afecta el costo a los percentiles
- Usa **04** para referencia rápida

### Desde 04-matching-engine-detailed.md
- Usa **01** para profundizar en cada clase
- Usa **02** para entender cómo se valida
- Usa **03** para entender BusinessLogicModel

---

## 🚀 Comenzar a Leer (Rutas Recomendadas)

### Ruta 1: "Entender el Motor" (Ingeniería)
**Objetivo:** Aprender cómo funciona el matching engine

1. `index.md` — Visión panorámica (5 min)
2. `01-arquitectura-matching-engine.md` → "Arquitectura General" (15 min)
3. `01-arquitectura-matching-engine.md` → "Análisis Detallado: EngineMain" (30 min)
4. `01-arquitectura-matching-engine.md` → "Análisis Detallado: MatchingHandler" (30 min)
5. `01-arquitectura-matching-engine.md` → "Análisis Detallado: OrderBook" (20 min)
6. `04-matching-engine-detailed.md` — Referencia rápida

**Tiempo total:** ~2 horas

---

### Ruta 2: "Entender el Costo de Servicio" (Performance)
**Objetivo:** Entender por qué el costo importa

1. `03-businesslogic-model-detallado.md` → "Propósito y Justificación" (20 min)
2. `03-businesslogic-model-detallado.md` → "El Problema: TreeMap" (10 min)
3. `01-arquitectura-matching-engine.md` → "Análisis Detallado: MatchingHandler" (20 min, líneas de `apply()`)
4. `03-businesslogic-model-detallado.md` → "Distribución MEZCLA" (20 min)
5. `03-businesslogic-model-detallado.md` → "CPU Burn" (15 min)
6. `02-arquitectura-load-testing.md` → "Experimentos y Resultados" (10 min)

**Tiempo total:** ~95 minutos

---

### Ruta 3: "Entender la Validación" (QA/Testing)
**Objetivo:** Aprender cómo se valida el sistema

1. `02-arquitectura-load-testing.md` → "Introducción y Propósito" (15 min)
2. `02-arquitectura-load-testing.md` → "Análisis Detallado: poc.js" (45 min)
3. `02-arquitectura-load-testing.md` → "Análisis Detallado: experimento.sh" (45 min)
4. `02-arquitectura-load-testing.md` → "Validación y Criterios" (25 min)
5. `01-arquitectura-matching-engine.md` → "Medición y Observabilidad" (15 min)

**Tiempo total:** ~145 minutos

---

### Ruta 4: "Entender Todo" (Arquitecto/Lead)
**Objetivo:** Visión completa del sistema

1. `index.md` — Visión panorámica (5 min)
2. `01-arquitectura-matching-engine.md` — Completo (120 min)
3. `02-arquitectura-load-testing.md` — Completo (110 min)
4. `03-businesslogic-model-detallado.md` — Completo (60 min)
5. `04-matching-engine-detailed.md` — Referencia rápida (20 min)

**Tiempo total:** ~315 minutos (~5.25 horas)

---

## 💡 Quick Answers

**"Tengo 5 minutos":** Lee `index.md`

**"Tengo 30 minutos":** Lee `01-arquitectura-matching-engine.md` → "Arquitectura General"

**"Tengo 1 hora":** Lee `01-arquitectura-matching-engine.md` → "Arquitectura General" + "EngineMain"

**"Tengo 2 horas":** Sigue "Ruta 1: Entender el Motor"

**"Tengo todo el día":** Sigue "Ruta 4: Entender Todo"

---

## 📝 Notas

Todos los documentos incluyen:
- ✅ Análisis línea por línea del código
- ✅ Ejemplos visuales (ASCII art)
- ✅ Explicaciones matemáticas
- ✅ Implicaciones en experimentos
- ✅ Tablas resumen
- ✅ Referencias cruzadas

**Ningún documento es independiente.** Están interconectados para formar una imagen completa del sistema.

---

**Última actualización:** 2026-09-05
**Estado:** Documentación completa y verificada
