import XCTest
@testable import JoesProxy

final class ReproPackageTests: XCTestCase {
    func testPackageRedactsCredentialsQueriesBodiesPrivateAddressesAndLocalPaths() throws {
        let session = makeSession(
            host: "192.168.1.12",
            path: "/v1/items?token=raw-query&mode=test",
            requestHeaders: [
                HTTPHeaderField(name: "Authorization", value: "Bearer raw-header-secret"),
                HTTPHeaderField(name: "X-Debug", value: "/Users/tester/private/config.json")
            ],
            requestBody: Data("password=raw-body-secret".utf8),
            responseBody: Data("{\"token\":\"raw-response-secret\"}".utf8)
        )
        let engine = ReproPackageEngine()
        let package = try engine.makePackage(
            title: "Failure token=raw-title-secret",
            notes: "Captured at 10.0.0.4 from /Users/tester/log.txt",
            sessions: [session],
            appVersion: "test",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try engine.data(for: package)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("raw-header-secret"))
        XCTAssertFalse(text.contains("raw-query"))
        XCTAssertFalse(text.contains("raw-body-secret"))
        XCTAssertFalse(text.contains("raw-response-secret"))
        XCTAssertFalse(text.contains("raw-title-secret"))
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertFalse(text.contains("192.168.1.12"))
        XCTAssertFalse(text.contains("10.0.0.4"))
        XCTAssertEqual(package.sessions.first?.request.host, "private-host.invalid")
        XCTAssertEqual(package.redactionReport.bodiesOmitted, 2)
        XCTAssertGreaterThan(package.redactionReport.totalRedactions, 0)
    }

    func testPackageEncodingIsDeterministicAndRoundTrips() throws {
        let engine = ReproPackageEngine()
        let package = try engine.makePackage(
            title: "Deterministic package",
            notes: "Same input produces the same bytes.",
            sessions: [makeSession()],
            appVersion: "test",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let first = try engine.data(for: package)
        let second = try engine.data(for: package)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try engine.read(data: first), package)
    }

