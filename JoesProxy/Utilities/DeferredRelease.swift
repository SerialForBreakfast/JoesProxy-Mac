import Foundation

/// Transfers destruction of large, no-longer-visible value graphs away from the main actor.
///
/// Callers must first replace their live state, then pass the retired Sendable snapshot here.
/// At most eight retirement jobs may retain snapshots. Under pressure, release on the caller
/// rather than queueing more graphs. Other owners can still determine the final destruction thread.
enum DeferredRelease {
    private static let queue = DeferredReleaseQueue()
    static func schedule<Value: Sendable>(_ value: consuming Value) {
        queue.schedule(value)
    }
    /// HANG-1: exposes whether retirements are actually reaching the background queue, or falling
    /// back to the calling thread often enough to matter. See `DeferredReleaseQueue.metrics`.
    static var metrics: DeferredReleaseQueue.Metrics { queue.metrics }
}

/// The lock protects job accounting; executor callbacks and destruction never run under it.
final class DeferredReleaseQueue: @unchecked Sendable {
    /// The payload is cleared before returning capacity; keeping an executor closure alive
    /// after execution must not keep its retired graph alive as well.
    private final class Payload<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        init(_ value: Value) { self.value = value }
        func release() {
            let retired = lock.withLock {
                let result = value
                value = nil
                return result
            }
            withExtendedLifetime(retired) {}
        }
    }
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let limit: Int
    private let execute: Executor
    private var pending = 0
    private var metricsState = Metrics()

    /// HANG-1: bounded counters distinguishing "handed to the background queue" from "the queue
    /// was full, so this retirement's own deinit happened on whoever called `schedule`" — the
    /// second case is the one that can turn into main-thread cost, since every real call site in
    /// this codebase calls `schedule` from inside `ProxySessionRecorder`'s `MainActor.run` batch
    /// drain (see `SessionStore.append`/`clear`/`remove`). `callerFallbackDuration` measures wall
    /// time from the fallback decision to `schedule` returning.
    ///
    /// `schedule`'s parameter is `consuming` specifically so this measurement is trustworthy: an
    /// earlier, non-`consuming` version of this code measured a ~1µs cost for retiring an entire
    /// ~10,000-session array (1.8GB of response bodies) — implausibly fast, and wrong. The caller's
    /// own binding was still alive for the whole measured window (ordinary function parameters are
    /// released at the caller's own scope exit, not necessarily right after the call returns,
    /// especially in an unoptimized debug build), so the bracket below was timing an intermediate
    /// refcount decrement, not the true final deallocation. `consuming` makes this function the
    /// value's sole owner from the call site onward — the caller's own reference is invalidated by
    /// the compiler at the call, not merely conventionally discouraged — so the release inside this
    /// bracket genuinely is the last one, regardless of build configuration or caller code shape.
    struct Metrics: Equatable, Sendable {
        var scheduledCount = 0
        var callerFallbackCount = 0
        var totalCallerFallbackDuration: TimeInterval = 0
        var maxCallerFallbackDuration: TimeInterval = 0
    }

    init(limit: Int = 8, execute: @escaping Executor = { work in
        DispatchQueue.global(qos: .utility).async(execute: work)
    }) {
        precondition(limit > 0)
        self.limit = limit
        self.execute = execute
    }

    var pendingCount: Int { lock.withLock { pending } }
    var metrics: Metrics { lock.withLock { metricsState } }

    func schedule<Value: Sendable>(_ value: consuming Value) {
        let admitted = lock.withLock {
            guard pending < limit else { return false }
            pending += 1
            return true
        }
        guard admitted else {
            let start = ContinuousClock.now
            var retiring: Value? = consume value
            retiring = nil
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            lock.withLock {
                metricsState.callerFallbackCount += 1
                metricsState.totalCallerFallbackDuration += seconds
                metricsState.maxCallerFallbackDuration = max(metricsState.maxCallerFallbackDuration, seconds)
            }
            return
        }
        lock.withLock { metricsState.scheduledCount += 1 }
        let payload = Payload(value)
        execute {
            payload.release()
            self.lock.withLock { self.pending -= 1 }
        }
    }
}
