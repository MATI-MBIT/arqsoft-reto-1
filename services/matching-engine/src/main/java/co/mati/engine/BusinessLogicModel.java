package co.mati.engine;

import java.util.SplittableRandom;

/**
 * Modelo sintético del tiempo de servicio de la lógica de negocio que este PoC
 * NO implementa: validación, control de riesgo, saldos y posiciones, tipos de
 * orden (mercado / límite / stop / FOK / IOC), comisiones, prevención de
 * auto-cruce y generación de trades.
 *
 * <p><b>Por qué existe.</b> En un diseño de un único escritor el costo por evento
 * se serializa, así que fija directamente el techo de throughput del shard
 * (techo = 1/S). Con el {@code match()} de juguete de {@link OrderBook} ese costo
 * es de microsegundos, y entonces cualquier medición de capacidad mide un
 * {@code TreeMap}, no un motor de emparejamiento. Barriendo S se obtiene un
 * <i>presupuesto de tiempo de servicio</i> — «el patrón sostiene el ASR mientras
 * el costo por orden se mantenga bajo X» — que es una conclusión falsable sin
 * conocer todavía la lógica real.
 *
 * <p><b>Qué NO es.</b> No es un retardo para «dar variabilidad» a la medición:
 * eso falsificaría el resultado. Es el modelo de carga del trabajo faltante,
 * declarado como parámetro del experimento — el shard lo escribe en el log al
 * arrancar y ninguna corrida debe reportarse sin él.
 *
 * <p><b>Quema CPU, no duerme.</b> Un {@code sleep} devolvería el núcleo: no
 * ensucia la caché, no compite con los hilos de gRPC ni con el GC, y su
 * granularidad en la JVM es de milisegundos — no se puede modelar 50 µs con eso.
 * La lógica de negocio real consume ciclos; el modelo también.
 *
 * <p><b>Una perilla de magnitud:</b> {@code BIZ_MICROS}, el costo <i>medio</i> por
 * orden en µs (0 o ausente = apagado, se mide solo el patrón). No es el costo de
 * cada orden: el modelo es una distribución, no una constante.
 *
 * <p><b>Y una perilla de forma:</b> {@code BIZ_DIST} = {@code mezcla} (default) o
 * {@code lognormal}. Existe para una sola pregunta: <i>¿el resultado depende de la
 * forma de la distribución, o solo de su media y su varianza?</i> Las dos variantes
 * comparten media y Cs² por construcción —la lognormal deriva su sigma del Cs² de
 * la mezcla— así que una corrida A/B entre ellas varía <b>solo la forma</b>. Si el
 * p95 no se mueve, la mezcla discreta es una simplificación válida; si se mueve,
 * el modelo necesita ser continuo. La σ no se expone como parámetro a propósito:
 * exponerla permitiría elegir la varianza que conviene al resultado.
 *
 * <p>Nada más está expuesto: sin una estimación del costo real, cada variable extra
 * es una manera más de producir una corrida cuya configuración nadie anotó.
 *
 * <p>No es thread-safe, igual que {@link OrderBook}: solo lo toca el único hilo
 * escritor de la partición.
 */
public final class BusinessLogicModel {

    /**
     * Mezcla de tres clases de orden, con la forma que tiene el costo real: la
     * mayoría son límite baratas que no cruzan y se quedan en reposo; unas pocas
     * barren varios niveles y generan varios trades; una fracción mínima dispara
     * cascadas. Es lo que hace que Cs² —el término de varianza del servicio en
     * Kingman— sea alto en un motor de verdad, y por eso el modelo no es una
     * constante. Al ser una mezcla discreta, el costo está acotado por
     * construcción (máximo 30/1,74 ≈ 17× la media): ninguna muestra puede
     * bloquear el shard de forma indefinida.
     */
    private static final double[] WEIGHT = {0.90, 0.09, 0.01};
    private static final double[] FACTOR = {1.0, 6.0, 30.0};