    func testHARImportFeedsSanitizedReproPackage() throws {
        let har = Data(
            """
            {
              "log": {
                "entries": [{
                  "startedDateTime": "2026-08-23T12:00:00.000Z",
                  "time": 125,
                  "request": {
                    "method": "GET",
                    "url": "https://example.com/v1/items?session=secret",
                    "headers": [{"name":"Cookie","value":"private-cookie"}],
                    "bodySize": 0
                  },
                  "response": {
                    "status": 503,
                    "headers": [{"name":"Content-Type","value":"application/json"}],
                    "content": {"text":"{\\"error\\":true}"},
                    "bodySize": 14
                  }
                }]
              }
            }
            """.utf8
        )
        let imported = try ReproHARImportService().decode(data: har)
        let package = try ReproPackageEngine().makePackage(
            title: "Imported capture",
            notes: "",
            source: .harImport,
            sessions: imported.sessions,
            appVersion: "test",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(imported.skippedEntryCount, 0)
        XCTAssertEqual(package.sessions.first?.id, "har-1")
        XCTAssertEqual(package.sessions.first?.response?.statusCode, 503)
        XCTAssertEqual(package.sessions.first?.request.path, "/v1/items?session=%3Credacted%3E")
        XCTAssertEqual(package.sessions.first?.request.headers.first?.value, "<redacted>")
        XCTAssertTrue(package.sessions.first?.response?.bodyOmittedForPrivacy == true)
    }

    func testInspectionCountsOnlySafeReplayableRequests() throws {
        let engine = ReproPackageEngine()
        let package = try engine.makePackage(
            title: "Replay scope",
            notes: "",
            sessions: [
                makeSession(method: "GET"),
                makeSession(method: "POST"),
                makeSession(method: "HEAD")
            ],
            appVersion: "test"
        )

        XCTAssertEqual(engine.inspection(of: package).replayableSessionCount, 2)
    }

    func testPackageIncludesSanitizedHypothesisGraphSummary() throws {
        let graph = HypothesisGraph(
            name: "Investigate token=private-graph-secret",
            targetBugDescription: "Failure from 10.0.0.8",
            nodes: [
                HypothesisNode(
                    id: "H1",
                    title: "Status behavior",
                    explanation: "Inspect /Users/tester/private/notes.txt",
                    parentID: nil,
                    mutation: .statusCodeFault(
                        urlPattern: "https://example.com/config?token=private-mutation-secret",
                        statusCode: 503,
                        responseBody: "private-response-body"
                    ),
                    expectedOutcome: .clientShowedHTTPStatus(statusCode: 503),
                    status: .proven,
                    evidenceSummary: "Bearer private-evidence-secret"
                )
            ],
            currentNodeID: nil,
            isCompleted: true,
            isolatedRootCauseNodeID: "H1"
        )

        let engine = ReproPackageEngine()
        let package = try engine.makePackage(
            title: "Graph package",
            notes: "",
            sessions: [makeSession()],
            hypothesisGraphs: [graph],
            appVersion: "test"
        )
        let text = try XCTUnwrap(String(data: engine.data(for: package), encoding: .utf8))

        XCTAssertEqual(package.hypothesisGraphs.count, 1)
        XCTAssertEqual(package.hypothesisGraphs.first?.nodes.first?.mutationKind, "statusCodeFault")
        XCTAssertFalse(text.contains("private-graph-secret"))
        XCTAssertFalse(text.contains("10.0.0.8"))
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertFalse(text.contains("private-mutation-secret"))
        XCTAssertFalse(text.contains("private-response-body"))
        XCTAssertFalse(text.contains("private-evidence-secret"))
    }

    func testMCPManifestAndCapabilityRoutingExposeReproductionLifecycle() {
        let names = Set(MCPCapabilitiesManifestBuilder.productionTools.map(\.name))

        XCTAssertTrue(names.contains("repro_export_package"))
        XCTAssertTrue(names.contains("repro_inspect_package"))
        XCTAssertTrue(names.contains("repro_replay_request"))
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "repro_export_package"), .sessionSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "repro_inspect_package"), .sessionSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "repro_replay_request"), .replayRequest)
    }

    private func makeSession(
        method: String = "GET",
        host: String = "example.com",
        path: String = "/health",
        requestHeaders: [HTTPHeaderField] = [],
        requestBody: Data? = nil,
        responseBody: Data? = nil
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: requestHeaders,
                bodyData: requestBody,
                bodySize: requestBody?.count
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: responseBody,
                bodySize: responseBody?.count
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: Date(timeIntervalSince1970: 1_000),
                completedAt: Date(timeIntervalSince1970: 1_001)
            )
        )
    }
}

@MainActor
final class ReproReplayEngineTests: XCTestCase {
    func testReplayStripsCredentialsAndValidatesExpectedStatus() async throws {
        let executor = ReproRecordingBookmarkExecutor(statusCode: 503)
        let engine = ReproReplayEngine(bookmarkExecutor: executor)
        let session = ReproSession(
            id: "session-1",
            request: ReproRequest(
                method: "GET",
                scheme: .https,
                host: "example.com",
                port: 443,
                path: "/failure",
                headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
                originalBodyByteCount: nil,
                bodyOmittedForPrivacy: false
            ),
            response: nil,
            timing: ReproTiming(startedAt: Date(), duration: nil, wireProfile: nil),
            expectedOutcome: ReproExpectedOutcome(statusCode: 503, failureBucket: nil)
        )

        let result = try await engine.replay(session: session, proxyPort: 9090)

        XCTAssertEqual(result.reproducedExpectedStatus, true)
        XCTAssertEqual(executor.lastStripCredentials, true)
        XCTAssertEqual(executor.lastBookmark?.request.path, "/failure")
    }
}

@MainActor
private final class ReproRecordingBookmarkExecutor: BookmarkExecuting {
    let statusCode: Int
    private(set) var lastBookmark: Bookmark?
    private(set) var lastStripCredentials: Bool?

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func execute(
        bookmark: Bookmark,
        proxyPort: UInt16,
        stripCredentials: Bool
    ) async throws -> BookmarkExecutionResult {
        lastBookmark = bookmark
        lastStripCredentials = stripCredentials
        return BookmarkExecutionResult(startedAt: Date(), statusCode: statusCode)
    }
}
