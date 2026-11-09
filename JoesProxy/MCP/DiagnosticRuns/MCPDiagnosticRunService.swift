import Foundation

/// Pending propose→apply plan for a diagnostic-run regression re-check (AN-6).
struct DiagnosticRunRecheckPlan: Equatable, Sendable {
    var clientID: String
    var preparation: DiagnosticRunRecheckPreparation
    var effectSummary: String
}

/// MCP surface for composite diagnostic-run create/start/status/observations/close/re-check.
///
/// Concurrency: `@MainActor` — mutates the run coordinator, proposal, and approval stores on the
/// main actor. Does not activate Mac system-proxy routing. One approval is required only for
/// `apply_diagnostic_run_recheck` when recreating reviewed effects; create/start/close of
/// observation-only runs do not mint approvals.
@MainActor
final class MCPDiagnosticRunService {
    private let runCoordinator: DiagnosticRunCoordinator
    private let recheckService: DiagnosticRunRegressionRecheckService
    private let proposalCoordinator: MCPProposalCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private let systemNotificationCoordinator: MCPSystemNotificationCoordinator?
    private var recheckPlansByProposalToken: [String: DiagnosticRunRecheckPlan] = [:]
    private let briefReadCache = MCPBriefReadCache()

    private var policyEvaluator: MCPPolicyEvaluator {
        MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
    }

