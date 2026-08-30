package co.mati.router;

import co.mati.matching.v1.MatchingIngestGrpc;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Servicio de ingesta gRPC (D-07) con router de sharding y cola acotada (E01).
 *
 * Variables de entorno:
 *   PORT            — puerto gRPC del router (default 8080)
 *   SHARDS          — lista host:port de los shards, separada por comas
 *                     (default "localhost:9090")
 *   QUEUE_CAPACITY  — solicitudes en vuelo máximas antes de rechazar (default 10000)
 */
public final class RouterMain {

    private static final Logger log = LoggerFactory.getLogger(RouterMain.class);

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String shardsSpec = env("SHARDS", "localhost:9090");
        int queueCapacity = Integer.parseInt(env("QUEUE_CAPACITY", "10000"));

        List<ManagedChannel> channels = new ArrayList<>();
        List<MatchingIngestGrpc.MatchingIngestStub> stubs = new ArrayList<>();
        for (String target : shardsSpec.split(",")) {
            ManagedChannel channel = ManagedChannelBuilder.forTarget(target.trim())
                    .usePlaintext()
                    .build();
            channels.add(channel);
            stubs.add(MatchingIngestGrpc.newStub(channel));
        }

        RouterService router = new RouterService(stubs, queueCapacity);
        Server server = ServerBuilder.forPort(port)
                .addService(router)
                .build()
                .start();

        log.info("ingest-router escuchando gRPC en :{} — {} shard(s): {} — cola acotada={}",
                port, stubs.size(), shardsSpec, queueCapacity);

        ScheduledExecutorService reporter = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "router-reporter");
            t.setDaemon(true);
            return t;
        });
        reporter.scheduleAtFixedRate(() ->
                log.info("router en_vuelo={} rechazadas_backpressure={}",
                        queueCapacity - router.availablePermits(), router.rejectedCount()),
                10, 10, TimeUnit.SECONDS);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            server.shutdown();
            channels.forEach(ManagedChannel::shutdown);
        }));

        server.awaitTermination();
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
