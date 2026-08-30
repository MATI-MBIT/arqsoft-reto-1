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
 */
public final class EngineMain {

    private static final Logger log = LoggerFactory.getLogger(EngineMain.class);

    public static void main(String[] args) throws Exception {
        int shardId = Integer.parseInt(env("SHARD_ID", "0"));
        int port = Integer.parseInt(env("PORT", "9090"));
        int ringSize = Integer.parseInt(env("RING_SIZE", "16384"));

        // Histograma de latencia interna (arribo → materialización), en microsegundos.
        Recorder latencyRecorder = new Recorder(3);

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

        disruptor.handleEventsWith(new MatchingHandler(shardId, latencyRecorder));
        disruptor.start();

        Server server = ServerBuilder.forPort(port)
                .addService(new IngestGrpcService(disruptor.getRingBuffer(), shardId))
                .build()
                .start();

        log.info("matching-engine shard={} escuchando gRPC en :{} (ring={})", shardId, port, ringSize);

        // Reporte periódico de percentiles: la contraparte interna de la medición del generador.
        ScheduledExecutorService reporter = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "latency-reporter");
            t.setDaemon(true);
            return t;
        });
        reporter.scheduleAtFixedRate(() -> {
            Histogram interval = latencyRecorder.getIntervalHistogram();
            if (interval.getTotalCount() == 0) {
                return;
            }
            log.info("shard={} n={} p50={}us p95={}us p99={}us p99.9={}us max={}us",
                    shardId,
                    interval.getTotalCount(),
                    interval.getValueAtPercentile(50.0),
                    interval.getValueAtPercentile(95.0),
                    interval.getValueAtPercentile(99.0),
                    interval.getValueAtPercentile(99.9),
                    interval.getMaxValue());
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
