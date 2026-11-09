import Foundation

// MARK: - Effect recreation seam (AN-5)

/// Read-only preview of whether/how a reference could be recreated, without recreating it.
enum DiagnosticRunEffectRecreationPreview: Equatable, Sendable {
    case supported(currentTargetRevision: String?, revisionChanged: Bool)
    case unsupported
    case targetMissing
}

/// Result of actually recreating one referenced effect through its normal proposal/apply path.
enum DiagnosticRunEffectRecreationResult: Equatable, Sendable {
    case recreated(newOpaqueID: String, targetRevision: String?)
    case unsupported
    case approvalDenied
    case interrupted
    case targetMissing
}

/// Recreates a referenced effect through its owning subsystem's normal proposal/apply path
/// (AN-5). Never bypasses approval or activates anything on the caller's behalf; a real
/// implementation calls into `MCPMutationService` the same way an agent-driven propose/apply
/// would. AN-2's analogous `DiagnosticRunEffectResolving` seam has no real (non-`NoOp`)
/// implementation wired anywhere in this codebase yet either (confirmed: `AppCoordinator` still
/// constructs `DiagnosticRunCoordinator` without an `effectResolver:` argument, defaulting to the
/// no-op) — this protocol follows the same deliberate pattern, so a real adapter into
/// `MCPMutationService` can land as its own focused follow-up once AN-6 defines the composite
/// MCP re-check tool that will actually drive it.
protocol DiagnosticRunEffectRecreating: AnyObject {
    /// Read-only. Must not create, enable, or mutate anything.
    func previewRecreation(reference: DiagnosticRunReference) async -> DiagnosticRunEffectRecreationPreview

    /// Recreates the effect. Implementations must go through the referenced subsystem's normal
    /// proposal/apply/approval path — never silently re-enable a stale rule.
    func recreate(
        reference: DiagnosticRunReference,
        requestingOwnerID: String
    ) async -> DiagnosticRunEffectRecreationResult
}

/// Default/test recreator: every reference is unsupported unless explicitly stubbed.
@MainActor
final class NoOpDiagnosticRunEffectRecreator: DiagnosticRunEffectRecreating {
    var previews: [String: DiagnosticRunEffectRecreationPreview] = [:]
    var results: [String: DiagnosticRunEffectRecreationResult] = [:]

    private func key(_ kind: DiagnosticReferenceKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    func previewRecreation(reference: DiagnosticRunReference) async -> DiagnosticRunEffectRecreationPreview {
        previews[key(reference.kind, reference.opaqueID)] ?? .unsupported
    }

    func recreate(
        reference: DiagnosticRunReference,
        requestingOwnerID: String
    ) async -> DiagnosticRunEffectRecreationResult {
        results[key(reference.kind, reference.opaqueID)] ?? .unsupported
    }
}

// MARK: - Preparation (read-only disclosure, before any activation)

/// One reference's recreation preview, carried alongside the original reference it describes.
struct DiagnosticRunRecheckReferencePreview: Equatable, Sendable {
    var reference: DiagnosticRunReference
    var preview: DiagnosticRunEffectRecreationPreview
}

/// Everything the owner must review before a re-check is allowed to recreate anything. Building
/// this never recreates, enables, or mutates any effect — it is pure disclosure.
struct DiagnosticRunRecheckPreparation: Equatable, Sendable {
    var sourceRunID: DiagnosticRunID
    var sourceEvidenceID: UUID
    var requestingOwnerID: String
    var scopes: [DiagnosticRunScope]
    var referencePreviews: [DiagnosticRunRecheckReferencePreview]
    var expectedOutcomeSummary: String
    var cleanupPlanDescription: String
    var preparedAt: Date
    var expiresAt: Date
    /// False when the saved record cannot be safely re-checked at all (unsupported schema/scope/
    /// effect kind, or a reference's target revision has already changed). `executeRecheck` still
    /// accepts an incompatible preparation — it short-circuits straight to Inconclusive with
    /// `incompatibilityReason`, recreating nothing.
    var isCompatible: Bool
    var incompatibilityReason: DiagnosticConclusionReasonCode?
}

enum DiagnosticRunRecheckError: Error, Equatable, Sendable {
    case evidenceNotFound
    case notOwner
    case sourceNotTerminal
    case preparationExpired
}

// MARK: - Fresh observation gathering (synchronous, no watch install, no waiting)

/// Synchronous lookup over already-captured sessions, used by regression re-check to build a
/// fresh observation without installing a new watch or blocking on live traffic — the operator/
/// agent is expected to have already driven the traffic they want re-checked before calling
/// `executeRecheck`.
protocol DiagnosticRunCaptureHistoryQuerying: AnyObject {
    func capturedEvents(since: Date) -> [DiagnosticRunCaptureEvent]
}

/// Default/test history source: returns nothing unless stubbed.
@MainActor
final class NoOpDiagnosticRunCaptureHistory: DiagnosticRunCaptureHistoryQuerying {
    var events: [DiagnosticRunCaptureEvent] = []

