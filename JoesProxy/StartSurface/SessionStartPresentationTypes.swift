//
//  SessionStartPresentationTypes.swift
//  JoesProxy
//
//  Shared types for BA-2 session-start presentation, presentation truth,
//  action ownership, and serialized launch interruptions.
//

import Foundation

/// Defines presentation truth levels, distinguishing between verified live states,
/// checks in-flight, timestamped historical hints, and failures.
enum PresentationTruth: Equatable, Sendable {
    case current(String)
    case checking
    case lastKnown(summary: String, timestamp: Date)
    case unavailable(String)
    case failed(String)

    var isLiveGreen: Bool {
        if case .current = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .current(let text):
            return text
        case .checking:
            return "Checking…"
        case .lastKnown(let summary, let date):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            let timeString = formatter.string(from: date)
            return "Last known: \(summary) (\(timeString))"
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

enum StatusCategory: String, CaseIterable, Sendable {
    case proxy
    case certificate
    case network
    case routing
    case client
}

struct WorkingSurfaceStatusRow: Identifiable, Equatable, Sendable {
    let id: String
    let category: StatusCategory
    let label: String
    let truth: PresentationTruth
}

enum IssueSeverity: String, Comparable, Sendable {
    case critical
    case warning
    case info

    private var priorityOrder: Int {
        switch self {
        case .critical: return 0
        case .warning: return 1
        case .info: return 2
        }
    }

    static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        lhs.priorityOrder < rhs.priorityOrder
    }
}

enum ActionEffect: Hashable, Sendable {
    case startProxy
    case repairCertificate
    case enrollClient
    case restoreSystemProxy
    case resolveConflict(String)
}

enum ActionOwner: Equatable, Sendable {
    case none
    case issueAction(actionID: String, title: String)
    case navigateToApproval(approvalID: UUID)
    case approvals(approvalID: UUID)
}

struct WorkingSurfaceIssueItem: Identifiable, Equatable, Sendable {
    let id: String
    let severity: IssueSeverity
    let title: String
    let message: String
    let actionOwner: ActionOwner
}

struct WorkingSurfaceApprovalItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let clientKind: String
    let summary: String
    let effect: ActionEffect
    let receivedAt: Date
}

enum LaunchInterruptionKind: String, CaseIterable, Comparable, Sendable {
    case systemProxyRecovery
    case certificateRepair
    case effectConflictRecovery
    case savedCaptureRestoration
    case guidedSetup

    private var priority: Int {
        switch self {
        case .systemProxyRecovery: return 1
        case .certificateRepair: return 2
        case .effectConflictRecovery: return 3
        case .savedCaptureRestoration: return 4
        case .guidedSetup: return 5
        }
    }

    static func < (lhs: LaunchInterruptionKind, rhs: LaunchInterruptionKind) -> Bool {
        lhs.priority < rhs.priority
    }
}

struct WorkingSurfaceState: Equatable, Sendable {
    var selectedTargetID: String?
    var preferredView: WorkingViewPreference
    var statusRows: [WorkingSurfaceStatusRow]
    var pendingApprovals: [WorkingSurfaceApprovalItem]
    var issues: [WorkingSurfaceIssueItem]
    var activeInterruption: LaunchInterruptionKind?

    static var empty: WorkingSurfaceState {
        WorkingSurfaceState(
            selectedTargetID: nil,
            preferredView: .inspector,
            statusRows: [],
            pendingApprovals: [],
            issues: [],
            activeInterruption: nil
        )
    }
}
