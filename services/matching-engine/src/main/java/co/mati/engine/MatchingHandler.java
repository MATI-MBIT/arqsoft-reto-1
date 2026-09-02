package co.mati.engine;

import co.mati.matching.v1.OrderResponse;
import co.mati.matching.v1.Status;
import com.lmax.disruptor.EventHandler;
import org.HdrHistogram.Recorder;

import java.util.HashMap;
import java.util.Map;

/**
 * ÚNICO consumidor del ring buffer: el "single writer" del patrón LMAX.
 * Procesa los eventos secuencialmente, en orden de llegada, sin locks.
 * La latencia que registra (arribo → materialización) es la medida de ASR-02.
 *
 * <p>Registra la latencia descompuesta en sus dos sumandos, porque agregados
 * dicen cosas distintas:
 * <ul>
 *   <li><b>espera</b> — arribo al shard → el escritor toma el evento. Es tiempo
 *       en el ring buffer: vale ~0 mientras haya holgura y explota cuando ρ→1.
 *       Es el detector de saturación.</li>
 *   <li><b>servicio</b> — matching + modelo de lógica de negocio. Es S, el
 *       parámetro que fija el techo del shard (techo = 1/S), y no depende de
 *       la carga.</li>
 * </ul>
 * total = espera + servicio. Ver un p95 alto no dice nada por sí solo; saber
 * cuál de los dos sumandos creció es lo que distingue «hay que shardear más»
 * de «hay que abaratar el costo por orden».
 */
public final class MatchingHandler implements EventHandler<OrderSlot> {

    private final int shardId;
    private final Map<String, OrderBook> books = new HashMap<>();
    private final Recorder latencyRecorder;
    private final Recorder waitRecorder;
    private final Recorder serviceRecorder;
    private final BusinessLogicModel businessLogic;

    public MatchingHandler(int shardId,
                           Recorder latencyRecorder,
                           Recorder waitRecorder,
                           Recorder serviceRecorder,
                           BusinessLogicModel businessLogic) {
        this.shardId = shardId;
        this.latencyRecorder = latencyRecorder;
        this.waitRecorder = waitRecorder;
        this.serviceRecorder = serviceRecorder;
        this.businessLogic = businessLogic;
    }

    @Override
    public void onEvent(OrderSlot slot, long sequence, boolean endOfBatch) {
        long startNanos = System.nanoTime();
        waitRecorder.recordValue(Math.max(1, (startNanos - slot.arrivalNanos) / 1_000));

        OrderBook book = books.computeIfAbsent(slot.symbol, s -> new OrderBook());
        long matched = book.match(slot.side, slot.priceCents, slot.quantity, slot.orderId);

        // Costo del trabajo que el PoC no implementa (validación, riesgo, tipos de
        // orden, comisiones, trades). Va aquí, en el hilo del único escritor, porque
        // es ahí donde se serializa; que corra antes o después del match da igual
        // para el tiempo de servicio, que es lo que se está modelando.
        businessLogic.apply();

        long endNanos = System.nanoTime();
        serviceRecorder.recordValue(Math.max(1, (endNanos - startNanos) / 1_000));

        long latencyMicros = (endNanos - slot.arrivalNanos) / 1_000;
        latencyRecorder.recordValue(Math.max(1, latencyMicros));

        Status status = (matched == 0) ? Status.RESTING
                : (matched < slot.quantity) ? Status.PARTIALLY_MATCHED
                : Status.MATCHED;

        OrderResponse response = OrderResponse.newBuilder()
                .setOrderId(slot.orderId)
                .setStatus(status)
                .setMatchedQuantity(matched)
                .setEngineLatencyMicros(latencyMicros)
                .setShardId(shardId)
                .build();

        slot.completion.complete(response);
        slot.clear(); // no retener referencias: el slot se recicla
    }
}
