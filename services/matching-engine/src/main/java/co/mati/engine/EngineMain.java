package co.mati.engine;

import com.lmax.disruptor.BlockingWaitStrategy;
import com.lmax.disruptor.dsl.Disruptor;
import com.lmax.disruptor.dsl.ProducerType;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import org.HdrHistogram.Histogram;
import org.HdrHistogram.Recorder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;

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
        Histogram totalCumulative = new Histogram(3);
        Histogram waitCumulative = new Histogram(3);
        Histogram serviceCumulative = new Histogram(3);
        Object drainLock = new Object();

        BusinessLogicModel businessLogic = BusinessLogicModel.fromEnv();

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

        disruptor.handleEventsWith(
                new MatchingHandler(shardId, latencyRecorder, waitRecorder, serviceRecorder, businessLogic));
        disruptor.start();

        Server server = ServerBuilder.forPort(port)
                .addService(new IngestGrpcService(disruptor.getRingBuffer(), shardId))
                .build()
                .start();

        log.info("matching-engine shard={} escuchando gRPC en :{} (ring={})", shardId, port, ringSize);
        // Provenance de la corrida: qué se midió exactamente. Sin esta línea, un
        // resultado de capacidad es ambiguo — ver BusinessLogicModel.
        log.info("shard={} modelo de logica de negocio: {}", shardId, businessLogic.describe());

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
                totalCumulative.add(total);
                waitCumulative.add(wait);
                serviceCumulative.add(service);
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

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
