package co.mati.engine;

import co.mati.matching.v1.OrderResponse;
import co.mati.matching.v1.Side;

import java.util.concurrent.CompletableFuture;

/**
 * Entrada (slot) del ring buffer del Disruptor. Mutable y reutilizable por diseño:
 * el Disruptor preasigna todos los slots al arrancar y los recicla, de modo que en
 * régimen no se crea basura en el camino crítico (menos presión de GC — causa #1
 * de cola larga según el análisis de decisiones).
 */
public final class OrderSlot {

    String orderId;
    String symbol;
    Side side;
    long priceCents;
    long quantity;
    long arrivalNanos;
    CompletableFuture<OrderResponse> completion;

    void set(String orderId, String symbol, Side side, long priceCents, long quantity,
             long arrivalNanos, CompletableFuture<OrderResponse> completion) {
        this.orderId = orderId;
        this.symbol = symbol;
        this.side = side;
        this.priceCents = priceCents;
        this.quantity = quantity;
        this.arrivalNanos = arrivalNanos;
        this.completion = completion;
    }

    void clear() {
        this.orderId = null;
        this.symbol = null;
        this.side = null;
        this.completion = null;
    }
}
