import Foundation
import XCTest
@testable import JoesProxy

final class MCPDisclosureTests: XCTestCase {
    private let serializer = MCPDisclosureSerializer()

    func testTransportEvidenceUsesDurationPolicyWithoutDisclosingBodiesOrHosts() throws {
        var record = Self.fixtureSession(host: "private.example.test", path: "/private", headers: [])
        var wire = WireTimingProfile()
        wire.transport = RequestTransportDiagnostics().snapshot()
        record.timing.wireProfile = wire
        let permitted = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "Timing",
            allowedFieldClasses: [.duration], isSelectableInPhase1: true)
        let result = try serializer.sessionSummary(record: record, captureSequence: 1, profile: permitted)
        XCTAssertNotNil(result.transportEvidence)
        XCTAssertEqual(result.transportDiagnostic?.reason, .observed)
        XCTAssertNil(result.bodyExcerpt)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("private.example.test"))
        let denied = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "No timing",
            allowedFieldClasses: [], isSelectableInPhase1: true)
        XCTAssertNil(try serializer.sessionSummary(record: record, captureSequence: 1, profile: denied).transportEvidence)
        XCTAssertNil(try serializer.sessionSummary(record: record, captureSequence: 1, profile: denied).transportDiagnostic)
    }

    func testPressureOmissionSurvivesRecordingAndExplainsRecoveryWithoutBodyApproval() throws {
        let profile = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "Metadata",
            allowedFieldClasses: [.bodyAvailabilityFlags], isSelectableInPhase1: true)
        var record = Self.fixtureSession(host: "example.test", path: "/private", headers: [])
        record.response = CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: 500, bodyTruncated: true)
        record.responseCaptureLimitedByPressure = true
        let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        let summary = try serializer.sessionSummary(record: restored, captureSequence: 1, profile: profile)
        XCTAssertEqual(summary.bodyUnavailableReason, "capture_pressure")
        XCTAssertTrue(summary.bodyRecoveryAction?.contains("automatic_recovery") == true)
        XCTAssertEqual(summary.responseBodyAvailable, false)
        XCTAssertNil(summary.bodyExcerpt)
    }

    func testUnavailableEncodingMetadataDoesNotDiscloseHeaderValue() throws {
        let profile = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "Metadata",
            allowedFieldClasses: [.bodyAvailabilityFlags], isSelectableInPhase1: true)
        let record = Self.fixtureSession(host: "example.test", path: "/", headers: [],
            responseBody: Data("payload".utf8), responseHeaders: [.init(name: "Content-Encoding", value: "private-sentinel")])
        let summary = try serializer.sessionSummary(record: record, captureSequence: 1, profile: profile)
        XCTAssertEqual(summary.bodyUnavailableReason, "unsupported_encoding")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self).contains("private-sentinel"))
        XCTAssertNil(summary.bodyExcerpt)
    }

    func testMissingBytesExplainRecoveryBeforeBodyReadApproval() throws {
        let profile = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "Metadata",
            allowedFieldClasses: [.bodyAvailabilityFlags], isSelectableInPhase1: true)
        var record = Self.fixtureSession(host: "example.test", path: "/private", headers: [])
        record.response = CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: 500)
        let summary = try serializer.sessionSummary(record: record, captureSequence: 1, profile: profile)
        XCTAssertEqual(summary.responseBodyAvailable, false, "Original size does not prove bytes are retained")
        XCTAssertEqual(summary.bodyUnavailableReason, "body_missing")
        XCTAssertTrue(summary.bodyRecoveryAction?.contains("capture_status") == true)
        XCTAssertNil(summary.bodyExcerpt)
        XCTAssertNil(summary.sanitizedPath)
    }

    func testDeferredOmittedPendingAndTunnelHaveDifferentActions() throws {
        let profile = MCPDisclosureProfileDocument(id: .metadataOnly, revision: 1, title: "Metadata",
            allowedFieldClasses: [.bodyAvailabilityFlags], isSelectableInPhase1: true)
        var record = Self.fixtureSession(host: "example.test", path: "/", headers: [])
        for (deferred, omitted, reason) in [(true, false, "body_deferred"), (false, true, "body_omitted")] {
            record.response = CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: 100,
                recordingBodyOmissionReason: omitted ? .metadataOnly : nil, bodyDeferred: deferred)
            let summary = try serializer.sessionSummary(record: record, captureSequence: 1, profile: profile)
            XCTAssertEqual(summary.bodyUnavailableReason, reason)
            XCTAssertNotNil(summary.bodyRecoveryAction)
            XCTAssertNil(summary.bodyExcerpt)
        }
        record.response = nil
        record.state = .pending
        XCTAssertEqual(try serializer.sessionSummary(record: record, captureSequence: 1,
            profile: profile).bodyUnavailableReason, "response_pending")
        record.request = CapturedRequest(method: "CONNECT", scheme: .https, inspectionKind: .tunneledTLS,
            host: "example.test", port: 443, path: "/", headers: [], bodyData: nil, bodySize: nil)
        XCTAssertEqual(try serializer.sessionSummary(record: record, captureSequence: 1,
            profile: profile).bodyUnavailableReason, "tls_passthrough")
    }

    /// AK-5 gap: nothing referenced `normalizedPageSize`/`defaultPageSize`/`maxPageSize` by name —
    /// the "no implicit broad session enumeration" guarantee (`sessions_list`/`sessions_search`
    /// default to 10, capped at 100) existed only as unexercised production code before this.
    func testNormalizedPageSizeDefaultsAndClampsToADRBudget() {
        XCTAssertEqual(serializer.normalizedPageSize(nil), MCPResourceBudget.defaultPageSize)
        XCTAssertEqual(MCPResourceBudget.defaultPageSize, 10)
        XCTAssertEqual(serializer.normalizedPageSize(500), MCPResourceBudget.maxPageSize)
        XCTAssertEqual(MCPResourceBudget.maxPageSize, 100)
        XCTAssertEqual(serializer.normalizedPageSize(1), 1)
        XCTAssertEqual(serializer.normalizedPageSize(0), 1, "must clamp up to a minimum of 1, not return 0")
        XCTAssertEqual(serializer.normalizedPageSize(-5), 1, "must clamp a negative request up to 1")
        XCTAssertEqual(serializer.normalizedPageSize(100), 100, "the cap itself must remain a valid request")
    }

    func testMetadataOnlyOmitsPathAndHeaders() throws {
        let profile = MCPDisclosureProfileDocument(
            id: .metadataOnly,
            revision: 1,
            title: "Metadata Only",
            allowedFieldClasses: [
                .sessionSequence, .sessionOpaqueID, .method, .hostCategory, .bodyAvailabilityFlags
            ],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/secret/path?token=abc",
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer secret")]
        )
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile
        )
        XCTAssertNil(summary.sanitizedPath)
        XCTAssertNil(summary.safeHeaders)
        XCTAssertEqual(summary.hostCategory, MCPHostCategory.api.rawValue)
    }

    func testShareableRedactsSensitiveHeaders() throws {
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [
                .sessionSequence, .sessionOpaqueID, .sanitizedHost, .sanitizedPath, .safeHeaders
            ],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "cdn.example.com",
            path: "/v1/resource",
            headers: [
                HTTPHeaderField(name: "Authorization", value: "Bearer secret"),
                HTTPHeaderField(name: "Accept", value: "application/json")
            ]
        )
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 2,
            profile: profile
        )
        XCTAssertEqual(summary.safeHeaders?.map(\.name), ["Accept"])
        XCTAssertEqual(summary.sanitizedPath, "/v1/resource")
    }

    func testShareableRedactsOpaqueValuesOnUnrecognizedHeaderNames() throws {
        // The header NAME here is not on any sensitive-name blocklist, but its VALUE is an opaque
        // token — this is exactly the case that leaked before the fix, since the old logic checked
        // the value against a key-name keyword heuristic ("token"/"secret"/...), which real secrets
        // essentially never contain literally.
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.safeHeaders],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/v1/resource",
            headers: [
                HTTPHeaderField(name: "X-Request-Context", value: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
                HTTPHeaderField(name: "X-Trace-Id", value: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"),
                HTTPHeaderField(name: "Content-Type", value: "application/json")
            ]
        )
        let summary = try serializer.sessionSummary(record: record, captureSequence: 1, profile: profile)
        let byName = Dictionary(uniqueKeysWithValues: (summary.safeHeaders ?? []).map { ($0.name, $0.redactedValue) })
        XCTAssertEqual(byName["X-Request-Context"], "<redacted>")
        XCTAssertEqual(byName["X-Trace-Id"], "<redacted>")
        XCTAssertEqual(byName["Content-Type"], "application/json", "structurally-safe allowlisted headers keep their value")
    }

    func testSanitizedPathRedactsOpaqueSegmentsButKeepsOrdinaryWords() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertEqual(
            serializer.sanitizedPath("/reset/confirm/\(jwt)"),
            "/reset/confirm/<redacted>"
        )
        XCTAssertEqual(
            serializer.sanitizedPath("/users/a1b2c3d4e5f60789abcdef1234567890"),
            "/users/<redacted>"
        )
        XCTAssertEqual(
            serializer.sanitizedPath("/api/v1/users/profile?token=abc"),
            "/api/v1/users/profile",
            "ordinary short path words are preserved; only the query string and opaque segments are stripped"
        )
    }

    func testApprovedSensitiveReadIncludesHeaderValuesAndQuery() throws {
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.sessionOpaqueID, .safeHeaders],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/v1/resource?token=secret",
            headers: [
                HTTPHeaderField(name: "Authorization", value: "Bearer secret"),
                HTTPHeaderField(name: "Accept", value: "application/json")
            ]
        )
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 3,
            profile: profile,
            approvedCapabilities: [.headerRead, .queryRead]
        )
        XCTAssertEqual(summary.approvedHeaders?.first?.redactedValue, "Bearer secret")
        XCTAssertEqual(summary.queryParameters?.first?.name, "token")
        XCTAssertEqual(summary.queryParameters?.first?.value, "secret")
    }

    func testBodyDisclosureDefaultsToDecodedResponseAndCanSelectRequest() throws {
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.bodyAvailabilityFlags],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/v1/resource",
            headers: [],
            requestBody: Data("request-body".utf8),
            responseBody: Data("response-body".utf8)
        )

        let response = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile,
            approvedCapabilities: [.bodyRead]
        )
        XCTAssertEqual(response.bodyExcerpt, "response-body")
        XCTAssertEqual(response.bodyExcerptSource, MCPSessionBodySource.response.rawValue)
        XCTAssertEqual(response.requestBodyAvailable, true)
        XCTAssertEqual(response.responseBodyAvailable, true)

        let request = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile,
            approvedCapabilities: [.bodyRead],
            bodySource: .request
        )
        XCTAssertEqual(request.bodyExcerpt, "request-body")
        XCTAssertEqual(request.bodyExcerptSource, MCPSessionBodySource.request.rawValue)
    }

    func testBodyDisclosureDecodesGzipBeforeDisclosureLimit() throws {
        let fixture = """
        H4sIAAAAAAAAALWQMU/DMBCFO/MzPDdSYscpyeZiIhiAATZURca+hiomLvYFiKr8d0wGMoDExHb39L53erc6EQ+\
        vAwS8NqQiRbEVPJV5wqm8SHIuy2QrmUwKWdcpK0RGJU9USfeMbfiea8g142RNnlVvLJDq8USOarROmXkO2h2jSh6U\
        bwG/fIce4z4ziPYetOtNIFV2nqbTegGEuFnc5R/mS9PCLeC7890COU9/w3ZRG2fKOq3w4Pqr6K88hMEimXbT2epf\
        P9LBGEO73mj0TZZKllHKOeV1zTdlKvIynpKNMO4J7nzbaDsEBB/z3pQd4LvXi/oQLfzoFFAhVAGdh7nLJ05GUqveA\
        QAA
        """
        let compressed = try XCTUnwrap(Data(base64Encoded: fixture.replacingOccurrences(of: "\n", with: "")))
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.bodyAvailabilityFlags],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/v1/resource",
            headers: [],
            responseBody: compressed,
            responseHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile,
            approvedCapabilities: [.bodyRead]
        )
        XCTAssertFalse(summary.bodyExcerpt?.isEmpty ?? true)
        XCTAssertTrue(summary.bodyDecodeStatus?.contains("decoded") == true)
        XCTAssertNil(summary.bodyUnavailableReason)
    }

    func testBodyDisclosureTruncatesOversizedBodyAtValidUTF8BoundaryWithoutSplittingAScalar() throws {
        // approvedBodyExcerpt() previously shrank oversized bodies via
        // `while ... { truncated = String(truncated.dropLast()) }`, which reallocates the whole
        // remaining string on every iteration — effectively O(n^2) — and, for a body near the
        // 256KB decode ceiling, was slow enough to freeze the entire app (this ran on the main
        // thread). This body is engineered so the naive byte-65536 cut point lands in the middle
        // of a 4-byte emoji scalar, proving the replacement boundary-snapping logic still backs
        // off to a valid Character boundary instead of splitting it, while staying fast.
        let maxBytes = MCPResourceBudget.maxDisclosedItemBytes
        let prefix = String(repeating: "a", count: maxBytes - 2)
        let clapperBoard = "\u{1F3AC}" // 4-byte UTF-8 scalar spanning offsets maxBytes-2...maxBytes+1
        let filler = String(repeating: "b", count: 4_096)
        let oversizedBody = prefix + clapperBoard + filler

        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.bodyAvailabilityFlags],
            isSelectableInPhase1: true
        )
        let record = Self.fixtureSession(
            host: "api.example.com",
            path: "/v1/resource",
            headers: [],
            responseBody: Data(oversizedBody.utf8),
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")]
        )

        let start = Date()
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile,
            approvedCapabilities: [.bodyRead]
        )
        let elapsed = Date().timeIntervalSince(start)

        let excerpt = try XCTUnwrap(summary.bodyExcerpt)
        XCTAssertEqual(summary.bodyExcerptTruncated, true)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, maxBytes, "truncated excerpt must respect the disclosure byte budget")
        XCTAssertFalse(excerpt.contains(clapperBoard), "a scalar that doesn't fully fit must be dropped, not split")
        XCTAssertEqual(excerpt, prefix, "boundary must back off to just before the multi-byte scalar, not cut mid-sequence")
        XCTAssertLessThan(
            elapsed, 3.0,
            "truncating a body ~64KB over budget must stay fast; a regression to the old O(n^2) dropLast() loop would make this take tens of seconds or more"
        )
    }

    private static func fixtureSession(
        host: String,
        path: String,
        headers: [HTTPHeaderField],
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        responseHeaders: [HTTPHeaderField] = []
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: host,
                port: 443,
                path: path,
                headers: headers,
                bodyData: requestBody,
                bodySize: requestBody?.count
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: responseHeaders,
                bodyData: responseBody,
                bodySize: responseBody?.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_001))
        )
    }
}
