package co.mati.engine;

import co.mati.matching.v1.Side;

import java.util.ArrayDeque;
import java.util.Comparator;
import java.util.Iterator;
import java.util.Map;
import java.util.TreeMap;

/**
 * Libro de órdenes en memoria de UN activo, con prioridad precio-tiempo.
 * No es thread-safe a propósito: por diseño (D-03 / patrón LMAX) solo lo toca
 * el único hilo escritor de la partición, así que la exclusión mutua está
 * garantizada por construcción y no por locks.
 */
final class OrderBook {

    /** Orden en reposo esperando contraparte. */
    static final class Resting {
        final String orderId;
        long quantity;

        Resting(String orderId, long quantity) {
            this.orderId = orderId;
            this.quantity = quantity;
        }
    }

    /** Compras: mejor precio = el más alto primero. */
    private final TreeMap<Long, ArrayDeque<Resting>> bids = new TreeMap<>(Comparator.reverseOrder());
    /** Ventas: mejor precio = el más bajo primero. */
    private final TreeMap<Long, ArrayDeque<Resting>> asks = new TreeMap<>();

    /**
     * Empareja la orden entrante contra el lado opuesto del libro.
     *
     * @return cantidad materializada (0 si no hubo contraparte válida; el resto queda en el libro).
     */
    long match(Side side, long priceCents, long quantity, String orderId) {
        TreeMap<Long, ArrayDeque<Resting>> opposite = (side == Side.BUY) ? asks : bids;
        long remaining = quantity;
        long matched = 0;

        Iterator<Map.Entry<Long, ArrayDeque<Resting>>> levels = opposite.entrySet().iterator();
        while (remaining > 0 && levels.hasNext()) {
            Map.Entry<Long, ArrayDeque<Resting>> level = levels.next();
            long levelPrice = level.getKey();
            boolean crosses = (side == Side.BUY) ? levelPrice <= priceCents : levelPrice >= priceCents;
            if (!crosses) {
                break; // los niveles siguientes son aún peores: no hay más cruce posible
            }
            ArrayDeque<Resting> queue = level.getValue();
            while (remaining > 0 && !queue.isEmpty()) {
                Resting head = queue.peekFirst();
                long fill = Math.min(remaining, head.quantity);
                head.quantity -= fill;
                remaining -= fill;
                matched += fill;
                if (head.quantity == 0) {
                    queue.pollFirst();
                }
            }
            if (queue.isEmpty()) {
                levels.remove();
            }
        }

        if (remaining > 0) {
            rest(side, priceCents, remaining, orderId);
        }
        return matched;
    }

    private void rest(Side side, long priceCents, long quantity, String orderId) {
        TreeMap<Long, ArrayDeque<Resting>> book = (side == Side.BUY) ? bids : asks;
        book.computeIfAbsent(priceCents, p -> new ArrayDeque<>()).addLast(new Resting(orderId, quantity));
    }

    int restingLevels() {
        return bids.size() + asks.size();
    }
}
