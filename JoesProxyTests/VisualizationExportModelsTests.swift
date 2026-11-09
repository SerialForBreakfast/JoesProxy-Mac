import XCTest
@testable import JoesProxy

final class VisualizationExportModelsTests: XCTestCase {
    func testDefaultRequestUsesShareablePNGExportDefaults() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSession(sessionID)
        )

        XCTAssertEqual(request.schemaVersion, VisualizationExportConstants.currentSchemaVersion)
        XCTAssertEqual(request.title, "Session Timeline")
        XCTAssertEqual(request.theme, .dark)
        XCTAssertEqual(request.dimensions, .hd)
        XCTAssertEqual(request.redactionPolicy, .shareableDefault)
        XCTAssertEqual(request.validationIssues(), [])
    }

    func testRequestRoundTripsThroughCodable() throws {
        let ids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ]
        let request = VisualizationExportRequest(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions(ids),
            theme: .presentation,
            dimensions: .qhd,
            title: "Startup requests",
            subtitle: "Filtered to playback startup"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(VisualizationExportRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.sourceScope.sessionIDs, ids)
    }

    func testMissingSchemaVersionDecodesAsCurrentVersion() throws {
        let payload = Data("""
        {
          "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "exportType": "sessionTimeline",
          "sourceScope": {
            "kind": "selectedSession",
            "sessionID": "11111111-1111-1111-1111-111111111111"
          },
          "title": "Legacy request"
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(VisualizationExportRequest.self, from: payload)

        XCTAssertEqual(decoded.schemaVersion, VisualizationExportConstants.currentSchemaVersion)
        XCTAssertEqual(decoded.title, "Legacy request")
        XCTAssertEqual(decoded.redactionPolicy, VisualizationExportRedactionPolicy.shareableDefault)
        XCTAssertEqual(decoded.dimensions, VisualizationExportDimensions.hd)
    }

    func testValidationRejectsLaterPhaseExportType() {
        let request = VisualizationExportRequest(
            exportType: .hlsPlaybackFlow,
            sourceScope: .playbackFlow("playback-1")
        )

        XCTAssertTrue(request.validationIssues().contains(.exportTypeNotAvailable(.hlsPlaybackFlow)))
    }

    func testValidationRejectsUnsupportedScopeForHostHealth() {
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .selectedSession(UUID())
        )

        XCTAssertEqual(request.validationIssues().count, 1)
        XCTAssertTrue(
            request.validationIssues().contains {
                if case .unsupportedScope(.hostHealthSummary, "1 selected session") = $0 {
                    return true
                }
                return false
            }
        )
    }

    func testValidationRejectsInvalidDimensionsAndTimeRange() {
        let range = VisualizationExportTimeRange(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 100)
        )
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .timeRange(range),
            dimensions: VisualizationExportDimensions(preset: .custom, width: 320, height: 200)
        )

        let issues = request.validationIssues()

        XCTAssertTrue(issues.contains(.invalidDimensions(width: 320, height: 200)))
        XCTAssertTrue(issues.contains(.invalidTimeRange))
    }

    func testRedactionSummaryReflectsPolicy() {
        var policy = VisualizationExportRedactionPolicy.shareableDefault
        policy.redactArtworkAndLogos = false
        policy.customSensitiveKeys = ["subscriberID", "deviceID"]

        let summary = policy.summary

        XCTAssertTrue(summary.redactedCategories.contains("auth headers"))
        XCTAssertTrue(summary.redactedCategories.contains("query parameters"))
        XCTAssertFalse(summary.redactedCategories.contains("artwork and logos"))
        XCTAssertEqual(summary.customSensitiveKeyCount, 2)
        XCTAssertFalse(summary.allowsRawValues)
    }

    func testRedactionPolicyRedactsSensitiveHeadersAndCustomKeys() {
        var policy = VisualizationExportRedactionPolicy.shareableDefault
        policy.customSensitiveKeys = ["x-account-id"]

        XCTAssertEqual(
            policy.redactedHeaderValue(for: "Authorization", value: "Bearer secret"),
            "<redacted>"
        )
        XCTAssertEqual(policy.redactedHeaderValue(for: "Set-Cookie", value: "session=secret"), "<redacted>")
        XCTAssertEqual(policy.redactedHeaderValue(for: "X-Account-ID", value: "account-1"), "<redacted>")
        XCTAssertEqual(policy.redactedHeaderValue(for: "Accept", value: "application/json"), "application/json")
    }

    func testRedactionPolicyAllowsRawValuesWhenOptedIn() {
        var policy = VisualizationExportRedactionPolicy.shareableDefault
        policy.customSensitiveKeys = ["subscriberID"]
        policy.allowsRawValues = true

        XCTAssertEqual(policy.redactedHeaderValue(for: "Authorization", value: "Bearer secret"), "Bearer secret")
        XCTAssertEqual(policy.redactedValue(forKey: "subscriberID", value: "subscriber-1"), "subscriber-1")
        XCTAssertEqual(
            policy.redactedURLString("https://example.com/path?token=abc&asset=video"),
            "https://example.com/path?token=abc&asset=video"
        )
    }

    func testRedactionPolicyRedactsQueryParameters() {
        let policy = VisualizationExportRedactionPolicy.shareableDefault

        XCTAssertEqual(
            policy.redactedURLString("https://example.com/path?token=abc&asset=video"),
            "https://example.com/path?token=%3Credacted%3E&asset=%3Credacted%3E"
        )
    }

    func testRedactionPolicyRedactsTokenAndUserIdentifierValues() {
        let policy = VisualizationExportRedactionPolicy.shareableDefault

        XCTAssertEqual(policy.redactedValue(forKey: "sessionToken", value: "abc"), "<redacted>")
        XCTAssertEqual(policy.redactedValue(forKey: "user_id", value: "user-1"), "<redacted>")
        XCTAssertEqual(policy.redactedValue(forKey: "quality", value: "1080p"), "1080p")
    }

    func testResultSourceDescriptorCarriesScopeAndProvenance() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var provenance = VisualizationExportProvenance.proxyOnlyComplete
        provenance.hasStrippedBodies = true
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSession(sessionID),
            provenance: provenance
        )

        let descriptor = VisualizationExportSourceDescriptor(request: request)

        XCTAssertEqual(descriptor.scopeSummary, "1 selected session")
        XCTAssertEqual(descriptor.sessionIDs, [sessionID])
        XCTAssertTrue(descriptor.provenance.hasStrippedBodies)
    }
}
