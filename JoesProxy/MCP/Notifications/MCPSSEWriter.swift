import Foundation
import NIO
import NIOHTTP1

/// Abstraction over an open SSE response body for hub delivery and tests.
protocol MCPSSEWriting: AnyObject {
    func writeSSE(jsonObject: [String: Any]) -> Bool
    func writeComment(_ comment: String) -> Bool
    /// Fire-and-forget close — the underlying channel close is scheduled on its event loop but not
    /// awaited. Fine for replacing/dropping a single writer; do NOT use this for graceful shutdown
    /// (see `closeAndWait()`).
    func close()
    /// Closes and waits for the underlying channel to actually finish closing. Graceful shutdown
    /// must use this — without it, `MCPNotificationHub.closeAllWriters()` returns as soon as every
    /// close is *scheduled*, not delivered, and the event-loop group can tear down before a
    /// scheduled `writeAndFlush(.end).whenComplete { close() }` actually runs, silently dropping
    /// the client's graceful close frame.
    func closeAndWait() async
}

/// NIO-backed SSE writer that appends `data:` frames to an already-open HTTP response.
///
/// Concurrency: created on the channel event loop; `Channel` is thread-safe across loops.
/// JSON serialization runs on the main actor before handing bytes to the event loop.
final class MCPSSEWriter: MCPSSEWriting, @unchecked Sendable {
    private let channel: Channel
    private let onClose: @Sendable () -> Void
    private let closeLock = NSLock()
    private var closed = false

    init(channel: Channel, onClose: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.onClose = onClose
    }

    func writeSSE(jsonObject: [String: Any]) -> Bool {
        guard channel.isActive else { return false }
        guard let body = try? JSONSerialization.data(withJSONObject: jsonObject),
              let json = String(data: body, encoding: .utf8) else {
            return false
        }
        return writeRaw("data: \(json)\n\n")
    }

    func writeComment(_ comment: String) -> Bool {
        guard channel.isActive else { return false }
        return writeRaw(": \(comment)\n\n")
    }

    func close() {
        performClose(continuation: nil)
    }

    func closeAndWait() async {
        await withCheckedContinuation { continuation in
            performClose(continuation: continuation)
        }
    }

    private func performClose(continuation: CheckedContinuation<Void, Never>?) {
        closeLock.lock()
        let wasAlreadyClosed = closed
        closed = true
        closeLock.unlock()
        guard !wasAlreadyClosed else {
            continuation?.resume()
            return
        }
        onClose()
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else {
                continuation?.resume()
                return
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close().whenComplete { _ in
                    continuation?.resume()
                }
            }
        }
    }

    private func writeRaw(_ frame: String) -> Bool {
        var buffer = channel.allocator.buffer(capacity: frame.utf8.count)
        buffer.writeString(frame)
        channel.eventLoop.execute { [weak self, channel, buffer] in
            guard channel.isActive else { return }
            // The synchronous `Bool` this method returns only reflects whether a write was
            // scheduled, not whether it was actually delivered — the write itself is async. A
            // discarded future here would mean a dead peer (TCP RST not yet observed, VPN/network
            // transition, etc.) looks identical to a healthy one forever: heartbeats would keep
            // "succeeding," never freeing this writer's slot in the small (4) listen-stream budget.
            // Treat a write failure as equivalent to the channel going inactive.
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).whenFailure { _ in
                self?.close()
            }
        }
        return true
    }
}

/// In-memory SSE writer used by unit tests.
final class MCPMockSSEWriter: MCPSSEWriting {
    private(set) var frames: [[String: Any]] = []
    private(set) var comments: [String] = []
    private(set) var didClose = false

    func writeSSE(jsonObject: [String: Any]) -> Bool {
        frames.append(jsonObject)
        return true
    }

    func writeComment(_ comment: String) -> Bool {
        comments.append(comment)
        return true
    }

    func close() {
        didClose = true
    }

    func closeAndWait() async {
        close()
    }
}
