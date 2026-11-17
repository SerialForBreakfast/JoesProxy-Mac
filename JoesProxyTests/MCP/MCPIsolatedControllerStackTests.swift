import XCTest
@testable import JoesProxy

@MainActor
final class MCPIsolatedControllerStackTests: XCTestCase {
    /// A local confirmation grants future access only to the named client. Awaiting the
    /// main-actor store flush before reload exercises the same disk handoff as a relaunch.
    func testSetupApprovalsSurviveReloadAndCanBeRevoked() async throws {
        let controller = try MCPIsolatedControllerStack.make().controller
        controller.bootstrap()
        let client = try controller.enrollClient(displayName: "Capture CLI", profileID: .shareable).client
        let other = try controller.enrollClient(displayName: "Other CLI", profileID: .shareable).client
        try controller.applySetupGrants([.runtimeControl: true, .bodyRead: true], for: client)
        controller.bootstrap()
        let saved = await controller.grantStore.saveReviewedChanges()
        XCTAssertTrue(saved)
        controller.grantStore.load()
        XCTAssertTrue(controller.policyEvaluator.skipsApprovalNonce(capability: .runtimeControl, client: client))
        XCTAssertFalse(controller.policyEvaluator.skipsApprovalNonce(capability: .runtimeControl, client: other))
        try controller.applySetupGrants([.runtimeControl: false], for: client)
        XCTAssertFalse(controller.policyEvaluator.skipsApprovalNonce(capability: .runtimeControl, client: client))
        XCTAssertTrue(controller.policyEvaluator.skipsApprovalNonce(capability: .bodyRead, client: client))
    }

    /// A mixed selection containing a restricted capability fails before any grant is saved.
    func testSetupApprovalsRespectProfileDenialAndOneUseReview() throws {
        let controller = try MCPIsolatedControllerStack.make().controller
        controller.bootstrap()
        let client = try controller.enrollClient(displayName: "Capture CLI", profileID: .shareable).client
        let restricted = try controller.enrollClient(displayName: "Metadata CLI", profileID: .metadataOnly).client
        XCTAssertThrowsError(try controller.applySetupGrants([.runtimeControl: true], for: restricted))
        XCTAssertThrowsError(try controller.applySetupGrants([.bodyRead: true, .httpsRulesManage: true], for: client))
        _ = controller.grantStore.addDenial(clientID: client.id, capability: .runtimeControl)
        XCTAssertThrowsError(try controller.applySetupGrants([.bodyRead: true, .runtimeControl: true], for: client))
        XCTAssertTrue(controller.grantStore.grants.isEmpty)
    }

    func testIsolatedStackDoesNotTouchLiveClientRegistry() throws {
        let liveURL = MCPClientRegistry.defaultPersistenceURL()
        let liveBefore = try? Data(contentsOf: liveURL)

        let stack = try MCPIsolatedControllerStack.make()
        XCTAssertEqual(stack.clientRegistry.persistenceURL, stack.clientRegistryPersistenceURL)
        XCTAssertNotEqual(
            stack.clientRegistryPersistenceURL.standardizedFileURL,
            liveURL.standardizedFileURL
        )
        XCTAssertFalse(
            stack.clientRegistryPersistenceURL.path.hasSuffix("/JoesProxy/mcp-clients.json"),
            "Isolated stacks must not bind Application Support/JoesProxy/mcp-clients.json"
        )

        stack.controller.bootstrap()
        let enrollment = try stack.controller.enrollClient(
            displayName: "Test Client",
            profileID: .shareable
        )
        try stack.controller.revokeClient(clientID: enrollment.client.id)

        XCTAssertEqual(stack.clientRegistry.client(id: enrollment.client.id)?.credentialState, .revoked)
        let liveAfter = try? Data(contentsOf: liveURL)
        XCTAssertEqual(liveBefore, liveAfter, "Enroll/revoke on an isolated stack must not rewrite the live registry")
    }
}
