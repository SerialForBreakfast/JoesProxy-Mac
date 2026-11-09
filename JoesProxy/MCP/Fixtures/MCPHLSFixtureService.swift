import Foundation

/// Pending propose→apply plan for starting an HLS fixture run.
struct HLSFixtureStartPlan: Equatable, Sendable {
    var runID: UUID
    var profileID: String
    var clientID: String
    var playbackConfiguration: HLSPlaybackConfiguration
    var effectSummary: String
}

struct HLSSubstitutionStartPlan: Equatable, Sendable {
    var experimentID: UUID
    var profileID: String
    var clientID: String
    var origin: HLSSubstitutionOrigin
    var scope: HLSSubstitutionScope
    var conflictStrategy: HLSSubstitutionConflictStrategy
    var playbackConfiguration: HLSPlaybackConfiguration
    var ttlSeconds: TimeInterval
    var effectSummary: String
    var requestPolicy: HLSRequestPolicy? = nil
}

/// MCP surface for HLS fixture capabilities, profiles, start/stop lifecycle, and status.
///
/// Concurrency: `@MainActor` — mutates ``HLSFixtureRunStore`` and proposal/approval stores on the
/// main actor; registry hops are awaited inside the store.
@MainActor
final class MCPHLSFixtureService {
    private let runStore: HLSFixtureRunStore
    private let proposalCoordinator: MCPProposalCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private let sessionStore: (any SessionStore)?
    private let substitutionCoordinator: HLSSubstitutionCoordinator?
    private var plansByProposalToken: [String: HLSFixtureStartPlan] = [:]
    private var substitutionPlansByProposalToken: [String: HLSSubstitutionStartPlan] = [:]

    private var policyEvaluator: MCPPolicyEvaluator {
        MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
    }

    init(
        runStore: HLSFixtureRunStore,
        proposalCoordinator: MCPProposalCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore,
        sessionStore: (any SessionStore)? = nil,
        substitutionCoordinator: HLSSubstitutionCoordinator? = nil
    ) {
        self.runStore = runStore
        self.proposalCoordinator = proposalCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        self.grantStore = grantStore
        self.auditStore = auditStore
        self.sessionStore = sessionStore
        self.substitutionCoordinator = substitutionCoordinator
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "hls_fixture_capabilities":
            return try capabilities(client: client)
        case "hls_fixture_profiles_list":
            return try profilesList(client: client)
        case "hls_fixture_status":
            return try await status(arguments: arguments, client: client)
        case "hls_fixture_window_preview":
            return try await windowPreview(arguments: arguments, client: client)
        case "propose_hls_fixture_start":
            return try proposeStart(arguments: arguments, client: client)
        case "apply_hls_fixture_start":
            return try await applyStart(arguments: arguments, client: client)
        case "hls_fixture_stop":
            return try await stop(arguments: arguments, client: client)
        case "hls_substitution_profiles_list":
            return try substitutionProfilesList(client: client)
        case "propose_hls_substitution_start":
            return try await proposeSubstitutionStart(arguments: arguments, client: client)
        case "apply_hls_substitution_start":
            return try await applySubstitutionStart(arguments: arguments, client: client)
        case "hls_substitution_status":
            return try await substitutionStatus(arguments: arguments, client: client)
        case "hls_substitution_stop":
            return try await stopSubstitution(arguments: arguments, client: client)
        case "hls_substitution_extend":
            return try await extendSubstitution(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown HLS fixture tool: \(name).")
        }
    }

    /// Active run count for cleanup status.
    func unresolvedRunCount(forClientID clientID: String) -> Int {
        runStore.unresolvedRunIDs(forClientID: clientID).count
    }

    /// Stops every active run for a client during session teardown.
    func stopAllRuns(ownedBy clientID: String) async {
        await substitutionCoordinator?.stopAll(ownedBy: clientID)
        try? await runStore.stopAll(ownedBy: clientID)
    }

    // MARK: - Read tools

    private func capabilities(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        let profiles = runStore.availableProfiles()
        return [
            "schemaVersion": 1,
            "payload": [
                "routingMode": HLSFixtureRunStore.routingModeReservedVirtualOrigin,
                "maxActiveRunsPerClient": HLSFixtureRunStore.maxActiveRunsPerClient,
                "maxRunDurationSeconds": Int(HLSFixtureRunStore.maxRunDuration),
                "reservedHostSuffix": HLSFixtureRunStore.reservedHostSuffix,
                "availableProfileCount": profiles.count,
                "profilesRootPresent": !profiles.isEmpty,
                "playbackConfiguration": playbackConfigurationCapabilitiesDictionary()
            ] as [String: Any]
        ]
    }

    private func profilesList(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        let items = runStore.availableProfileDescriptors().sorted { $0.id < $1.id }.map { descriptor -> [String: Any] in
            if descriptor.textFixture != nil { return profileDictionary(descriptor) }
            return ["profileID": descriptor.id, "version": descriptor.version]
        }
        return [
            "schemaVersion": 1,
            "payload": [
                "items": items,
                "count": items.count
            ] as [String: Any]
        ]
    }

    private func substitutionProfilesList(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        let items = runStore.availableProfileDescriptors().map(profileDictionary)
        return [
            "schemaVersion": 1,
            "payload": [
                "items": items,
                "count": items.count,
                "playbackConfiguration": playbackConfigurationCapabilitiesDictionary()
            ] as [String: Any]
        ]
    }

    private func status(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        try await runStore.expireOverdueRuns()
        if let runIDString = arguments["runID"] as? String {
            guard let runID = UUID(uuidString: runIDString),
                  let record = runStore.run(id: runID),
                  record.clientID == client.id else {
                throw MCPStructuredError(code: .malformedRequest, message: "runID not found for this client.")
            }
            return [
                "schemaVersion": 1,
                "payload": runDictionary(record)
            ]
        }
        let items = runStore.runs(ownedBy: client.id).map(runDictionary)
        return [
            "schemaVersion": 1,
            "payload": [
                "items": items,
                "activeCount": runStore.activeRuns(ownedBy: client.id).count,
                "count": items.count
            ] as [String: Any]
        ]
    }

