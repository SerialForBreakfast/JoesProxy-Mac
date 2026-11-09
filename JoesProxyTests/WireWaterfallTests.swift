import XCTest
@testable import JoesProxy

final class WireWaterfallTests: XCTestCase {
    func testPhaseBreakdownUsesOnlyObservedMilestones() {
        let start = Date(timeIntervalSince1970: 1_000)
        let profile = WireTimingProfile(
            connectionStartedAt: start,
            connectionEstablishedAt: start.addingTimeInterval(0.020),
            tlsHandshakeCompletedAt: start.addingTimeInterval(0.050),
            requestSendStartedAt: start.addingTimeInterval(0.050),
            requestSentAt: start.addingTimeInterval(0.055),
            firstResponseByteAt: start.addingTimeInterval(0.155),
            responseCompletedAt: start.addingTimeInterval(0.255)
        )
        let phases = WireWaterfallAnalyzer.phases(
            for: SessionTiming(
                startedAt: start,
                completedAt: start.addingTimeInterval(0.255),
                wireProfile: profile
            )
        )

        XCTAssertEqual(phases.map(\.phase), [.connect, .tls, .requestSend, .wait, .contentDownload])
        let wait = try? XCTUnwrap(phases.first(where: { $0.phase == .wait }))
        let contentDownload = try? XCTUnwrap(phases.first(where: { $0.phase == .contentDownload }))
        XCTAssertEqual(wait?.duration ?? 0, 0.100, accuracy: 0.000_001)
        XCTAssertEqual(contentDownload?.duration ?? 0, 0.100, accuracy: 0.000_001)
    }

    func testMissingTLSMilestoneDoesNotCreateSyntheticTLSPhase() {
        let start = Date(timeIntervalSince1970: 2_000)
        let profile = WireTimingProfile(
            connectionStartedAt: start,
            connectionEstablishedAt: start.addingTimeInterval(0.010),
            requestSentAt: start.addingTimeInterval(0.015),
            firstResponseByteAt: start.addingTimeInterval(0.030)
        )

        let phases = WireWaterfallAnalyzer.phases(
            for: SessionTiming(startedAt: start, wireProfile: profile)
        )

        XCTAssertFalse(phases.contains(where: { $0.phase == .tls }))
        XCTAssertTrue(phases.contains(where: { $0.phase == .connect }))
    }

    func testStallDetectionUsesConfigurableThreshold() {
        let profile = WireTimingProfile(
            chunks: [
                WireChunkSample(offset: 0, byteCount: 100),
                WireChunkSample(offset: 0.050, byteCount: 200),
                WireChunkSample(offset: 0.800, byteCount: 300),
                WireChunkSample(offset: 0.900, byteCount: 400)
            ]
        )

        XCTAssertEqual(WireWaterfallAnalyzer.stalledChunkIndices(profile: profile, threshold: 0.500), [2])
        XCTAssertEqual(WireWaterfallAnalyzer.stalledChunkIndices(profile: profile, threshold: 0.040), [1, 2, 3])
    }

    func testTransferMetricsReportCompressionSavings() {
        let metrics = WireTransferMetrics(
            headerByteCount: 240,
            transferBodyByteCount: 250,
            decodedBodyByteCount: 1_000,
            contentEncoding: "gzip"
        )

        XCTAssertEqual(metrics.compressionRatio, 0.25)
        XCTAssertEqual(metrics.compressionSavingsFraction, 0.75)
    }

    func testCacheDispositionRequiresResponseEvidence() {
        XCTAssertEqual(
            WireWaterfallAnalyzer.cacheDisposition(headers: [HTTPHeaderField(name: "Cache-Status", value: "edge; hit")]),
            .hit
        )
        XCTAssertEqual(
            WireWaterfallAnalyzer.cacheDisposition(headers: [HTTPHeaderField(name: "X-Cache", value: "MISS")]),
            .miss
        )
        XCTAssertEqual(WireWaterfallAnalyzer.cacheDisposition(headers: []), .unknown)
    }

    func testLegacySessionTimingDecodesWithoutWireProfile() throws {
        let data = Data("{\"startedAt\":0,\"completedAt\":1}".utf8)
        let decoded = try JSONDecoder().decode(SessionTiming.self, from: data)
        XCTAssertNil(decoded.wireProfile)
    }
}
