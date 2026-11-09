import Foundation

/// Pending propose→apply plan for activating one OpenAPI mock pack.
struct OpenAPIMockPackStartPlan: Equatable, Sendable {
    var packID: OpenAPIMockPackID
    var clientID: String
    var bookmark: OpenAPIDocumentBookmark
    var origin: OpenAPIMockOrigin
    var ttl: TimeInterval
    var conflictStrategy: OpenAPIMockConflictStrategy
    var compiled: OpenAPIMockCompiledPack
    var effectSummary: String
}

/// MCP surface for OpenAPI mock-pack preview, one-approval activate, status, and owner-scoped stop.
///
/// Concurrency: `@MainActor` — mutates coordinator, proposal, and approval stores on the main actor.
@MainActor
final class MCPOpenAPIMockPackService {
    private let packCoordinator: OpenAPIMockPackCoordinator
    private let proposalCoordinator: MCPProposalCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private let schemaStore: OpenAPISchemaStore
    private let sessionStore: SessionStore?
    private var plansByProposalToken: [String: OpenAPIMockPackStartPlan] = [:]

    private var policyEvaluator: MCPPolicyEvaluator {
        MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
    }

    init(
        packCoordinator: OpenAPIMockPackCoordinator,
        proposalCoordinator: MCPProposalCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore,
        schemaStore: OpenAPISchemaStore = OpenAPISchemaStore(),
        sessionStore: SessionStore? = nil
    ) {
        self.packCoordinator = packCoordinator
        self.proposalCoordinator = proposalCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        self.grantStore = grantStore
        self.auditStore = auditStore
        self.schemaStore = schemaStore
        self.sessionStore = sessionStore
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "openapi_pack_preview":
            return try await preview(arguments: arguments, client: client)
        case "propose_openapi_pack_start":
            return try await proposeStart(arguments: arguments, client: client)
        case "apply_openapi_pack_start":
            return try await applyStart(arguments: arguments, client: client)
        case "openapi_pack_status":
            return try await status(arguments: arguments, client: client)
        case "openapi_pack_stop":
            return try await stop(arguments: arguments, client: client)
        case "openapi_validate_session":
            return try await validateSession(arguments: arguments, client: client)
        case "openapi_generate_mock":
            return try await generateMock(arguments: arguments, client: client)
        case "openapi_import_spec":
            return try await importSpec(arguments: arguments, client: client)
        case "mocker_export_suite":
            return try await exportMockerSuite(arguments: arguments, client: client)
        case "mocker_validate_fixture":
            return try await validateMockerFixture(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown OpenAPI / Mocker tool: \(name).")
        }
    }

    /// Serving pack count owned by `clientID` for cleanup status.
    func unresolvedPackCount(forClientID clientID: String) -> Int {
        packCoordinator.activeCount(ownedBy: clientID)
    }

    /// Stops serving packs and invalidates leftover activation proposals for one client.
    func stopAll(ownedBy clientID: String) async {
        await packCoordinator.stopAll(ownedBy: clientID)
        invalidatePlans(ownedBy: clientID)
    }

    // MARK: - Tools

    private func preview(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        let compiled = try compileFromArguments(arguments)
        let ttl = try parseTTL(arguments["ttlSeconds"])
        let strategy = try parseConflictStrategy(arguments["conflictStrategy"], default: .refuse)
        let packID = OpenAPIMockPackID(rawValue: UUID())
        let decision = await packCoordinator.previewActivation(
            compiled: compiled,
            owner: .mcpClient(id: client.id, displayName: client.displayName),
            ttl: ttl,
            conflictStrategy: strategy,
            packID: packID
        )
        return [
            "schemaVersion": 1,
            "payload": previewPayload(compiled: compiled, ttl: ttl, decision: decision)
        ]
    }