    func capturedEvents(since: Date) -> [DiagnosticRunCaptureEvent] {
        events.filter { $0.observedAt >= since }
    }
}

/// Re-scans already-captured events against a run's saved scopes and aggregates a fresh
/// `DiagnosticRunObservationSummary`, mirroring `DiagnosticRunObservationIndex`'s live
/// hit/matcherMiss/status-family/latency aggregation exactly so re-check comparisons behave the
/// same as the original watching run. `.effect` scopes are skipped — resolving an effect ID to
/// its disclosed HTTP matcher needs `DiagnosticRunEffectScopeResolving`, which this synchronous
/// path does not have; effect-scoped re-checks fall back to today's `inconclusive(.noRequest)`.
enum DiagnosticRunFreshObservationGatherer {
    static func summarize(
        runID: DiagnosticRunID,
        scopes: [DiagnosticRunScope],
        events: [DiagnosticRunCaptureEvent]
    ) -> DiagnosticRunObservationSummary {
        let watches: [DiagnosticInstalledWatch] = scopes.compactMap { scope in
            switch scope {
            case .http(let http):
                return DiagnosticInstalledWatch(
                    id: UUID(), runID: runID, ownerID: "", scope: scope, resolvedHTTP: http, fingerprint: nil
                )
            case .capturedSession(let captured):
                return DiagnosticInstalledWatch(
                    id: UUID(), runID: runID, ownerID: "", scope: scope, resolvedHTTP: nil,
                    fingerprint: captured.requestFingerprint
                )
            case .effect:
                return nil
            }
        }
        guard !watches.isEmpty else { return .empty }

        var summary = DiagnosticRunObservationSummary.empty
        var ingestedSessionIDs: Set<UUID> = []
        for event in events.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard !event.isMarker, !ingestedSessionIDs.contains(event.sessionID) else { continue }
            if !summary.captureEpochs.contains(event.captureEpoch) {
                summary.captureEpochs.append(event.captureEpoch)
            }
            var best: DiagnosticRunScopeMatcher.Decision = .ignore
            for watch in watches {
                switch DiagnosticRunScopeMatcher.decision(for: event, watch: watch) {
                case .hit: best = .hit
                case .matcherMiss: if best != .hit { best = .matcherMiss }
                case .ignore: break
                }
            }
            guard best != .ignore else { continue }
            ingestedSessionIDs.insert(event.sessionID)
            if best == .hit {
                summary.matchedRequestCount += 1
                if let family = DiagnosticRunScopeMatcher.statusFamily(for: event.statusCode) {
                    summary.statusFamilies[family, default: 0] += 1
                }
                if let latency = event.latencyMilliseconds {
                    summary.minimumLatencyMilliseconds = min(summary.minimumLatencyMilliseconds ?? latency, latency)
                    summary.maximumLatencyMilliseconds = max(summary.maximumLatencyMilliseconds ?? latency, latency)
                }
            } else {
                summary.matcherMissCount += 1
            }
            summary.lastObservedAt = event.observedAt
        }
        return summary
    }
}

