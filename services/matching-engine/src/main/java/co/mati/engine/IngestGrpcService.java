package co.mati.engine;

import co.mati.matching.v1.MatchingIngestGrpc;
import co.mati.matching.v1.OrderRequest;
import co.mati.matching.v1.OrderResponse;
import co.mati.matching.v1.Status;
import com.lmax.disruptor.InsufficientCapacityException;
import com.lmax.disruptor.RingBuffer;
import io.grpc.stub.StreamObserver;

import java.util.concurrent.CompletableFuture;

/**
 * Borde gRPC del shard. Publica cada orden en el ring buffer con tryNext():
 * si el ring está lleno NO bloquea los hilos de gRPC — responde REJECTED,
 * que es la señal de backpressure de la táctica de amortiguación (cola acotada).
 */
public final class IngestGrpcService extends MatchingIngestGrpc.MatchingIngestImplBase {

    private final RingBuffer<OrderSlot> ringBuffer;
    private final int shardId;

    public IngestGrpcService(RingBuffer<OrderSlot> ringBuffer, int shardId) {
        this.ringBuffer = ringBuffer;
        this.shardId = shardId;
    }

    @Override
    public void submitOrder(OrderRequest request, StreamObserver<OrderResponse> responseObserver) {
        long arrivalNanos = System.nanoTime(); // t0 de la medida arribo → materialización
        CompletableFuture<OrderResponse> completion = new CompletableFuture<>();

        long sequence;
        try {
            sequence = ringBuffer.tryNext();
        } catch (InsufficientCapacityException backpressure) {
            responseObserver.onNext(OrderResponse.newBuilder()
                    .setOrderId(request.getOrderId())
                    .setStatus(Status.REJECTED)
                    .setShardId(shardId)
                    .build());
            responseObserver.onCompleted();
            return;
        }

        try {
            OrderSlot slot = ringBuffer.get(sequence);
            slot.set(request.getOrderId(), request.getSymbol(), request.getSide(),
                    request.getPriceCents(), request.getQuantity(), arrivalNanos, completion);
        } finally {
            ringBuffer.publish(sequence);
        }

        completion.whenComplete((response, error) -> {
            if (error != null) {
                responseObserver.onError(error);
            } else {
                responseObserver.onNext(response);
                responseObserver.onCompleted();
            }
        });
    }
}
