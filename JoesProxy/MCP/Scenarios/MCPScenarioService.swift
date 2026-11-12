import Foundation

/// Summary returned by scenario MCP tools (AI-4).
struct MCPScenarioRecordSummaryDTO: Equatable, Sendable, Codable {
    var scenarioID: String
    var name: String
    var phase: MCPScenarioPhase
    var originatingClientID: String
    var riskTier: String?
    var armedAt: Date?
    var activatedAt: Date?
    var cleanupCompletedAt: Date?
    var evidenceCount: Int
    var assertionResultCount: Int
    var hasReport: Bool
    var lastError: String?
}

/// Observation payload for `get_test_observations` (AI-4).
struct MCPScenarioObservationsDTO: Equatable, Sendable, Codable {
    var scenarioID: MCPScenarioID
    var phase: MCPScenarioPhase
    var evidence: [MCPScenarioEvidenceRecord]
    var warnings: [String]
}

/// Production adapter for AI-4 scenario MCP tools.
///
/// Concurrency: `@MainActor` — lifecycle, policy, and approval state stay on the main actor.
@MainActor
final class MCPScenarioService {
    private let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let scenarioStore: MCPScenarioStore
    private let runtimeServiceProvider: () -> MCPScenarioRuntimeService?
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let approvalStore: MCPApprovalStore
    private let auditStore: MCPAuditStore
    private let validationRunID: MCPValidationRunID?
    private let policyEvaluator: MCPPolicyEvaluator
    private let loopbackPolicyReader: () -> LoopbackDestinationPolicy
    private let encoder: JSONEncoder