    /** Media y Cs² de la mezcla, derivados de los pesos (no son números mágicos). */
    private static final double MEAN_FACTOR;
    private static final double CV2;
    static {
        double m1 = 0.0, m2 = 0.0;
        for (int i = 0; i < WEIGHT.length; i++) {
            m1 += WEIGHT[i] * FACTOR[i];
            m2 += WEIGHT[i] * FACTOR[i] * FACTOR[i];
        }
        MEAN_FACTOR = m1;              // 1,74
        CV2 = m2 / (m1 * m1) - 1.0;    // 3,34
    }

    /**
     * Semilla base. La efectiva es {@code SEED + shardId}: <b>cada partición debe
     * sacar una secuencia distinta</b>.
     *
     * <p>Con una semilla común todos los shards sacaban la MISMA secuencia de
     * tiempos de servicio. Como todos reciben la misma tasa, sus órdenes k-ésimas
     * llegan casi a la vez, así que las órdenes caras de la clase pesada caían
     * sobre todas las particiones <i>simultáneamente</i> en vez de repartirse en
     * el tiempo. Eso sincroniza la congestión y engorda la cola del p95 agregado:
     * en vez de que la mitad del tráfico encuentre siempre una partición
     * despejada, hay instantes en que ninguna lo está.
     *
     * <p>La lógica de negocio real no está correlacionada entre particiones, así
     * que era un artefacto del banco de pruebas — y uno que solo afecta a las
     * corridas multi-shard, no a las de partición caliente. Sesgaba a la baja
     * justamente el presupuesto de N&gt;1.
     */
    private static final long SEED = 42L;

    /** Iteraciones de trabajo aritmético entre dos lecturas del reloj. */
    private static final int SPIN_BATCH = 32;

    /** Formas disponibles. La mezcla es la de referencia; la lognormal es el control. */
    public enum Shape { MEZCLA, LOGNORMAL }

    /**
     * Tope de una muestra individual, en múltiplos de la media. Solo aplica a la
     * lognormal, que no tiene cota superior: sin él, una muestra patológica podría
     * bloquear el único escritor de la partición durante segundos. A 100× la media
     * la probabilidad de recorte es ~5e-6, así que no deforma la distribución —
     * pero si se activa se cuenta y se reporta, porque un recorte silencioso
     * falsearía el Cs² que la corrida dice tener.
     */
    private static final double MAX_SAMPLE_FACTOR = 100.0;

    /** Partición a la que pertenece este modelo: decide la semilla. */
    private final int shardId;

    /** Costo de la clase barata, en nanosegundos. 0 = modelo apagado. */
    private final double unitNanos;
    private final double meanNanos;
    private final Shape shape;
    /** Parámetros de la lognormal, derivados de la media y del Cs² de la mezcla. */
    private final double logMu;
    private final double logSigma;
    private final SplittableRandom random;

    /** Muestras recortadas por {@link #MAX_SAMPLE_FACTOR}. Debe quedar en 0. */
    private long clamped;

    /** Acumulador del trabajo quemado: impide que el JIT elimine el bucle. */
    private long sink;

    public BusinessLogicModel(double meanMicros, Shape shape, int shardId) {
        this.shardId = shardId;
        this.random = new SplittableRandom(SEED + shardId);
        this.meanNanos = Math.max(0.0, meanMicros) * 1_000.0;
        this.unitNanos = meanNanos / MEAN_FACTOR;
        this.shape = shape;
        // Lognormal con la MISMA media y el MISMO Cs2 que la mezcla:
        //   sigma^2 = ln(1 + Cs2)   y   mu = ln(media) - sigma^2/2
        // De ahi que el A/B aisle la forma: los dos primeros momentos coinciden.
        double sigma2 = Math.log(1.0 + CV2);
        this.logSigma = Math.sqrt(sigma2);
        this.logMu = (meanNanos > 0.0) ? Math.log(meanNanos) - sigma2 / 2.0 : 0.0;
    }

