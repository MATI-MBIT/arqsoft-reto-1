package co.mati.router;

import co.mati.matching.v1.MatchingIngestGrpc;
import co.mati.matching.v1.OrderRequest;
import co.mati.matching.v1.OrderResponse;
import co.mati.matching.v1.Status;
import io.grpc.stub.StreamObserver;

import java.util.List;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

/**
 * Router de sharding (D-03): enruta cada orden de forma determinística
 * al shard dueño de su símbolo — hash(symbol) % N — de modo que todas las
 * órdenes de un mismo activo caen siempre en el mismo único escritor.
 *
 * La cola acotada de la táctica de amortiguación se materializa aquí como un
 * límite de solicitudes en vuelo (Semaphore): al llenarse, se rechaza con
 * REJECTED en vez de encolar sin límite — se prefiere frenar la entrada antes
 * que prometer una latencia incumplible.
 */
public final class RouterService extends MatchingIngestGrpc.MatchingIngestImplBase {

    private final List<MatchingIngestGrpc.MatchingIngestStub> shardStubs;
    private final Semaphore inFlight;
    private final AtomicLong rejectedByBackpressure = new AtomicLong();
    private final LongAdder received = new LongAdder();
    /**
     * Órdenes enviadas a cada partición. Es la evidencia del reparto vista desde
     * el router: si el conjunto de símbolos desbalancea, se ve aquí antes de que
     * el desbalance se disfrace de problema de latencia.
     */
    private final LongAdder[] routed;

    public RouterService(List<MatchingIngestGrpc.MatchingIngestStub> shardStubs, int queueCapacity) {
        this.shardStubs = shardStubs;
        this.inFlight = new Semaphore(queueCapacity);
        this.routed = new LongAdder[shardStubs.size()];
        for (int i = 0; i < routed.length; i++) {
            routed[i] = new LongAdder();
        }
    }

    @Override
    public void submitOrder(OrderRequest request, StreamObserver<OrderResponse> responseObserver) {
        received.increment();
        if (!inFlight.tryAcquire()) {
            rejectedByBackpressure.incrementAndGet();
            responseObserver.onNext(OrderResponse.newBuilder()
                    .setOrderId(request.getOrderId())
                    .setStatus(Status.REJECTED)
                    .setShardId(-1)
                    .build());
            responseObserver.onCompleted();
            return;
        }

        int shard = Math.floorMod(request.getSymbol().hashCode(), shardStubs.size());
        routed[shard].increment();

        shardStubs.get(shard).submitOrder(request, new StreamObserver<>() {
            @Override
            public void onNext(OrderResponse value) {
                responseObserver.onNext(value);
            }

            @Override
            public void onError(Throwable t) {
                inFlight.release();
                responseObserver.onError(t);
            }

            @Override
            public void onCompleted() {
                inFlight.release();
                responseObserver.onCompleted();
            }
        });
    }

    public long rejectedCount() {
        return rejectedByBackpressure.get();
    }

    public int availablePermits() {
        return inFlight.availablePermits();
    }

    public long receivedCount() {
        return received.sum();
    }

    public long routedCount(int shard) {
        return routed[shard].sum();
    }

    public int shardCount() {
        return shardStubs.size();
    }
}