    init(
        lifecycleCoordinator: MCPScenarioLifecycleCoordinator,
        scenarioStore: MCPScenarioStore,
        runtimeServiceProvider: @escaping () -> MCPScenarioRuntimeService?,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore? = nil,
        approvalStore: MCPApprovalStore,
        auditStore: MCPAuditStore,
        validationRunID: MCPValidationRunID? = nil,
        loopbackPolicyReader: @escaping () -> LoopbackDestinationPolicy = { .disabled }
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        self.scenarioStore = scenarioStore
        self.runtimeServiceProvider = runtimeServiceProvider
        self.policyStore = policyStore
        let resolvedGrantStore = grantStore ?? MCPClientGrantStore()
        self.grantStore = resolvedGrantStore
        self.approvalStore = approvalStore
        self.auditStore = auditStore
        self.validationRunID = validationRunID
        self.policyEvaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: resolvedGrantStore)
        self.loopbackPolicyReader = loopbackPolicyReader
        self.encoder = MCPScenarioJSONCodec.makeEncoder()
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "draft_test_scenario":
            return try payloadDictionary(draftScenario(arguments: arguments, client: client))
        case "validate_test_scenario":
            return try payloadDictionary(validateScenario(arguments: arguments, client: client))
        case "preview_test_scenario":
            return try payloadDictionary(previewScenario(arguments: arguments, client: client))
        case "request_test_scenario_approval":
            return try requestScenarioApproval(arguments: arguments, client: client)
        case "arm_test_scenario":
            return try payloadDictionary(try armScenario(arguments: arguments, client: client))
        case "activate_test_scenario":
            return try payloadDictionary(try await activateScenario(arguments: arguments, client: client))
        case "get_test_observations":
            return try payloadDictionary(getObservations(arguments: arguments, client: client))
        case "evaluate_test_assertions":
            return try payloadDictionary(try evaluateAssertions(arguments: arguments, client: client))
        case "stop_test_scenario":
            return try payloadDictionary(try await stopScenario(arguments: arguments, client: client))
        case "cleanup_test_scenario":
            return try payloadDictionary(try await cleanupScenario(arguments: arguments, client: client))
        case "get_test_report":
            return try payloadDictionary(getReport(arguments: arguments, client: client))
        case "record_test_marker":
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "External test markers are not yet ingested; use captured proxy assertions instead."
            )
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown scenario tool: \(name).")
        }
    }

    // MARK: - Read-only tools

    private func draftScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioRecordSummaryDTO {
        try requireScenarioAccess(client: client)
        let draft = try parseDraft(from: arguments, client: client)
        let record = try lifecycleCoordinator.createDraft(from: draft, validationRunID: validationRunID)
        auditScenarioEvent(client: client, reason: "draft_test_scenario", detail: record.id.rawValue)
        return summary(for: record)
    }

    private func validateScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioValidationResultDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        let record = try ownedRecord(scenarioID: scenarioID, client: client)
        guard record.phase == .draft else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "validate_test_scenario requires a scenario in draft phase."
            )
        }
        let result = try lifecycleCoordinator.validate(
            scenarioID: scenarioID,
            loopbackPolicy: loopbackPolicyReader()
        )
        auditScenarioEvent(client: client, reason: "validate_test_scenario", detail: scenarioID.rawValue)
        return result
    }

    private func previewScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioValidationResultDTO {
        try requireScenarioAccess(client: client)
        let draft = try parseDraft(from: arguments, client: client)
        return try MCPScenarioValidationService.validate(
            draft: draft,
            loopbackPolicy: loopbackPolicyReader()
        )
    }

    private func getObservations(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioObservationsDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        let record = try ownedRecord(scenarioID: scenarioID, client: client)
        // Evidence is a disclosure surface exactly like `sessionSummary` — it must route through
        // a resolved profile, not an unconditional assignment (the same bug class as the earlier
        // `provenance` leak). Gate on the SCENARIO's own declared disclosure profile, matching
        // `MCPScenarioObservationService.evaluateScenario`/`MCPScenarioReportBuilder`, which already
        // gate `get_test_report` this same way — not the calling client's assigned profile, since a
        // scenario can declare a stricter profile than its owning client's default.
        let profile = try policyStore.resolvedProfile(for: record.definition.disclosureProfileID)
        let evidence = profile.allowedFieldClasses.contains(.scenarioEvidence) ? record.observationEvidence : []
        return MCPScenarioObservationsDTO(
            scenarioID: scenarioID,
            phase: record.phase,
            evidence: evidence,
            warnings: observationWarnings(for: record)
        )
    }

    private func evaluateAssertions(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioEvaluationResultDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        _ = try ownedRecord(scenarioID: scenarioID, client: client)
        guard let runtime = runtimeServiceProvider() else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        let result = try runtime.evaluateScenario(scenarioID)
        auditScenarioEvent(client: client, reason: "evaluate_test_assertions", detail: scenarioID.rawValue)
        return result
    }

    private func getReport(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioReportDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        let record = try ownedRecord(scenarioID: scenarioID, client: client)
        guard let report = record.evaluationReport else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "Scenario has no evaluation report yet."
            )
        }
        return report
    }

    // MARK: - Approval-gated mutating tools

    private func requestScenarioApproval(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> [String: Any] {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        let record = try ownedRecord(scenarioID: scenarioID, client: client)
        guard record.phase == .awaitingApproval else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "request_test_scenario_approval requires awaitingApproval phase."
            )
        }
        try throwScenarioApprovalRequired(
            toolName: "request_test_scenario_approval",
            arguments: arguments,
            client: client,
            capability: activationCapability(for: record),
            record: record,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        return [:]
    }

    private func armScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> MCPScenarioRecordSummaryDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        var record = try ownedRecord(scenarioID: scenarioID, client: client)
        guard record.phase == .awaitingApproval else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "arm_test_scenario requires awaitingApproval phase."
            )
        }
        try resolveScenarioApproval(
            toolName: "arm_test_scenario",
            arguments: arguments,
            client: client,
            capability: activationCapability(for: record),
            record: record,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        record = try lifecycleCoordinator.approve(scenarioID: scenarioID)
        auditScenarioEvent(client: client, reason: "arm_test_scenario", detail: scenarioID.rawValue)
        return summary(for: record)
    }

    private func activateScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> MCPScenarioRecordSummaryDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        var record = try ownedRecord(scenarioID: scenarioID, client: client)
        guard record.phase == .armed else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "activate_test_scenario requires armed phase."
            )
        }
        let capability = activationCapability(for: record)
        try resolveScenarioApproval(
            toolName: "activate_test_scenario",
            arguments: arguments,
            client: client,
            capability: capability,
            record: record,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        _ = try MCPScenarioCompiler.compile(
            draft: MCPScenarioDraftInput.fromDefinition(record.definition),
            now: record.definition.createdAt,
            loopbackPolicy: loopbackPolicyReader()
        )
        guard let runtime = runtimeServiceProvider() else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        try await runtime.activateScenario(scenarioID)
        record = scenarioStore.scenario(id: scenarioID) ?? record
        auditScenarioEvent(client: client, reason: "activate_test_scenario", detail: scenarioID.rawValue)
        return summary(for: record)
    }

    private func stopScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> MCPScenarioRecordSummaryDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        _ = try ownedRecord(scenarioID: scenarioID, client: client)
        guard let runtime = runtimeServiceProvider() else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        let explicitOutcome = try optionalOutcome(from: arguments)
        await runtime.finishScenario(scenarioID, outcome: explicitOutcome)
        guard let record = scenarioStore.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        auditScenarioEvent(client: client, reason: "stop_test_scenario", detail: scenarioID.rawValue)
        return summary(for: record)
    }

    private func cleanupScenario(
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> MCPScenarioRecordSummaryDTO {
        try requireScenarioAccess(client: client)
        let scenarioID = try requiredScenarioID(from: arguments)
        _ = try ownedRecord(scenarioID: scenarioID, client: client)
        guard let runtime = runtimeServiceProvider() else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        let explicitOutcome = try optionalOutcome(from: arguments) ?? .canceled
        await runtime.finishScenario(scenarioID, outcome: explicitOutcome)
        guard let record = scenarioStore.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        auditScenarioEvent(client: client, reason: "cleanup_test_scenario", detail: scenarioID.rawValue)
        return summary(for: record)
    }

    // MARK: - Helpers

    private func requireScenarioAccess(client: MCPClientRecord) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: .scenarioLifecycle, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: .scenarioLifecycle,
                detail: "Scenario tools require Shareable profile.",
                validationRunID: validationRunID?.rawValue
            )
            throw MCPStructuredError(code: .policyDenied, message: "Scenario tools require Shareable profile.")
        }
    }

    private func ownedRecord(scenarioID: MCPScenarioID, client: MCPClientRecord) throws -> MCPScenarioRecord {
        guard let record = scenarioStore.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        guard record.definition.originatingClientID == client.id else {
            throw MCPStructuredError(code: .policyDenied, message: "Scenario is owned by another client.")
        }
        return record
    }

    private func parseDraft(from arguments: [String: Any], client: MCPClientRecord) throws -> MCPScenarioDraftInput {
        if var draftObject = arguments["draft"] as? [String: Any] {
            draftObject["originatingClientID"] = client.id
            guard JSONSerialization.isValidJSONObject(draftObject),
                  let data = try? JSONSerialization.data(withJSONObject: draftObject) else {
                throw MCPStructuredError(code: .malformedRequest, message: "draft must be a JSON object.")
            }
            var draft = try MCPScenarioJSONCodec.decodeDraft(from: data)
            draft.originatingClientID = client.id
            if draft.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.id = MCPScenarioID(rawValue: UUID().uuidString)
            }
            return draft
        }
        if let draftJSON = arguments["draftJSON"] as? String,
           let rawData = draftJSON.data(using: .utf8),
           var draftObject = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            draftObject["originatingClientID"] = client.id
            let data = try JSONSerialization.data(withJSONObject: draftObject)
            var draft = try MCPScenarioJSONCodec.decodeDraft(from: data)
            draft.originatingClientID = client.id
            if draft.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.id = MCPScenarioID(rawValue: UUID().uuidString)
            }
            return draft
        }
        throw MCPStructuredError(code: .malformedRequest, message: "draft or draftJSON is required.")
    }

    private func requiredScenarioID(from arguments: [String: Any]) throws -> MCPScenarioID {
        guard let raw = arguments["scenarioID"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "scenarioID is required.")
        }
        return MCPScenarioID(rawValue: raw)
    }

    private func optionalOutcome(from arguments: [String: Any]) throws -> MCPScenarioPhase? {
        guard let raw = arguments["outcome"] as? String,
              !raw.isEmpty else {
            return nil
        }
        guard let phase = MCPScenarioPhase(rawValue: raw) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown outcome phase \(raw).")
        }
        return phase
    }

    private func activationCapability(for record: MCPScenarioRecord) -> MCPCapabilityID {
        let highest = record.definition.faults
            .map(\.capabilityID)
            .max { $0.riskTier.severityRank < $1.riskTier.severityRank }
        guard let highest else { return .scenarioLifecycle }
        if highest.riskTier.severityRank >= MCPCapabilityRiskTier.openWorldTool.severityRank {
            return highest
        }
        return .scenarioLifecycle
    }

    private func resolveScenarioApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        record: MCPScenarioRecord,
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
            policyRevision: policyStore.policyRevision
        ) {
            return
        }
        if policyEvaluator.skipsApprovalNonce(capability: capability, client: client) {
            return
        }
        try throwScenarioApprovalRequired(
            toolName: toolName,
            arguments: boundArguments,
            client: client,
            capability: capability,
            record: record,
            mcpSessionID: mcpSessionID
        )
    }

    private func throwScenarioApprovalRequired(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        record: MCPScenarioRecord,
        mcpSessionID: String?
    ) throws -> Never {
        let digest = MCPArgumentDigest.normalized(arguments)
        let disclosure = record.validationResult?.approvalDisclosure
            ?? MCPScenarioCompiler.approvalDisclosure(for: record.definition)
        let reason = """
        \(toolName) for scenario \(record.definition.name): risk=\(disclosure.riskTier) \
        faults=\(disclosure.faultSummaries.joined(separator: "; ")) \
        cleanup=\(disclosure.cleanupSummary.joined(separator: "; "))
        """
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            mcpSessionID: mcpSessionID,
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
            return MCPStructuredError(code: .policyDenied, message: "Policy changed since approval was granted.")
        case .targetRevisionChanged:
            return MCPStructuredError(code: .malformedRequest, message: "Target revision changed since approval was granted.")
        }
    }

    private func summary(for record: MCPScenarioRecord) -> MCPScenarioRecordSummaryDTO {
        MCPScenarioRecordSummaryDTO(
            scenarioID: record.id.rawValue,
            name: record.definition.name,
            phase: record.phase,
            originatingClientID: record.definition.originatingClientID,
            riskTier: record.validationResult?.riskTier,
            armedAt: record.armedAt,
            activatedAt: record.activatedAt,
            cleanupCompletedAt: record.cleanupCompletedAt,
            evidenceCount: record.observationEvidence.count,
            assertionResultCount: record.assertionResults.count,
            hasReport: record.evaluationReport != nil,
            lastError: record.lastError
        )
    }

    private func observationWarnings(for record: MCPScenarioRecord) -> [String] {
        var warnings: [String] = []
        if record.phase == .observing,
           let activatedAt = record.activatedAt {
            let windowEnd = activatedAt.addingTimeInterval(record.definition.observationWindow.duration)
            if Date() < windowEnd {
                warnings.append("Observation window still open until \(ISO8601DateFormatter().string(from: windowEnd)).")
            }
        }
        if record.observationEvidence.isEmpty,
           record.phase == .evaluating || record.phase.isPrunableTerminal {
            warnings.append("No captured evidence was retained for this scenario.")
        }
        return warnings
    }

    private func auditScenarioEvent(client: MCPClientRecord, reason: String, detail: String?) {
        let reasonCode: String
        if let validationRunID {
            reasonCode = "self-validation:\(validationRunID.rawValue):\(reason)"
        } else {
            reasonCode = reason
        }
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: reasonCode,
                detail: detail,
                validationRunID: validationRunID?.rawValue
            )
        )
    }

    private func payloadDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Payload encoding failed.")
        }
        return object
    }
}
