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
        Recorder latencyRecorder = new Recorder(3);
        Recorder waitRecorder = new Recorder(3);
        Recorder serviceRecorder = new Recorder(3);

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
            Histogram total = latencyRecorder.getIntervalHistogram();
            Histogram wait = waitRecorder.getIntervalHistogram();
            Histogram service = serviceRecorder.getIntervalHistogram();
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
            disruptor.shutdown();
        }));

        server.awaitTermination();
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