// MARK: - Outcome / result

/// Tri-state comparison of fresh evidence against a saved conclusion (AN-5).
enum DiagnosticRunRegressionOutcome: Equatable, Sendable {
    case stillHolds
    case regressionDetected
    case inconclusive(DiagnosticConclusionReasonCode)
}

/// Outcome of one re-check attempt, including proof that anything recreated was cleaned up —
/// populated on every path, including the ones that never recreated anything.
struct DiagnosticRunRecheckResult: Equatable, Sendable {
    var sourceRunID: DiagnosticRunID
    var outcome: DiagnosticRunRegressionOutcome
    var recreatedReferences: [DiagnosticRunReference]
    var cleanupProof: DiagnosticRunCleanupProof
    var completedAt: Date
}

enum DiagnosticRunRegressionBudget {
    /// How long a prepared disclosure remains valid before `executeRecheck` must be re-prepared —
    /// mirrors the "never trust an obsolete target revision" contract for the preparation itself.
    static let defaultPreparationLifetime: TimeInterval = 10 * 60
}

// MARK: - Service

/// Prepares and executes a regression re-check of one terminal, owned diagnostic-run evidence
/// record (AN-5). Never operates on a nonterminal or foreign-owned record, never recreates an
/// effect without the owner having first seen `prepareRecheck`'s disclosure, and always leaves
/// behind a cleanup proof — even when nothing was ever recreated.
///
/// Deliberately does not reuse `DiagnosticRunCoordinator`'s Draft→Watching→Closing lifecycle: a
/// re-check is a bounded, self-contained operation (recreate → caller drives real traffic →
/// compare → clean up), not a new multi-scope observation session, and forcing it through the
/// full run lifecycle would require an illegal Draft→Inconclusive transition the coordinator does
/// not support for a record that never started watching.
///
/// Concurrency: `@MainActor`, matching `DiagnosticRunStore`/`DiagnosticRunCoordinator`.
@MainActor
final class DiagnosticRunRegressionRecheckService {
    private let store: DiagnosticRunStore
    private let effectResolver: any DiagnosticRunEffectResolving
    private let effectRecreator: any DiagnosticRunEffectRecreating
    private let captureHistory: any DiagnosticRunCaptureHistoryQuerying
    private let policyRevisionProvider: () -> MCPPolicyRevision
    private let clock: () -> Date

    init(
        store: DiagnosticRunStore,
        effectResolver: (any DiagnosticRunEffectResolving)? = nil,
        effectRecreator: (any DiagnosticRunEffectRecreating)? = nil,
        captureHistory: (any DiagnosticRunCaptureHistoryQuerying)? = nil,
        policyRevisionProvider: @escaping () -> MCPPolicyRevision = { .initial },
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.effectResolver = effectResolver ?? NoOpDiagnosticRunEffectResolver()
        self.effectRecreator = effectRecreator ?? NoOpDiagnosticRunEffectRecreator()
        self.captureHistory = captureHistory ?? NoOpDiagnosticRunCaptureHistory()
        self.policyRevisionProvider = policyRevisionProvider
        self.clock = clock
    }

