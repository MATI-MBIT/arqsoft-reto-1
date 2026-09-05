package co.mati.metrics;

import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.function.Supplier;

/**
 * Endpoint {@code /metrics} en formato de texto de Prometheus, servido por el
 * servidor HTTP del JDK.
 *
 * <p><b>Por qué sin librería.</b> Un cliente de Prometheus traería una
 * dependencia y su modelo de registro global al camino de medición. Lo que hace
 * falta aquí es publicar percentiles que <i>ya</i> están calculados por
 * HdrHistogram cada diez segundos, así que el trabajo real es serializar texto.
 * El servidor del JDK alcanza y no agrega nada al catálogo de versiones.
 *
 * <p><b>Fuera del camino crítico, por construcción.</b> El proveedor devuelve una
 * cadena que otro hilo ya dejó armada; el hilo HTTP no toca histogramas, no toma
 * candados y no compite con el escritor. Un raspado no puede alterar la medición
 * que está raspando.
 */
public final class PrometheusEndpoint {

    private final HttpServer server;

    private PrometheusEndpoint(HttpServer server) {
        this.server = server;
    }

    /**
     * Levanta el endpoint. {@code exposicion} se invoca en cada raspado y debe ser
     * barato: se espera que devuelva texto ya construido.
     */
    public static PrometheusEndpoint start(int port, Supplier<String> exposicion) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/metrics", exchange -> {
            byte[] cuerpo = exposicion.get().getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            exchange.sendResponseHeaders(200, cuerpo.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(cuerpo);
            }
        });
        // Sonda de vida: Compose la usa para no dar por arriba un contenedor que
        // todavia no responde. El contexto "/metrics" gana por prefijo mas largo.
        server.createContext("/", exchange -> {
            byte[] cuerpo = "ok\n".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, cuerpo.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(cuerpo);
            }
        });
        server.setExecutor(Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "metrics-http");
            t.setDaemon(true);
            return t;
        }));
        server.start();
        return new PrometheusEndpoint(server);
    }

    public void stop() {
        server.stop(0);
    }

    // ---------------------------------------------------------------------
    // Ayudas de formato. Locale.ROOT es obligatorio: con una configuracion
    // regional que use coma decimal, Prometheus rechaza la muestra entera.
    // ---------------------------------------------------------------------

    /** Cuantiles que se publican, y su etiqueta exacta. */
    public static final double[] CUANTILES = {50.0, 95.0, 99.0, 99.9};
    public static final String[] ETIQUETAS_CUANTIL = {"0.5", "0.95", "0.99", "0.999"};

    public static void ayuda(StringBuilder sb, String nombre, String tipo, String texto) {
        sb.append("# HELP ").append(nombre).append(' ').append(texto).append('\n');
        sb.append("# TYPE ").append(nombre).append(' ').append(tipo).append('\n');
    }

    public static void muestra(StringBuilder sb, String nombre, String etiquetas, long valor) {
        sb.append(nombre);
        if (etiquetas != null && !etiquetas.isEmpty()) {
            sb.append('{').append(etiquetas).append('}');
        }
        sb.append(' ').append(valor).append('\n');
    }

    public static void muestra(StringBuilder sb, String nombre, String etiquetas, double valor) {
        sb.append(nombre);
        if (etiquetas != null && !etiquetas.isEmpty()) {
            sb.append('{').append(etiquetas).append('}');
        }
        sb.append(' ').append(String.format(Locale.ROOT, "%.6f", valor)).append('\n');
    }
}
