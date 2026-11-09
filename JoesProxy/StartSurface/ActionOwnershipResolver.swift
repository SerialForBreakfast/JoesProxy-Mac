//
//  ActionOwnershipResolver.swift
//  JoesProxy
//
//  Enforces single interactive ownership per effect (BA-2.4).
//  When an approval owns an effect, issues provide navigation only ("Show Approval"),
//  never a duplicate execution button.
//

import Foundation

enum ActionOwnershipResolver {

    /// Resolves the single interactive owner for a given effect.
    ///
    /// - Parameters:
    ///   - effect: The desired mutation or state change.
    ///   - pendingApprovals: Currently pending agent/MCP approval requests.
    ///   - localIssueAction: A local repair action if available (actionID, title).
    /// - Returns: The designated `ActionOwner`.
    static func resolveOwner(
        for effect: ActionEffect,
        pendingApprovals: [WorkingSurfaceApprovalItem],
        localIssueAction: (actionID: String, title: String)? = nil
    ) -> ActionOwner {
        // If an approval is pending for this effect, it owns the decision.
        if let matchingApproval = pendingApprovals.first(where: { $0.effect == effect }) {
            return .navigateToApproval(approvalID: matchingApproval.id)
        }

        // Otherwise, if a local repair action is available, issues own it.
        if let local = localIssueAction {
            return .issueAction(actionID: local.actionID, title: local.title)
        }

        return .none
    }

    /// Verifies that no two items across the working surface provide duplicate executable triggers
    /// for the same underlying effect.
    static func validateSingleOwnerInvariant(
        approvals: [WorkingSurfaceApprovalItem],
        issues: [WorkingSurfaceIssueItem]
    ) -> Bool {
        var ownedEffects = Set<ActionEffect>()
        for approval in approvals {
            if ownedEffects.contains(approval.effect) {
                return false
            }
            ownedEffects.insert(approval.effect)
        }
        return true
    }
}
