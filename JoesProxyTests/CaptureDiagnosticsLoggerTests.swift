import XCTest
@testable import JoesProxy

final class CaptureDiagnosticsLoggerTests: XCTestCase {
    func testSummaryRedactsQueryValuesFromPathCategories() {
        let sessions = [
            makeSession(
                host: "video.example.com",
                path: "/playlist/master.m3u8?userid=secret-user&token=secret-token",
                statusCode: 200,
                state: .completed
            ),
            makeSession(
                host: "video.example.com",
                path: "/playlist/segment.ts?sessionid=secret-session",
                statusCode: 206,
                state: .completed
            ),
            makeSession(
                host: "api.example.com",
                path: "/v1/profile?at=secret-access-token",
                statusCode: 500,
                state: .failed
            )
        ]
        let metrics = CaptureHealthMetrics(
            sessionCount: sessions.count,
            retainedBodyBytes: 4096,
            droppedSessionCount: 1,
            captureStartedAt: Date(timeIntervalSince1970: 100),
            processMetrics: AppProcessMetrics(cpuPercent: 42.25, residentMemoryBytes: 123_456)
        )

        let transport = CaptureTransportDiagnosticsSnapshot(
            activeProxyChannels: 3,
            upstreamResponseBytesForwarded: 3_090_000_000,
            expectedClientDisconnectCount: 98,
            unexpectedChannelErrorCount: 2,
            expectedClientWriteFailureCount: 95,
            unexpectedClientWriteFailureCount: 5,
            leafCertCacheHits: 10_200,
            leafCertCacheMisses: 50
        )
        let counts = WorkspaceRetentionCounts(summaries: 3, filteredIDs: 2, tableRows: 2,
            searchTexts: 0, explorerFolders: 1, explorerSummaries: 2, retentionPresentationSkips: 7)
        let summary = CaptureDiagnosticsSummary.make(metrics: metrics, sessions: sessions,
            transport: transport, workspaceRetention: counts, retainedHeaderFieldCount: 17)
        let message = summary.logMessage

        XCTAssertTrue(message.contains("capture_summary"))
        XCTAssertTrue(message.contains("workspaceExplorerSummaries=2"))
        XCTAssertTrue(message.contains("retentionPresentationSkips=7"))
        XCTAssertTrue(message.contains("retainedHeaderFields=17"))
        XCTAssertFalse(message.contains("workspaceRetention=unavailable"))
        XCTAssertTrue(message.contains("upstreamResponseBytes=3090000000"))
        XCTAssertTrue(message.contains("activeChannels=3"))
        XCTAssertTrue(message.contains("expectedDisconnects=98"))
        XCTAssertTrue(message.contains("unexpectedErrors=2"))
        XCTAssertTrue(message.contains("expectedWriteFailures=95"))
        XCTAssertTrue(message.contains("unexpectedWriteFailures=5"))
        XCTAssertTrue(message.contains("leafCertCacheHits=10200/10250"))
        XCTAssertTrue(message.contains("topHosts=video.example.com:2,api.example.com:1"))
        XCTAssertTrue(message.contains("topPaths=/playlist/master.m3u8:1,/playlist/segment.ts:1,/v1/profile:1"))
        XCTAssertTrue(message.contains("statusFamilies=2xx:2,5xx:1"))
        XCTAssertFalse(message.contains("secret-user"))
        XCTAssertFalse(message.contains("secret-token"))
        XCTAssertFalse(message.contains("secret-session"))
        XCTAssertFalse(message.contains("secret-access-token"))
        XCTAssertFalse(message.contains("userid="))
        XCTAssertFalse(message.contains("sessionid="))
        XCTAssertFalse(message.contains("at="))
    }

    func testSummaryCountsTruncatedAndStrippedBodies() {
        let sessions = [
            makeSession(
                host: "api.example.com",
                path: "/v1/items",
                statusCode: 200,
                state: .completed,
                requestBodyTruncated: true
            ),
            makeSession(
                host: "api.example.com",
                path: "/v1/items/2",
                statusCode: 200,
                state: .completed,
                requestBodyDeferred: true
            )
        ]
        let metrics = CaptureHealthMetrics(
            sessionCount: sessions.count,
            retainedBodyBytes: 0,
            droppedSessionCount: 0,
            captureStartedAt: Date(timeIntervalSince1970: 100),
            processMetrics: .empty
        )

        let summary = CaptureDiagnosticsSummary.make(metrics: metrics, sessions: sessions)

        XCTAssertEqual(summary.truncatedBodyCount, 1)
        XCTAssertEqual(summary.strippedBodyCount, 1)
        XCTAssertTrue(summary.logMessage.contains("truncatedBodies=1"))
        XCTAssertTrue(summary.logMessage.contains("strippedBodies=1"))
    }

    func testCadenceEmitsOnlyWhenEnabledWithSessionsAndIntervalElapsed() {
        var cadence = CaptureDiagnosticsLogCadence(interval: 60)
        let start = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(cadence.shouldEmit(now: start, isEnabled: false, sessionCount: 10))
        XCTAssertFalse(cadence.shouldEmit(now: start, isEnabled: true, sessionCount: 0))
        XCTAssertTrue(cadence.shouldEmit(now: start, isEnabled: true, sessionCount: 10))
        XCTAssertFalse(cadence.shouldEmit(now: start.addingTimeInterval(59), isEnabled: true, sessionCount: 10))
        XCTAssertTrue(cadence.shouldEmit(now: start.addingTimeInterval(60), isEnabled: true, sessionCount: 10))

        cadence.reset()

        XCTAssertTrue(cadence.shouldEmit(now: start.addingTimeInterval(1), isEnabled: true, sessionCount: 10))
    }

    private func makeSession(
        host: String,
        path: String,
        statusCode: Int,
        state: SessionLifecycleState,
        requestBodyTruncated: Bool = false,
        requestBodyDeferred: Bool = false
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil,
                bodyTruncated: requestBodyTruncated,
                bodyDeferred: requestBodyDeferred
            ),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: state,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 100))
        )
    }
}
