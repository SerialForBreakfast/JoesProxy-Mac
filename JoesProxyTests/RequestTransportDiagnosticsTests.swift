import XCTest
@testable import JoesProxy

final class RequestTransportDiagnosticsTests: XCTestCase {
    func testRecentRequestRegistryIsBoundedAndDoesNotRetainOldEntries() throws {
        let registry = CaptureTransportDiagnostics()
        let oldID = UUID()
        var old: RequestTransportDiagnostics? = RequestTransportDiagnostics()
        weak var weakOld = old
        registry.observeRequest(id: oldID, diagnostics: try XCTUnwrap(old))
        old = nil
        XCTAssertNotNil(weakOld)
        let latestID = UUID()
        for _ in 0..<255 { registry.observeRequest(id: UUID(), diagnostics: RequestTransportDiagnostics()) }
        registry.observeRequest(id: latestID, diagnostics: RequestTransportDiagnostics())
        XCTAssertNil(registry.evidence(for: oldID))
        XCTAssertNil(weakOld)
        XCTAssertNotNil(registry.evidence(for: latestID))
        let previousEpoch = registry.requestEvidenceEpoch
        registry.reset()
        registry.observeRequest(id: oldID, diagnostics: RequestTransportDiagnostics(), epoch: previousEpoch)
        XCTAssertNil(registry.evidence(for: oldID))
        XCTAssertNil(registry.evidence(for: latestID))
    }

    func testOverlappingWritesMeasureUnionAndFailuresWithoutPayloadRetention() throws {
        let diagnostics = RequestTransportDiagnostics(now: 0)
        diagnostics.connected(now: 1_000_000_000)
        diagnostics.tlsReady(protocolName: nil, now: 2_000_000_000)
        diagnostics.upstreamRead(now: 3_000_000_000)
        diagnostics.submitted(bytes: 100, now: 3_000_000_000)
        diagnostics.readPaused(aggregatePressure: false, socketBackpressure: false, now: 3_000_000_000)
        diagnostics.submitted(bytes: 200, now: 4_000_000_000)
        diagnostics.readPaused(aggregatePressure: true, socketBackpressure: true, now: 4_000_000_000)
        diagnostics.completed(bytes: 100, succeeded: true, now: 5_000_000_000)
        XCTAssertEqual(diagnostics.snapshot(now: 6_000_000_000).pendingWrites, 1)
        XCTAssertEqual(diagnostics.snapshot(now: 6_000_000_000).relayOutstandingSeconds, 3)
        diagnostics.upstreamRead(now: 7_000_000_000)
        diagnostics.completed(bytes: 200, succeeded: false, now: 8_000_000_000)
        diagnostics.readsResumedOrClosed(now: 8_000_000_000)
        let result = diagnostics.snapshot(now: 9_000_000_000)
        XCTAssertEqual(result.relayOutstandingSeconds, 5)
        XCTAssertEqual(result.maximumUpstreamReadGapSeconds, 4)
        XCTAssertEqual(result.bytesWriteCompleted, 100)
        XCTAssertEqual(result.peakPendingBytes, 300)
        XCTAssertEqual(result.pendingWrites, 0)
        XCTAssertEqual(result.deliveryState, "write_failed")
        XCTAssertEqual(result.observedReadPausedSeconds, 5)
        XCTAssertFalse(result.readsCurrentlyPaused)
        XCTAssertTrue(result.aggregatePressureObserved)
        XCTAssertTrue(result.socketBackpressureObserved)
        XCTAssertLessThan(try JSONEncoder().encode(result).count, 2048)
    }

    func testHistoricalProfilesDecodeWithoutInventedTransportEvidence() throws {
        let profile = try JSONDecoder().decode(WireTimingProfile.self,
            from: Data(#"{"chunks":[],"omittedChunkCount":0}"#.utf8))
        XCTAssertNil(profile.transport)
        XCTAssertNil(profile.tlsHandshakeCompletedAt)
    }

    func testRepeatedDrainsStayConstantSize() throws {
        let diagnostics = RequestTransportDiagnostics(now: 0)
        for tick in 1...20_000 {
            diagnostics.submitted(bytes: 16_384, now: UInt64(tick * 2))
            diagnostics.completed(bytes: 16_384, succeeded: true, now: UInt64(tick * 2 + 1))
        }
        let result = diagnostics.snapshot()
        XCTAssertEqual(result.pendingWrites, 0)
        XCTAssertEqual(result.peakPendingBytes, 16_384)
        XCTAssertEqual(result.bytesWriteCompleted, 327_680_000)
        XCTAssertLessThan(try JSONEncoder().encode(result).count, 2048)
    }
}