    /// Read-only mode-aware introspection for an owned active fixture rendition (AP).
    ///
    /// Reuses ``HLSFixtureServer/slidingWindow(forPath:now:)`` → ``HLSSlidingPlaylistComputer/window``
    /// — the same computation ``response(forPath:method:rangeHeader:)`` uses — so agents can inspect
    /// MEDIA-SEQUENCE / segments without HTTP, cert trust, or wall-clock waiting.
    private func windowPreview(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        try await runStore.expireOverdueRuns()
        guard let runIDString = arguments["runID"] as? String,
              let runID = UUID(uuidString: runIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "runID is required.")
        }
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "path is required (rendition stream.m3u8 relative path).")
        }
        guard let record = runStore.run(id: runID), record.clientID == client.id else {
            throw MCPStructuredError(code: .malformedRequest, message: "runID not found for this client.")
        }
        guard record.isActive else {
            throw MCPStructuredError(code: .conflict, message: "Fixture run is not active.")
        }
        guard let server = runStore.liveServer(id: runID) else {
            throw MCPStructuredError(
                code: .conflict,
                message: "Fixture run has no live server in this process (restart and start a new run)."
            )
        }

        let elapsedSeconds: Double?
        if let number = arguments["elapsedSeconds"] as? Double {
            elapsedSeconds = number
        } else if let number = arguments["elapsedSeconds"] as? Int {
            elapsedSeconds = Double(number)
        } else if let string = arguments["elapsedSeconds"] as? String, let number = Double(string) {
            elapsedSeconds = number
        } else if arguments["elapsedSeconds"] != nil {
            throw MCPStructuredError(code: .malformedRequest, message: "elapsedSeconds must be a non-negative number when provided.")
        } else {
            elapsedSeconds = nil
        }
        if let elapsedSeconds, elapsedSeconds < 0 {
            throw MCPStructuredError(code: .malformedRequest, message: "elapsedSeconds must be non-negative.")
        }

        let evaluationNow = elapsedSeconds.map { server.startedAt.addingTimeInterval($0) }
            ?? server.currentTime
        guard let preview = server.playlistPreview(forPath: path, now: evaluationNow) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "path is not a rendition stream playlist on this profile (expected a rendition stream.m3u8)."
            )
        }
        let resolvedElapsed = max(0, evaluationNow.timeIntervalSince(server.startedAt))
        var payload: [String: Any] = [
            "runID": runID.uuidString,
            "profileID": record.profileID,
            "path": path.hasPrefix("/") ? String(path.dropFirst()) : path,
            "elapsedSeconds": resolvedElapsed
        ]
        switch preview {
        case .vod(let parsed, let playlistText):
            payload["presentationMode"] = HLSPresentationMode.vodStatic.rawValue
            payload["clockDependent"] = false
            payload["targetDuration"] = parsed.targetDuration
            payload["segments"] = parsed.segments.map {
                [
                    "uri": $0.uri,
                    "duration": $0.duration,
                    "hasDiscontinuityBefore": $0.hasDiscontinuityBefore
                ] as [String: Any]
            }
            payload["playlistText"] = playlistText
            payload["hasEndList"] = playlistText.contains("#EXT-X-ENDLIST")
        case .live(let window):
            payload["presentationMode"] = window.configuration.presentationMode?.rawValue ?? "legacySlidingLive"
            payload["timeShiftMode"] = window.configuration.effectiveTimeShiftMode.rawValue
            payload["clockDependent"] = true
            payload["mediaSequence"] = window.mediaSequence
            payload["discontinuitySequence"] = window.discontinuitySequence
            payload["targetDuration"] = window.targetDuration
            payload["segments"] = window.entries.map { entry in
                [
                    "uri": entry.segment.uri,
                    "duration": entry.segment.duration,
                    "virtualIndex": entry.virtualIndex,
                    "hasDiscontinuityBefore": entry.segment.hasDiscontinuityBefore
                ] as [String: Any]
            }
            payload["playlistText"] = server.renderPlaylist(window)
            payload["advertisedDurationSeconds"] = window.advertisedDuration
            if let oldestAdvertisedSequence = window.oldestAdvertisedSequence {
                payload["oldestAdvertisedSequence"] = oldestAdvertisedSequence
            }
            if let newestPublishedSequence = window.newestPublishedSequence {
                payload["newestPublishedSequence"] = newestPublishedSequence
            }
            if let earliestProgramDateTime = window.earliestProgramDateTime {
                payload["earliestProgramDateTime"] = MCPApprovalPolicy.iso8601String(from: earliestProgramDateTime)
            }
            if let liveEdgeProgramDateTime = window.liveEdgeProgramDateTime {
                payload["liveEdgeProgramDateTime"] = MCPApprovalPolicy.iso8601String(from: liveEdgeProgramDateTime)
            }
            if let oldestRetained = server.oldestRetainedButEvictedSequence(
                forPath: path,
                now: evaluationNow
            ) {
                payload["oldestRetainedButEvictedSequence"] = oldestRetained
            }
        }
        return ["schemaVersion": 1, "payload": payload]
    }

    // MARK: - Start propose/apply

    private func proposeStart(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureLifecycle)
        guard let profileID = arguments["profileID"] as? String, !profileID.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "profileID is required.")
        }
        _ = try runStore.profileDirectory(forProfileID: profileID)
        let activeCount = runStore.activeRuns(ownedBy: client.id).count
        guard activeCount < HLSFixtureRunStore.maxActiveRunsPerClient else {
            throw MCPStructuredError(
                code: .conflict,
                message: "Client already has \(HLSFixtureRunStore.maxActiveRunsPerClient) active fixture runs."
            )
        }
        let runID = UUID()
        let reservedHost = HLSFixtureRunStore.reservedHost(for: runID)
        let playbackConfiguration: HLSPlaybackConfiguration
        if arguments.keys.contains("playbackConfiguration") {
            playbackConfiguration = try parsePlaybackConfiguration(arguments["playbackConfiguration"])
        } else {
            let descriptor = HLSFixtureProfileDescriptor.load(from: try runStore.profileDirectory(forProfileID: profileID))
            playbackConfiguration = descriptor.textFixture == nil ? .legacyCompatible : descriptor.defaultPlaybackConfiguration
        }
        try validateProfileConfiguration(profileID: profileID, configuration: playbackConfiguration)
        let plan = HLSFixtureStartPlan(
            runID: runID,
            profileID: profileID,
            clientID: client.id,
            playbackConfiguration: playbackConfiguration,
            effectSummary: "Start HLS fixture profile \(profileID) at reserved host \(reservedHost)."
        )
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .hlsFixtureLifecycle,
            argumentDigest: digest,
            targetRevision: nil,
            targetLockKey: "hls-fixture:\(runID.uuidString)"
        )
        plansByProposalToken[proposal.token] = plan
        let payload: [String: Any] = [
            "proposalToken": proposal.token,
            "expiresAt": MCPApprovalPolicy.iso8601String(from: proposal.expiresAt),
            "targetLockKey": proposal.targetLockKey,
            "effectSummary": plan.effectSummary,
            "riskTier": MCPCapabilityID.hlsFixtureLifecycle.riskTier.rawValue,
            "defaultEnabled": true,
            "proposedRunID": runID.uuidString,
            "profileID": profileID,
            "reservedHost": reservedHost,
            "routingMode": HLSFixtureRunStore.routingModeReservedVirtualOrigin,
            "baseURL": "http://\(reservedHost)/",
            "maxRunDurationSeconds": Int(HLSFixtureRunStore.maxRunDuration),
            "playbackConfiguration": playbackConfigurationDictionary(playbackConfiguration)
        ]
        return [
            "schemaVersion": 1,
            "payload": payload
        ]
    }

    private func applyStart(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureLifecycle)
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "proposalToken is required.")
        }
        guard let proposal = proposalCoordinator.proposal(forToken: proposalToken),
              proposal.clientID == client.id,
              proposal.capability == .hlsFixtureLifecycle,
              let plan = plansByProposalToken[proposalToken],
              plan.clientID == client.id else {
            approvalStore.invalidate(proposalToken: proposalToken)
            plansByProposalToken.removeValue(forKey: proposalToken)
            throw MCPStructuredError(code: .staleProposal, message: "Fixture start proposal is stale or unknown.")
        }
        try resolveLifecycleApproval(
            toolName: "apply_hls_fixture_start",
            arguments: arguments,
            client: client,
            capability: .hlsFixtureLifecycle,
            proposalToken: proposalToken,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        let digest = proposal.argumentDigest
        let result: MCPProposalApplyResult
        // Captured so a specific `HLSFixtureRunStoreError` from `startRun` survives
        // `MCPProposalCoordinator.applyProposal`'s generic `.conflict` conversion below and can be
        // rethrown for `MCPProtocolService.hlsFixtureTool`'s existing per-case message switch.
        var capturedStartError: HLSFixtureRunStoreError?
        do {
            result = try await proposalCoordinator.applyProposal(
                token: proposalToken,
                clientID: client.id,
                capability: .hlsFixtureLifecycle,
                argumentDigest: digest,
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: client.id,
                    targetKind: .hlsFixtureRun,
                    targetID: plan.runID.uuidString,
                    baselineRevision: nil,
                    intendedChangeDigest: digest,
                    rollbackSnapshot: nil,
                    expiresAt: MCPApprovalPolicy.expiration()
                ),
                performMutation: {
                    do {
                        _ = try await self.runStore.startRun(
                            id: plan.runID,
                            clientID: client.id,
                            profileID: plan.profileID,
                            playbackConfiguration: plan.playbackConfiguration
                        )
                        return nil
                    } catch let error as HLSFixtureRunStoreError {
                        capturedStartError = error
                        throw error
                    }
                },
                idempotencyKey: idempotencyKey(from: arguments, proposalToken: proposalToken)
            )
        } catch let error as MCPProposalCoordinatorError {
            if error == .conflict, let capturedStartError {
                throw capturedStartError
            }
            throw proposalCoordinator.structuredError(for: error)
        } catch let error as MCPRecoveryCoordinatorError {
            switch error {
            case .journalUnavailable:
                throw proposalCoordinator.structuredError(for: .journalUnavailable)
            default:
                throw MCPStructuredError(code: .conflict, message: "Fixture start apply conflicted with recovery state.")
            }
        }
        plansByProposalToken.removeValue(forKey: proposalToken)
        recordApplied(client: client, targetID: plan.runID.uuidString, detail: plan.effectSummary)
        guard let record = runStore.run(id: plan.runID) else {
            throw MCPStructuredError(code: .internalFailure, message: "Fixture run missing after apply.")
        }
        var payload = runDictionary(record)
        payload["transactionID"] = result.transactionID
        payload["appliedAt"] = MCPApprovalPolicy.iso8601String(from: result.appliedAt)
        return [
            "schemaVersion": 1,
            "payload": payload
        ]
    }

    private func stop(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureLifecycle)
        guard let runIDString = arguments["runID"] as? String,
              let runID = UUID(uuidString: runIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "runID is required.")
        }
        // Owner-scoped stop without a second propose/apply — mirrors scenario cleanup_test_scenario.
        let record = try await runStore.stopRun(id: runID, clientID: client.id)
        recordApplied(client: client, targetID: runID.uuidString, detail: "Stopped HLS fixture run \(runID.uuidString).")
        return [
            "schemaVersion": 1,
            "payload": runDictionary(record)
        ]
    }

    // MARK: - First-class HLS substitution

    private func proposeSubstitutionStart(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsSubstitutionLifecycle)
        guard let substitutionCoordinator else {
            throw MCPStructuredError(code: .internalFailure, message: "HLS substitution is unavailable.")
        }
        guard let profileID = arguments["profileID"] as? String, !profileID.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "profileID is required.")
        }
        _ = try runStore.profileDirectory(forProfileID: profileID)

        guard let scopeRaw = arguments["scope"] as? String,
              scopeRaw == "selectedPlaylist" || scopeRaw == "host" else {
            throw MCPStructuredError(code: .malformedRequest, message: "scope must be selectedPlaylist or host.")
        }
        guard let conflictRaw = arguments["conflictStrategy"] as? String,
              let conflictStrategy = HLSSubstitutionConflictStrategy(rawValue: conflictRaw) else {
            throw MCPStructuredError(code: .malformedRequest, message: "conflictStrategy must be cancel or replaceExisting.")
        }
        let descriptor = HLSFixtureProfileDescriptor.load(from: try runStore.profileDirectory(forProfileID: profileID))
        let playbackConfiguration = arguments["playbackConfiguration"] == nil && descriptor.textFixture != nil
            ? descriptor.defaultPlaybackConfiguration : try parsePlaybackConfiguration(arguments["playbackConfiguration"])
        try validateProfileConfiguration(profileID: profileID, configuration: playbackConfiguration)
        let ttlSeconds = try parseSubstitutionTTL(arguments["ttlSeconds"])

        let resolvedTarget = try resolveSubstitutionTarget(arguments: arguments, scopeRaw: scopeRaw)
        for field in ["sourceClientAddress", "missingTextTrackID"] {
            if arguments[field] != nil && !(arguments[field] is String) {
                throw MCPStructuredError(code: .malformedRequest, message: "\(field) must be a string; omit it only for a legacy unscoped route.")
            }
        }
        let requestPolicy: HLSRequestPolicy?
        if let address = arguments["sourceClientAddress"] as? String {
            requestPolicy = .init(clientAddress: address, missingTextTrackID: arguments["missingTextTrackID"] as? String)
            do { try requestPolicy?.validate(scope: resolvedTarget.scope) }
            catch { throw MCPStructuredError(code: .malformedRequest, message: error.localizedDescription) }
            if let track = requestPolicy?.missingTextTrackID,
               descriptor.textFixture?.tracks.contains(where: { $0.id == track }) != true {
                throw MCPStructuredError(code: .malformedRequest, message: "missingTextTrackID must name a track in the selected profile.")
            }
        } else {
            guard arguments["missingTextTrackID"] == nil else {
                throw MCPStructuredError(code: .malformedRequest, message: "missingTextTrackID requires sourceClientAddress and selectedPlaylist scope.")
            }
            requestPolicy = nil
        }
        let conflicts = await substitutionCoordinator.conflictSummary(
            origin: resolvedTarget.origin,
            scope: resolvedTarget.scope,
            requestPolicy: requestPolicy
        )
        let experimentID = UUID()
        let scopeSummary: String
        switch resolvedTarget.scope {
        case .selectedPlaylist(let path): scopeSummary = "selected playlist \(path)"
        case .host: scopeSummary = "every .m3u8 playlist on the exact origin"
        }
        let violations = playbackConfiguration.recommendationViolations
        let conformanceSummary = violations.isEmpty
            ? "conformant live-playlist controls"
            : "deliberate faults: \(violations.map(\.rawValue).joined(separator: ", "))"
        let ttlMinutes = Int(ttlSeconds / 60)
        let effectSummary = "Serve HLS profile \(profileID) with \(conformanceSummary) for \(scopeSummary) at \(resolvedTarget.origin.displayString), fail open after \(ttlMinutes) minutes. \(requestPolicy?.summary ?? HLSRequestPolicy.legacySummary)"
        let plan = HLSSubstitutionStartPlan(
            experimentID: experimentID,
            profileID: profileID,
            clientID: client.id,
            origin: resolvedTarget.origin,
            scope: resolvedTarget.scope,
            conflictStrategy: conflictStrategy,
            playbackConfiguration: playbackConfiguration,
            ttlSeconds: ttlSeconds,
            effectSummary: effectSummary,
            requestPolicy: requestPolicy
        )
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .hlsSubstitutionLifecycle,
            argumentDigest: digest,
            targetRevision: nil,
            targetLockKey: "hls-substitution:\(experimentID.uuidString)"
        )
        substitutionPlansByProposalToken[proposal.token] = plan
        return [
            "schemaVersion": 1,
            "payload": [
                "proposalToken": proposal.token,
                "expiresAt": MCPApprovalPolicy.iso8601String(from: proposal.expiresAt),
                "proposedExperimentID": experimentID.uuidString,
                "profileID": profileID,
                "scope": scopeRaw,
                "matchScope": substitutionMatchScopeDictionary(origin: plan.origin, scope: plan.scope),
                "scopePolicy": HLSRequestPolicy.disclosure(plan.requestPolicy),
                "conflictStrategy": conflictStrategy.rawValue,
                "playbackConfiguration": playbackConfigurationDictionary(playbackConfiguration),
                "recommendationViolations": violations.map {
                    ["id": $0.rawValue, "summary": $0.summary]
                },
                "isDeliberatelyNonconformant": playbackConfiguration.isDeliberatelyNonconformant,
                "conflicts": [
                    "hasConflicts": conflicts.totalCount > 0,
                    "totalCount": conflicts.totalCount,
                    "testStreamCount": conflicts.experimentCount,
                    "responseRuleCount": conflicts.responseRuleCount
                ] as [String: Any],
                "effectSummary": effectSummary,
                "riskTier": MCPCapabilityID.hlsSubstitutionLifecycle.riskTier.rawValue,
                "maxRunDurationSeconds": Int(ttlSeconds),
                "failOpen": true
            ] as [String: Any]
        ]
    }

    private func applySubstitutionStart(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsSubstitutionLifecycle)
        guard let coordinator = substitutionCoordinator else {
            throw MCPStructuredError(code: .internalFailure, message: "HLS substitution is unavailable.")
        }
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty,
              let proposal = proposalCoordinator.proposal(forToken: proposalToken),
              proposal.clientID == client.id,
              proposal.capability == .hlsSubstitutionLifecycle,
              let plan = substitutionPlansByProposalToken[proposalToken],
              plan.clientID == client.id else {
            throw MCPStructuredError(code: .staleProposal, message: "HLS substitution proposal is stale or unknown.")
        }
        try resolveLifecycleApproval(
            toolName: "apply_hls_substitution_start",
            arguments: arguments,
            client: client,
            capability: .hlsSubstitutionLifecycle,
            proposalToken: proposalToken,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        let digest = proposal.argumentDigest
        var appliedExperiment: HLSSubstitutionExperiment?
        let result: MCPProposalApplyResult
        do {
            result = try await proposalCoordinator.applyProposal(
                token: proposalToken,
                clientID: client.id,
                capability: .hlsSubstitutionLifecycle,
                argumentDigest: digest,
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: client.id,
                    targetKind: .hlsFixtureRun,
                    targetID: plan.experimentID.uuidString,
                    baselineRevision: nil,
                    intendedChangeDigest: digest,
                    rollbackSnapshot: nil,
                    expiresAt: MCPApprovalPolicy.expiration()
                ),
                performMutation: {
                    appliedExperiment = try await coordinator.start(
                        owner: .mcpClient(id: client.id, displayName: client.displayName),
                        profileID: plan.profileID,
                        origin: plan.origin,
                        scope: plan.scope,
                        requestPolicy: plan.requestPolicy,
                        conflictStrategy: plan.conflictStrategy,
                        playbackConfiguration: plan.playbackConfiguration,
                        duration: plan.ttlSeconds,
                        mcpProvenance: MCPProvenance(
                            clientID: client.id,
                            operationID: proposalToken,
                            capability: .hlsSubstitutionLifecycle,
                            createdAt: Date()
                        ),
                        experimentID: plan.experimentID
                    )
                    return nil
                },
                idempotencyKey: idempotencyKey(from: arguments, proposalToken: proposalToken)
            )
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        }
        substitutionPlansByProposalToken.removeValue(forKey: proposalToken)
        let persistedExperiment = await coordinator.experiment(id: plan.experimentID)
        guard let experiment = appliedExperiment ?? persistedExperiment else {
            throw MCPStructuredError(code: .internalFailure, message: "HLS substitution missing after apply.")
        }
        recordApplied(
            client: client,
            capability: .hlsSubstitutionLifecycle,
            targetID: experiment.id.uuidString,
            detail: plan.effectSummary
        )
        var payload = substitutionDictionary(experiment)
        payload["transactionID"] = result.transactionID
        payload["appliedAt"] = MCPApprovalPolicy.iso8601String(from: result.appliedAt)
        return ["schemaVersion": 1, "payload": payload]
    }

    private func substitutionStatus(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsFixtureInspect)
        guard let coordinator = substitutionCoordinator else {
            throw MCPStructuredError(code: .internalFailure, message: "HLS substitution is unavailable.")
        }
        if let idString = arguments["experimentID"] as? String, let id = UUID(uuidString: idString) {
            guard let experiment = await coordinator.experiment(id: id),
                  experiment.owner.fixtureOwnerID == client.id else {
                throw MCPStructuredError(code: .malformedRequest, message: "experimentID not found for this client.")
            }
            return ["schemaVersion": 1, "payload": substitutionDictionary(experiment)]
        }
        let experiments = await coordinator.experiments(
            ownedBy: .mcpClient(id: client.id, displayName: client.displayName)
        )
        return [
            "schemaVersion": 1,
            "payload": [
                "items": experiments.map(substitutionDictionary),
                "count": experiments.count,
                "activeCount": experiments.filter(\.isActive).count
            ] as [String: Any]
        ]
    }

    private func stopSubstitution(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsSubstitutionLifecycle)
        guard let coordinator = substitutionCoordinator,
              let idString = arguments["experimentID"] as? String,
              let id = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "experimentID is required.")
        }
        let experiment = try await coordinator.stop(id: id, requestingOwnerID: client.id)
        recordApplied(
            client: client,
            capability: .hlsSubstitutionLifecycle,
            targetID: id.uuidString,
            detail: "Stopped HLS test-stream substitution \(id.uuidString)."
        )
        return ["schemaVersion": 1, "payload": substitutionDictionary(experiment)]
    }

    /// Bumps a running substitution's expiry forward — deliberately as ungated as `stopSubstitution`
    /// above (policy check only, no propose/apply/approval dance). Extending changes only *how long*
    /// an already-approved substitution keeps running, not *what* it serves, so it doesn't need the
    /// same re-approval ceremony `apply_hls_substitution_start` requires for deciding scope/content.
    /// See `HLSSubstitutionCoordinator.extend`'s doc comment for the full rationale.
    private func extendSubstitution(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .hlsSubstitutionLifecycle)
        guard let coordinator = substitutionCoordinator,
              let idString = arguments["experimentID"] as? String,
              let id = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "experimentID is required.")
        }
        let ttlSeconds = try parseSubstitutionTTL(arguments["ttlSeconds"])
        let experiment = try await coordinator.extend(id: id, requestingOwnerID: client.id, duration: ttlSeconds)
        recordApplied(
            client: client,
            capability: .hlsSubstitutionLifecycle,
            targetID: id.uuidString,
            detail: "Extended HLS test-stream substitution \(id.uuidString) by \(Int(ttlSeconds))s."
        )
        return ["schemaVersion": 1, "payload": substitutionDictionary(experiment)]
    }

    private func resolveSubstitutionTarget(
        arguments: [String: Any],
        scopeRaw: String
    ) throws -> (origin: HLSSubstitutionOrigin, scope: HLSSubstitutionScope) {
        var session: SessionRecord?
        if let sessionIDString = arguments["sessionID"] as? String,
           let sessionID = UUID(uuidString: sessionIDString) {
            session = sessionStore?.record(for: sessionID)
            guard session != nil else {
                throw MCPStructuredError(code: .malformedRequest, message: "sessionID was not found.")
            }
        }
        let schemeRaw = (arguments["scheme"] as? String) ?? session?.request.scheme.rawValue ?? "https"
        guard let scheme = SessionScheme(rawValue: schemeRaw) else {
            throw MCPStructuredError(code: .malformedRequest, message: "scheme must be http or https.")
        }
        guard let host = (arguments["host"] as? String) ?? session?.request.host, !host.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "host or sessionID is required.")
        }
        let port = (arguments["port"] as? Int) ?? session?.request.port
        let origin = HLSSubstitutionOrigin(scheme: scheme, host: host, port: port)
        if scopeRaw == "host" { return (origin, .host) }
        guard let path = (arguments["path"] as? String) ?? session?.request.path, !path.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "selectedPlaylist scope requires path or sessionID.")
        }
        let pathWithoutQuery = String(
            path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/"
        )
        return (origin, .selectedPlaylist(path: arguments["sourceClientAddress"] == nil ? pathWithoutQuery : path))
    }

    // MARK: - Helpers

    private func requireAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "HLS fixture tools denied by profile or policy."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Profile or policy denies \(capability.rawValue).")
        }
    }

    private func resolveLifecycleApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        proposalToken: String,
        mcpSessionID: String?
    ) throws {
        let boundArguments = MCPArgumentDigest.dispatchArguments(arguments)
        let digest = MCPArgumentDigest.normalized(boundArguments)
        if let presentedAuthorization = MCPArgumentDigest.authorization(from: arguments) {
            if approvalStore.nonceAlreadyUsed(presentedAuthorization.nonce) {
                throw approvalValidationError(.reused)
            }
            if approvalStore.nonceExpired(presentedAuthorization.nonce) {
                throw approvalValidationError(.expired)
            }
            if let granted = approvalStore.grantedAuthorization(nonce: presentedAuthorization.nonce) {
                if let failure = MCPApprovalValidation.validateRetry(
                    request: granted.request,
                    authorization: granted.authorization,
                    currentClientID: client.id,
                    currentCapability: capability,
                    normalizedArgumentDigest: digest,
                    currentPolicyRevision: policyStore.policyRevision,
                    currentTargetRevision: nil,
                    nonceAlreadyUsed: false
                ) {
                    throw approvalValidationError(failure)
                }
                approvalStore.consumeNonce(granted.authorization.nonce)
                return
            }
        }
        if approvalStore.consumeApprovedRequest(
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            proposalToken: proposalToken
        ) {
            return
        }
        if policyEvaluator.skipsApprovalNonce(capability: capability, client: client) {
            return
        }
        let reason = "\(toolName) requires in-app approval to start an HLS fixture reserved origin."
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            targetRevision: nil,
            mcpSessionID: mcpSessionID,
            proposalToken: proposalToken,
            reason: reason
        )
        throw MCPStructuredError.approvalRequired(request)
    }

    private func approvalValidationError(_ failure: MCPApprovalValidation.Failure) -> MCPStructuredError {
        switch failure {
        case .expired:
            return MCPStructuredError(code: .approvalExpired, message: "Approval authorization expired.")
        case .reused:
            return MCPStructuredError(code: .approvalReused, message: "Approval authorization was already used.")
        case .argumentMismatch:
            return MCPStructuredError(code: .malformedRequest, message: "Approval authorization does not match request arguments.")
        case .policyTightened:
            return MCPStructuredError(code: .policyDenied, message: "Policy changed; approval is no longer valid.")
        case .targetRevisionChanged:
            return MCPStructuredError(code: .staleTargetRevision, message: "Target revision changed; approval is no longer valid.")
        }
    }

    private func idempotencyKey(from arguments: [String: Any], proposalToken: String) -> MCPIdempotencyKey? {
        if let raw = arguments["idempotencyKey"] as? String, !raw.isEmpty {
            return MCPIdempotencyKey(rawValue: raw)
        }
        return MCPIdempotencyKey(rawValue: "proposal:\(proposalToken)")
    }

    private func recordApplied(
        client: MCPClientRecord,
        capability: MCPCapabilityID = .hlsFixtureLifecycle,
        targetID: String,
        detail: String
    ) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalApplied,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "\(capability.rawValue):\(targetID)",
                detail: detail
            )
        )
    }

    private func runDictionary(_ record: HLSFixtureRunRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "runID": record.id.uuidString,
            "profileID": record.profileID,
            "profileVersion": record.profileVersion,
            "reservedHost": record.reservedHost,
            "routingMode": HLSFixtureRunStore.routingModeReservedVirtualOrigin,
            "baseURL": "http://\(record.reservedHost)/",
            "startedAt": MCPApprovalPolicy.iso8601String(from: record.startedAt),
            "expiresAt": MCPApprovalPolicy.iso8601String(from: record.expiresAt),
            "isActive": record.isActive
        ]
        if let stoppedAt = record.stoppedAt {
            payload["stoppedAt"] = MCPApprovalPolicy.iso8601String(from: stoppedAt)
        }
        if let playbackConfiguration = record.playbackConfiguration {
            payload["playbackConfiguration"] = playbackConfigurationDictionary(playbackConfiguration)
        }
        return payload
    }

    private func validateProfileConfiguration(profileID: String, configuration: HLSPlaybackConfiguration) throws {
        do { try runStore.validateProfileConfiguration(profileID: profileID, configuration: configuration) }
        catch let error as HLSWebVTTFixture.ValidationError {
            throw MCPStructuredError(code: .malformedRequest,
                message: error.localizedDescription + " Example: {\"playbackConfiguration\":{\"presentationMode\":\"vodStatic\"}}")
        }
    }

    private func profileDictionary(_ descriptor: HLSFixtureProfileDescriptor) -> [String: Any] {
        var payload: [String: Any] = [
            "profileID": descriptor.id,
            "version": descriptor.version,
            "displayName": descriptor.displayName,
            "purpose": descriptor.purpose,
            "featureTags": descriptor.featureTags,
            "isRecommended": descriptor.isRecommended,
            "renditions": descriptor.renditions.map {
                [
                    "width": $0.width,
                    "height": $0.height,
                    "bandwidth": $0.bandwidth,
                    "codecs": $0.codecs
                ] as [String: Any]
            }
        ]
        if let audioTopology = descriptor.audioTopology {
            payload["audioTopology"] = audioTopology
        }
        payload["supportedPresentationModes"] = descriptor.supportedPresentationModes.map(\.rawValue)
        if let text = descriptor.textFixture {
            payload["textRenditions"] = text.tracks.map { track -> [String: Any] in
                ["id": track.id, "name": track.name, "language": track.language, "role": track.role.rawValue,
                 "format": "webvtt", "playlistPath": track.playlistPath, "isDefault": track.isDefault,
                 "isAutoSelect": track.isAutoSelect, "isForced": track.role == .forced,
                 "characteristics": track.characteristics, "reviewStatus": track.reviewStatus,
                 "cueCount": track.cues.count]
            }
            payload["textSourceRevision"] = text.sourceRevision
            payload["textDeliveryQualification"] = "Delivery does not establish selected language or visible rendering. VOD and conformant shared-grid liveLoop are supported; embedded captions and JIT text are unsupported."
        }
        if let audioDescription = descriptor.audioDescription {
            payload["audioDescription"] = audioDescription
        }
        if let audioRenditions = descriptor.audioRenditions {
            payload["audioRenditions"] = audioRenditions.map {
                var rendition: [String: Any] = [
                    "name": $0.name,
                    "language": $0.language,
                    "channels": $0.channels,
                    "isDefault": $0.isDefault,
                    "isAutoSelect": $0.isAutoSelect,
                    "characteristics": $0.characteristics,
                    "audibleSignature": $0.audibleSignature
                ]
                if let associatedLanguage = $0.associatedLanguage {
                    rendition["associatedLanguage"] = associatedLanguage
                }
                if let deliveryKind = $0.deliveryKind {
                    rendition["deliveryKind"] = deliveryKind
                }
                if let variantsCarryingInBand = $0.variantsCarryingInBand {
                    rendition["variantsCarryingInBand"] = variantsCarryingInBand
                }
                if let publicationSchedule = $0.publicationSchedule {
                    rendition["publicationSchedule"] = publicationSchedule
                }
                if let segmentGridDuration = $0.segmentGridDuration {
                    rendition["segmentGridDuration"] = segmentGridDuration
                }
                if let hasDiscontinuities = $0.hasDiscontinuities {
                    rendition["hasDiscontinuities"] = hasDiscontinuities
                }
                return rendition
            }
        }
        if let bundleSizeBudgetBytes = descriptor.bundleSizeBudgetBytes {
            payload["bundleSizeBudgetBytes"] = bundleSizeBudgetBytes
        }
        if let conformanceClass = descriptor.conformanceClass {
            payload["conformanceClass"] = conformanceClass
        }
        if let controlledFaults = descriptor.controlledFaults {
            payload["controlledFaults"] = controlledFaults
        }
        if let expectedClientBehavior = descriptor.expectedClientBehavior {
            payload["expectedClientBehavior"] = expectedClientBehavior
        }
        if let jitPublicationState = descriptor.jitPublicationState {
            payload["jitPublicationState"] = jitPublicationState
        }
        if let id3Schedule = descriptor.id3Schedule {
            payload["id3Schedule"] = [
                "carrier": id3Schedule.carrier,
                "version": id3Schedule.version,
                "allowedFrameIDs": id3Schedule.allowedFrameIDs,
                "events": id3Schedule.events.map {
                    [
                        "id": $0.id,
                        "eventClass": $0.eventClass,
                        "mediaTime": $0.mediaTime,
                        "segmentIndex": $0.segmentIndex,
                        "frameID": $0.frameID,
                        "label": $0.label
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return payload
    }

    private func substitutionDictionary(_ experiment: HLSSubstitutionExperiment) -> [String: Any] {
        var payload: [String: Any] = [
            "experimentID": experiment.id.uuidString,
            "profileID": experiment.profileID,
            "state": experiment.state.rawValue,
            "scope": experiment.scope.displayName,
            "matchScope": substitutionMatchScopeDictionary(origin: experiment.origin, scope: experiment.scope),
            "requestPolicy": experiment.requestPolicy?.summary ?? HLSRequestPolicy.legacySummary,
            "scopePolicy": HLSRequestPolicy.disclosure(experiment.requestPolicy),
            "mountPath": experiment.mountPath,
            "failOpen": true,
            "playbackConfiguration": playbackConfigurationDictionary(experiment.effectivePlaybackConfiguration),
            "recommendationViolations": experiment.effectivePlaybackConfiguration.recommendationViolations.map {
                ["id": $0.rawValue, "summary": $0.summary]
            },
            "metrics": [
                "entryPlaylistHits": experiment.metrics.entryPlaylistHits,
                "childPlaylistHits": experiment.metrics.childPlaylistHits,
                "segmentHits": experiment.metrics.segmentHits,
                "totalHits": experiment.metrics.totalHits,
                "stallClass": experiment.metrics.stallClass.rawValue,
                "stallClassBasis": "sinceStart"
            ] as [String: Any]
        ]
        if let runID = experiment.fixtureRunID { payload["fixtureRunID"] = runID.uuidString }
        if let startedAt = experiment.startedAt { payload["startedAt"] = MCPApprovalPolicy.iso8601String(from: startedAt) }
        if let expiresAt = experiment.expiresAt { payload["expiresAt"] = MCPApprovalPolicy.iso8601String(from: expiresAt) }
        if let stoppedAt = experiment.stoppedAt { payload["stoppedAt"] = MCPApprovalPolicy.iso8601String(from: stoppedAt) }
        if let lastMatchedAt = experiment.metrics.lastMatchedAt {
            var metrics = payload["metrics"] as? [String: Any] ?? [:]
            metrics["lastMatchedAt"] = MCPApprovalPolicy.iso8601String(from: lastMatchedAt)
            payload["metrics"] = metrics
        }
        return payload
    }

    /// Parses `ttlSeconds` for `propose_hls_substitution_start`/`hls_substitution_extend` — mirrors
    /// `MCPOpenAPIMockPackService.parseTTL`'s int-or-double acceptance, defaulting to
    /// `HLSSubstitutionTTLPolicy.defaultTTL` (today's original, only-ever fixed duration) when absent.
    private func parseSubstitutionTTL(_ raw: Any?) throws -> TimeInterval {
        guard let raw else { return HLSSubstitutionTTLPolicy.defaultTTL }
        let value: TimeInterval
        if let number = raw as? Int {
            value = TimeInterval(number)
        } else if let number = raw as? Double {
            value = number
        } else {
            throw MCPStructuredError(code: .malformedRequest, message: "ttlSeconds must be a number.")
        }
        try HLSSubstitutionTTLPolicy.validate(value)
        return value
    }

    private func parsePlaybackConfiguration(_ rawValue: Any?) throws -> HLSPlaybackConfiguration {
        guard let rawValue else { return .conformant }
        guard let raw = rawValue as? [String: Any] else {
            throw MCPStructuredError(code: .malformedRequest, message: "playbackConfiguration must be an object.")
        }
        var configuration = HLSPlaybackConfiguration.conformant
        if let value = raw["presentationMode"] as? String {
            guard let parsed = HLSPresentationMode(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.presentationMode",
                    provided: value,
                    validValues: HLSPresentationMode.allCases.map(\.rawValue)
                )
            }
            configuration.presentationMode = parsed
        }
        if let value = raw["timeShiftMode"] as? String {
            guard let parsed = HLSTimeShiftMode(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.timeShiftMode",
                    provided: value,
                    validValues: HLSTimeShiftMode.allCases.map(\.rawValue)
                )
            }
            configuration.timeShiftMode = parsed
            if parsed != .off, !raw.keys.contains("windowSegmentCount") {
                configuration.windowSegmentCount = HLSPlaybackConfiguration.boundedTimeShiftSmokeWindowSegmentCount
            }
        }
        if let value = raw["intent"] as? String {
            guard let parsed = HLSExperimentIntent(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.intent",
                    provided: value,
                    validValues: HLSExperimentIntent.allCases.map(\.rawValue)
                )
            }
            configuration.intent = parsed
        }
        if let value = raw["windowSegmentCount"] as? Int { configuration.windowSegmentCount = value }
        if let value = raw["loopBoundaryTreatment"] as? String {
            guard let parsed = HLSLoopBoundaryTreatment(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.loopBoundaryTreatment",
                    provided: value,
                    validValues: HLSLoopBoundaryTreatment.allCases.map(\.rawValue)
                )
            }
            configuration.loopBoundaryTreatment = parsed
        }
        if let value = raw["segmentURIIdentity"] as? String {
            guard let parsed = HLSSegmentURIIdentity(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.segmentURIIdentity",
                    provided: value,
                    validValues: HLSSegmentURIIdentity.allCases.map(\.rawValue)
                )
            }
            configuration.segmentURIIdentity = parsed
        }
        if let value = raw["targetDurationTreatment"] as? String {
            guard let parsed = HLSTargetDurationTreatment(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.targetDurationTreatment",
                    provided: value,
                    validValues: HLSTargetDurationTreatment.allCases.map(\.rawValue)
                )
            }
            configuration.targetDurationTreatment = parsed
        }
        if let value = raw["programDateTimeTreatment"] as? String {
            guard let parsed = HLSProgramDateTimeTreatment(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.programDateTimeTreatment",
                    provided: value,
                    validValues: HLSProgramDateTimeTreatment.allCases.map(\.rawValue)
                )
            }
            configuration.programDateTimeTreatment = parsed
        }
        if let value = raw["playlistCachePolicy"] as? String {
            guard let parsed = HLSPlaylistCachePolicy(rawValue: value) else {
                throw MCPStructuredError.invalidEnumValue(
                    field: "playbackConfiguration.playlistCachePolicy",
                    provided: value,
                    validValues: HLSPlaylistCachePolicy.allCases.map(\.rawValue)
                )
            }
            configuration.playlistCachePolicy = parsed
        }
        if raw.keys.contains("playlistMaxAgeSeconds") {
            guard let value = raw["playlistMaxAgeSeconds"] as? Int else {
                throw MCPStructuredError(code: .malformedRequest, message: "playbackConfiguration.playlistMaxAgeSeconds must be an integer.")
            }
            configuration.playlistMaxAgeSeconds = value
        }
        do {
            return try configuration.validated()
        } catch {
            throw MCPStructuredError(code: .malformedRequest, message: error.localizedDescription)
        }
    }

    private func playbackConfigurationDictionary(_ configuration: HLSPlaybackConfiguration) -> [String: Any] {
        var payload: [String: Any] = [
            "intent": configuration.intent.rawValue,
            "timeShiftMode": configuration.effectiveTimeShiftMode.rawValue,
            "windowSegmentCount": configuration.windowSegmentCount,
            "loopBoundaryTreatment": configuration.loopBoundaryTreatment.rawValue,
            "segmentURIIdentity": configuration.segmentURIIdentity.rawValue,
            "targetDurationTreatment": configuration.targetDurationTreatment.rawValue,
            "programDateTimeTreatment": configuration.programDateTimeTreatment.rawValue,
            "playlistCachePolicy": configuration.playlistCachePolicy.rawValue
        ]
        if let seconds = configuration.playlistMaxAgeSeconds {
            payload["playlistMaxAgeSeconds"] = seconds
        }
        if let presentationMode = configuration.presentationMode {
            payload["presentationMode"] = presentationMode.rawValue
        }
        return payload
    }

    private func playbackConfigurationCapabilitiesDictionary() -> [String: Any] {
        [
            "default": playbackConfigurationDictionary(.conformant),
            "presentationModes": HLSPresentationMode.allCases.map(\.rawValue),
            "timeShiftModes": HLSTimeShiftMode.allCases.map(\.rawValue),
            "boundedTimeShiftSmokeWindowSegmentCount": HLSPlaybackConfiguration.boundedTimeShiftSmokeWindowSegmentCount,
            "windowSegmentCountRange": [
                "minimum": HLSPlaybackConfiguration.minimumWindowSegmentCount,
                "maximum": HLSPlaybackConfiguration.maximumWindowSegmentCount
            ],
            "maxRenderedPlaylistBytes": HLSFixtureLimits.maxRenderedPlaylistBytes,
            "maxAdvertisedDurationSeconds": Int(HLSFixtureLimits.maxAdvertisedDurationSeconds),
            "loopBoundaryTreatments": HLSLoopBoundaryTreatment.allCases.map(\.rawValue),
            "segmentURIIdentities": HLSSegmentURIIdentity.allCases.map(\.rawValue),
            "targetDurationTreatments": HLSTargetDurationTreatment.allCases.map(\.rawValue),
            "programDateTimeTreatments": HLSProgramDateTimeTreatment.allCases.map(\.rawValue),
            "playlistCachePolicies": HLSPlaylistCachePolicy.allCases.map(\.rawValue),
            "playlistMaxAgeSecondsRange": ["minimum": 0, "maximum": 60],
            "deliberateFaultIntentRequired": true,
            "mediaByteChangesRequireBundledProfile": true
        ]
    }

    private func substitutionMatchScopeDictionary(
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "scheme": origin.scheme.rawValue,
            "host": origin.host,
            "port": origin.port,
            "scope": scope.displayName
        ]
        switch scope {
        case .selectedPlaylist(let path): payload["path"] = path
        case .host: payload["pathSuffix"] = ".m3u8"
        }
        return payload
    }
}
