import XCTest
@testable import JoesProxy

@MainActor
final class MCPIsolatedControllerStackTests: XCTestCase {
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
