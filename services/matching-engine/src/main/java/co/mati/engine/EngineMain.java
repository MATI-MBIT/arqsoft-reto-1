package co.mati.engine;

import co.mati.metrics.PrometheusEndpoint;
import com.lmax.disruptor.BlockingWaitStrategy;
import com.lmax.disruptor.EventHandler;
import com.lmax.disruptor.dsl.Disruptor;
import com.lmax.disruptor.dsl.ProducerType;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import org.HdrHistogram.Histogram;
import org.HdrHistogram.Recorder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.LongAdder;

/**
 * Shard del motor de emparejamiento (experimento E01).
 * Un proceso = una partición = un único hilo escritor sobre su ring buffer (patrón LMAX).
 *
 * Variables de entorno:
 *   SHARD_ID   — id de esta partición (default 0)
 *   PORT       — puerto gRPC (default 9090)
 *   RING_SIZE  — tamaño del ring buffer, potencia de 2 (default 16384)
 *   BIZ_MICROS — costo medio por orden, en µs, del modelo sintético de lógica
 *                de negocio (0 o ausente = apagado; ver BusinessLogicModel)
 *   METRICS_PORT — puerto del endpoint /metrics que raspa Prometheus (default 9095)
 */
public final class EngineMain {

    private static final Logger log = LoggerFactory.getLogger(EngineMain.class);

