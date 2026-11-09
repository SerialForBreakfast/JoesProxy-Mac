import Foundation

enum EffectBundlePresentation {
    enum PhaseBlocker: String, Codable, Sendable {
        case phasedHLSUnavailable, phasedSourceKindUnavailable, timestampRequiresStaticJSON, ambiguousEarlierArtwork

        var explanation: String {
            switch self {
            case .phasedHLSUnavailable: return "Phased HLS requires conformant live-loop fixtures started in the first phase. Prepared switches require an identical master and uniform matching segment grid; delayed starts and JIT faults are unsupported."
            case .phasedSourceKindUnavailable: return "This phase contains a legacy rewrite or directory rule not supported by the bounded lifecycle."
            case .timestampRequiresStaticJSON: return "Timestamp bindings require a static JSON response; live collection items are not timestamp templates."
            case .ambiguousEarlierArtwork: return "Earlier artwork must use exact, noncompeting URLs so later phases cannot replace it."
            }
        }
    }

    struct Supervision: Codable, Equatable, Sendable {
        let bundleID: UUID
        let revisionID: UUID
        let state: EffectBundleState
        let routingOpen: Bool
        let lifecycleBusy: Bool
        let phase: EffectBundleTimeline.Snapshot?
        let clientScopes: [String]
        let blockers: [PhaseBlocker]
        let nextActions: [String]
        let cleanupRequired: Bool
        let liveCollectionEffectCount: Int
        let evidenceScope: String
        let authority: String
        var media: [MediaState] = []
        var labReadiness: LabReadiness? = nil
    }

    struct LabReadiness: Codable, Equatable, Sendable {
        let contractVersion = 1
        let revisionID: UUID
        let compatibility: String
        let lifecycle: String
        let enforcedClientScopes: [String]
        let approvalState = "inspectProposalApprovalSeparately"
        let assetsState = "revalidatedAtActivation"
        let nextAction: String
        let targetOutcome = "unassessed"
        let qualification = "Metadata only. Active routing is not delivery or playback. Approval belongs to the exact proposal and is not inferred from configuration."
    }

    struct MediaState: Codable, Equatable, Sendable {
        let substitutionID: UUID
        let active: Bool
        let completedAt: Date?
        let activePreparedMediaID: UUID?
        let expiresAt: Date?
        let scope: String
    }

    /// Metadata-only compatibility, not body validation, approval, or a second lifecycle owner.
    static func phaseBlockers(_ manifest: EffectBundleManifest) -> [PhaseBlocker] {
        guard let phases = manifest.phases else { return [] }
        var result: [PhaseBlocker] = []
        if !manifest.hlsSubstitutions.isEmpty {
            let starts = Set(phases.first?.hlsSubstitutionIDs ?? [])
            if starts != Set(manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.map(\.id)) || manifest.hlsSubstitutions.contains(where: {
                $0.playbackConfiguration.presentationMode != .liveLoop || $0.playbackConfiguration.intent != .conformant
                    || $0.playbackConfiguration.jitPublicationState != nil
            }) { result.append(.phasedHLSUnavailable) }
        }
        if !manifest.responseEffects.allSatisfy({ [.inlineText, .localFile, .block, .collectionMock].contains($0.sourceKind) }) {
            result.append(.phasedSourceKindUnavailable)
        }
        if phases.flatMap(\.timestampBindings).contains(where: { binding in
            !manifest.responseEffects.contains { $0.id == binding.responseEffectID && [.inlineText, .localFile].contains($0.sourceKind) }
        }) { result.append(.timestampRequiresStaticJSON) }
        let images = manifest.responseEffects.filter { effect in
            effect.bodySource.assetIDs.contains { id in
                manifest.assets.contains { $0.id == id && ($0.contentType?.hasPrefix("image/") ?? false) }
            }
        }
        if images.contains(where: { image in
            image.matchMode != .exactPath || manifest.responseEffects.contains {
                $0.id != image.id && $0.host.caseInsensitiveCompare(image.host) == .orderedSame
                    && ($0.matchMode != .exactPath || $0.path == image.path)
            }
        }) { result.append(.ambiguousEarlierArtwork) }
        return result
    }

