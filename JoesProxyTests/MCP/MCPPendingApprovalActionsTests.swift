import XCTest
@testable import JoesProxy

/// With several approvals pending, VoiceOver and the rotor list every row's controls together;
/// identical "Allow Once"/"Deny" labels would make it impossible to tell which request each resolves.
final class MCPPendingApprovalActionsTests: XCTestCase {
    func testActionLabelsNameTheRequestAndDifferAcrossRequests() {
        let bodyRead = request(id: "r1", reason: "Read response body", client: "agent-a")
        let block = request(id: "r2", reason: "Create block rule", client: "agent-b")

        let first = MCPPendingApprovalActions.accessibilityLabel("Allow Once", for: bodyRead)
        let second = MCPPendingApprovalActions.accessibilityLabel("Allow Once", for: block)

        XCTAssertTrue(first.hasPrefix("Allow Once"))
        XCTAssertTrue(first.contains("Read response body"))
        XCTAssertTrue(first.contains("agent-a"))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(
            MCPPendingApprovalActions.accessibilityLabel("Deny", for: bodyRead),
            MCPPendingApprovalActions.accessibilityLabel("Always Deny", for: bodyRead)
        )
    }

    private func request(id: String, reason: String, client: String) -> MCPApprovalRequest {
        MCPApprovalRequest(
            requestID: id,
            clientID: client,
            argumentDigest: "digest-\(id)",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: Date().addingTimeInterval(60),
            reason: reason,
            capability: .bodyRead
        )
    }
}
