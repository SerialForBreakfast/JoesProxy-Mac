import XCTest
@testable import JoesProxy

final class CaptureTransportDiagnosticsTests: XCTestCase {
    func testProgressIsBoundedTimestampedAndResettable() {
        let diagnostics = CaptureTransportDiagnostics()
        let now = Date(timeIntervalSince1970: 100)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            diagnostics.recordProgress(.routingStarted, at: now)
        }
        diagnostics.recordProgress(.routingStarted, at: now.addingTimeInterval(-1))
        XCTAssertEqual(diagnostics.snapshot().requestProgress.count, 1)
        XCTAssertEqual(diagnostics.snapshot().requestProgress[.routingStarted]?.count, 1001)
        XCTAssertEqual(diagnostics.snapshot().requestProgress[.routingStarted]?.lastObservedAt, now)
        diagnostics.reset()
        XCTAssertEqual(diagnostics.snapshot(), .empty)
    }

    func testCountersIncrementAndReset() {
        let diagnostics = CaptureTransportDiagnostics()

        diagnostics.recordChannelOpened()
        diagnostics.recordChannelOpened()
        diagnostics.recordChannelClosed()
        diagnostics.recordUpstreamResponseBytes(1024)
        diagnostics.recordExpectedClientDisconnect()
        diagnostics.recordUnexpectedChannelError()
        diagnostics.recordExpectedClientWriteFailure()
        diagnostics.recordUnexpectedClientWriteFailure()
        _ = diagnostics.recordLeafCertCacheHit()
        diagnostics.recordLeafCertCacheMiss()

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.activeProxyChannels, 1)
        XCTAssertEqual(snapshot.upstreamResponseBytesForwarded, 1024)
        XCTAssertEqual(snapshot.expectedClientDisconnectCount, 1)
        XCTAssertEqual(snapshot.unexpectedChannelErrorCount, 1)
        XCTAssertEqual(snapshot.expectedClientWriteFailureCount, 1)
        XCTAssertEqual(snapshot.unexpectedClientWriteFailureCount, 1)
        XCTAssertEqual(snapshot.leafCertCacheHits, 1)
        XCTAssertEqual(snapshot.leafCertCacheMisses, 1)

        diagnostics.reset()

        XCTAssertEqual(diagnostics.snapshot(), .empty)
    }

    func testConcurrentUpdatesRemainConsistent() {
        let diagnostics = CaptureTransportDiagnostics()
        let iterations = 200

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            diagnostics.recordChannelOpened()
            diagnostics.recordUpstreamResponseBytes(1)
            diagnostics.recordExpectedClientDisconnect()
            _ = diagnostics.recordLeafCertCacheHit()
        }

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            diagnostics.recordChannelClosed()
        }

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.activeProxyChannels, 0)
        XCTAssertEqual(snapshot.upstreamResponseBytesForwarded, iterations)
        XCTAssertEqual(snapshot.expectedClientDisconnectCount, iterations)
        XCTAssertEqual(snapshot.leafCertCacheHits, iterations)
    }
}
