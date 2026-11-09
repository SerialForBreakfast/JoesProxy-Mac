import XCTest
@testable import JoesProxy

final class MCPScenarioCompilerTests: XCTestCase {
    private func matcher(host: String = "api.example.com", path: String = "/v1") -> MCPMutationMatcher {
        MCPMutationMatcher(method: "GET", scheme: .https, host: host, port: nil, path: path, matchMode: .exactPath)
    }

    private func draft(
        faults: [MCPScenarioFault],
        cleanupActions: [MCPScenarioCleanupAction]? = nil,
        hosts: [String] = ["api.example.com"],
        schemaVersion: Int = MCPScenarioSchemaVersion.current
    ) -> MCPScenarioDraftInput {
        MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: schemaVersion,
            name: "Test Scenario",
            purpose: "Verify behavior under fault.",
            originatingClientID: "client-1",
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: hosts, paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: hosts, includeBodies: false),
            disclosureProfileID: .shareable,
            faults: faults,
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: cleanupActions ?? faults.enumerated().map {
                MCPScenarioCleanupAction(faultIndex: $0.offset, kind: $0.element.effectKind)
            }
        )
    }

    // MARK: - Happy path

    func testCompileSingleBlockFaultSucceeds() throws {
        let definition = try MCPScenarioCompiler.compile(
            draft: draft(faults: [.block(matcher: matcher(), statusCode: 503)])
        )
        XCTAssertEqual(definition.faults.count, 1)
        XCTAssertEqual(MCPScenarioCompiler.riskTier(for: definition), .mutatingTool)
    }

    func testCompileMultiFaultScenarioSucceeds() throws {
        let definition = try MCPScenarioCompiler.compile(
            draft: draft(
                faults: [
                    .block(matcher: matcher(path: "/a"), statusCode: 500),
                    .throttle(configuration: .defaults)
                ]
            )
        )
        XCTAssertEqual(definition.faults.count, 2)
    }

    func testRiskTierPicksMaxAcrossMixedRiskFaults() throws {
        let definition = try MCPScenarioCompiler.compile(
            draft: draft(
                faults: [
                    .block(matcher: matcher(path: "/a"), statusCode: 500),
                    .mapRemote(matcher: matcher(path: "/b"), remoteHost: "backup.example.com", remotePort: 443, remoteScheme: .https)
                ]
            )
        )
        XCTAssertEqual(MCPScenarioCompiler.riskTier(for: definition), .openWorldTool)
    }

    func testApprovalDisclosureIncludesOpenWorldDestinationForMapRemoteFault() throws {
        let definition = try MCPScenarioCompiler.compile(
            draft: draft(faults: [.mapRemote(matcher: matcher(), remoteHost: "backup.example.com", remotePort: 443, remoteScheme: .https)])
        )
        let disclosure = MCPScenarioCompiler.approvalDisclosure(for: definition)
        XCTAssertEqual(disclosure.riskTier, MCPCapabilityRiskTier.openWorldTool.rawValue)
        XCTAssertEqual(disclosure.openWorldDisclosures.first?.destinationHost, "backup.example.com")
    }

    func testCompileRejectsJsonRewriteFaultAsUnsupportedInScenarioComposition() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(
                    faults: [
                        .jsonRewrite(
                            matcher: matcher(path: "/live"),
                            jsonPath: "$.flag",
                            overrideValue: .bool(true)
                        )
                    ]
                )
            )
        ) { error in
            guard case MCPScenarioCompilerError.unsupportedFaultCombination = error else {
                return XCTFail("Expected unsupportedFaultCombination, got \(error)")
            }
        }
    }

    func testCompileRejectsJsonRewriteFaultEvenWhenMixedWithOtherFaults() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(
                    faults: [
                        .block(matcher: matcher(path: "/a"), statusCode: 500),
                        .jsonRewrite(
                            matcher: matcher(path: "/b"),
                            jsonPath: "$.flag",
                            overrideValue: .bool(true)
                        )
                    ]
                )
            )
        ) { error in
            guard case MCPScenarioCompilerError.unsupportedFaultCombination = error else {
                return XCTFail("Expected unsupportedFaultCombination, got \(error)")
            }
        }
    }

    // MARK: - Rejection rules

    func testCompileRejectsUnsupportedSchemaVersion() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(draft: draft(faults: [.block(matcher: matcher(), statusCode: 500)], schemaVersion: 99))
        ) { error in
            guard case MCPScenarioCompilerError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("Expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, MCPScenarioSchemaVersion.current)
        }
    }

    func testCompileRejectsEmptyTargetHosts() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(draft: draft(faults: [.block(matcher: matcher(), statusCode: 500)], hosts: []))
        ) { error in
            guard case MCPScenarioCompilerError.ambiguousTarget = error else {
                return XCTFail("Expected ambiguousTarget, got \(error)")
            }
        }
    }

    func testCompileRejectsFaultHostOutsideDeclaredTarget() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(
                    faults: [.block(matcher: matcher(host: "other.example.com"), statusCode: 500)],
                    hosts: ["api.example.com"]
                )
            )
        ) { error in
            guard case MCPScenarioCompilerError.ambiguousTarget = error else {
                return XCTFail("Expected ambiguousTarget, got \(error)")
            }
        }
    }

    func testCompileRejectsLoopbackMapRemoteDestination() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(faults: [.mapRemote(matcher: matcher(), remoteHost: "127.0.0.1", remotePort: 443, remoteScheme: .https)])
            )
        ) { error in
            guard case MCPScenarioCompilerError.unsafeDestination = error else {
                return XCTFail("Expected unsafeDestination, got \(error)")
            }
        }
    }

    func testCompileRejectsMissingCleanupAction() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(
                    faults: [.block(matcher: matcher(), statusCode: 500)],
                    cleanupActions: []
                )
            )
        ) { error in
            guard case MCPScenarioCompilerError.missingCleanup = error else {
                return XCTFail("Expected missingCleanup, got \(error)")
            }
        }
    }

    func testCompileRejectsTwoFaultsOnSameTarget() {
        let sharedMatcher = matcher()
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(faults: [
                    .block(matcher: sharedMatcher, statusCode: 500),
                    .mapLocal(matcher: sharedMatcher, inlineBodyText: "{}", inlineContentType: "application/json", inlineStatusCode: 200)
                ])
            )
        ) { error in
            guard case MCPScenarioCompilerError.unsupportedFaultCombination = error else {
                return XCTFail("Expected unsupportedFaultCombination, got \(error)")
            }
        }
    }

    func testCompileRejectsReplayComposedWithMapRemote() {
        let bookmarkID = UUID()
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(faults: [
                    .replay(bookmarkID: bookmarkID),
                    .mapRemote(matcher: matcher(), remoteHost: "backup.example.com", remotePort: 443, remoteScheme: .https)
                ])
            )
        ) { error in
            guard case MCPScenarioCompilerError.unsupportedFaultCombination = error else {
                return XCTFail("Expected unsupportedFaultCombination, got \(error)")
            }
        }
    }

    func testCompileRejectsExpiredScenario() {
        var input = draft(faults: [.block(matcher: matcher(), statusCode: 500)])
        input.expiresAt = Date(timeIntervalSince1970: 1)
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(draft: input, now: Date())
        ) { error in
            guard case MCPScenarioCompilerError.malformed = error else {
                return XCTFail("Expected malformed, got \(error)")
            }
        }
    }

    func testCompileRejectsCleanupKindMismatch() {
        XCTAssertThrowsError(
            try MCPScenarioCompiler.compile(
                draft: draft(
                    faults: [.block(matcher: matcher(), statusCode: 500)],
                    cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .mapLocal)]
                )
            )
        ) { error in
            guard case MCPScenarioCompilerError.missingCleanup = error else {
                return XCTFail("Expected missingCleanup, got \(error)")
            }
        }
    }

    func testCompileRejectsCaptureScopeOutsideTarget() {
        var input = draft(faults: [.block(matcher: matcher(), statusCode: 500)])
        input.captureScope = MCPScenarioCaptureScope(hosts: ["other.example.com"], includeBodies: false)
        XCTAssertThrowsError(try MCPScenarioCompiler.compile(draft: input)) { error in
            guard case MCPScenarioCompilerError.ambiguousTarget = error else {
                return XCTFail("Expected ambiguousTarget, got \(error)")
            }
        }
    }

    func testCompileRejectsInferredAssertionWithoutNotes() {
        var input = draft(faults: [.block(matcher: matcher(), statusCode: 500)])
        input.assertions = [
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
                evidenceSource: .inferredCorrelation,
                notes: nil
            )
        ]
        XCTAssertThrowsError(try MCPScenarioCompiler.compile(draft: input)) { error in
            guard case MCPScenarioCompilerError.malformed = error else {
                return XCTFail("Expected malformed, got \(error)")
            }
        }
    }

    func testCompileRejectsNonSelectableDisclosureProfile() {
        var input = draft(faults: [.block(matcher: matcher(), statusCode: 500)])
        input.disclosureProfileID = .fullLocalInspection
        XCTAssertThrowsError(try MCPScenarioCompiler.compile(draft: input)) { error in
            guard case MCPScenarioCompilerError.policyDenied = error else {
                return XCTFail("Expected policyDenied, got \(error)")
            }
        }
    }
}