    /// Read-only: discloses exact scope, recreated-effect previews, changed targets, expiry,
    /// expected outcome, and cleanup plan. Never recreates, enables, or mutates anything.
    func prepareRecheck(
        sourceEvidenceID: UUID,
        requestingOwnerID: String
    ) async throws -> DiagnosticRunRecheckPreparation {
        guard let record = store.evidenceRecord(id: sourceEvidenceID) else {
            throw DiagnosticRunRecheckError.evidenceNotFound
        }
        guard record.ownerID == requestingOwnerID else {
            throw DiagnosticRunRecheckError.notOwner
        }
        let compatibleTerminalStatus = record.immutable.terminalStatus == .passed
            || record.immutable.terminalStatus == .failed
            || record.immutable.terminalStatus == .inconclusive
        guard compatibleTerminalStatus, record.immutable.conclusion != nil else {
            throw DiagnosticRunRecheckError.sourceNotTerminal
        }

        let now = clock()
        var incompatibilityReason: DiagnosticConclusionReasonCode?
        if record.immutable.schemaVersion != DiagnosticEvidenceSchemaVersion.current {
            incompatibilityReason = .unsupportedCapability
        }

        var previews: [DiagnosticRunRecheckReferencePreview] = []
        for reference in record.immutable.references {
            let preview = await effectRecreator.previewRecreation(reference: reference)
            previews.append(DiagnosticRunRecheckReferencePreview(reference: reference, preview: preview))
            guard incompatibilityReason == nil else { continue }
            switch preview {
            case .unsupported:
                incompatibilityReason = .unsupportedCapability
            case .targetMissing:
                incompatibilityReason = .targetMissing
            case .supported(_, let revisionChanged):
                if revisionChanged {
                    incompatibilityReason = .targetChanged
                }
            }
        }

        let cleanupPlan = record.immutable.references.isEmpty
            ? "No references to recreate; nothing will be cleaned up."
            : "\(record.immutable.references.count) recreated reference(s) will be disabled or removed "
                + "through their normal risk-reducing cleanup path after observation, regardless of outcome."

        return DiagnosticRunRecheckPreparation(
            sourceRunID: record.runID,
            sourceEvidenceID: record.id,
            requestingOwnerID: requestingOwnerID,
            scopes: record.immutable.scopes,
            referencePreviews: previews,
            expectedOutcomeSummary: record.immutable.conclusion?.summary ?? "",
            cleanupPlanDescription: cleanupPlan,
            preparedAt: now,
            expiresAt: now.addingTimeInterval(DiagnosticRunRegressionBudget.defaultPreparationLifetime),
            isCompatible: incompatibilityReason == nil,
            incompatibilityReason: incompatibilityReason
        )
    }

    /// Recreates referenced effects through their normal proposal/apply path, then re-scans
    /// already-captured sessions (since `preparation.preparedAt`) against the run's saved scopes
    /// to build a fresh observation and compare it against the saved conclusion, cleaning up
    /// everything it recreated on every outcome, including failure paths. This never waits on new
    /// live traffic itself — the operator/agent is expected to have already driven the traffic
    /// they want re-checked before calling `apply`, matching the rest of this subsystem's
    /// "coordination, not a new mutation engine" boundary.
    func executeRecheck(
        preparation: DiagnosticRunRecheckPreparation,
        requestingOwnerID: String
    ) async throws -> DiagnosticRunRecheckResult {
        guard preparation.requestingOwnerID == requestingOwnerID else {
            throw DiagnosticRunRecheckError.notOwner
        }
        let now = clock()
        guard now <= preparation.expiresAt else {
            throw DiagnosticRunRecheckError.preparationExpired
        }

        guard preparation.isCompatible,
              let sourceRecord = store.evidenceRecord(id: preparation.sourceEvidenceID) else {
            return DiagnosticRunRecheckResult(
                sourceRunID: preparation.sourceRunID,
                outcome: .inconclusive(preparation.incompatibilityReason ?? .insufficientEvidence),
                recreatedReferences: [],
                cleanupProof: emptyCleanupProof(now: now),
                completedAt: now
            )
        }

        var recreated: [DiagnosticRunReference] = []
        var haltingOutcome: DiagnosticRunRegressionOutcome?

        referenceLoop: for referencePreview in preparation.referencePreviews {
            let reference = referencePreview.reference
            let result = await effectRecreator.recreate(reference: reference, requestingOwnerID: requestingOwnerID)
            switch result {
            case .recreated(let newOpaqueID, let targetRevision):
                var updated = reference
                updated.opaqueID = newOpaqueID
                updated.targetRevision = targetRevision
                updated.attachedAt = clock()
                recreated.append(updated)
            case .unsupported:
                haltingOutcome = .inconclusive(.unsupportedCapability)
                break referenceLoop
            case .approvalDenied:
                haltingOutcome = .inconclusive(.approvalDenied)
                break referenceLoop
            case .interrupted:
                haltingOutcome = .inconclusive(.operationInterrupted)
                break referenceLoop
            case .targetMissing:
                haltingOutcome = .inconclusive(.targetMissing)
                break referenceLoop
            }
        }

        let freshObservation = haltingOutcome == nil
            ? DiagnosticRunFreshObservationGatherer.summarize(
                runID: preparation.sourceRunID,
                scopes: preparation.scopes,
                events: captureHistory.capturedEvents(since: preparation.preparedAt)
            )
            : nil
        let outcome = haltingOutcome ?? compareOutcome(
            sourceSummary: sourceRecord.immutable.observationSummary,
            fresh: freshObservation
        )

        let cleanupProof = await cleanUp(
            recreated: recreated,
            requestingOwnerID: requestingOwnerID,
            now: clock()
        )

        return DiagnosticRunRecheckResult(
            sourceRunID: preparation.sourceRunID,
            outcome: outcome,
            recreatedReferences: recreated,
            cleanupProof: cleanupProof,
            completedAt: clock()
        )
    }

