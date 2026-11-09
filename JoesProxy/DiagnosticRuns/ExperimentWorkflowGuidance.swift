import Foundation

/// Read-only guidance, not a second lifecycle engine or an authorization decision.
/// Pure projections can run on any executor; callers retain ownership/policy checks.
struct ExperimentWorkflowGuidance: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case define, preflight, baseline, analyze, prepare, review, activate, observe, evaluate, cleanup, report
    }

    struct Action: Codable, Equatable, Sendable {
        let tool: String?
        let intent: String
        let authority: String
    }

    let stage: Stage
    let reasonCodes: [String]
    let nextActions: [Action]
    let evidenceScope: String
    let targetOutcome: String

    static let prepared = Self(stage: .review, reasonCodes: ["inactiveRevision"], nextActions: [
        Action(tool: "effect_bundle_inspect", intent: "Inspect revisionID, changed fields, asset hashes and client scope before importing inactive.", authority: "existingReadPolicy"),
        Action(tool: "effect_bundle_import", intent: "Retain the reviewed revision inactive; then propose activation for local-user approval.", authority: "existingOwnerPolicy")
    ], evidenceScope: "Prepared bytes only; no activation or delivery established.", targetOutcome: "unknown")

    static let activated = Self(stage: .observe, reasonCodes: ["deliveryUnverified"], nextActions: [
        Action(tool: "effect_bundle_inspect", intent: "Record nextMarker before a separately authorized target action; inspect later changes with afterMarker.", authority: "existingReadPolicy")
    ], evidenceScope: "Activation result only; verify each expected resource and target outcome independently.", targetOutcome: "unknown")

    static let stopped = Self(stage: .cleanup, reasonCodes: ["returnToNormalUnverified"], nextActions: [
        Action(tool: "effect_bundle_list", intent: "Verify this owned bundle's state and other attempt effects; close the diagnostic run separately.", authority: "existingReadPolicy"),
        Action(tool: nil, intent: "Verify return to normal in the target; stopping does not undo client caches or prove target recovery.", authority: "separateTargetInteractionPermission")
    ], evidenceScope: "This bundle's stop result only; unrelated effects and target state are not inferred.", targetOutcome: "unknown")

    var payload: [String: Any] {
        ["schemaVersion": 1, "stage": stage.rawValue, "reasonCodes": reasonCodes,
         "nextActions": nextActions.map { action -> [String: Any] in
             var result = ["intent": action.intent, "authority": action.authority]
             if let tool = action.tool { result["tool"] = tool }
             return result
         }, "evidenceScope": evidenceScope, "targetOutcome": targetOutcome]
    }

    static func delivery(_ evidence: EffectBundleDeliveryEvidence) -> Self {
        var reasons: [String] = []
        let hasObservations = !evidence.observations.isEmpty || !evidence.receipts.isEmpty
        let deliveries = evidence.observations.isEmpty
            ? evidence.receipts.map(\.delivery) : evidence.observations.map(\.delivery)
        if evidence.retentionGap { reasons.append("retentionGap") }
        if evidence.hasMore { reasons.append("moreEvidencePages") }
        if !hasObservations { reasons.append("noRetainedObservation") }
        for evaluation in [EffectBundleDeliveryReceipt.Evaluation.matcherMismatch, .clientScopeMismatch, .assetReadFailed] {
            if evidence.receipts.contains(where: { $0.evaluation == evaluation }) { reasons.append(evaluation.rawValue) }
        }
        if evidence.receipts.contains(where: { $0.matchesExpectedDelivery == false }) { reasons.append("reviewedAssetMismatch") }
        if deliveries.contains(.downstreamWriteFailed) { reasons.append("downstreamWriteFailed") }
        if deliveries.contains(.pending) { reasons.append("deliveryPending") }
        if evidence.observations.contains(where: {
            $0.kind == .liveCollection && $0.outcome != "applied" && $0.outcome != "awaitingResponse"
        }) {
            reasons.append("liveTransformationNotApplied")
        }
        reasons.append("targetOutcomeUnknown")
        var actions = [Action(tool: "effect_bundle_inspect",
            intent: evidence.hasMore ? "Read the next page using nextMarker; retain revision and activation identities."
                : "After new target activity or pending completion, read changes using nextMarker; avoid tight polling.",
            authority: "existingReadPolicy")]
        if reasons.contains("assetReadFailed") || reasons.contains("reviewedAssetMismatch") {
            actions.append(Action(tool: "effect_bundle_stop", intent: "Stop the owned bundle before preparing replacement bytes.", authority: "existingOwnerPolicy"))
        } else if !evidence.hasMore {
            actions.append(Action(tool: nil,
                intent: "Check each expected resource, client scope and revision. Review typed skip reasons before retrying. Missing requests do not prove caching; upstream delivery after a skip is not mutation success; delivery does not prove rendering.",
                authority: "separateTargetInteractionPermission"))
        }
        return Self(stage: hasObservations ? .evaluate : .observe, reasonCodes: reasons,
            nextActions: actions, evidenceScope: "Returned observation page only; not active state, complete resource coverage, or a cross-request transaction.",
            targetOutcome: "unknown")
    }

    /// Lifecycle is sampled after the async inspection. Evidence can describe older activations;
    /// it must never tell an agent to drive new traffic against a stopped or incomplete bundle.
    static func retained(state: EffectBundleState, evidence: EffectBundleDeliveryEvidence,
                         lifecycleChanged: Bool = false) -> Self {
        if lifecycleChanged {
            return Self(stage: .preflight, reasonCodes: ["lifecycleChangedDuringRead"], nextActions: [
                Action(tool: "effect_bundle_inspect", intent: "Reinspect this bundle by ID before acting; lifecycle changed during this read.", authority: "existingReadPolicy")
            ], evidenceScope: "Non-atomic lifecycle/evidence read; no readiness inferred.", targetOutcome: "unknown")
        }
        switch state {
        case .serving: return delivery(evidence)
        case .inactive:
            return Self(stage: .review, reasonCodes: ["inactiveBundle"], nextActions: [
                Action(tool: "diagnostic_run_window_begin", intent: "If comparison is needed, explicitly begin and end an owned baseline window while this bundle is inactive.", authority: "existingOwnerPolicy"),
                Action(tool: "propose_activate_effect_bundle", intent: "Review bundle ID, revision, client scope and expiry; propose activation, then let the local user resolve any required approval.", authority: "existingApprovalPolicy")
            ], evidenceScope: "Retained configuration only; historical observations do not establish current delivery.", targetOutcome: "unknown")
        case .cleanupRequired:
            return Self(stage: .cleanup, reasonCodes: ["cleanupRequired"], nextActions: [
                Action(tool: "effect_bundle_stop", intent: "Retry this owned bundle's cleanup, then inspect by ID. Do not activate a replacement or stop unrelated effects while cleanup is unresolved.", authority: "existingOwnerPolicy")
            ], evidenceScope: "Cleanup is incomplete; historical delivery does not establish return to normal.", targetOutcome: "unknown")
        case .stopped, .expired: return stopped
        }
    }

    static func run(status: DiagnosticRunStatus, cleanupVerified: Bool) -> Self {
        let stage: Stage
        let action: Action
        var reasons: [String] = []
        switch status {
        case .draft:
            stage = .preflight
            action = Action(tool: "diagnostic_run_start", intent: "After baseline prerequisites are verified, install observation watches only; this does not activate effects.", authority: "existingOwnerPolicy")
        case .watching, .active:
            stage = .observe
            action = Action(tool: "diagnostic_run_observations", intent: "Read bounded observations; relate them to separately owned bundle revision and attempt markers.", authority: "existingReadPolicy")
        case .closing:
            stage = .cleanup
            action = Action(tool: "diagnostic_run_status", intent: "Inspect cleanup progress before reporting completion.", authority: "existingReadPolicy")
        case .cleanupRequired:
            stage = .cleanup
            reasons = ["cleanupRequired"]
            action = Action(tool: "diagnostic_run_retry_cleanup", intent: "Retry cleanup through the existing owner; do not stop unrelated effects.", authority: "existingOwnerPolicy")
        case .passed, .failed, .inconclusive, .expired:
            stage = cleanupVerified ? .report : .cleanup
            reasons = cleanupVerified ? [] : ["cleanupUnverified"]
            action = Action(tool: "diagnostic_run_status", intent: "Report the stored conclusion and cleanup proof separately; verify separately owned bundles independently.", authority: "existingReadPolicy")
        }
        return Self(stage: stage, reasonCodes: reasons, nextActions: [action],
            evidenceScope: "Diagnostic-run lifecycle only; bundle ownership and target outcomes are not inferred.", targetOutcome: "notInferred")
    }
}
