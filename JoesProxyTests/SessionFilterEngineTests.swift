import XCTest
@testable import JoesProxy

final class SessionFilterEngineTests: XCTestCase {
    private let engine = SessionFilterEngine()

    func testCancellationStopsSearchBeforeBuildingRemainingBlobs() {
        let sessions = (0..<100).map {
            makeRecord(method: "GET", scheme: .https, host: "api.example.test",
                       path: "/item-\($0)", statusCode: 200)
        }
        var cache: [SessionRecord.ID: String] = [:]
        var visited = 0
        XCTAssertThrowsError(try engine.filter(sessions, criteria: SessionFilterCriteria(),
            searchText: "item", searchTextCache: &cache, cancellationCheck: {
                visited += 1
                if visited == 4 { throw CancellationError() }
            })) { error in
                XCTAssertTrue(error is CancellationError)
            }
        XCTAssertEqual(visited, 4)
        XCTAssertEqual(cache.count, 3)
    }

    func testFiltersByStructuredCriteriaAndSearchTextWithANDSemantics() {
        let matching = makeRecord(
            method: "POST",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            path: "/v1/login",
            statusCode: 401,
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer token")]
        )
        let wrongMethod = makeRecord(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            path: "/v1/login",
            statusCode: 401,
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer token")]
        )
        let wrongSearch = makeRecord(
            method: "POST",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            path: "/v1/login",
            statusCode: 401,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")]
        )

        let filtered = engine.filter(
            [matching, wrongMethod, wrongSearch],
            criteria: SessionFilterCriteria(
                hostContains: "api",
                method: "POST",
                scheme: .https,
                inspectionMatch: .exact(.interceptedTLS),
                statusMatch: .range(400...499)
            ),
            searchText: "authorization"
        )

        XCTAssertEqual(filtered.map(\.id), [matching.id])
    }

    func testFilteringDoesNotMutateSourceData() {
        let sessions = [
            makeRecord(method: "GET", scheme: .http, host: "example.com", path: "/one", statusCode: 200),
            makeRecord(method: "POST", scheme: .https, host: "api.example.com", path: "/two", statusCode: 500)
        ]

        _ = engine.filter(
            sessions,
            criteria: SessionFilterCriteria(hostContains: "api", method: nil, scheme: nil, statusMatch: nil),
            searchText: ""
        )

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].request.path, "/one")
        XCTAssertEqual(sessions[1].request.path, "/two")
    }

    func testFiltersByInspectionKindAndTunnelReasonSearch() {
        let tunneled = makeRecord(
            method: "CONNECT",
            scheme: .https,
            inspectionKind: .tunneledTLS,
            inspectionReason: "Built-in compatibility bypass: .apple.com",
            host: "bag.itunes.apple.com",
            path: "bag.itunes.apple.com:443",
            statusCode: 200
        )
        let inspected = makeRecord(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            inspectionReason: "HTTPS inspected",
            host: "api.example.com",
            path: "/v1/data",
            statusCode: 200
        )

        let filtered = engine.filter(
            [tunneled, inspected],
            criteria: SessionFilterCriteria(inspectionMatch: .exact(.tunneledTLS)),
            searchText: "compatibility"
        )

        XCTAssertEqual(filtered.map(\.id), [tunneled.id])
    }

    func testNotTunneledFilterMatchesHTTPAndInspectedHTTPS() {
        let plain = makeRecord(
            method: "GET",
            scheme: .http,
            inspectionKind: .plain,
            host: "example.com",
            path: "/plain",
            statusCode: 200
        )
        let inspected = makeRecord(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            path: "/secure",
            statusCode: 200
        )
        let tunneled = makeRecord(
            method: "CONNECT",
            scheme: .https,
            inspectionKind: .tunneledTLS,
            host: "pinned.example.com",
            path: "pinned.example.com:443",
            statusCode: 200
        )

        let filtered = engine.filter(
            [plain, inspected, tunneled],
            criteria: SessionFilterCriteria(inspectionMatch: .notTunneled),
            searchText: ""
        )

        XCTAssertEqual(filtered.map(\.id), [plain.id, inspected.id])
    }

    func testFailedConnectionStatusFilterMatchesOnlyFailedSessions() {
        let completed = makeRecord(
            method: "GET",
            scheme: .http,
            host: "example.com",
            path: "/ok",
            statusCode: 200
        )
        let serverError = makeRecord(
            method: "GET",
            scheme: .http,
            host: "example.com",
            path: "/error",
            statusCode: 500
        )
        let failed = makeFailedRecord(
            method: "GET",
            scheme: .https,
            host: "offline.example.com",
            path: "/missing",
            failureMessage: "Connection refused",
            bucket: .refusedConnection
        )

        let filtered = engine.filter(
            [completed, serverError, failed],
            criteria: SessionFilterCriteria(statusMatch: .failedConnection),
            searchText: ""
        )

        XCTAssertEqual(filtered.map(\.id), [failed.id])
    }

    private func makeFailedRecord(
        method: String,
        scheme: SessionScheme,
        host: String,
        path: String,
        failureMessage: String,
        bucket: NetworkFailureBucket
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: scheme,
                host: host,
                port: scheme == .https ? 443 : 80,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: nil,
            state: .failed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.2)),
            failure: SessionFailure(message: failureMessage, bucket: bucket)
        )
    }

    private func makeRecord(
        method: String,
        scheme: SessionScheme,
        inspectionKind: SessionInspectionKind = .plain,
        inspectionReason: String? = nil,
        host: String,
        path: String,
        statusCode: Int,
        headers: [HTTPHeaderField] = []
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: scheme,
                inspectionKind: inspectionKind,
                inspectionReason: inspectionReason,
                host: host,
                port: scheme == .https ? 443 : 80,
                path: path,
                headers: headers,
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.2))
        )
    }
}