    // MARK: - Private

    /// Bounded, deterministic comparison over status-family sets only — the same privacy-bounded
    /// shape `DiagnosticRunObservationSummary` already stores (no bodies/headers/values).
    private func compareOutcome(
        sourceSummary: DiagnosticRunObservationSummary,
        fresh: DiagnosticRunObservationSummary?
    ) -> DiagnosticRunRegressionOutcome {
        guard let fresh else { return .inconclusive(.noRequest) }
        guard fresh.matchedRequestCount > 0 else {
            return fresh.matcherMissCount > 0 ? .inconclusive(.matcherMiss) : .inconclusive(.noRequest)
        }
        let sourceFamilies = Set(sourceSummary.statusFamilies.keys)
        let freshFamilies = Set(fresh.statusFamilies.keys)
        return sourceFamilies == freshFamilies ? .stillHolds : .regressionDetected
    }

    private func cleanUp(
        recreated: [DiagnosticRunReference],
        requestingOwnerID: String,
        now: Date
    ) async -> DiagnosticRunCleanupProof {
        var checked: [String] = []
        var cleaned: [String] = []
        var conflicts: [String] = []
        for reference in recreated {
            let refID = "\(reference.kind.rawValue):\(reference.opaqueID)"
            checked.append(refID)
            let result = await effectResolver.requestRiskReducingCleanup(
                kind: reference.kind,
                opaqueID: reference.opaqueID,
                requestingOwnerID: requestingOwnerID
            )
            if result.cleaned {
                cleaned.append(refID)
            } else {
                conflicts.append(result.conflictReasonCode ?? "cleanup_failed")
            }
        }
        var remainingLive = 0
        for reference in recreated {
            if case .live = await effectResolver.liveState(kind: reference.kind, opaqueID: reference.opaqueID) {
                remainingLive += 1
            }
        }
        var proof = DiagnosticRunCleanupProof(
            startedAt: now,
            completedAt: now,
            checkedReferenceIDs: checked,
            cleanedReferenceIDs: cleaned,
            observeOnlyReferenceIDs: [],
            conflictReasonCodes: conflicts,
            remainingLiveEffectCount: remainingLive,
            policyRevision: policyRevisionProvider(),
            verifiedClean: remainingLive == 0 && conflicts.isEmpty,
            verificationDigest: nil
        )
        proof.verificationDigest = try? DiagnosticRunValidation.digest(proof)
        return proof
    }

    private func emptyCleanupProof(now: Date) -> DiagnosticRunCleanupProof {
        var proof = DiagnosticRunCleanupProof(
            startedAt: now,
            completedAt: now,
            checkedReferenceIDs: [],
            cleanedReferenceIDs: [],
            observeOnlyReferenceIDs: [],
            conflictReasonCodes: [],
            remainingLiveEffectCount: 0,
            policyRevision: policyRevisionProvider(),
            verifiedClean: true,
            verificationDigest: nil
        )
        proof.verificationDigest = try? DiagnosticRunValidation.digest(proof)
        return proof
    }
}
