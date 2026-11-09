import NIOCore

/// Destination-loop confined. Only one chunk and one delay are outstanding per buffer.
/// Closing the channel cancels the delay and drops unsent bytes without waiting for the timer.
final class ThrottledBufferPump {
    private var buffer: ByteBuffer?
    private let channel: Channel
    private let kbps: Int
    private let promise: EventLoopPromise<Void>
    private var delay: Scheduled<Void>?
    private var finished = false

    init(buffer: ByteBuffer, channel: Channel, kbps: Int) {
        self.buffer = buffer
        self.channel = channel
        self.kbps = kbps
        promise = channel.eventLoop.makePromise(of: Void.self)
    }

    func start(latencyMs: Int) -> EventLoopFuture<Void> {
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.finish(.failure(ChannelError.ioOnClosedChannel))
        }
        schedule(after: .milliseconds(Int64(latencyMs)))
        return promise.futureResult
    }

    private func schedule(after interval: TimeAmount) {
        guard !finished else { return }
        delay = channel.eventLoop.scheduleTask(in: interval) {
            self.delay = nil
            self.writeNext()
        }
    }

    private func writeNext() {
        guard !finished else { return }
        guard channel.isActive else { finish(.failure(ChannelError.ioOnClosedChannel)); return }
        let count = min(buffer?.readableBytes ?? 0, 16_384)
        guard let chunk = buffer?.readSlice(length: count),
              chunk.readableBytes > 0 else { finish(.success(())); return }
        let byteCount = chunk.readableBytes
        channel.writeAndFlush(chunk).whenComplete { result in
            guard !self.finished else { return }
            switch result {
            case .failure(let error): self.finish(.failure(error))
            case .success:
                if self.buffer?.readableBytes == 0 { self.finish(.success(())) }
                else { self.schedule(after: NetworkThrottleWriter.delayAfterChunk(byteCount: byteCount, kbps: self.kbps)) }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        delay?.cancel()
        delay = nil
        buffer = nil
        promise.completeWith(result)
    }
}