    public static void main(String[] args) throws Exception {
        int shardId = Integer.parseInt(env("SHARD_ID", "0"));
        int port = Integer.parseInt(env("PORT", "9090"));
        int ringSize = Integer.parseInt(env("RING_SIZE", "16384"));

        // Histogramas de latencia interna, en microsegundos. Total = espera + servicio.
        //
        // Dos niveles a propósito:
        //  · Recorder  — ventana de 10 s. Sirve para ver la EVOLUCIÓN (cuándo se
        //    degrada, si drena el backlog), pero sus percentiles son de la ventana.
        //  · Histogram acumulado — suma de todas las ventanas. De aquí salen los
        //    percentiles VERDADEROS sobre toda la población de órdenes, que son los
        //    únicos comparables con los de k6. Promediar los p95 por ventana NO da
        //    un p95: da la media de una muestra de percentiles, un estadístico
        //    distinto que oculta la dispersión entre ventanas.
        Recorder latencyRecorder = new Recorder(3);
        Recorder waitRecorder = new Recorder(3);
        Recorder serviceRecorder = new Recorder(3);
        Recorder journalRecorder = new Recorder(3);
        Histogram totalCumulative = new Histogram(3);
        Histogram waitCumulative = new Histogram(3);
        Histogram serviceCumulative = new Histogram(3);
        Histogram journalCumulative = new Histogram(3);
        Object drainLock = new Object();

        BusinessLogicModel businessLogic = BusinessLogicModel.fromEnv(shardId);
        int metricsPort = Integer.parseInt(env("METRICS_PORT", "9095"));
        LongAdder rejectedOrders = new LongAdder();

        ThreadFactory matcherThreadFactory = r -> {
            Thread t = new Thread(r, "matcher-shard-" + shardId);
            t.setDaemon(false);
            return t;
        };

        // Deuda de decisión registrada en E01: la estrategia de espera se re-evaluará con datos.
        // BlockingWaitStrategy es amable con la máquina compartida del PoC; Yielding/BusySpin
        // reducen latencia a costa de quemar un núcleo por shard.
        Disruptor<OrderSlot> disruptor = new Disruptor<>(
                OrderSlot::new,
                ringSize,
                matcherThreadFactory,
                ProducerType.MULTI,          // varios hilos gRPC publican; consume UNO solo
                new BlockingWaitStrategy());

        // Cableado del journal. Las tres disposiciones prueban la clausula de H1
        // sobre mantener el journaling FUERA del camino critico:
        //
        //   OFF      matcher                       -- configuracion original
        //   PARALELO (journal | matcher) -> limpia -- el journal no suma latencia,
        //                                             pero el acuse no implica durabilidad
        //   SERIE    journal -> matcher  -> limpia -- durabilidad antes del acuse,
        //                                             con el journal en el camino critico
        //
        // La limpieza del slot va SIEMPRE al final de la cadena: con consumidores
        // en paralelo ninguno puede mutar el evento (ver MatchingHandler).
        JournalHandler.Mode journalMode = JournalHandler.Mode.fromEnv();
        MatchingHandler matcher =
                new MatchingHandler(shardId, latencyRecorder, waitRecorder, serviceRecorder, businessLogic);
        EventHandler<OrderSlot> cleaner = (slot, seq, endOfBatch) -> slot.clear();
        JournalHandler journal = (journalMode == JournalHandler.Mode.OFF) ? null
                : new JournalHandler(shardId, Path.of(env("JOURNAL_DIR", "/var/lib/engine/journal")), journalRecorder);

        switch (journalMode) {
            case PARALELO -> disruptor.handleEventsWith(journal, matcher).then(cleaner);
            case SERIE    -> disruptor.handleEventsWith(journal).then(matcher).then(cleaner);
            case OFF      -> disruptor.handleEventsWith(matcher).then(cleaner);
        }
        disruptor.start();

        Server server = ServerBuilder.forPort(port)
                .addService(new IngestGrpcService(disruptor.getRingBuffer(), shardId, rejectedOrders))
                .build()
                .start();

        log.info("matching-engine shard={} escuchando gRPC en :{} (ring={})", shardId, port, ringSize);
        // Provenance de la corrida: qué se midió exactamente. Sin esta línea, un
        // resultado de capacidad es ambiguo — ver BusinessLogicModel.
        log.info("shard={} modelo de logica de negocio: {}", shardId, businessLogic.describe());
        log.info("shard={} journal: modo={}", shardId, journalMode);
        // Cuantas CPU CREE tener la JVM. Con un limite de cgroup (cpus/cpuset) este
        // numero baja, y con el bajan los hilos de ZGC, los de compilacion JIT y el
        // executor de gRPC. Sin registrarlo, una corrida restringida y una libre son
        // indistinguibles en la evidencia.
        log.info("shard={} runtime: availableProcessors={} maxHeap={}MB",
                shardId,
                Runtime.getRuntime().availableProcessors(),
                Runtime.getRuntime().maxMemory() / (1024 * 1024));

        // Exposición para Prometheus. La cadena se rearma en el hilo del reporte,
        // cada 10 s, y el endpoint solo devuelve la última: raspar las métricas no
        // toca un histograma ni toma un candado, así que no puede alterar la
        // medición que está observando.
        AtomicReference<String> exposicion = new AtomicReference<>("# shard iniciando\n");
        PrometheusEndpoint.start(metricsPort, exposicion::get);
        log.info("shard={} metricas Prometheus en :{}/metrics", shardId, metricsPort);

        // Reporte periódico de percentiles: la contraparte interna de la medición del generador.
        ScheduledExecutorService reporter = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "latency-reporter");
            t.setDaemon(true);
            return t;
        });
        reporter.scheduleAtFixedRate(() -> {
            Histogram total, wait, service;
            // getIntervalHistogram() no admite llamadas concurrentes: el hilo del
            // reporte y el de cierre compiten por él.
            synchronized (drainLock) {
                total = latencyRecorder.getIntervalHistogram();
                wait = waitRecorder.getIntervalHistogram();
                service = serviceRecorder.getIntervalHistogram();
                Histogram journalWindow = journalRecorder.getIntervalHistogram();
                totalCumulative.add(total);
                waitCumulative.add(wait);
                serviceCumulative.add(service);
                journalCumulative.add(journalWindow);
                exposicion.set(exponer(shardId, ringSize, businessLogic, journalMode,
                        rejectedOrders.sum(), total, wait, service, journalWindow,
                        totalCumulative, waitCumulative, serviceCumulative));
            }
            if (total.getTotalCount() == 0) {
                return;
            }
            log.info("shard={} n={} p50={}us p95={}us p99={}us p99.9={}us max={}us"
                            + " | espera p50={}us p95={}us p99.9={}us max={}us"
                            + " | servicio p50={}us p95={}us p99.9={}us max={}us",
                    shardId,
                    total.getTotalCount(),
                    total.getValueAtPercentile(50.0),
                    total.getValueAtPercentile(95.0),
                    total.getValueAtPercentile(99.0),
                    total.getValueAtPercentile(99.9),
                    total.getMaxValue(),
                    wait.getValueAtPercentile(50.0),
                    wait.getValueAtPercentile(95.0),
                    wait.getValueAtPercentile(99.9),
                    wait.getMaxValue(),
                    service.getValueAtPercentile(50.0),
                    service.getValueAtPercentile(95.0),
                    service.getValueAtPercentile(99.9),
                    service.getMaxValue());
        }, 10, 10, TimeUnit.SECONDS);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            server.shutdown();
            disruptor.shutdown(); // drena el ring: al volver, todo evento fue procesado

            // Última ventana pendiente + resumen ACUMULADO de la corrida completa.
            // Estos sí son percentiles de la población entera, comparables con los
            // de k6. Requiere que el proceso viva exactamente una fase.
            synchronized (drainLock) {
                totalCumulative.add(latencyRecorder.getIntervalHistogram());
                waitCumulative.add(waitRecorder.getIntervalHistogram());
                serviceCumulative.add(serviceRecorder.getIntervalHistogram());
            }
            if (journal != null) {
                synchronized (drainLock) {
                    journalCumulative.add(journalRecorder.getIntervalHistogram());
                }
                journal.close();
                // Linea propia: no se mezcla con ACUMULADO para no romper los
                // extractores que ya leen ese formato.
                log.info("JOURNAL shard={} {} | p50={}us p95={}us p99.9={}us max={}us",
                        shardId, journal.describe(journalMode, journalCumulative.getTotalCount()),
                        journalCumulative.getValueAtPercentile(50.0),
                        journalCumulative.getValueAtPercentile(95.0),
                        journalCumulative.getValueAtPercentile(99.9),
                        journalCumulative.getMaxValue());
            }
            if (totalCumulative.getTotalCount() == 0) {
                return;
            }
            log.info("ACUMULADO shard={} n={}"
                            + " total p50={}us p95={}us p99={}us p99.9={}us max={}us"
                            + " | espera p50={}us p95={}us p99.9={}us max={}us"
                            + " | servicio p50={}us p95={}us p99.9={}us max={}us",
                    shardId, totalCumulative.getTotalCount(),
                    totalCumulative.getValueAtPercentile(50.0),
                    totalCumulative.getValueAtPercentile(95.0),
                    totalCumulative.getValueAtPercentile(99.0),
                    totalCumulative.getValueAtPercentile(99.9),
                    totalCumulative.getMaxValue(),
                    waitCumulative.getValueAtPercentile(50.0),
                    waitCumulative.getValueAtPercentile(95.0),
                    waitCumulative.getValueAtPercentile(99.9),
                    waitCumulative.getMaxValue(),
                    serviceCumulative.getValueAtPercentile(50.0),
                    serviceCumulative.getValueAtPercentile(95.0),
                    serviceCumulative.getValueAtPercentile(99.9),
                    serviceCumulative.getMaxValue());
        }));

        server.awaitTermination();
    }

    /**
     * Texto de exposición de Prometheus para este shard.
     *
     * <p>Los nombres de las métricas van en inglés y en minúscula con guiones
     * bajos porque esa es la convención que Prometheus y Grafana esperan; la
     * explicación de cada una, en {@code # HELP}, va en el idioma del proyecto.
     *
     * <p>Publica tres familias. El <b>punto de operación</b> (S, la forma, el
     * techo teórico, las CPU que la JVM cree ver) es provenance: sin él, dos
     * corridas con resultados distintos son indistinguibles. La <b>ventana</b> de
     * 10 s es la que dibuja la serie de tiempo. El <b>acumulado</b> es el único
     * comparable cifra a cifra con k6.
     */
    private static String exponer(int shardId, int ringSize, BusinessLogicModel businessLogic,
                                  JournalHandler.Mode journalMode, long rejected,
                                  Histogram ventanaTotal, Histogram ventanaEspera,
                                  Histogram ventanaServicio, Histogram ventanaJournal,
                                  Histogram acumTotal, Histogram acumEspera, Histogram acumServicio) {
        String shard = "shard=\"" + shardId + "\"";
        StringBuilder sb = new StringBuilder(4096);

        PrometheusEndpoint.ayuda(sb, "engine_operating_point_micros", "gauge",
                "Costo medio por orden declarado para la corrida (S), en microsegundos. 0 = logica de negocio apagada.");
        PrometheusEndpoint.muestra(sb, "engine_operating_point_micros", shard,
                (long) businessLogic.mediaMicros());

        PrometheusEndpoint.ayuda(sb, "engine_ceiling_orders_per_second", "gauge",
                "Techo teorico de la particion que implica S: 1/S. 0 cuando la logica esta apagada.");
        PrometheusEndpoint.muestra(sb, "engine_ceiling_orders_per_second", shard,
                businessLogic.enabled() ? businessLogic.ceilingOrdersPerSecond() : 0.0);

        PrometheusEndpoint.ayuda(sb, "engine_info", "gauge",
                "Provenance de la corrida como etiquetas: forma de la distribucion, disposicion del journal, recursos visibles.");
        PrometheusEndpoint.muestra(sb, "engine_info",
                shard + ",forma=\"" + businessLogic.forma() + "\""
                        + ",journal=\"" + journalMode.name().toLowerCase(java.util.Locale.ROOT) + "\""
                        + ",cs2=\"" + String.format(java.util.Locale.ROOT, "%.2f", businessLogic.cs2()) + "\"",
                1L);

        PrometheusEndpoint.ayuda(sb, "engine_ring_size", "gauge", "Casillas del ring buffer.");
        PrometheusEndpoint.muestra(sb, "engine_ring_size", shard, (long) ringSize);

        PrometheusEndpoint.ayuda(sb, "engine_available_processors", "gauge",
                "CPU que la JVM cree tener. Baja con una cuota de cgroup, y con ella bajan los hilos de ZGC, JIT y gRPC.");
        PrometheusEndpoint.muestra(sb, "engine_available_processors", shard,
                (long) Runtime.getRuntime().availableProcessors());

        PrometheusEndpoint.ayuda(sb, "engine_max_heap_bytes", "gauge", "Heap maximo de la JVM.");
        PrometheusEndpoint.muestra(sb, "engine_max_heap_bytes", shard, Runtime.getRuntime().maxMemory());

        PrometheusEndpoint.ayuda(sb, "engine_orders_total", "counter",
                "Ordenes materializadas por esta particion desde que arranco. La suma entre shards evidencia el reparto.");
        PrometheusEndpoint.muestra(sb, "engine_orders_total", shard, acumTotal.getTotalCount());

        PrometheusEndpoint.ayuda(sb, "engine_orders_rejected_total", "counter",
                "Ordenes rechazadas por ring lleno: la senal de la cola acotada del motor.");
        PrometheusEndpoint.muestra(sb, "engine_orders_rejected_total", shard, rejected);

        PrometheusEndpoint.ayuda(sb, "engine_business_clamped_total", "counter",
                "Muestras de servicio recortadas por el tope. Distinto de 0 invalida el Cs2 declarado.");
        PrometheusEndpoint.muestra(sb, "engine_business_clamped_total", shard,
                businessLogic.clampedSamples());

        PrometheusEndpoint.ayuda(sb, "engine_window_orders", "gauge",
                "Ordenes materializadas en la ultima ventana de 10 s.");
        PrometheusEndpoint.muestra(sb, "engine_window_orders", shard, ventanaTotal.getTotalCount());

        cuantiles(sb, "engine_window_latency_micros", shard, ventanaTotal,
                "Latencia interna arribo -> materializacion, ventana de 10 s.");
        cuantiles(sb, "engine_window_wait_micros", shard, ventanaEspera,
                "Espera en el ring, ventana de 10 s. Es el detector de saturacion: explota cuando rho tiende a 1.");
        cuantiles(sb, "engine_window_service_micros", shard, ventanaServicio,
                "Tiempo de servicio (cruce + logica de negocio), ventana de 10 s. No depende de la carga.");
        if (journalMode != JournalHandler.Mode.OFF) {
            cuantiles(sb, "engine_window_journal_micros", shard, ventanaJournal,
                    "Costo de escribir la bitacora, ventana de 10 s.");
        }

        PrometheusEndpoint.ayuda(sb, "engine_window_latency_max_micros", "gauge",
                "Peor orden de la ultima ventana. Un solo atasco aqui puede incumplir el SLA por si mismo.");
        PrometheusEndpoint.muestra(sb, "engine_window_latency_max_micros", shard, ventanaTotal.getMaxValue());

        cuantiles(sb, "engine_total_latency_micros", shard, acumTotal,
                "Latencia interna acumulada de la corrida. Es la unica comparable cifra a cifra con k6.");
        cuantiles(sb, "engine_total_wait_micros", shard, acumEspera, "Espera acumulada de la corrida.");
        cuantiles(sb, "engine_total_service_micros", shard, acumServicio, "Servicio acumulado de la corrida.");

        PrometheusEndpoint.ayuda(sb, "engine_total_latency_max_micros", "gauge",
                "Peor orden de toda la corrida.");
        PrometheusEndpoint.muestra(sb, "engine_total_latency_max_micros", shard, acumTotal.getMaxValue());

        return sb.toString();
    }

    /** Publica los cuatro cuantiles de un histograma bajo un mismo nombre de metrica. */
    private static void cuantiles(StringBuilder sb, String nombre, String shard,
                                  Histogram h, String ayuda) {
        PrometheusEndpoint.ayuda(sb, nombre, "gauge", ayuda);
        for (int i = 0; i < PrometheusEndpoint.CUANTILES.length; i++) {
            PrometheusEndpoint.muestra(sb, nombre,
                    shard + ",quantile=\"" + PrometheusEndpoint.ETIQUETAS_CUANTIL[i] + "\"",
                    h.getValueAtPercentile(PrometheusEndpoint.CUANTILES[i]));
        }
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
