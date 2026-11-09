import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioToolsTests: XCTestCase {
    private struct Stack {
        let service: MCPScenarioService
        let runtime: MCPScenarioRuntimeService
        let store: MCPScenarioStore
        let approvalStore: MCPApprovalStore
        let responseOverrideStore: ResponseOverrideStore
        let client: MCPClientRecord
        let otherClient: MCPClientRecord
    }

    private func makeStack(profile: MCPDisclosureProfileID = .shareable) throws -> Stack {
        let lane = MCPSelfValidationLane(validationRunID: MCPValidationRunID.generate())
        let built = MCPSelfValidationScenarioStackFactory.makeStack(
            lane: lane,
            validationProxyPort: NetworkConstants.defaultPort
        )
        let client = MCPClientRecord(
            id: built.validationClient.id,
            displayName: built.validationClient.displayName,
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let otherClient = MCPClientRecord(
            id: "client-2",
            displayName: "Other",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            service: built.service,
            runtime: built.runtime,
            store: lane.scenarioStore,
            approvalStore: lane.approvalStore,
            responseOverrideStore: lane.responseOverrideStore,
            client: client,
            otherClient: otherClient
        )
    }

    private func makeDraftArguments(clientID: String = "self-validation-client") throws -> [String: Any] {
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/blocked",
            matchMode: .exactPath
        )
        let draft = MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Tool scenario",
            purpose: "AI-4 end-to-end",
            originatingClientID: clientID,
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.block(matcher: matcher, statusCode: 503)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [
                MCPScenarioAssertion(
                    kind: .requestOccurred,
                    matcher: matcher,
                    host: nil,
                    path: nil,
                    statusCode: nil,
                    thresholdSeconds: nil,
                    expectedCount: nil,
                    markerName: nil,
                    detail: nil,
                    evidenceSource: .captured,
                    notes: nil
                )
            ],
            assertionSeverity: .blocking,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)]
        )
        let data = try MCPScenarioJSONCodec.encodeDraft(draft)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ["draft": object as Any]
    }

    private func approvedCall(
        stack: Stack,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await stack.service.handleTool(name: tool, arguments: args, client: stack.client)
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"] as? String)
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            return try await stack.service.handleTool(name: tool, arguments: retry, client: stack.client)
        }
    }

    private func authorizationDictionary(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "authorization encoding failed")
        }
        return object
    }

    func testScenarioToolsDeniedForMetadataOnly() async throws {
        let stack = try makeStack(profile: .metadataOnly)
        do {
            _ = try await stack.service.handleTool(
                name: "draft_test_scenario",
                arguments: try makeDraftArguments(),
                client: stack.client
            )
            XCTFail("expected denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testPreviewDoesNotPersistScenario() async throws {
        let stack = try makeStack()
        let before = stack.store.scenarios.count
        _ = try await stack.service.handleTool(
            name: "preview_test_scenario",
            arguments: try makeDraftArguments(),
            client: stack.client
        )
        XCTAssertEqual(stack.store.scenarios.count, before)
    }

    func testDraftValidateArmActivateStopEndToEnd() async throws {
        let stack = try makeStack()
        let draftResult = try await stack.service.handleTool(
            name: "draft_test_scenario",
            arguments: try makeDraftArguments(),
            client: stack.client
        )
        let scenarioID = try XCTUnwrap(draftResult["scenarioID"] as? String)

        _ = try await stack.service.handleTool(
            name: "validate_test_scenario",
            arguments: ["scenarioID": scenarioID],
            client: stack.client
        )
        XCTAssertEqual(stack.store.scenario(id: MCPScenarioID(rawValue: scenarioID))?.phase, .awaitingApproval)

        _ = try await approvedCall(
            stack: stack,
            tool: "arm_test_scenario",
            args: ["scenarioID": scenarioID]
        )
        XCTAssertEqual(stack.store.scenario(id: MCPScenarioID(rawValue: scenarioID))?.phase, .armed)

        _ = try await approvedCall(
            stack: stack,
            tool: "activate_test_scenario",
            args: ["scenarioID": scenarioID]
        )
        XCTAssertEqual(stack.store.scenario(id: MCPScenarioID(rawValue: scenarioID))?.phase, .observing)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)

        _ = try await stack.service.handleTool(
            name: "evaluate_test_assertions",
            arguments: ["scenarioID": scenarioID],
            client: stack.client
        )
        XCTAssertEqual(stack.store.scenario(id: MCPScenarioID(rawValue: scenarioID))?.phase, .evaluating)

        _ = try await stack.service.handleTool(
            name: "get_test_report",
            arguments: ["scenarioID": scenarioID],
            client: stack.client
        )

        _ = try await stack.service.handleTool(
            name: "stop_test_scenario",
            arguments: ["scenarioID": scenarioID],
            client: stack.client
        )
        let final = stack.store.scenario(id: MCPScenarioID(rawValue: scenarioID))
        XCTAssertEqual(final?.phase, .failed)
        let clearedRules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(clearedRules.isEmpty)
    }

    func testScenarioOwnershipEnforced() async throws {
        let stack = try makeStack()
        let draftResult = try await stack.service.handleTool(
            name: "draft_test_scenario",
            arguments: try makeDraftArguments(),
            client: stack.client
        )
        let scenarioID = try XCTUnwrap(draftResult["scenarioID"] as? String)
        do {
            _ = try await stack.service.handleTool(
                name: "validate_test_scenario",
                arguments: ["scenarioID": scenarioID],
                client: stack.otherClient
            )
            XCTFail("expected ownership denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }
}

