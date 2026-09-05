package co.mati.router;

import co.mati.matching.v1.MatchingIngestGrpc;
import co.mati.metrics.PrometheusEndpoint;
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
 *   METRICS_PORT    — puerto del endpoint /metrics que raspa Prometheus (default 8085)
 */
public final class RouterMain {

    private static final Logger log = LoggerFactory.getLogger(RouterMain.class);

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String shardsSpec = env("SHARDS", "localhost:9090");
        int queueCapacity = Integer.parseInt(env("QUEUE_CAPACITY", "10000"));
        int metricsPort = Integer.parseInt(env("METRICS_PORT", "8085"));

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

        PrometheusEndpoint.start(metricsPort, () -> exponer(router, queueCapacity));
        log.info("router metricas Prometheus en :{}/metrics", metricsPort);

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

    /**
     * Exposición de Prometheus del router. A diferencia de la del motor se arma en
     * el momento del raspado, porque son cinco contadores atómicos y no hay
     * histogramas que drenar: leerlos no le cuesta nada al camino crítico.
     */
    private static String exponer(RouterService router, int queueCapacity) {
        StringBuilder sb = new StringBuilder(1024);

        PrometheusEndpoint.ayuda(sb, "router_requests_total", "counter",
                "Ordenes recibidas por el router, aceptadas y rechazadas.");
        PrometheusEndpoint.muestra(sb, "router_requests_total", "", router.receivedCount());

        PrometheusEndpoint.ayuda(sb, "router_rejected_total", "counter",
                "Ordenes rechazadas por la cola acotada. Debe ser 0 en las fases oficiales.");
        PrometheusEndpoint.muestra(sb, "router_rejected_total", "", router.rejectedCount());

        PrometheusEndpoint.ayuda(sb, "router_inflight", "gauge",
                "Solicitudes en vuelo en este instante. Al llegar a la capacidad, el router rechaza.");
        PrometheusEndpoint.muestra(sb, "router_inflight", "",
                (long) (queueCapacity - router.availablePermits()));

        PrometheusEndpoint.ayuda(sb, "router_queue_capacity", "gauge",
                "Tope de solicitudes en vuelo de la cola acotada.");
        PrometheusEndpoint.muestra(sb, "router_queue_capacity", "", (long) queueCapacity);

        PrometheusEndpoint.ayuda(sb, "router_routed_total", "counter",
                "Ordenes enviadas a cada particion: la evidencia del reparto por simbolo.");
        for (int i = 0; i < router.shardCount(); i++) {
            PrometheusEndpoint.muestra(sb, "router_routed_total",
                    "shard=\"" + i + "\"", router.routedCount(i));
        }
        return sb.toString();
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
