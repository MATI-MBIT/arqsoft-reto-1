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
 * <p><b>Una sola perilla:</b> {@code BIZ_MICROS}, el costo medio por orden en µs
 * (0 o ausente = apagado, se mide solo el patrón). Todo lo demás está fijo a
 * propósito: sin una estimación del costo real, exponer la forma de la
 * distribución o su varianza sería precisión falsa, y cada variable extra es una
 * manera más de producir una corrida cuya configuración nadie anotó.
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
     * Semilla fija: sobre las ~10⁵ órdenes de una corrida los percentiles
     * agregados no dependen de la semilla, así que exponerla solo agregaría una
     * perilla; fijarla mantiene las corridas reproducibles.
     */
    private static final long SEED = 42L;

    /** Iteraciones de trabajo aritmético entre dos lecturas del reloj. */
    private static final int SPIN_BATCH = 32;

    /** Costo de la clase barata, en nanosegundos. 0 = modelo apagado. */
    private final double unitNanos;
    private final double meanNanos;
    private final SplittableRandom random = new SplittableRandom(SEED);

    /** Acumulador del trabajo quemado: impide que el JIT elimine el bucle. */
    private long sink;

    public BusinessLogicModel(double meanMicros) {
        this.meanNanos = Math.max(0.0, meanMicros) * 1_000.0;
        this.unitNanos = meanNanos / MEAN_FACTOR;
    }

    public static BusinessLogicModel fromEnv() {
        String value = System.getenv("BIZ_MICROS");
        return new BusinessLogicModel(
                (value == null || value.isBlank()) ? 0.0 : Double.parseDouble(value));
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
        double u = random.nextDouble();
        double factor = (u < 0.90) ? 1.0 : (u < 0.99) ? 6.0 : 30.0;
        burn((long) (unitNanos * factor));
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

    /** Descripción para el log de arranque: ninguna corrida debe ser ambigua. */
    public String describe() {
        if (!enabled()) {
            return "APAGADO (S=0) — se mide solo el patrón; el techo medido NO es el de un motor real";
        }
        return String.format("mezcla 90/9/1 media=%.0fus Cs2=%.2f techo_teorico=%.0f ord/s",
                meanNanos / 1_000.0, CV2, ceilingOrdersPerSecond());
    }

    /** Solo para que el acumulador sea observable y el bucle no sea código muerto. */
    public long sink() {
        return sink;
    }
}
