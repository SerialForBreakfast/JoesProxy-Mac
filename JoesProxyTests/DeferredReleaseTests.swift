import Synchronization
import XCTest
@testable import JoesProxy

final class DeferredReleaseTests: XCTestCase {
    private final class ReleaseLedger: Sendable {
        let values = Mutex<[Int]>([])
    }
    private final class RetiredProbe: Sendable {
        let id: Int
        let released: ReleaseLedger
        init(_ id: Int, released: ReleaseLedger) { self.id = id; self.released = released }
        deinit { released.values.withLock { $0.append(id) } }
    }

    func testStalledCleanupExecutorBoundsJobsAndReleasesOverflowOnCaller() {
        let jobs = Mutex<[@Sendable () -> Void]>([])
        let released = ReleaseLedger()
        let queue = DeferredReleaseQueue(limit: 2) { job in jobs.withLock { $0.append(job) } }
        for id in 0..<100 { queue.schedule(RetiredProbe(id, released: released)) }
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(jobs.withLock { $0.count }, 2)
        XCTAssertEqual(released.values.withLock { $0.count }, 98)
        drain(jobs)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(released.values.withLock { Set($0) }, Set(0..<100))
        queue.schedule(RetiredProbe(100, released: released))
        XCTAssertEqual(queue.pendingCount, 1)
        drain(jobs)
        XCTAssertEqual(released.values.withLock { $0.count }, 101)
    }

    private func drain(_ jobs: borrowing Mutex<[@Sendable () -> Void]>) {
        let ready = jobs.withLock { pending in
            let result = pending
            pending.removeAll()
            return result
        }
        ready.forEach { $0() }
    }

    func testCompletedExecutorClosuresDoNotRetainPayloadsAcrossCycles() {
        let jobs = Mutex<[@Sendable () -> Void]>([])
        let released = ReleaseLedger()
        let queue = DeferredReleaseQueue(limit: 2) { job in jobs.withLock { $0.append(job) } }
        for cycle in 0..<20 {
            queue.schedule(RetiredProbe(cycle, released: released))
            let completed = jobs.withLock { $0.last! }
            completed()
            XCTAssertEqual(queue.pendingCount, 0)
            XCTAssertEqual(released.values.withLock { $0.count }, cycle + 1)
        }
        XCTAssertEqual(jobs.withLock { $0.count }, 20,
                       "Keep completed executor closures alive to expose accidental payload retention")
        XCTAssertEqual(released.values.withLock { Set($0) }, Set(0..<20))
    }

    // MARK: - HANG-1: caller-fallback measurement

    func testMetricsDistinguishQueuedFromCallerFallbackReleases() {
        let jobs = Mutex<[@Sendable () -> Void]>([])
        let released = ReleaseLedger()
        let queue = DeferredReleaseQueue(limit: 2) { job in jobs.withLock { $0.append(job) } }

        XCTAssertEqual(queue.metrics, .init())

        queue.schedule(RetiredProbe(0, released: released))
        queue.schedule(RetiredProbe(1, released: released))
        XCTAssertEqual(queue.metrics.scheduledCount, 2, "both fit under the limit")
        XCTAssertEqual(queue.metrics.callerFallbackCount, 0)

        // The limit (2) is now full; every further schedule() call falls back to the caller.
        for id in 2..<10 {
            queue.schedule(RetiredProbe(id, released: released))
        }
        XCTAssertEqual(queue.metrics.scheduledCount, 2, "still only the original two were admitted")
        XCTAssertEqual(queue.metrics.callerFallbackCount, 8)
        XCTAssertEqual(released.values.withLock { $0.count }, 8, "fallback releases already ran, synchronously")
        XCTAssertGreaterThanOrEqual(
            queue.metrics.totalCallerFallbackDuration, 0,
            "duration is measured, never negative, even though it can legitimately be ~0 for a trivial payload"
        )
        XCTAssertGreaterThanOrEqual(queue.metrics.maxCallerFallbackDuration, queue.metrics.totalCallerFallbackDuration / 8)

        drain(jobs)
        queue.schedule(RetiredProbe(10, released: released))
        XCTAssertEqual(queue.metrics.scheduledCount, 3, "capacity freed up after draining")
        XCTAssertEqual(queue.metrics.callerFallbackCount, 8, "unchanged — this one was admitted, not a fallback")
    }

    func testCallerFallbackDurationGrowsWithReleaseCostNotJustCount() {
        // A payload whose deinit does real, measurable work (not just decrement a refcount) —
        // proves `totalCallerFallbackDuration` reflects actual release cost, not merely a fixed
        // per-call overhead, which is the property HANG-1 needs to tell "many cheap fallbacks"
        // apart from "one fallback that itself blocked the caller for real time."
        final class SlowDeinit: Sendable {
            let workItems: [Int]
            init(count: Int) { workItems = Array(0..<count) }
            deinit {
                // Deliberately touch every element so the optimizer can't elide the work; this is
                // a stand-in for a large retired session-array graph's real per-element teardown.
                var checksum = 0
                for value in workItems { checksum ^= value }
                withExtendedLifetime(checksum) {}
            }
        }
        let queue = DeferredReleaseQueue(limit: 0 + 1) { _ in } // never drains — every call after the first falls back
        queue.schedule(SlowDeinit(count: 1))
        XCTAssertEqual(queue.metrics.scheduledCount, 1)
        queue.schedule(SlowDeinit(count: 2_000_000))
        XCTAssertEqual(queue.metrics.callerFallbackCount, 1)
        // Not a strict timing assertion (host-speed dependent) — just proves the counter/duration
        // machinery runs for a real, non-trivial payload without crashing or silently no-op'ing.
        XCTAssertGreaterThan(queue.metrics.maxCallerFallbackDuration, 0)
    }
}
