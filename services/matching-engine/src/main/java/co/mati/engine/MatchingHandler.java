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
 */
public final class MatchingHandler implements EventHandler<OrderSlot> {

    private final int shardId;
    private final Map<String, OrderBook> books = new HashMap<>();
    private final Recorder latencyRecorder;

    public MatchingHandler(int shardId, Recorder latencyRecorder) {
        this.shardId = shardId;
        this.latencyRecorder = latencyRecorder;
    }

    @Override
    public void onEvent(OrderSlot slot, long sequence, boolean endOfBatch) {
        OrderBook book = books.computeIfAbsent(slot.symbol, s -> new OrderBook());
        long matched = book.match(slot.side, slot.priceCents, slot.quantity, slot.orderId);

        long latencyMicros = (System.nanoTime() - slot.arrivalNanos) / 1_000;
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
