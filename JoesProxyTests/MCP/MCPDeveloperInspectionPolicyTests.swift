import XCTest
@testable import JoesProxy

/// AO Axis 2 — `developerInspection` profile gates and automation standing-grant recipe.
@MainActor
final class MCPDeveloperInspectionPolicyTests: XCTestCase {
    func testMetadataOnlyStillFailsClosedForMutatingEvenWithGrant() throws {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "meta-policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "meta-grants.json"))
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
        let client = makeClient(id: "meta", profile: .metadataOnly)

        try grantStore.addGrant(clientID: client.id, capability: .scenarioLifecycle, mode: .durablePolicy)

        XCTAssertFalse(evaluator.profileAllows(capability: .scenarioLifecycle, profileID: .metadataOnly))
        XCTAssertFalse(evaluator.effectiveAllows(capability: .scenarioLifecycle, client: client))
        XCTAssertFalse(evaluator.skipsApprovalNonce(capability: .scenarioLifecycle, client: client))
        try grantStore.addGrant(clientID: client.id, capability: .httpsRulesManage, mode: .durablePolicy)
        XCTAssertFalse(evaluator.effectiveAllows(capability: .httpsRulesManage, client: client))
        XCTAssertFalse(evaluator.profileAllows(capability: .httpsRulesInspect, profileID: .metadataOnly))
    }

    func testDeveloperInspectionAllowsAutomationCapabilities() {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "dev-policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "dev-grants.json"))
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)

        XCTAssertTrue(evaluator.profileAllows(capability: .hlsFixtureLifecycle, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .scenarioLifecycle, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .liveMediaProbe, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .createDisabledMapLocal, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .enableRule, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .hlsFixtureInspect, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .openAPIMockInspect, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .openAPIMockLifecycle, profileID: .developerInspection))
    }

    func testDeveloperInspectionDeniesHighBlastRadiusAtProfileLayer() {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "deny-policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "deny-grants.json"))
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
        let client = makeClient(id: "auto", profile: .developerInspection)
        XCTAssertFalse(evaluator.profileAllows(capability: .httpsRulesManage, profileID: .developerInspection))
        XCTAssertTrue(evaluator.profileAllows(capability: .httpsRulesInspect, profileID: .developerInspection))

        for capability in MCPAutomationClientGrantRecipe.alwaysDenyCapabilities {
            XCTAssertFalse(
                evaluator.profileAllows(capability: capability, profileID: .developerInspection),
                "Expected profile deny for \(capability.rawValue)"
            )
            XCTAssertFalse(evaluator.effectiveAllows(capability: capability, client: client))
        }
    }

    func testRecipeGrantsSkipNonceAndAlwaysDenyBlocksEvenWithMistakenGrant() throws {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "recipe-policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "recipe-grants.json"))
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
        let client = makeClient(id: "automation", profile: .developerInspection)

        _ = try MCPAutomationClientGrantRecipe.apply(to: grantStore, clientID: client.id)

        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .scenarioLifecycle, client: client))
        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .hlsFixtureLifecycle, client: client))
        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .openAPIMockLifecycle, client: client))
        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .liveMediaProbe, client: client))
        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .createDisabledMapLocal, client: client))

        // Mistaken durable grant must not elevate a profile-denied capability.
        try grantStore.addGrant(clientID: client.id, capability: .runtimeControl, mode: .durablePolicy)
        XCTAssertFalse(evaluator.effectiveAllows(capability: .runtimeControl, client: client))
        XCTAssertFalse(evaluator.skipsApprovalNonce(capability: .runtimeControl, client: client))

        XCTAssertFalse(evaluator.effectiveAllows(capability: .certificateCleanup, client: client))
        XCTAssertFalse(evaluator.effectiveAllows(capability: .activateMapRemote, client: client))
    }

    private func makeClient(id: String, profile: MCPDisclosureProfileID) -> MCPClientRecord {
        MCPClientRecord(
            id: id,
            displayName: id,
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
