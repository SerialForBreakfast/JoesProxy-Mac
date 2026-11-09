import Foundation

enum EffectBundleRecoveryAction: String, CaseIterable, Sendable {
    case inspectRequest, reviewMatcher, reviewClientScope, reviewIntegrity, checkAsset, refreshEvidence, observeNextRequest

    var label: String {
        switch self {
        case .inspectRequest: return "Inspect request"
        case .reviewMatcher: return "Review matcher"
        case .reviewClientScope: return "Review client scope"
        case .reviewIntegrity: return "Review integrity issue"
        case .checkAsset: return "Check retained asset"
        case .refreshEvidence: return "Refresh evidence"
        case .observeNextRequest: return "Observe next request"
        }
    }
}

struct EffectBundleRecoveryAvailability: Equatable {
    var receiptExists: Bool
    var resourceExists: Bool
    var captureExists: Bool
    var bundleServing: Bool
}

struct EffectBundleRecoveryChoice: Equatable, Identifiable {
    let action: EffectBundleRecoveryAction
    let unavailableReason: String?
    var id: EffectBundleRecoveryAction { action }
    var isEnabled: Bool { unavailableReason == nil }
}

struct EffectBundleRecoveryPresentation: Equatable {
    let title: String
    let explanation: String
    let primary: EffectBundleRecoveryChoice
    let secondary: [EffectBundleRecoveryChoice]
}

enum EffectBundleRecoveryPolicy {
    static func choice(_ action: EffectBundleRecoveryAction, receipt: EffectBundleDeliveryReceipt?,
                       availability: EffectBundleRecoveryAvailability) -> EffectBundleRecoveryChoice {
        let reason: String?
        switch action {
        case .refreshEvidence: reason = nil
        case .observeNextRequest:
            reason = availability.bundleServing ? nil : "This bundle is not serving. Its existing evidence is still available."
        default:
            if !availability.receiptExists || receipt == nil {
                reason = "This receipt is no longer retained. Refresh evidence to see available observations."
            } else if action == .inspectRequest && receipt?.sessionID == nil {
                reason = "Capture identity is not available yet. Refresh evidence; no request will be replayed."
            } else if action == .inspectRequest && !availability.captureExists {
                reason = "The captured request is no longer available. Existing receipt details are preserved."
            } else if [.reviewMatcher, .reviewClientScope, .checkAsset].contains(action) && !availability.resourceExists {
                reason = "The matching retained revision/resource is unavailable. Do not substitute a newer rule."
            } else { reason = nil }
        }
        return .init(action: action, unavailableReason: reason)
    }

    static func resolve(_ receipt: EffectBundleDeliveryReceipt, availability: EffectBundleRecoveryAvailability) -> EffectBundleRecoveryPresentation {
        let title: String, explanation: String, primary: EffectBundleRecoveryAction
        var secondary: [EffectBundleRecoveryAction] = [.refreshEvidence]
        if receipt.matchesExpectedDelivery == false {
            title = "Response differs from reviewed asset"
            explanation = "Compare the recorded hashes before deciding how to recover. Inspection does not accept new bytes or stop the bundle."
            primary = .reviewIntegrity
            secondary.insert(.checkAsset, at: 0)
            secondary.insert(.inspectRequest, at: 0)
        } else {
            switch receipt.evaluation {
            case .matcherMismatch:
                title = "Request did not match this resource"
                explanation = "A sibling request may legitimately miss this matcher. Compare the request and configured scope before proposing changes."
                primary = .inspectRequest; secondary.insert(.reviewMatcher, at: 0)
            case .clientScopeMismatch:
                title = "Request came from a different client scope"
                explanation = "Other request criteria matched. Review the observed and configured client; scope will not be widened."
                primary = .reviewClientScope; secondary.insert(.inspectRequest, at: 0)
            case .assetReadFailed:
                title = "Asset could not be read"
                explanation = "No authored body was resolved. Check the retained package without changing active traffic. A verified package does not prove runtime availability."
                primary = .checkAsset; secondary.insert(.inspectRequest, at: 0)
            case .responseResolved:
                switch receipt.delivery {
                case .pending:
                    title = "Waiting for downstream write completion"
                    explanation = "No final write result has been recorded. Refreshing does not resend the request or invent a timeout."
                    primary = .refreshEvidence; secondary = [.inspectRequest]
                case .downstreamWriteFailed:
                    title = "Downstream write failed"
                    explanation = "The client may have disconnected. Inspect captured evidence; this does not identify a target application error."
                    primary = .inspectRequest; secondary.insert(.observeNextRequest, at: 0)
                case .downstreamWriteSucceeded:
                    title = "Downstream write completed"
                    explanation = "Proxy transport completed. Rendering, parsing, and playback remain unconfirmed."
                    primary = .inspectRequest
                case .notApplied:
                    title = "No authored response applied"
                    explanation = "Inspect available evidence before changing the mock."
                    primary = .inspectRequest
                }
            }
        }
        return .init(title: title, explanation: explanation,
            primary: choice(primary, receipt: receipt, availability: availability),
            secondary: secondary.map { choice($0, receipt: receipt, availability: availability) })
    }
}
