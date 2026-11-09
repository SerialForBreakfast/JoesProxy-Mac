import Foundation

/// Compact join of already-authorized, closed observation windows and current run/bundle state.
/// Stored cleanup proof and external target reports retain their provenance; neither is inferred.
struct DiagnosticRunBrief: Codable, Sendable {
    struct Resource: Codable, Sendable {
        var resourceID: UUID
        var baselineObserved: Int
        var modifiedObserved: Int
        var modifiedCompleted: Int
        var delivered: Int
        var deliveryFailed: Int
        var deliveryPending: Int
    }
    struct Cleanup: Codable, Sendable {
        var verifiedAtRunClose: Bool
        var remainingEffectsAtRunClose: Int
        var proofPolicyRevision: String
        var proofCompletedAt: Date?
    }
    var schemaVersion = 1
    var status: String
    var runID: UUID
    var runStatus: String
    var baselineWindowID: UUID
    var modifiedWindowID: UUID
    var bundleID: UUID
    var revisionID: UUID
    var modifiedActivationID: UUID?
    var bundleLifecycleState: String
    var runCleanupProof: Cleanup?
    var resources: [Resource]
    var omittedResourceCount: Int
    var qualifications: [String]
    var omittedQualificationCount: Int
    var targetOutcome: String
    var targetOutcomeSource: String?
    var contentTrust = "captured_untrusted"
    var scope = "Closed-window resource counts, not unique requests or causality. Delivery is downstream write completion, not target acceptance. Bundle lifecycle is current metadata; run cleanup proof is historical and does not own bundle cleanup. Inspect client_cleanup_status for current client-wide cleanup."
    var nextTools = ["effect_bundle_compare", "diagnostic_run_status", "client_cleanup_status"]

    init(run: DiagnosticRun, comparison: EffectBundleComparison) {
        runID = run.id.rawValue
        runStatus = run.status.rawValue
        baselineWindowID = comparison.baseline.id
        modifiedWindowID = comparison.modified.id
        bundleID = comparison.modified.bundleID
        revisionID = comparison.modified.revisionID
        modifiedActivationID = comparison.modified.activationID
        bundleLifecycleState = comparison.cleanupState
        if let proof = run.cleanupProof {
            runCleanupProof = Cleanup(verifiedAtRunClose: proof.verifiedClean,
                remainingEffectsAtRunClose: proof.remainingLiveEffectCount,
                proofPolicyRevision: proof.policyRevision.rawValue, proofCompletedAt: proof.completedAt)
        }
        resources = comparison.resources.prefix(16).map {
            Resource(resourceID: $0.resourceID, baselineObserved: $0.baseline.observed,
                modifiedObserved: $0.modified.observed, modifiedCompleted: $0.modified.completed,
                delivered: $0.modified.delivered, deliveryFailed: $0.modified.deliveryFailed,
                deliveryPending: $0.modified.deliveryPending)
        }
        omittedResourceCount = comparison.resources.count - resources.count
        let reasons = Array(Set(comparison.baseline.qualifications + comparison.modified.qualifications)).sorted()
        qualifications = Array(reasons.prefix(32))
        omittedQualificationCount = reasons.count - qualifications.count
        targetOutcome = comparison.modified.targetOutcome
        targetOutcomeSource = comparison.modified.targetOutcomeSource
        status = reasons.isEmpty && omittedResourceCount == 0 &&
            comparison.resources.allSatisfy({ $0.modified.deliveryPending == 0 && $0.modified.completed == $0.modified.observed })
            ? "complete" : "incomplete"
    }
}