    static func supervision(_ record: EffectBundleRecord, phase: EffectBundleTimeline.Snapshot?, routingOpen: Bool, lifecycleBusy: Bool = false) -> Supervision {
        let blockers = phaseBlockers(record.manifest)
        let cleanup = record.state == .cleanupRequired
        let actions: [String]
        if cleanup { actions = ["effect_bundle_stop", "effect_bundle_inspect"] }
        else if lifecycleBusy || (record.isServing && !routingOpen) { actions = ["effect_bundle_inspect"] }
        else if routingOpen {
            actions = phase == nil ? ["effect_bundle_inspect", "effect_bundle_stop"]
                : ["effect_bundle_inspect", "effect_bundle_advance", "effect_bundle_stop"]
        } else if !blockers.isEmpty { actions = ["effect_bundle_inspect"] }
        else { actions = ["propose_activate_effect_bundle"] }
        let liveCount = record.manifest.responseEffects.filter { $0.sourceKind == .collectionMock }.count
        var result = Supervision(bundleID: record.id, revisionID: record.manifest.authoring?.revisionID ?? record.id,
            state: record.state, routingOpen: routingOpen, lifecycleBusy: lifecycleBusy, phase: phase, clientScopes: clientScopes(record),
            blockers: blockers, nextActions: actions, cleanupRequired: cleanup, liveCollectionEffectCount: liveCount,
            evidenceScope: liveCount == 0 ? "Asset receipts do not establish target outcomes."
                : "Live collection outcomes use captured response attribution with original activation/phase IDs. Asset receipts alone do not cover live transformations or prove delivery or target outcomes.",
            authority: "Metadata-only guidance; assets and conflicts are revalidated at activation. Existing ownership, client policy and local-user approval still apply.")
        if !record.manifest.hlsSubstitutions.isEmpty {
            let scoped = record.manifest.hlsSubstitutions.allSatisfy { $0.requestPolicy != nil }
            result.labReadiness = .init(revisionID: result.revisionID,
                compatibility: scoped ? "scopedMediaConfigured" : "legacyScopeRequiresRevision",
                lifecycle: cleanup ? "cleanupRequired" : lifecycleBusy ? "transitioning" : routingOpen ? "active" : "configured",
                enforcedClientScopes: record.manifest.hlsSubstitutions.compactMap { $0.requestPolicy?.clientAddress }.sorted(),
                nextAction: !scoped ? "Prepare a client-scoped media revision before lab execution."
                    : cleanup ? "Stop owned effects and inspect the cleanup receipt."
                    : lifecycleBusy ? "Inspect again after the owned lifecycle transition finishes."
                    : routingOpen ? "Open an explicit run window and retrieve delivery evidence; target observations remain separate."
                    : "Inspect assets, scope and the exact activation proposal; obtain local approval before applying.")
        }
        return result
    }

    static func isCurrentReview(_ reviewed: EffectBundleRecord, current: EffectBundleRecord?) -> Bool {
        guard let current else { return false }
        return current.id == reviewed.id && current.manifest == reviewed.manifest
            && current.owner == reviewed.owner && current.state == reviewed.state
    }

    static func matches(_ record: EffectBundleRecord, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [record.manifest.name, record.id.uuidString, record.manifest.notes,
                record.manifest.authoring?.revisionID.uuidString ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func clientScopes(_ record: EffectBundleRecord) -> [String] {
        Set(record.manifest.responseEffects.map { $0.sourceClientAddress ?? "All clients" }
            + record.manifest.hlsSubstitutions.map { $0.requestPolicy?.clientAddress ?? "All clients (legacy HLS)" }).sorted()
    }
}
