package co.mati.engine;

import com.lmax.disruptor.EventHandler;
import org.HdrHistogram.Recorder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/**
 * Registro de eventos (journal) del shard: escribe cada orden en un archivo de
 * solo-anexado antes de que se pierda la memoria del proceso.
 *
 * <p><b>Qué hipótesis prueba.</b> H1 afirma que el patrón sostiene el p95 «con el
 * journaling fuera del camino crítico». Esa cláusula nunca se probó porque el PoC
 * no tenía journaling. El Disruptor permite las dos disposiciones y la diferencia
 * entre ellas es justamente la afirmación:
 *
 * <ul>
 *   <li>{@code PARALELO} — {@code handleEventsWith(journal, matcher)}: los dos
 *       consumidores leen la MISMA secuencia de forma independiente. El journaling
 *       no suma latencia al cliente… pero el matcher responde sin esperar a que el
 *       registro llegue a disco, así que <b>el acuse no garantiza durabilidad</b>.</li>
 *   <li>{@code SERIE} — {@code handleEventsWith(journal).then(matcher)}: primero se
 *       registra, después se empareja. El acuse sí implica durabilidad, pero el
 *       journaling entra al camino crítico y su costo se suma al p95.</li>
 * </ul>
 *
 * <p>No hay una correcta: son dos contratos distintos con el cliente. El
 * experimento mide el precio de cada uno.
 *
 * <p><b>Durabilidad por lote.</b> El {@code force()} se hace una vez por lote
 * ({@code endOfBatch}), no por evento. Es el diseño de LMAX y es lo que lo vuelve
 * viable: bajo carga el lote crece, así que el costo del fsync se amortiza entre
 * más órdenes — el sistema se abarata justo cuando más se le exige. Un fsync por
 * evento convertiría cada orden en una escritura sincrónica a disco.
 *
 * <p><b>No muta el evento.</b> Con consumidores en paralelo el slot pertenece al
 * ring hasta que todos pasaron; limpiarlo es tarea de un manejador encadenado al
 * final. Ver {@link EngineMain}.
 */
public final class JournalHandler implements EventHandler<OrderSlot> {

    private static final Logger log = LoggerFactory.getLogger(JournalHandler.class);

    public enum Mode {
        /** Sin journaling: la configuración original del PoC. */
        OFF,
        /** Consumidor paralelo: fuera del camino crítico, acuse sin durabilidad. */
        PARALELO,
        /** Encadenado antes del matcher: durabilidad antes del acuse, con costo. */
        SERIE;

        static Mode fromEnv() {
            String v = System.getenv("JOURNAL");
            if (v == null || v.isBlank()) {
                return OFF;
            }
            return switch (v.trim().toLowerCase()) {
                case "paralelo", "parallel" -> PARALELO;
                case "serie", "serial"      -> SERIE;
                default                     -> OFF;
            };
        }
    }

    /** Holgado para el registro más grande posible; se reutiliza en cada evento. */
    private static final int BUFFER_BYTES = 512;

    private final FileChannel channel;
    private final ByteBuffer buffer = ByteBuffer.allocateDirect(BUFFER_BYTES);
    private final Recorder journalRecorder;

    private long records;
    private long bytes;
    private long batches;

    public JournalHandler(int shardId, Path directory, Recorder journalRecorder) throws IOException {
        Files.createDirectories(directory);
        Path file = directory.resolve("shard-" + shardId + ".journal");
        this.channel = FileChannel.open(file,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING);
        this.journalRecorder = journalRecorder;
        log.info("shard={} journal en {}", shardId, file.toAbsolutePath());
    }

    @Override
    public void onEvent(OrderSlot slot, long sequence, boolean endOfBatch) {
        long start = System.nanoTime();
        buffer.clear();
        buffer.putLong(sequence);
        buffer.putLong(slot.arrivalNanos);
        buffer.put((byte) slot.side.getNumber());
        buffer.putLong(slot.priceCents);
        buffer.putLong(slot.quantity);
        putAscii(slot.symbol);
        putAscii(slot.orderId);
        buffer.flip();
        int written = buffer.remaining();
        try {
            while (buffer.hasRemaining()) {
                channel.write(buffer);
            }
            if (endOfBatch) {
                // Un fsync por LOTE, no por evento: bajo carga el lote crece y el
                // costo se amortiza. Es la sympathy mecánica del patrón.
                channel.force(false);
                batches++;
            }
        } catch (IOException e) {
            // Un journal que falla en silencio es peor que no tenerlo.
            throw new IllegalStateException("fallo al escribir el journal", e);
        }
        records++;
        bytes += written;
        journalRecorder.recordValue(Math.max(1, (System.nanoTime() - start) / 1_000));
    }

    /**
     * Escribe la cadena sin materializar un {@code byte[]}: {@code getBytes()}
     * asignaría en el camino crítico y el patrón existe para no hacer eso.
     * Los nemotécnicos y los UUID son ASCII.
     */
    private void putAscii(String s) {
        int n = Math.min(s.length(), 255);
        buffer.put((byte) n);
        for (int i = 0; i < n; i++) {
            buffer.put((byte) s.charAt(i));
        }
    }

    public long records() {
        return records;
    }

    /** Órdenes por fsync. Cuanto mayor, más se amortiza la durabilidad. */
    public double ordersPerBatch() {
        return batches == 0 ? 0.0 : (double) records / batches;
    }

    public String describe(Mode mode, long recordCount) {
        return String.format("modo=%s registros=%d bytes=%d ordenes_por_fsync=%.1f",
                mode, recordCount, bytes, ordersPerBatch());
    }

    public void close() {
        try {
            channel.force(true);
            channel.close();
        } catch (IOException e) {
            log.warn("no se pudo cerrar el journal limpiamente", e);
        }
    }
}