    init(
        runCoordinator: DiagnosticRunCoordinator,
        recheckService: DiagnosticRunRegressionRecheckService,
        proposalCoordinator: MCPProposalCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore,
        systemNotificationCoordinator: MCPSystemNotificationCoordinator? = nil
    ) {
        self.runCoordinator = runCoordinator
        self.recheckService = recheckService
        self.proposalCoordinator = proposalCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        self.grantStore = grantStore
        self.auditStore = auditStore
        self.systemNotificationCoordinator = systemNotificationCoordinator
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "diagnostic_run_brief":
            return try runBrief(arguments: arguments, client: client)
        case "diagnostic_run_window_begin":
            try requireAccess(client: client, capability: .diagnosticRunLifecycle)
            guard Set(arguments.keys).isSubset(of: ["runID", "bundleID", "mode"]) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Allowed arguments: runID, bundleID, mode. Authority comes from the authenticated client.")
            }
            guard let run = (arguments["runID"] as? String).flatMap(UUID.init(uuidString:)),
                  let bundle = (arguments["bundleID"] as? String).flatMap(UUID.init(uuidString:)),
                  let mode = (arguments["mode"] as? String).flatMap(DiagnosticExperimentWindow.Mode.init(rawValue:)) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Supply runID, bundleID and mode: baseline or modified. Example: {runID: <UUID>, bundleID: <UUID>, mode: baseline}.")
            }
            return ["schemaVersion": 1, "payload": try encodeJSONObject(runCoordinator.beginExperimentWindow(
                runID: .init(rawValue: run), bundleID: bundle, mode: mode, requestingOwnerID: client.id))]
        case "diagnostic_run_window_end":
            try requireAccess(client: client, capability: .diagnosticRunLifecycle)
            guard Set(arguments.keys).isSubset(of: ["windowID", "targetOutcome", "outcomeSource"]) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Allowed arguments: windowID, targetOutcome, outcomeSource. Authority comes from the authenticated client.")
            }
            guard let id = (arguments["windowID"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Supply windowID from diagnostic_run_window_begin.")
            }
            return ["schemaVersion": 1, "payload": try encodeJSONObject(runCoordinator.endExperimentWindow(id: id,
                requestingOwnerID: client.id, targetOutcome: arguments["targetOutcome"] as? String,
                outcomeSource: arguments["outcomeSource"] as? String))]
        case "diagnostic_run_list":
            return try listRuns(arguments: arguments, client: client)
        case "diagnostic_run_create":
            return try create(arguments: arguments, client: client)
        case "diagnostic_run_start":
            return try await start(arguments: arguments, client: client)
        case "diagnostic_run_status":
            return try status(arguments: arguments, client: client)
        case "diagnostic_run_observations":
            return try await observations(arguments: arguments, client: client)
        case "diagnostic_run_close":
            return try await close(arguments: arguments, client: client)
        case "diagnostic_run_retry_cleanup":
            return try await retryCleanup(arguments: arguments, client: client)
        case "diagnostic_run_evidence_list":
            return try evidenceList(arguments: arguments, client: client)
        case "diagnostic_run_evidence_get":
            return try evidenceGet(arguments: arguments, client: client)
        case "propose_diagnostic_run_recheck":
            return try await proposeRecheck(arguments: arguments, client: client)
        case "apply_diagnostic_run_recheck":
            return try await applyRecheck(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown diagnostic-run tool: \(name).")
        }
    }

    // MARK: - Tools

    private func listRuns(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        let limit = boundedInt(arguments["limit"], default: DiagnosticRunBudget.listPageDefault, max: DiagnosticRunBudget.listPageMax)
        let offset = max(0, (arguments["offset"] as? Int) ?? 0)
        let owned = runCoordinator.runs(ownedBy: client.id)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
        let slice = Array(owned.dropFirst(offset).prefix(limit))
        let redact = shouldRedactExactScope(client: client)
        return [
            "schemaVersion": 1,
            "payload": [
                "items": slice.map { runDictionary($0, redactExactScope: redact) },
                "totalCount": owned.count,
                "hasMore": offset + slice.count < owned.count
            ] as [String: Any]
        ]
    }

    private func create(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        let summary = try requireNonEmptyString(arguments["hypothesisSummary"], field: "hypothesisSummary")
        let expected = try requireNonEmptyString(arguments["expectedObservation"], field: "expectedObservation")
        let hypothesis = DiagnosticRunHypothesis(
            summary: summary,
            expectedObservation: expected,
            source: .mcpClient
        )
        let scopes = try parseScopes(arguments["scopes"])
        let lifetime = arguments["lifetimeSeconds"] as? Double
        do {
            let run = try runCoordinator.createDraft(
                owner: .mcpClient(id: client.id, displayNameSnapshot: client.displayName),
                hypothesis: hypothesis,
                scopes: scopes,
                lifetime: lifetime
            )
            recordAudit(client: client, targetID: run.id.rawValue.uuidString, detail: "Created diagnostic run draft.")
            return [
                "schemaVersion": 1,
                "payload": runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
            ]
        } catch let error as DiagnosticRunError {
            throw structuredRunError(error)
        }
    }

    private func start(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        let runID = try parseRunID(arguments["runID"])
        do {
            let run = try await runCoordinator.startWatching(id: runID, requestingOwnerID: client.id)
            recordAudit(client: client, targetID: run.id.rawValue.uuidString, detail: "Started diagnostic run watching.")
            return [
                "schemaVersion": 1,
                "payload": runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
            ]
        } catch let error as DiagnosticRunError {
            throw structuredRunError(error)
        }
    }

    private func status(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        let runID = try parseRunID(arguments["runID"])
        guard let run = runCoordinator.run(id: runID), run.owner.ownerID == client.id else {
            throw MCPStructuredError(code: .malformedRequest, message: "runID not found for this client.")
        }
        var payload = runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
        payload["experimentWindows"] = runCoordinator.experimentWindowReferences(runID: runID, requestingOwnerID: client.id)
        return ["schemaVersion": 1, "payload": payload]
    }

    private func runBrief(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        try requireAccess(client: client, capability: .overrideInspect)
        guard Set(arguments.keys).isSubset(of: ["runID", "baselineWindowID", "modifiedWindowID", "ifBriefDigest"]),
              MCPBriefReadCache.validDigest(arguments["ifBriefDigest"]),
              let baseline = (arguments["baselineWindowID"] as? String).flatMap(UUID.init(uuidString:)),
              let modified = (arguments["modifiedWindowID"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw MCPStructuredError.malformedRequest(message: "Provide runID, baselineWindowID, modifiedWindowID and optional ifBriefDigest.")
        }
        let runID = try parseRunID(arguments["runID"])
        guard let run = runCoordinator.run(id: runID), run.owner.ownerID == client.id else {
            throw MCPStructuredError.malformedRequest(message: "runID not found for this client.")
        }
        let comparison = try runCoordinator.compareExperimentWindows(baselineID: baseline, modifiedID: modified,
            requestingOwnerID: client.id)
        guard comparison.baseline.runID == runID, comparison.modified.runID == runID else {
            throw MCPStructuredError.malformedRequest(message: "Both closed windows must belong to the requested run.")
        }
        // Refresh before every conditional read: cleanup/lifecycle changes are not capture mutations.
        let report = DiagnosticRunBrief(run: run, comparison: comparison)
        var payload = try encodeJSONObject(report)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let scope = try MCPBriefReadCache.scope(["run-v1", client.id, client.assignedProfileID.rawValue,
            policyStore.policyRevision.rawValue, String(decoding: bytes, as: UTF8.self)])
        if let unchanged = briefReadCache.unchanged(arguments["ifBriefDigest"] as? String,
            owner: client.id, scope: scope, analysisReused: false) {
            return ["schemaVersion": 1, "payload": unchanged]
        }
        guard bytes.count < 16_000 else {
            throw MCPStructuredError(code: .policyDenied, message: "Run brief exceeds budget; inspect windows separately.")
        }
        payload["briefDigest"] = try briefReadCache.retain(payload: payload, owner: client.id, scope: scope)
        payload["unchanged"] = false
        payload["analysisReused"] = false
        return ["schemaVersion": 1, "payload": payload]
    }

    private func observations(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        let runID = try parseRunID(arguments["runID"])
        let limit = boundedInt(
            arguments["limit"],
            default: DiagnosticRunBudget.observationPageDefault,
            max: DiagnosticRunBudget.observationPageMax
        )
        let afterMarker = (arguments["afterMarker"] as? String).flatMap(UUID.init(uuidString:))
        let beforeMarker = (arguments["beforeMarker"] as? String).flatMap(UUID.init(uuidString:))
        do {
            let page = try await runCoordinator.listObservations(
                id: runID,
                requestingOwnerID: client.id,
                limit: limit,
                afterMarker: afterMarker,
                beforeMarker: beforeMarker
            )
            let redact = shouldRedactExactScope(client: client)
            return [
                "schemaVersion": 1,
                "payload": [
                    "records": page.records.map { observationDictionary($0, redactExactScope: redact) },
                    "droppedObservationCount": page.droppedObservationCount,
                    "evidenceUnavailableReason": page.evidenceUnavailableReason?.rawValue as Any,
                    "nextCursor": page.nextCursor.map(cursorDictionary) as Any
                ] as [String: Any]
            ]
        } catch let error as DiagnosticRunError {
            throw structuredRunError(error)
        }
    }

    private func close(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        let runID = try parseRunID(arguments["runID"])
        let terminal = try parseRequestedTerminal(arguments["requestedTerminal"])
        let conclusion: DiagnosticRunConclusion?
        if terminal == .expired {
            conclusion = nil
        } else {
            conclusion = try parseConclusion(arguments)
        }
        do {
            let run = try await runCoordinator.close(
                id: runID,
                requestingOwnerID: client.id,
                requestedTerminal: terminal,
                conclusion: conclusion
            )
            if run.status == .cleanupRequired {
                systemNotificationCoordinator?.handleDiagnosticRunAttention(
                    runID: run.id,
                    status: run.status
                )
            }
            recordAudit(client: client, targetID: run.id.rawValue.uuidString, detail: "Closed diagnostic run (\(run.status.rawValue)).")
            var payload = runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
            if let evidence = try? runCoordinator.evidenceRecord(forRunID: run.id, requestingOwnerID: client.id) {
                payload["evidenceID"] = evidence.id.uuidString
                payload["evidenceDigest"] = evidence.evidenceDigest
            }
            return ["schemaVersion": 1, "payload": payload]
        } catch let error as DiagnosticRunError {
            if error == .cleanupNotVerified,
               let run = runCoordinator.run(id: runID),
               run.owner.ownerID == client.id {
                systemNotificationCoordinator?.handleDiagnosticRunAttention(
                    runID: run.id,
                    status: run.status
                )
                var payload = runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
                payload["cleanupVerified"] = false
                return ["schemaVersion": 1, "payload": payload]
            }
            throw structuredRunError(error)
        }
    }

    private func retryCleanup(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        let runID = try parseRunID(arguments["runID"])
        do {
            let run = try await runCoordinator.retryCleanup(id: runID, requestingOwnerID: client.id)
            recordAudit(client: client, targetID: run.id.rawValue.uuidString, detail: "Retried diagnostic run cleanup.")
            return [
                "schemaVersion": 1,
                "payload": runDictionary(run, redactExactScope: shouldRedactExactScope(client: client))
            ]
        } catch let error as DiagnosticRunError {
            throw structuredRunError(error)
        }
    }

    private func evidenceList(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        let limit = boundedInt(arguments["limit"], default: DiagnosticRunBudget.listPageDefault, max: DiagnosticRunBudget.listPageMax)
        let offset = max(0, (arguments["offset"] as? Int) ?? 0)
        let page = try runCoordinator.listEvidence(
            requestingOwnerID: client.id,
            limit: limit,
            offset: offset
        )
        return [
            "schemaVersion": 1,
            "payload": [
                "items": page.records.map(disclosedEvidenceDictionary),
                "totalCount": page.totalCount,
                "hasMore": page.hasMore
            ] as [String: Any]
        ]
    }

    private func evidenceGet(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunInspect)
        let evidenceID = try parseUUID(arguments["evidenceID"], field: "evidenceID")
        do {
            if client.assignedProfileID == .metadataOnly {
                let disclosed = try runCoordinator.disclosedEvidenceRecord(
                    id: evidenceID,
                    requestingOwnerID: client.id
                )
                return ["schemaVersion": 1, "payload": disclosedEvidenceDictionary(from: disclosed)]
            }
            let export = try runCoordinator.exportEvidence(id: evidenceID, requestingOwnerID: client.id)
            return ["schemaVersion": 1, "payload": try encodeJSONObject(export)]
        } catch let error as DiagnosticRunError {
            throw structuredRunError(error)
        }
    }

    private func proposeRecheck(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        let evidenceID = try parseUUID(arguments["evidenceID"], field: "evidenceID")
        let preparation: DiagnosticRunRecheckPreparation
        do {
            preparation = try await recheckService.prepareRecheck(
                sourceEvidenceID: evidenceID,
                requestingOwnerID: client.id
            )
        } catch let error as DiagnosticRunRecheckError {
            throw structuredRecheckError(error)
        }
        let effectSummary = "Re-check saved diagnostic evidence \(evidenceID.uuidString)."
        let digest = MCPArgumentDigest.normalized([
            "evidenceID": evidenceID.uuidString,
            "sourceRunID": preparation.sourceRunID.rawValue.uuidString
        ])
        let proposal: MCPProposalToken
        do {
            proposal = try proposalCoordinator.createProposal(
                clientID: client.id,
                capability: .diagnosticRunLifecycle,
                argumentDigest: digest,
                targetRevision: nil,
                targetLockKey: "diagnostic-recheck:\(evidenceID.uuidString)"
            )
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        }
        recheckPlansByProposalToken[proposal.token] = DiagnosticRunRecheckPlan(
            clientID: client.id,
            preparation: preparation,
            effectSummary: effectSummary
        )
        var payload = preparationDictionary(preparation, redactExactScope: shouldRedactExactScope(client: client))
        payload["proposalToken"] = proposal.token
        payload["expiresAt"] = MCPApprovalPolicy.iso8601String(from: proposal.expiresAt)
        payload["riskTier"] = MCPCapabilityID.diagnosticRunLifecycle.riskTier.rawValue
        payload["targetLockKey"] = proposal.targetLockKey
        payload["effectSummary"] = effectSummary
        return ["schemaVersion": 1, "payload": payload]
    }

    private func applyRecheck(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .diagnosticRunLifecycle)
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty,
              let proposal = proposalCoordinator.proposal(forToken: proposalToken),
              proposal.clientID == client.id,
              proposal.capability == .diagnosticRunLifecycle,
              let plan = recheckPlansByProposalToken[proposalToken],
              plan.clientID == client.id else {
            if let token = arguments["proposalToken"] as? String {
                approvalStore.invalidate(proposalToken: token)
                recheckPlansByProposalToken.removeValue(forKey: token)
            }
            throw MCPStructuredError(code: .staleProposal, message: "Diagnostic re-check proposal is stale or unknown.")
        }
        try resolveLifecycleApproval(
            toolName: "apply_diagnostic_run_recheck",
            arguments: arguments,
            client: client,
            capability: .diagnosticRunLifecycle,
            proposalToken: proposalToken,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        let digest = proposal.argumentDigest
        var appliedResult: DiagnosticRunRecheckResult?
        let applyResult: MCPProposalApplyResult
        do {
            applyResult = try await proposalCoordinator.applyProposal(
                token: proposalToken,
                clientID: client.id,
                capability: .diagnosticRunLifecycle,
                argumentDigest: digest,
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: client.id,
                    targetKind: .diagnosticRun,
                    targetID: plan.preparation.sourceEvidenceID.uuidString,
                    baselineRevision: nil,
                    intendedChangeDigest: digest,
                    rollbackSnapshot: nil,
                    expiresAt: MCPApprovalPolicy.expiration()
                ),
                performMutation: {
                    appliedResult = try await self.recheckService.executeRecheck(
                        preparation: plan.preparation,
                        requestingOwnerID: client.id
                    )
                    return nil
                },
                idempotencyKey: idempotencyKey(from: arguments, proposalToken: proposalToken)
            )
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        } catch let error as DiagnosticRunRecheckError {
            throw structuredRecheckError(error)
        }
        recheckPlansByProposalToken.removeValue(forKey: proposalToken)
        guard let result = appliedResult else {
            throw MCPStructuredError(code: .internalFailure, message: "Diagnostic re-check result missing after apply.")
        }
        recordAudit(client: client, targetID: plan.preparation.sourceEvidenceID.uuidString, detail: plan.effectSummary)
        var payload = recheckResultDictionary(result)
        payload["transactionID"] = applyResult.transactionID
        payload["appliedAt"] = MCPApprovalPolicy.iso8601String(from: applyResult.appliedAt)
        return ["schemaVersion": 1, "payload": payload]
    }

    // MARK: - Parsing

    private func parseScopes(_ raw: Any?) throws -> [DiagnosticRunScope] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return try items.map(parseScope)
    }

    private func parseScope(_ raw: [String: Any]) throws -> DiagnosticRunScope {
        guard let kind = raw["kind"] as? String else {
            throw MCPStructuredError(code: .malformedRequest, message: "scope.kind is required.")
        }
        switch kind {
        case "http":
            guard let method = raw["method"] as? String,
                  let host = raw["host"] as? String,
                  let path = raw["path"] as? String else {
                throw MCPStructuredError(code: .malformedRequest, message: "http scope requires method, host, and path.")
            }
            let schemeRaw = (raw["scheme"] as? String) ?? "https"
            guard let scheme = SessionScheme(rawValue: schemeRaw) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Invalid HTTP scheme.")
            }
            let pathMatchRaw = (raw["pathMatch"] as? String) ?? "exact"
            guard let pathMatch = DiagnosticPathMatch(rawValue: pathMatchRaw) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Invalid pathMatch.")
            }
            let port: Int
            if let explicit = raw["port"] as? Int {
                port = explicit
            } else {
                port = scheme == .https ? 443 : 80
            }
            return .http(DiagnosticHTTPScope(
                method: method,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                pathMatch: pathMatch
            ))
        case "capturedSession":
            let sessionID = try parseUUID(raw["sessionID"], field: "sessionID")
            let fingerprint = try requireNonEmptyString(raw["requestFingerprint"], field: "requestFingerprint")
            let epochRaw = (raw["captureEpoch"] as? String) ?? MCPCaptureEpoch.initial.rawValue
            return .capturedSession(DiagnosticCapturedSessionScope(
                sessionID: sessionID,
                captureEpoch: MCPCaptureEpoch(rawValue: epochRaw),
                requestFingerprint: fingerprint
            ))
        case "effect":
            guard let effectKindRaw = raw["effectKind"] as? String,
                  let effectKind = DiagnosticReferenceKind(rawValue: effectKindRaw),
                  let effectID = raw["effectID"] as? String, !effectID.isEmpty else {
                throw MCPStructuredError(code: .malformedRequest, message: "effect scope requires effectKind and effectID.")
            }
            return .effect(DiagnosticEffectScope(
                kind: effectKind,
                effectID: effectID,
                targetRevision: raw["targetRevision"] as? String
            ))
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unsupported scope kind '\(kind)'.")
        }
    }

    private func parseConclusion(_ arguments: [String: Any]) throws -> DiagnosticRunConclusion {
        guard let outcomeRaw = arguments["conclusionOutcome"] as? String,
              let outcome = DiagnosticConclusionOutcome(rawValue: outcomeRaw),
              let reasonRaw = arguments["conclusionReasonCode"] as? String,
              let reason = DiagnosticConclusionReasonCode(rawValue: reasonRaw) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "conclusionOutcome and conclusionReasonCode are required unless requestedTerminal is expired."
            )
        }
        let summary = try requireNonEmptyString(arguments["conclusionSummary"], field: "conclusionSummary")
        let confidenceRaw = (arguments["conclusionConfidence"] as? String) ?? "unassessed"
        guard let confidence = DiagnosticConclusionConfidence(rawValue: confidenceRaw) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Invalid conclusionConfidence.")
        }
        return DiagnosticRunConclusion(
            outcome: outcome,
            reasonCode: reason,
            summary: summary,
            confidence: confidence,
            concludedAt: Date(),
            evidenceDigest: (arguments["evidenceDigest"] as? String) ?? ""
        )
    }

    private func parseRequestedTerminal(_ raw: Any?) throws -> DiagnosticRunRequestedTerminal {
        guard let value = raw as? String,
              let terminal = DiagnosticRunRequestedTerminal(rawValue: value) else {
            throw MCPStructuredError(code: .malformedRequest, message: "requestedTerminal is required.")
        }
        return terminal
    }

    private func parseRunID(_ raw: Any?) throws -> DiagnosticRunID {
        let uuid = try parseUUID(raw, field: "runID")
        return DiagnosticRunID(rawValue: uuid)
    }

    private func parseUUID(_ raw: Any?, field: String) throws -> UUID {
        guard let value = raw as? String, let uuid = UUID(uuidString: value) else {
            throw MCPStructuredError(code: .malformedRequest, message: "\(field) must be a UUID string.")
        }
        return uuid
    }

    private func requireNonEmptyString(_ raw: Any?, field: String) throws -> String {
        guard let value = raw as? String else {
            throw MCPStructuredError(code: .malformedRequest, message: "\(field) is required.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "\(field) is required.")
        }
        return trimmed
    }

    private func boundedInt(_ raw: Any?, default defaultValue: Int, max maxValue: Int) -> Int {
        let value = (raw as? Int) ?? defaultValue
        return min(max(value, 1), maxValue)
    }

    // MARK: - Projections

    private func shouldRedactExactScope(client: MCPClientRecord) -> Bool {
        client.assignedProfileID == .metadataOnly
    }

    private func runDictionary(_ run: DiagnosticRun, redactExactScope: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "runID": run.id.rawValue.uuidString,
            "ownerID": run.owner.ownerID,
            "status": run.status.rawValue,
            "workflow": ExperimentWorkflowGuidance.run(status: run.status,
                cleanupVerified: run.cleanupProof?.verifiedClean == true).payload,
            "hypothesisSummary": run.hypothesis.summary,
            "expectedObservation": run.hypothesis.expectedObservation,
            "hypothesisSource": run.hypothesis.source.rawValue,
            "scopeCount": run.scopes.count,
            "referenceCount": run.references.count,
            "installedWatchCount": run.installedWatchIDs.count,
            "matchedRequestCount": run.observationSummary.matchedRequestCount,
            "matcherMissCount": run.observationSummary.matcherMissCount,
            "droppedObservationCount": run.observationSummary.droppedObservationCount,
            "createdAt": MCPApprovalPolicy.iso8601String(from: run.createdAt),
            "expiresAt": MCPApprovalPolicy.iso8601String(from: run.expiresAt),
            "lastUpdatedAt": MCPApprovalPolicy.iso8601String(from: run.lastUpdatedAt),
            "cleanupVerified": run.cleanupProof?.verifiedClean as Any,
            "remainingLiveEffectCount": run.cleanupProof?.remainingLiveEffectCount as Any,
            "requestedTerminal": run.requestedTerminal?.rawValue as Any,
            "conclusionOutcome": run.conclusion?.outcome.rawValue as Any,
            "conclusionReasonCode": run.conclusion?.reasonCode.rawValue as Any,
            "confidence": run.conclusion?.confidence.rawValue as Any
        ]
        if !redactExactScope {
            payload["scopes"] = run.scopes.map(scopeDictionary)
            payload["references"] = run.references.map(referenceDictionary)
        } else {
            payload["scopes"] = run.scopes.map { scope -> [String: Any] in
                switch scope {
                case .http:
                    return ["kind": "http", "redacted": true]
                case .capturedSession:
                    return ["kind": "capturedSession", "redacted": true]
                case .effect(let effect):
                    return [
                        "kind": "effect",
                        "effectKind": effect.kind.rawValue,
                        "effectID": effect.effectID
                    ]
                }
            }
        }
        if let terminalAt = run.terminalAt {
            payload["terminalAt"] = MCPApprovalPolicy.iso8601String(from: terminalAt)
        }
        return payload
    }

    private func scopeDictionary(_ scope: DiagnosticRunScope) -> [String: Any] {
        switch scope {
        case .http(let http):
            return [
                "kind": "http",
                "method": http.method,
                "scheme": http.scheme.rawValue,
                "host": http.host,
                "port": http.port,
                "path": http.path,
                "pathMatch": http.pathMatch.rawValue
            ]
        case .capturedSession(let session):
            return [
                "kind": "capturedSession",
                "sessionID": session.sessionID.uuidString,
                "captureEpoch": session.captureEpoch.rawValue,
                "requestFingerprint": session.requestFingerprint
            ]
        case .effect(let effect):
            return [
                "kind": "effect",
                "effectKind": effect.kind.rawValue,
                "effectID": effect.effectID,
                "targetRevision": effect.targetRevision as Any
            ]
        }
    }

    private func referenceDictionary(_ reference: DiagnosticRunReference) -> [String: Any] {
        [
            "kind": reference.kind.rawValue,
            "opaqueID": reference.opaqueID,
            "relationship": reference.relationship.rawValue,
            "ownerIDSnapshot": reference.ownerIDSnapshot as Any,
            "targetRevision": reference.targetRevision as Any
        ]
    }

    private func observationDictionary(
        _ record: DiagnosticRunObservationRecord,
        redactExactScope: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": record.id.uuidString,
            "runID": record.runID.rawValue.uuidString,
            "sequence": record.sequence,
            "kind": record.kind.rawValue,
            "observedAt": MCPApprovalPolicy.iso8601String(from: record.observedAt),
            "captureEpoch": record.captureEpoch.rawValue,
            "statusFamily": record.statusFamily as Any,
            "latencyMilliseconds": record.latencyMilliseconds as Any,
            "attributionIDs": record.attributionIDs,
            "markerID": record.markerID?.uuidString as Any,
            "unavailableReason": record.unavailableReason?.rawValue as Any
        ]
        if !redactExactScope {
            payload["method"] = record.method as Any
            payload["scheme"] = record.scheme?.rawValue as Any
            payload["host"] = record.host as Any
            payload["port"] = record.port as Any
            payload["path"] = record.path as Any
            payload["sessionID"] = record.sessionID?.uuidString as Any
        }
        return payload
    }

    private func cursorDictionary(_ cursor: DiagnosticObservationCursor) -> [String: Any] {
        [
            "runID": cursor.runID.rawValue.uuidString,
            "ownerID": cursor.ownerID,
            "captureEpoch": cursor.captureEpoch.rawValue,
            "lastSequence": cursor.lastSequence
        ]
    }

    private func disclosedEvidenceDictionary(_ record: DiagnosticEvidenceRecord) -> [String: Any] {
        disclosedEvidenceDictionary(from: DiagnosticRunEvidenceMaterializer.disclosed(record))
    }

    private func disclosedEvidenceDictionary(from record: DiagnosticEvidenceDisclosedRecord) -> [String: Any] {
        [
            "evidenceID": record.id.uuidString,
            "runID": record.runID.rawValue.uuidString,
            "ownerID": record.ownerID,
            "createdAt": MCPApprovalPolicy.iso8601String(from: record.createdAt),
            "terminalStatus": record.terminalStatus.rawValue,
            "terminalAt": MCPApprovalPolicy.iso8601String(from: record.terminalAt),
            "hypothesisSummary": record.hypothesisSummary,
            "conclusionOutcome": record.conclusionOutcome?.rawValue as Any,
            "conclusionReasonCode": record.conclusionReasonCode?.rawValue as Any,
            "confidence": record.confidence?.rawValue as Any,
            "matchedRequestCount": record.matchedRequestCount,
            "matcherMissCount": record.matcherMissCount,
            "droppedObservationCount": record.droppedObservationCount,
            "isEvidenceComplete": record.isEvidenceComplete,
            "cleanupVerified": record.cleanupVerified,
            "evidenceDigest": record.evidenceDigest,
            "observationCount": record.observationCount
        ]
    }

    private func preparationDictionary(
        _ preparation: DiagnosticRunRecheckPreparation,
        redactExactScope: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "sourceRunID": preparation.sourceRunID.rawValue.uuidString,
            "sourceEvidenceID": preparation.sourceEvidenceID.uuidString,
            "expectedOutcomeSummary": preparation.expectedOutcomeSummary,
            "cleanupPlanDescription": preparation.cleanupPlanDescription,
            "preparedAt": MCPApprovalPolicy.iso8601String(from: preparation.preparedAt),
            "expiresAt": MCPApprovalPolicy.iso8601String(from: preparation.expiresAt),
            "isCompatible": preparation.isCompatible,
            "incompatibilityReason": preparation.incompatibilityReason?.rawValue as Any,
            "referencePreviews": preparation.referencePreviews.map { preview in
                [
                    "kind": preview.reference.kind.rawValue,
                    "opaqueID": preview.reference.opaqueID,
                    "relationship": preview.reference.relationship.rawValue,
                    "preview": recreationPreviewRaw(preview.preview)
                ] as [String: Any]
            }
        ]
        if !redactExactScope {
            payload["scopes"] = preparation.scopes.map(scopeDictionary)
        } else {
            payload["scopeCount"] = preparation.scopes.count
        }
        return payload
    }

    private func recreationPreviewRaw(_ preview: DiagnosticRunEffectRecreationPreview) -> [String: Any] {
        switch preview {
        case .supported(let revision, let changed):
            return [
                "state": "supported",
                "currentTargetRevision": revision as Any,
                "revisionChanged": changed
            ]
        case .unsupported:
            return ["state": "unsupported"]
        case .targetMissing:
            return ["state": "targetMissing"]
        }
    }

    private func recheckResultDictionary(_ result: DiagnosticRunRecheckResult) -> [String: Any] {
        [
            "sourceRunID": result.sourceRunID.rawValue.uuidString,
            "outcome": regressionOutcomeRaw(result.outcome),
            "recreatedReferences": result.recreatedReferences.map {
                [
                    "kind": $0.kind.rawValue,
                    "opaqueID": $0.opaqueID,
                    "relationship": $0.relationship.rawValue
                ] as [String: Any]
            },
            "cleanupVerified": result.cleanupProof.verifiedClean,
            "remainingLiveEffectCount": result.cleanupProof.remainingLiveEffectCount,
            "completedAt": MCPApprovalPolicy.iso8601String(from: result.completedAt)
        ]
    }

    private func regressionOutcomeRaw(_ outcome: DiagnosticRunRegressionOutcome) -> [String: Any] {
        switch outcome {
        case .stillHolds:
            return ["kind": "stillHolds"]
        case .regressionDetected:
            return ["kind": "regressionDetected"]
        case .inconclusive(let reason):
            return ["kind": "inconclusive", "reasonCode": reason.rawValue]
        }
    }

    private func encodeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Failed to encode diagnostic evidence export.")
        }
        return dictionary
    }

    // MARK: - Policy / approval

    private func requireAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            throw MCPStructuredError(
                code: .policyDenied,
                message: "Profile or policy denies \(capability.rawValue)."
            )
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
        let reason = "\(toolName) requires in-app approval to recreate reviewed diagnostic-run effects."
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

    private func recordAudit(client: MCPClientRecord, targetID: String, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalApplied,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "\(MCPCapabilityID.diagnosticRunLifecycle.rawValue):\(targetID)",
                detail: detail
            )
        )
    }

    private func structuredRunError(_ error: DiagnosticRunError) -> MCPStructuredError {
        switch error {
        case .notOwner:
            return MCPStructuredError(code: .policyDenied, message: error.errorDescription ?? "Not owner.")
        case .runNotFound, .evidenceNotFound:
            return MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "Not found.")
        case .quotaExceeded(let reason), .evidenceQuotaExceeded(let reason):
            return MCPStructuredError(code: .conflict, message: reason)
        case .cleanupNotVerified, .cleanupRequired:
            return MCPStructuredError(code: .conflict, message: error.errorDescription ?? "Cleanup not verified.")
        case .illegalTransition, .invalidScopes, .invalidHypothesis, .invalidLifetime,
             .conclusionRequired, .staleTarget, .attachRejected, .observationUnavailable,
             .cursorExpired, .storeUnavailable, .evidenceTampered:
            return MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "Invalid diagnostic-run request.")
        }
    }

    private func structuredRecheckError(_ error: DiagnosticRunRecheckError) -> MCPStructuredError {
        switch error {
        case .evidenceNotFound:
            return MCPStructuredError(code: .malformedRequest, message: "Diagnostic evidence record not found.")
        case .notOwner:
            return MCPStructuredError(code: .policyDenied, message: "Diagnostic evidence is owned by another client.")
        case .sourceNotTerminal:
            return MCPStructuredError(code: .malformedRequest, message: "Source evidence is not a closed terminal record.")
        case .preparationExpired:
            return MCPStructuredError(code: .staleProposal, message: "Diagnostic re-check preparation expired.")
        }
    }
}