    public BusinessLogicModel(double meanMicros, Shape shape) {
        this(meanMicros, shape, 0);
    }

    public BusinessLogicModel(double meanMicros) {
        this(meanMicros, Shape.MEZCLA, 0);
    }

    public static BusinessLogicModel fromEnv(int shardId) {
        String micros = System.getenv("BIZ_MICROS");
        String dist = System.getenv("BIZ_DIST");
        Shape shape = (dist != null && dist.equalsIgnoreCase("lognormal"))
                ? Shape.LOGNORMAL : Shape.MEZCLA;
        return new BusinessLogicModel(
                (micros == null || micros.isBlank()) ? 0.0 : Double.parseDouble(micros),
                shape, shardId);
    }

    /**
     * Consume CPU durante una muestra de la distribución.
     * Se invoca desde el hilo del único escritor: es ahí donde el costo se
     * serializa, y esa serialización es justamente lo que el experimento evalúa.
     */
    public void apply() {
        if (unitNanos <= 0.0) {
            return;
        }
        burn(sampleNanos());
    }

    /** Una muestra del costo de esta orden. NO es constante: esa es la razón de ser de la clase. */
    private long sampleNanos() {
        if (shape == Shape.LOGNORMAL) {
            double sample = Math.exp(logMu + logSigma * random.nextGaussian());
            double cap = meanNanos * MAX_SAMPLE_FACTOR;
            if (sample > cap) {
                clamped++;
                sample = cap;
            }
            return (long) sample;
        }
        double u = random.nextDouble();
        double factor = (u < 0.90) ? 1.0 : (u < 0.99) ? 6.0 : 30.0;
        return (long) (unitNanos * factor);
    }

    /** Bucle de trabajo real, acotado por reloj monótono. */
    private void burn(long targetNanos) {
        long deadline = System.nanoTime() + targetNanos;
        long acc = sink;
        do {
            for (int i = 0; i < SPIN_BATCH; i++) {
                // LCG + mezcla: trabajo aritmético dependiente, no eliminable.
                acc = acc * 6364136223846793005L + 1442695040888963407L;
                acc ^= (acc >>> 29);
            }
        } while (System.nanoTime() < deadline);
        sink = acc; // publicar el resultado: sin esto el JIT borraría el bucle
    }

    public boolean enabled() {
        return unitNanos > 0.0;
    }

    /** Techo teórico de throughput del shard que implica este costo: 1/S. */
    public double ceilingOrdersPerSecond() {
        return enabled() ? 1_000_000_000.0 / meanNanos : Double.POSITIVE_INFINITY;
    }

    /** Muestras recortadas por el tope. Distinto de 0 invalida el Cs² declarado. */
    public long clampedSamples() {
        return clamped;
    }

    /** Descripción para el log de arranque: ninguna corrida debe ser ambigua. */
    public String describe() {
        if (!enabled()) {
            return "APAGADO (S=0) — se mide solo el patrón; el techo medido NO es el de un motor real";
        }
        if (shape == Shape.LOGNORMAL) {
            return String.format(
                    "lognormal media=%.0fus Cs2=%.2f sigma=%.4f (tope %.0fx) semilla=%d techo_teorico=%.0f ord/s",
                    meanNanos / 1_000.0, CV2, logSigma, MAX_SAMPLE_FACTOR, SEED + shardId,
                    ceilingOrdersPerSecond());
        }
        return String.format("mezcla 90/9/1 media=%.0fus Cs2=%.2f semilla=%d techo_teorico=%.0f ord/s",
                meanNanos / 1_000.0, CV2, SEED + shardId, ceilingOrdersPerSecond());
    }

    /** Solo para que el acumulador sea observable y el bucle no sea código muerto. */
    public long sink() {
        return sink;
    }
}
