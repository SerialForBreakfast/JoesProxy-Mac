//
//  ActionOwnershipResolverTests.swift
//  JoesProxyTests
//
//  Tests for BA-2.4 single action owner per effect invariant.
//

import XCTest
@testable import JoesProxy

final class ActionOwnershipResolverTests: XCTestCase {

    func testWhenNoApprovalPendingLocalIssueActionOwnsExecution() {
        let owner = ActionOwnershipResolver.resolveOwner(
            for: .startProxy,
            pendingApprovals: [],
            localIssueAction: (actionID: "start_proxy", title: "Start Proxy")
        )

        XCTAssertEqual(owner, .issueAction(actionID: "start_proxy", title: "Start Proxy"))
    }

    func testWhenApprovalPendingIssueResolvesToNavigateToApproval() {
        let approvalID = UUID()
        let approval = WorkingSurfaceApprovalItem(
            id: approvalID,
            clientKind: "test-client",
            summary: "Start Proxy on Port 8080",
            effect: .startProxy,
            receivedAt: Date()
        )

        let owner = ActionOwnershipResolver.resolveOwner(
            for: .startProxy,
            pendingApprovals: [approval],
            localIssueAction: (actionID: "start_proxy", title: "Start Proxy")
        )

        // Must NOT return .issueAction; must return navigation to the owning approval
        XCTAssertEqual(owner, .navigateToApproval(approvalID: approvalID))
    }

    func testSingleOwnerInvariantValidation() {
        let approval1 = WorkingSurfaceApprovalItem(
            id: UUID(),
            clientKind: "client-a",
            summary: "Start Proxy",
            effect: .startProxy,
            receivedAt: Date()
        )
        let approval2 = WorkingSurfaceApprovalItem(
            id: UUID(),
            clientKind: "client-b",
            summary: "Repair CA",
            effect: .repairCertificate,
            receivedAt: Date()
        )

        XCTAssertTrue(ActionOwnershipResolver.validateSingleOwnerInvariant(approvals: [approval1, approval2], issues: []))

        // Duplicate approvals for same effect violate invariant
        let duplicateApproval = WorkingSurfaceApprovalItem(
            id: UUID(),
            clientKind: "client-c",
            summary: "Start Proxy Duplicate",
            effect: .startProxy,
            receivedAt: Date()
        )
        XCTAssertFalse(ActionOwnershipResolver.validateSingleOwnerInvariant(approvals: [approval1, duplicateApproval], issues: []))
    }
}
