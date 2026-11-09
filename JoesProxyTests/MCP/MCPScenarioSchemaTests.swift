import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioSchemaTests: XCTestCase {
    private func matcher(host: String = "api.example.com", path: String = "/v1") -> MCPMutationMatcher {
        MCPMutationMatcher(method: "GET", scheme: .https, host: host, port: nil, path: path, matchMode: .exactPath)
    }

    private func draftWithAssertion() -> MCPScenarioDraftInput {
        MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: "scenario-123"),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "JSON Round Trip",
            purpose: "Verify codable interchange.",
            originatingClientID: "client-1",
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [MCPScenarioPrecondition(kind: .captureActive, detail: nil)],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.block(matcher: matcher(), statusCode: 503)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [
                MCPScenarioAssertion(
                    kind: .requestOccurred,
                    matcher: matcher(),
                    host: nil,
                    path: nil,
                    statusCode: nil,
                    thresholdSeconds: nil,
                    expectedCount: nil,
                    markerName: nil,
                    detail: nil,
                    evidenceSource: .captured,
                    notes: nil
                ),
                MCPScenarioAssertion(
                    kind: .externalTestStepBegin,
                    matcher: nil,
                    host: nil,
                    path: nil,
                    statusCode: nil,
                    thresholdSeconds: nil,
                    expectedCount: nil,
                    markerName: "setup_complete",
                    detail: nil,
                    evidenceSource: .externalRunner,
                    notes: nil
                )
            ],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)]
        )
    }

    func testJSONRoundTripDraftWithBlockFaultAndAssertions() throws {
        let original = draftWithAssertion()
        let data = try MCPScenarioJSONCodec.encodeDraft(original)
        let decoded = try MCPScenarioJSONCodec.decodeDraft(from: data)
        XCTAssertEqual(decoded, original)
        let definition = try MCPScenarioCompiler.compile(draft: decoded)
        XCTAssertEqual(definition.assertions.count, 2)
        XCTAssertEqual(definition.assertions[0].kind, .requestOccurred)
    }

    func testValidationServiceReturnsApprovalDisclosureBundle() throws {
        let result = try MCPScenarioValidationService.validate(draft: draftWithAssertion())
        XCTAssertEqual(result.definition.name, "JSON Round Trip")
        XCTAssertEqual(result.riskTier, MCPCapabilityRiskTier.mutatingTool.rawValue)
        XCTAssertEqual(result.affectedTargetKeys.count, 1)
        XCTAssertEqual(result.approvalDisclosure.faultSummaries.count, 1)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testValidationServiceWarnsForSDKAssertions() throws {
        var draft = draftWithAssertion()
        draft.assertions.append(
            MCPScenarioAssertion(
                kind: .sdkPlaybackState,
                matcher: nil,
                host: nil,
                path: nil,
                statusCode: nil,
                thresholdSeconds: nil,
                expectedCount: nil,
                markerName: "playing",
                detail: nil,
                evidenceSource: .sdkReported,
                notes: nil
            )
        )
        let result = try MCPScenarioValidationService.validate(draft: draft)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("AI-3") }))
    }

    func testSchemaVersion99RejectedDeterministically() {
        var draft = draftWithAssertion()
        draft.schemaVersion = 99
        XCTAssertThrowsError(try MCPScenarioCompiler.compile(draft: draft)) { error in
            guard case MCPScenarioCompilerError.unsupportedSchemaVersion(let found, _) = error else {
                return XCTFail("Expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 99)
        }
    }
}