    private func proposeStart(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockLifecycle)
        let bookmark = try parseBookmark(arguments["openapiDocumentBookmarkRef"])
        let compiled = try compileFromArguments(arguments)
        let ttl = try parseTTL(arguments["ttlSeconds"])
        let strategy = try parseConflictStrategy(arguments["conflictStrategy"], default: .refuse)
        let packID = OpenAPIMockPackID(rawValue: UUID())
        let owner = OpenAPIMockPackOwner.mcpClient(id: client.id, displayName: client.displayName)
        let decision = await packCoordinator.previewActivation(
            compiled: compiled,
            owner: owner,
            ttl: ttl,
            conflictStrategy: strategy,
            packID: packID
        )
        if case .refusedBusy = decision {
            throw MCPStructuredError(code: .conflict, message: OpenAPIMockPackError.ownerSlotBusy.errorDescription ?? "Owner slot busy.")
        }
        if case .refusedBudget(let error) = decision {
            throw MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "Budget refused.")
        }
        if case .refusedConflicts(let rules) = decision, strategy == .refuse {
            throw MCPStructuredError(
                code: .conflict,
                message: OpenAPIMockPackError.overlappingRules(rules).errorDescription ?? "Overlapping rules.",
                details: ["conflictCount": "\(rules.count)"]
            )
        }

        let effectSummary = "Serve OpenAPI mock pack at \(compiled.origin.displayString) (\(compiled.routes.count) routes, TTL \(Int(ttl))s)."
        let plan = OpenAPIMockPackStartPlan(
            packID: packID,
            clientID: client.id,
            bookmark: bookmark,
            origin: compiled.origin,
            ttl: ttl,
            conflictStrategy: strategy,
            compiled: compiled,
            effectSummary: effectSummary
        )
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .openAPIMockLifecycle,
            argumentDigest: digest,
            targetRevision: nil,
            targetLockKey: "openapi-mock-pack:\(packID.rawValue.uuidString)"
        )
        plansByProposalToken[proposal.token] = plan
        var payload = previewPayload(compiled: compiled, ttl: ttl, decision: decision)
        payload["proposalToken"] = proposal.token
        payload["expiresAt"] = MCPApprovalPolicy.iso8601String(from: proposal.expiresAt)
        payload["proposedPackID"] = packID.rawValue.uuidString
        payload["conflictStrategy"] = strategy.rawValue
        payload["effectSummary"] = effectSummary
        payload["riskTier"] = MCPCapabilityID.openAPIMockLifecycle.riskTier.rawValue
        payload["targetLockKey"] = proposal.targetLockKey
        return ["schemaVersion": 1, "payload": payload]
    }

    private func applyStart(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockLifecycle)
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty,
              let proposal = proposalCoordinator.proposal(forToken: proposalToken),
              proposal.clientID == client.id,
              proposal.capability == .openAPIMockLifecycle,
              let plan = plansByProposalToken[proposalToken],
              plan.clientID == client.id else {
            if let token = arguments["proposalToken"] as? String {
                approvalStore.invalidate(proposalToken: token)
                plansByProposalToken.removeValue(forKey: token)
            }
            throw MCPStructuredError(code: .staleProposal, message: "OpenAPI mock-pack proposal is stale or unknown.")
        }
        try resolveLifecycleApproval(
            toolName: "apply_openapi_pack_start",
            arguments: arguments,
            client: client,
            capability: .openAPIMockLifecycle,
            proposalToken: proposalToken,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )
        let digest = proposal.argumentDigest
        var appliedPack: OpenAPIMockPack?
        let result: MCPProposalApplyResult
        do {
            result = try await proposalCoordinator.applyProposal(
                token: proposalToken,
                clientID: client.id,
                capability: .openAPIMockLifecycle,
                argumentDigest: digest,
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: client.id,
                    targetKind: .openAPIMockPack,
                    targetID: plan.packID.rawValue.uuidString,
                    baselineRevision: nil,
                    intendedChangeDigest: digest,
                    rollbackSnapshot: nil,
                    expiresAt: MCPApprovalPolicy.expiration()
                ),
                performMutation: {
                    appliedPack = try await self.packCoordinator.activate(
                        compiled: plan.compiled,
                        owner: .mcpClient(id: client.id, displayName: client.displayName),
                        documentBookmark: plan.bookmark,
                        ttl: plan.ttl,
                        conflictStrategy: plan.conflictStrategy,
                        mcpProvenance: MCPProvenance(
                            clientID: client.id,
                            operationID: proposalToken,
                            capability: .openAPIMockLifecycle,
                            createdAt: Date()
                        ),
                        packID: plan.packID
                    )
                    return nil
                },
                idempotencyKey: idempotencyKey(from: arguments, proposalToken: proposalToken)
            )
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        } catch let error as OpenAPIMockPackError {
            throw structuredPackError(error)
        }
        plansByProposalToken.removeValue(forKey: proposalToken)
        let persistedPack = await packCoordinator.pack(id: plan.packID)
        guard let pack = appliedPack ?? persistedPack else {
            throw MCPStructuredError(code: .internalFailure, message: "OpenAPI mock pack missing after apply.")
        }
        recordApplied(client: client, targetID: pack.id.rawValue.uuidString, detail: plan.effectSummary)
        var payload = packDictionary(pack)
        payload["transactionID"] = result.transactionID
        payload["appliedAt"] = MCPApprovalPolicy.iso8601String(from: result.appliedAt)
        return ["schemaVersion": 1, "payload": payload]
    }

    private func status(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        let owner = OpenAPIMockPackOwner.mcpClient(id: client.id, displayName: client.displayName)
        if let idString = arguments["packID"] as? String, let uuid = UUID(uuidString: idString) {
            let id = OpenAPIMockPackID(rawValue: uuid)
            guard let pack = await packCoordinator.pack(id: id), pack.owner.ownerID == client.id else {
                throw MCPStructuredError(code: .malformedRequest, message: "packID not found for this client.")
            }
            return ["schemaVersion": 1, "payload": packDictionary(pack)]
        }
        let packs = await packCoordinator.packs(ownedBy: owner)
        return [
            "schemaVersion": 1,
            "payload": [
                "items": packs.map(packDictionary),
                "count": packs.count,
                "servingCount": packs.filter(\.isServing).count
            ] as [String: Any]
        ]
    }

    private func stop(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockLifecycle)
        guard let idString = arguments["packID"] as? String, let uuid = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "packID is required.")
        }
        let packID = OpenAPIMockPackID(rawValue: uuid)
        do {
            let pack = try await packCoordinator.stop(id: packID, requestingOwnerID: client.id)
            invalidatePlans(packID: packID)
            recordApplied(
                client: client,
                targetID: packID.rawValue.uuidString,
                detail: "Stopped OpenAPI mock pack \(packID.rawValue.uuidString)."
            )
            return ["schemaVersion": 1, "payload": packDictionary(pack)]
        } catch let error as OpenAPIMockPackError {
            throw structuredPackError(error)
        }
    }

    // MARK: - Compile / parse

    private func compileFromArguments(_ arguments: [String: Any]) throws -> OpenAPIMockCompiledPack {
        let bookmark = try parseBookmark(arguments["openapiDocumentBookmarkRef"])
        let document = try OpenAPIMockDocumentReader.data(from: bookmark)
        let origin = try parseOriginOverride(arguments)
        let packID = OpenAPIMockPackID(rawValue: UUID())
        do {
            return try OpenAPIMockCompiler.compile(
                OpenAPIMockCompileRequest(document: document, packID: packID, originOverride: origin)
            )
        } catch let error as OpenAPIMockCompilerError {
            throw MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "OpenAPI compile failed.")
        } catch let error as OpenAPIMockPackError {
            throw structuredPackError(error)
        }
    }

    private func parseBookmark(_ raw: Any?) throws -> OpenAPIDocumentBookmark {
        guard let ref = raw as? String, let bookmark = OpenAPIDocumentBookmark(ref: ref) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "openapiDocumentBookmarkRef must be base64-encoded bookmark data."
            )
        }
        return bookmark
    }

    private func parseOriginOverride(_ arguments: [String: Any]) throws -> OpenAPIMockOrigin? {
        let host = (arguments["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isEmpty else { return nil }
        let schemeRaw = (arguments["scheme"] as? String) ?? "https"
        guard let scheme = SessionScheme(rawValue: schemeRaw) else {
            throw MCPStructuredError(code: .malformedRequest, message: "scheme must be http or https.")
        }
        let port = arguments["port"] as? Int
        return OpenAPIMockOrigin(scheme: scheme, host: host, port: port)
    }

    private func parseTTL(_ raw: Any?) throws -> TimeInterval {
        guard let raw else { return OpenAPIMockPackBudget.defaultTTL }
        let value: TimeInterval
        if let number = raw as? Int {
            value = TimeInterval(number)
        } else if let number = raw as? Double {
            value = number
        } else {
            throw MCPStructuredError(code: .malformedRequest, message: "ttlSeconds must be a number.")
        }
        do {
            try OpenAPIMockPackBudget.validateTTL(value)
        } catch let error as OpenAPIMockPackError {
            throw structuredPackError(error)
        }
        return value
    }

    private func parseConflictStrategy(_ raw: Any?, default fallback: OpenAPIMockConflictStrategy) throws -> OpenAPIMockConflictStrategy {
        guard let raw = raw as? String, !raw.isEmpty else { return fallback }
        guard let strategy = OpenAPIMockConflictStrategy(rawValue: raw) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "conflictStrategy must be refuse or replaceConflicts."
            )
        }
        return strategy
    }

    // MARK: - Disclosure

    private func previewPayload(
        compiled: OpenAPIMockCompiledPack,
        ttl: TimeInterval,
        decision: OpenAPIMockActivationDecision
    ) -> [String: Any] {
        let overlap: [OpenAPIMockOverlappingRule]
        switch decision {
        case .refusedConflicts(let rules): overlap = rules
        default: overlap = []
        }
        return [
            "originDisplay": compiled.origin.displayString,
            "routeCount": compiled.routes.count,
            "ttlSeconds": Int(ttl),
            "conflictCount": overlap.count,
            "conflicts": overlapDictionaries(overlap),
            "unsupported": compiled.report.unsupported.map {
                [
                    "method": $0.method as Any,
                    "template": $0.template as Any,
                    "feature": $0.feature.rawValue,
                    "detail": $0.detail
                ] as [String: Any]
            },
            "operations": compiled.report.operations.map {
                [
                    "method": $0.method,
                    "template": $0.template,
                    "variantCount": $0.variantCount,
                    "defaultVariantID": $0.defaultVariantID,
                    "generatedVariantCount": $0.generatedVariantCount,
                    "declaredExampleCount": $0.declaredExampleCount
                ] as [String: Any]
            },
            "coverage": [
                "supportedOperationCount": compiled.report.coverage.supportedOperationCount,
                "variantCount": compiled.report.coverage.variantCount,
                "generatedVariantCount": compiled.report.coverage.generatedVariantCount,
                "declaredExampleCount": compiled.report.coverage.declaredExampleCount,
                "unsupportedFeatureCount": compiled.report.coverage.unsupportedFeatureCount,
                "conflictCount": compiled.report.coverage.conflictCount
            ] as [String: Any],
            "activationAllowed": {
                if case .allowed = decision { return true }
                return false
            }(),
            "schemaValidOutputIsNotAuthorization": true
        ]
    }

    private func packDictionary(_ pack: OpenAPIMockPack) -> [String: Any] {
        var payload: [String: Any] = [
            "packID": pack.id.rawValue.uuidString,
            "state": pack.state.rawValue,
            "originDisplay": pack.origin.displayString,
            "hits": pack.metrics.hits,
            "misses": pack.metrics.misses,
            "operationHits": pack.metrics.operationHits,
            "coverage": [
                "supportedOperationCount": pack.coverage.supportedOperationCount,
                "variantCount": pack.coverage.variantCount,
                "unsupportedFeatureCount": pack.coverage.unsupportedFeatureCount,
                "conflictCount": pack.coverage.conflictCount
            ] as [String: Any]
        ]
        if let lastMatchedAt = pack.metrics.lastMatchedAt {
            payload["lastMatchedAt"] = MCPApprovalPolicy.iso8601String(from: lastMatchedAt)
        }
        if let startedAt = pack.startedAt {
            payload["startedAt"] = MCPApprovalPolicy.iso8601String(from: startedAt)
        }
        if let expiresAt = pack.expiresAt {
            payload["expiresAt"] = MCPApprovalPolicy.iso8601String(from: expiresAt)
        }
        if let stoppedAt = pack.stoppedAt {
            payload["stoppedAt"] = MCPApprovalPolicy.iso8601String(from: stoppedAt)
        }
        return payload
    }

    private func overlapDictionaries(_ rules: [OpenAPIMockOverlappingRule]) -> [[String: Any]] {
        rules.map {
            [
                "ruleID": $0.ruleID.uuidString,
                "method": $0.method,
                "pathDescription": $0.pathDescription
            ]
        }
    }

    // MARK: - Approval / audit

    private func requireAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "OpenAPI mock-pack tools denied by profile or policy."
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
        let reason = "\(toolName) requires in-app approval to activate an OpenAPI mock pack."
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

    private func recordApplied(client: MCPClientRecord, targetID: String, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalApplied,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "\(MCPCapabilityID.openAPIMockLifecycle.rawValue):\(targetID)",
                detail: detail
            )
        )
    }

    private func invalidatePlans(ownedBy clientID: String) {
        let tokens = plansByProposalToken.compactMap { token, plan in
            plan.clientID == clientID ? token : nil
        }
        for token in tokens {
            approvalStore.invalidate(proposalToken: token)
            plansByProposalToken.removeValue(forKey: token)
        }
    }

    private func invalidatePlans(packID: OpenAPIMockPackID) {
        let tokens = plansByProposalToken.compactMap { token, plan in
            plan.packID == packID ? token : nil
        }
        for token in tokens {
            approvalStore.invalidate(proposalToken: token)
            plansByProposalToken.removeValue(forKey: token)
        }
    }

    private func structuredPackError(_ error: OpenAPIMockPackError) -> MCPStructuredError {
        switch error {
        case .overlappingRules(let rules):
            return MCPStructuredError(
                code: .conflict,
                message: error.errorDescription ?? "Overlapping rules.",
                details: ["conflictCount": "\(rules.count)"]
            )
        case .ownerSlotBusy, .packIsServing:
            return MCPStructuredError(code: .conflict, message: error.errorDescription ?? "Pack conflict.")
        case .notOwner:
            return MCPStructuredError(code: .policyDenied, message: error.errorDescription ?? "Not owner.")
        case .packNotFound:
            return MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "Pack not found.")
        default:
            return MCPStructuredError(code: .malformedRequest, message: error.errorDescription ?? "OpenAPI mock pack error.")
        }
    }

    private func validateSession(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        guard let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID must be a valid UUID.")
        }
        guard let sessionStore else {
            throw MCPStructuredError(code: .internalFailure, message: "Session store is not available.")
        }
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionIDString) not found.")
        }
        let report = await OpenAPIContractValidator.validate(session: session, schemaStore: schemaStore)
        let data = try JSONEncoder().encode(report)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func generateMock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        guard let pathTemplate = arguments["pathTemplate"] as? String, !pathTemplate.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "pathTemplate is required.")
        }
        let method = (arguments["method"] as? String ?? "GET").uppercased()
        let statusCode = arguments["statusCode"] as? String ?? "200"
        let modeString = arguments["mode"] as? String ?? "validDefault"
        let mode = OpenAPIMockGenerationMode(rawValue: modeString) ?? .validDefault

        guard let match = await schemaStore.match(method: method, path: pathTemplate) else {
            throw MCPStructuredError(code: .malformedRequest, message: "No OpenAPI operation matches \(method) \(pathTemplate).")
        }
        guard let respDef = match.operation.responses[statusCode] ?? match.operation.responses["default"] else {
            throw MCPStructuredError(code: .malformedRequest, message: "No response definition for status \(statusCode).")
        }
        guard let schema = respDef.content.first(where: { $0.key.lowercased().contains("json") })?.value else {
            throw MCPStructuredError(code: .malformedRequest, message: "No JSON response schema found for status \(statusCode).")
        }

        let mockData = try OpenAPISyntheticMockGenerator.generateMockData(for: schema, mode: mode)
        let jsonString = String(data: mockData, encoding: .utf8) ?? "{}"

        return [
            "operationId": match.operation.id,
            "pathTemplate": match.operation.pathTemplate,
            "statusCode": statusCode,
            "mode": mode.rawValue,
            "mockPayload": jsonString
        ]
    }

    private func importSpec(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        let specData: Data
        if let base64 = arguments["specBase64"] as? String, let decoded = Data(base64Encoded: base64) {
            specData = decoded
        } else if let jsonString = arguments["specJSON"] as? String {
            specData = Data(jsonString.utf8)
        } else if let bookmarkRef = arguments["openapiDocumentBookmarkRef"] as? String,
                  let bookmark = OpenAPIDocumentBookmark(ref: bookmarkRef) {
            specData = try OpenAPIMockDocumentReader.data(from: bookmark)
        } else {
            throw MCPStructuredError(code: .malformedRequest, message: "specJSON, specBase64, or openapiDocumentBookmarkRef is required.")
        }

        do {
            let doc = try await schemaStore.importDocument(data: specData)
            return [
                "title": doc.title,
                "version": doc.version,
                "operationCount": doc.operations.count,
                "servers": doc.servers
            ]
        } catch let error as OpenAPISchemaReaderError {
            throw MCPStructuredError(code: .malformedRequest, message: error.localizedDescription)
        }
    }

    private func exportMockerSuite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        guard let sessionStore else {
            throw MCPStructuredError(code: .internalFailure, message: "Session store is not available.")
        }
        let frameworkString = arguments["framework"] as? String ?? "mocker"
        let framework = SwiftMockFramework(rawValue: frameworkString) ?? .mocker
        let fixtureModeString = arguments["fixtureMode"] as? String ?? "inline"
        let fixtureMode = SwiftMockFixtureMode(rawValue: fixtureModeString) ?? .inlineString
        let className = arguments["testClassName"] as? String ?? "GeneratedNetworkFlowTests"
        let methodName = arguments["testMethodName"] as? String ?? "testUserJourneyFlow"

        let targetSessions: [SessionRecord]
        if let sessionIDs = arguments["sessionIDs"] as? [String] {
            let uuids = sessionIDs.compactMap { UUID(uuidString: $0) }
            targetSessions = sessionStore.sessions.filter { uuids.contains($0.id) }
        } else if let sessionID = arguments["sessionID"] as? String, let uuid = UUID(uuidString: sessionID) {
            targetSessions = sessionStore.sessions.filter { $0.id == uuid }
        } else {
            targetSessions = Array(sessionStore.sessions.prefix(20))
        }

        guard !targetSessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No matching sessions found to export.")
        }

        let options = SwiftMockExportOptions(
            framework: framework,
            fixtureMode: fixtureMode,
            testClassName: className,
            testMethodName: methodName
        )
        let suite = SwiftMockerExporter.generateSuite(for: targetSessions, options: options)

        var fixtureDicts: [[String: Any]] = []
        for file in suite.fixtureFiles {
            fixtureDicts.append([
                "filename": file.filename,
                "relativePath": file.relativePath,
                "mimeType": file.mimeType,
                "dataBase64": file.data.base64EncodedString()
            ])
        }

        return [
            "swiftSourceCode": suite.swiftSourceCode,
            "sessionCount": suite.sessionCount,
            "framework": suite.framework.rawValue,
            "fixtureFiles": fixtureDicts
        ]
    }

    private func validateMockerFixture(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .openAPIMockInspect)
        guard let sessionStore else {
            throw MCPStructuredError(code: .internalFailure, message: "Session store is not available.")
        }
        guard let sessionIDString = arguments["sessionID"] as? String, let sessionID = UUID(uuidString: sessionIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID is required.")
        }
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionIDString) not found.")
        }
        guard let wireBody = session.response?.bodyData else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionIDString) has no response body.")
        }

        let fixtureData: Data
        if let base64 = arguments["fixtureBase64"] as? String, let decoded = Data(base64Encoded: base64) {
            fixtureData = decoded
        } else if let jsonString = arguments["fixtureJSON"] as? String {
            fixtureData = Data(jsonString.utf8)
        } else {
            throw MCPStructuredError(code: .malformedRequest, message: "fixtureJSON or fixtureBase64 is required.")
        }

        let report = MockerDriftValidator.validate(
            fixtureData: fixtureData,
            wireData: wireBody,
            wireStatusCode: session.response?.statusCode
        )
        let reportData = try JSONEncoder().encode(report)
        return (try JSONSerialization.jsonObject(with: reportData) as? [String: Any]) ?? [:]
    }
}
