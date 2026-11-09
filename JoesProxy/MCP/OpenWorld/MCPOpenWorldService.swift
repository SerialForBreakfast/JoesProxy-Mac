import Foundation

/// Production adapter for AH-5 open-world MCP tools.
///
/// Concurrency: `@MainActor` — approvals, policy, and store reads stay on the main actor;
/// bookmark execution awaits the executor (network I/O) without blocking the actor spin.
@MainActor
final class MCPOpenWorldService {
    private let bookmarkStore: any BookmarkStore
    private let sessionStore: any SessionStore
    private let responseOverrideStore: ResponseOverrideStore
    private let bookmarkExecutor: any BookmarkExecuting
    private let directOriginFetcher: any DirectOriginBodyFetching
    private let sessionMatcher: MCPExecutedSessionMatcher
    private let proposalCoordinator: MCPProposalCoordinator
    private let recoveryCoordinator: MCPRecoveryCoordinator
    private let operationCoordinator: MCPOperationCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let policyEvaluator: MCPPolicyEvaluator
    private let auditStore: MCPAuditStore
    private let runningProxyPort: () -> UInt16?
    private let throttleConfigurationReader: () -> NetworkThrottleConfiguration
    private let encoder: JSONEncoder

    init(
        bookmarkStore: any BookmarkStore,
        sessionStore: any SessionStore,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkExecutor: any BookmarkExecuting,
        directOriginFetcher: any DirectOriginBodyFetching = URLSessionDirectOriginBodyFetcher(),
        sessionMatcher: MCPExecutedSessionMatcher,
        proposalCoordinator: MCPProposalCoordinator,
        recoveryCoordinator: MCPRecoveryCoordinator,
        operationCoordinator: MCPOperationCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore? = nil,
        auditStore: MCPAuditStore,
        runningProxyPort: @escaping () -> UInt16?,
        throttleConfigurationReader: @escaping () -> NetworkThrottleConfiguration = { .defaults }
    ) {
        self.bookmarkStore = bookmarkStore
        self.sessionStore = sessionStore
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkExecutor = bookmarkExecutor
        self.directOriginFetcher = directOriginFetcher
        self.sessionMatcher = sessionMatcher
        self.proposalCoordinator = proposalCoordinator
        self.recoveryCoordinator = recoveryCoordinator
        self.operationCoordinator = operationCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        let resolvedGrantStore = grantStore ?? MCPClientGrantStore()
        self.grantStore = resolvedGrantStore
        self.policyEvaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: resolvedGrantStore)
        self.auditStore = auditStore
        self.runningProxyPort = runningProxyPort
        self.throttleConfigurationReader = throttleConfigurationReader
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        do {
            switch name {
            case "execute_bookmark":
                return try await executeBookmark(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "replay_request":
                return try await replayRequest(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "repro_replay_request":
                return try await replayReproRequest(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "recapture_session_body":
                return try await recaptureSessionBody(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "activate_map_remote":
                return try await activateMapRemote(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "activate_live_rewrite":
                return try await activateLiveRewrite(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "activate_collection_mock":
                return try await activateCollectionMock(arguments: arguments, client: client, mcpSessionID: mcpSessionID)
            case "live_media_probe_start":
                return try await startLiveMediaProbe(
                    arguments: arguments,
                    client: client,
                    mcpSessionID: mcpSessionID
                )
            default:
                throw MCPStructuredError(code: .malformedRequest, message: "Unknown open-world tool: \(name).")
            }
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        }
    }

    // MARK: - Execute / Replay

    private func executeBookmark(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .executeBookmark)
        guard let bookmarkIDString = arguments["bookmarkID"] as? String,
              let bookmarkID = UUID(uuidString: bookmarkIDString),
              let bookmark = bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "bookmarkID not found.")
        }
        let includeCredentials = arguments["includeCredentials"] as? Bool ?? false
        let prepared = BookmarkRequestEditing.preparedRequest(forExecution: bookmark.request)
        let disclosure = disclosure(
            for: prepared,
            includesCredentials: includeCredentials,
            expectedSideEffect: "Execute bookmark through the local proxy and capture the resulting session.",
            targetID: bookmarkID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "execute_bookmark",
            arguments: arguments,
            client: client,
            capability: .executeBookmark,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )
        return try await runExecution(
            request: prepared,
            includeCredentials: includeCredentials,
            client: client,
            capability: .executeBookmark,
            bookmark: bookmark
        )
    }

    private func replayRequest(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .replayRequest)
        guard let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID not found.")
        }
        let includeCredentials = arguments["includeCredentials"] as? Bool ?? false
        let prepared = BookmarkRequestEditing.preparedRequest(forExecution: session.request)
        let disclosure = disclosure(
            for: prepared,
            includesCredentials: includeCredentials,
            expectedSideEffect: "Replay the captured request through the local proxy.",
            targetID: sessionID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "replay_request",
            arguments: arguments,
            client: client,
            capability: .replayRequest,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )
        let bookmark = Bookmark(
            name: "mcp-replay-\(sessionID.uuidString.prefix(8))",
            request: prepared
        )
        return try await runExecution(
            request: prepared,
            includeCredentials: includeCredentials,
            client: client,
            capability: .replayRequest,
            bookmark: bookmark
        )
    }

    private func replayReproRequest(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .replayRequest)
        guard let method = arguments["method"] as? String,
              ["GET", "HEAD", "OPTIONS"].contains(method.uppercased()),
              let schemeValue = arguments["scheme"] as? String,
              let scheme = SessionScheme(rawValue: schemeValue),
              let host = arguments["host"] as? String,
              !host.isEmpty,
              host != "private-host.invalid",
              let path = arguments["path"] as? String,
              path.hasPrefix("/"),
              !path.contains(ReproPackageRedactor.placeholder) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "A reproduction replay requires a sanitized GET, HEAD, or OPTIONS request with a public host and path."
            )
        }
        let port = (arguments["port"] as? NSNumber)?.intValue
        let request = CapturedRequest(
            method: method.uppercased(),
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let disclosure = disclosure(
            for: request,
            includesCredentials: false,
            expectedSideEffect: "Replay one sanitized reproduction request through the local proxy.",
            targetID: arguments["packageSessionID"] as? String ?? "reproduction-request"
        )
        try resolveOpenWorldApproval(
            toolName: "repro_replay_request",
            arguments: arguments,
            client: client,
            capability: .replayRequest,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )
        let bookmark = Bookmark(name: "mcp-reproduction-replay", request: request)
        return try await runExecution(
            request: request,
            includeCredentials: false,
            client: client,
            capability: .replayRequest,
            bookmark: bookmark
        )
    }

    /// On-demand body recapture (P3, memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md
    /// §6): fetches a session's request directly against the real origin — deliberately NOT through
    /// the local proxy/`replay_request`'s path, which would re-apply `CaptureBodyLimiter`'s 1MB cap
    /// and defeat the point — then backfills that session's stored response body in place. Same
    /// capability/approval tier as `replay_request`: this still re-hits a live endpoint right now,
    /// with no guarantee the response matches what was originally captured.
    private func recaptureSessionBody(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .replayRequest)
        guard let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID not found.")
        }
        guard session.response != nil else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID has no response to recapture a body onto.")
        }
        let includeCredentials = arguments["includeCredentials"] as? Bool ?? false
        let prepared = BookmarkRequestEditing.preparedRequest(forExecution: session.request)
        let disclosure = disclosure(
            for: prepared,
            includesCredentials: includeCredentials,
            expectedSideEffect: "Fetch this request directly from the real origin server (bypassing the local proxy) to recapture up to \(SessionBodyRecaptureBudget.maxBodyBytes) bytes of its full response body onto this session.",
            targetID: sessionID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "recapture_session_body",
            arguments: arguments,
            client: client,
            capability: .replayRequest,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )

        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .openWorldExecuted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: MCPCapabilityID.replayRequest.rawValue,
                detail: "recapture \(prepared.method) \(prepared.host)"
            )
        )

        let result: DirectOriginFetchResult
        do {
            result = try await directOriginFetcher.fetch(
                request: prepared,
                includeCredentials: includeCredentials,
                maxBodyBytes: SessionBodyRecaptureBudget.maxBodyBytes
            )
        } catch let error as DirectOriginFetchError {
            throw MCPStructuredError(code: .internalFailure, message: error.localizedDescription)
        }

        // Re-fetch rather than reuse the pre-approval/pre-fetch copy: guards against resurrecting a
        // session that was deleted while this call was in flight (`SessionStore.update` treats an
        // unknown ID as a fresh append, which would be wrong here).
        guard var updatedSession = sessionStore.sessions.first(where: { $0.id == sessionID }),
              let existingResponse = updatedSession.response else {
            throw MCPStructuredError(code: .internalFailure, message: "Session no longer available to update.")
        }
        updatedSession.response = CapturedResponse(
            statusCode: existingResponse.statusCode,
            headers: existingResponse.headers,
            bodyData: result.bodyData,
            bodySize: result.bodyData.count,
            source: existingResponse.source,
            sourceDescription: existingResponse.sourceDescription,
            bodyTruncated: result.bodyTruncatedAtCeiling,
            recordingBodyOmissionReason: nil,
            bodyDeferred: false,
            mcpAttribution: existingResponse.mcpAttribution,
            localCACertificateSHA256Fingerprint: existingResponse.localCACertificateSHA256Fingerprint
        )
        sessionStore.update(updatedSession)

        let dto = MCPOpenWorldRecaptureResultDTO(
            sessionID: sessionID.uuidString,
            statusCode: result.statusCode,
            recapturedBodyBytes: result.bodyData.count,
            truncatedAtCeiling: result.bodyTruncatedAtCeiling,
            includesCredentials: includeCredentials
        )
        return try payloadDictionary(dto)
    }

    private func runExecution(
        request: CapturedRequest,
        includeCredentials: Bool,
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        bookmark: Bookmark
    ) async throws -> [String: Any] {
        guard let port = runningProxyPort() else {
            throw MCPStructuredError(code: .busy, message: "Proxy is not running.")
        }
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .openWorldExecuted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: capability.rawValue,
                detail: "\(request.method) \(request.host)"
            )
        )
        let result: BookmarkExecutionResult
        do {
            result = try await bookmarkExecutor.execute(
                bookmark: bookmark,
                proxyPort: port,
                stripCredentials: !includeCredentials
            )
        } catch let error as BookmarkExecutionError {
            throw MCPStructuredError(code: .internalFailure, message: error.localizedDescription)
        }
        let matched = await sessionMatcher.waitForMatch(request: request, startedAt: result.startedAt)
        let dto = MCPOpenWorldExecutionResultDTO(
            status: matched == nil ? "executed_unmatched" : "executed",
            matchedSessionID: matched?.id.uuidString,
            startedAt: result.startedAt,
            includesCredentials: includeCredentials,
            destinationHost: request.host,
            method: request.method
        )
        return try payloadDictionary(dto)
    }

    // MARK: - Activate Map Remote

    private func activateMapRemote(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .activateMapRemote)
        guard let overrideIDString = arguments["overrideID"] as? String,
              let overrideID = UUID(uuidString: overrideIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID is required.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID not found.")
        }
        guard rule.sourceKind == .mapRemote else {
            throw MCPStructuredError(code: .malformedRequest, message: "Override is not a Map Remote rule.")
        }
        guard rule.mcpOrigin == .mcp else {
            throw MCPStructuredError(code: .policyDenied, message: "Only MCP-created Map Remote rules can be activated.")
        }
        guard !rule.isEnabled else {
            throw MCPStructuredError(code: .malformedRequest, message: "Map Remote rule is already enabled.")
        }
        guard let remoteHost = rule.mapRemoteHost,
              let remotePort = rule.mapRemotePort,
              let remoteScheme = rule.mapRemoteScheme else {
            throw MCPStructuredError(code: .malformedRequest, message: "Map Remote rule is missing destination fields.")
        }

        let disclosure = MCPOpenWorldDisclosureDTO(
            destinationHost: remoteHost,
            destinationPort: remotePort,
            destinationScheme: remoteScheme.rawValue,
            method: rule.requestMethod,
            includesCredentials: false,
            expectedSideEffect: "Enable Map Remote so matching traffic is forwarded to \(remoteScheme.rawValue)://\(remoteHost):\(remotePort).",
            riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
            targetID: overrideID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "activate_map_remote",
            arguments: arguments,
            client: client,
            capability: .activateMapRemote,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )

        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .activateMapRemote,
            argumentDigest: digest,
            targetRevision: rule.mcpTargetRevision,
            targetLockKey: "override:\(overrideID.uuidString)",
            idempotencyKey: idempotencyKey(from: arguments)
        )
        let rollbackData = try MCPRollbackSnapshotReader.encodeRuleRollback(
            MCPRuleRollbackSnapshot(
                isEnabled: rule.isEnabled,
                mcpTargetRevision: rule.mcpTargetRevision?.rawValue
            )
        )
        let applyResult = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .activateMapRemote,
            argumentDigest: digest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .mapRemote,
                targetID: overrideID.uuidString,
                baselineRevision: rule.mcpTargetRevision,
                intendedChangeDigest: digest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try await self.responseOverrideStore.setEnabled(true, for: overrideID)
                let rules = await self.responseOverrideStore.rules()
                return rules.first(where: { $0.id == overrideID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )

        let enabledRules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        recoveryCoordinator.updateCachedLiveEffectSummary(
            MCPEffectStateScanner.summarize(
                rules: enabledRules,
                bookmarks: bookmarks,
                throttleConfiguration: throttleConfigurationReader()
            )
        )

        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .openWorldExecuted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: MCPCapabilityID.activateMapRemote.rawValue,
                detail: "\(remoteScheme.rawValue)://\(remoteHost):\(remotePort)"
            )
        )

        let dto = MCPOpenWorldActivateMapRemoteResultDTO(
            overrideID: overrideID.uuidString,
            isEnabled: true,
            remoteHost: remoteHost,
            remotePort: remotePort,
            remoteScheme: remoteScheme.rawValue,
            transactionID: applyResult.transactionID
        )
        return try payloadDictionary(dto)
    }

    // MARK: - Activate Live Response Rewrite

    private func activateLiveRewrite(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .activateLiveRewrite)
        guard let overrideIDString = arguments["overrideID"] as? String,
              let overrideID = UUID(uuidString: overrideIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID is required.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID not found.")
        }
        guard rule.sourceKind == .liveResponseRewrite else {
            throw MCPStructuredError(code: .malformedRequest, message: "Override is not a live response rewrite rule.")
        }
        guard rule.mcpOrigin == .mcp else {
            throw MCPStructuredError(code: .policyDenied, message: "Only MCP-created live response rewrite rules can be activated.")
        }
        guard !rule.isEnabled else {
            throw MCPStructuredError(code: .malformedRequest, message: "Live response rewrite rule is already enabled.")
        }
        guard rule.liveResponseRewrites.contains(where: \.isRuleEnabled) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Live response rewrite rule has no enabled JSON field overrides.")
        }

        let upstreamPort = rule.port ?? (rule.requestScheme == .https ? 443 : 80)
        let rewriteSummary = Self.liveRewriteSummary(rule.liveResponseRewrites)
        let disclosure = MCPOpenWorldDisclosureDTO(
            destinationHost: rule.host,
            destinationPort: upstreamPort,
            destinationScheme: rule.requestScheme.rawValue,
            method: rule.requestMethod,
            includesCredentials: false,
            expectedSideEffect: "Enable live response rewrite: matching requests reach \(rule.requestScheme.rawValue)://\(rule.host):\(upstreamPort); response JSON may be patched (\(rewriteSummary)).",
            riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
            targetID: overrideID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "activate_live_rewrite",
            arguments: arguments,
            client: client,
            capability: .activateLiveRewrite,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )

        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .activateLiveRewrite,
            argumentDigest: digest,
            targetRevision: rule.mcpTargetRevision,
            targetLockKey: "override:\(overrideID.uuidString)",
            idempotencyKey: idempotencyKey(from: arguments)
        )
        let rollbackData = try MCPRollbackSnapshotReader.encodeRuleRollback(
            MCPRuleRollbackSnapshot(
                isEnabled: rule.isEnabled,
                mcpTargetRevision: rule.mcpTargetRevision?.rawValue
            )
        )
        let applyResult = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .activateLiveRewrite,
            argumentDigest: digest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .liveResponseRewrite,
                targetID: overrideID.uuidString,
                baselineRevision: rule.mcpTargetRevision,
                intendedChangeDigest: digest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try await self.responseOverrideStore.setEnabled(true, for: overrideID)
                let rules = await self.responseOverrideStore.rules()
                return rules.first(where: { $0.id == overrideID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )

        let enabledRules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        recoveryCoordinator.updateCachedLiveEffectSummary(
            MCPEffectStateScanner.summarize(
                rules: enabledRules,
                bookmarks: bookmarks,
                throttleConfiguration: throttleConfigurationReader()
            )
        )

        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .openWorldExecuted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: MCPCapabilityID.activateLiveRewrite.rawValue,
                detail: "\(rule.requestScheme.rawValue)://\(rule.host):\(upstreamPort) · \(rewriteSummary)"
            )
        )

        let dto = MCPOpenWorldActivateLiveRewriteResultDTO(
            overrideID: overrideID.uuidString,
            isEnabled: true,
            rewriteSummary: rewriteSummary,
            transactionID: applyResult.transactionID
        )
        return try payloadDictionary(dto)
    }

    private func activateCollectionMock(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .activateCollectionMock)
        guard let overrideIDString = arguments["overrideID"] as? String,
              let overrideID = UUID(uuidString: overrideIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID is required.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID not found.")
        }
        guard rule.sourceKind == .collectionMock else {
            throw MCPStructuredError(code: .malformedRequest, message: "Override is not a collection mock rule.")
        }
        guard rule.mcpOrigin == .mcp else {
            throw MCPStructuredError(code: .policyDenied, message: "Only MCP-created collection mock rules can be activated.")
        }
        guard !rule.isEnabled else {
            throw MCPStructuredError(code: .malformedRequest, message: "Collection mock rule is already enabled.")
        }
        guard let plan = rule.collectionMockPlan else {
            throw MCPStructuredError(code: .malformedRequest, message: "Collection mock rule has no compiled plan.")
        }

        let upstreamPort = rule.port ?? (rule.requestScheme == .https ? 443 : 80)
        let summary = plan.mcpSummary
        let disclosure = MCPOpenWorldDisclosureDTO(
            destinationHost: rule.host,
            destinationPort: upstreamPort,
            destinationScheme: rule.requestScheme.rawValue,
            method: rule.requestMethod,
            includesCredentials: false,
            expectedSideEffect: "Enable collection mock: matching requests reach \(rule.requestScheme.rawValue)://\(rule.host):\(upstreamPort); response JSON collection may change (\(summary)).",
            riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
            targetID: overrideID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "activate_collection_mock",
            arguments: arguments,
            client: client,
            capability: .activateCollectionMock,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )

        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .activateCollectionMock,
            argumentDigest: digest,
            targetRevision: rule.mcpTargetRevision,
            targetLockKey: "override:\(overrideID.uuidString)",
            idempotencyKey: idempotencyKey(from: arguments)
        )
        let rollbackData = try MCPRollbackSnapshotReader.encodeRuleRollback(
            MCPRuleRollbackSnapshot(
                isEnabled: rule.isEnabled,
                mcpTargetRevision: rule.mcpTargetRevision?.rawValue
            )
        )
        let applyResult = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .activateCollectionMock,
            argumentDigest: digest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .collectionMock,
                targetID: overrideID.uuidString,
                baselineRevision: rule.mcpTargetRevision,
                intendedChangeDigest: digest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try await self.responseOverrideStore.setEnabled(true, for: overrideID)
                let rules = await self.responseOverrideStore.rules()
                return rules.first(where: { $0.id == overrideID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )

        let enabledRules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        recoveryCoordinator.updateCachedLiveEffectSummary(
            MCPEffectStateScanner.summarize(
                rules: enabledRules,
                bookmarks: bookmarks,
                throttleConfiguration: throttleConfigurationReader()
            )
        )

        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .openWorldExecuted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: MCPCapabilityID.activateCollectionMock.rawValue,
                detail: "\(rule.requestScheme.rawValue)://\(rule.host):\(upstreamPort) · \(summary)"
            )
        )

        let dto = MCPOpenWorldActivateCollectionMockResultDTO(
            overrideID: overrideID.uuidString,
            isEnabled: true,
            summary: summary,
            transactionID: applyResult.transactionID
        )
        return try payloadDictionary(dto)
    }

    private static func liveRewriteSummary(_ rewrites: [BookmarkResponseFieldRewrite]) -> String {
        rewrites
            .filter(\.isRuleEnabled)
            .map { rewrite -> String in
                switch rewrite.operation {
                case .removeProperty:
                    // No literal to describe — removeProperty carries no overrideValue.
                    return "\(rewrite.jsonPath) removeProperty"
                case .removeIndex:
                    // No literal to describe — removeIndex carries no overrideValue either.
                    return "\(rewrite.jsonPath) removeIndex"
                case .move:
                    // The override value is a target array index, not sensitive content — show it
                    // plainly rather than routing through the generic sanitized digest, which
                    // would otherwise collapse an uninformative index into "Number (1 bytes, ...)".
                    if case .number(let toIndex) = rewrite.overrideValue {
                        return "\(rewrite.jsonPath) move to index \(toIndex)"
                    }
                    return "\(rewrite.jsonPath) move \(rewrite.overrideValue.disclosureDescriptor)"
                case .appendString, .prependString:
                    let policySuffix = rewrite.repeatPolicy == .ifMissingSuffix
                        ? " (skip if already applied)"
                        : ""
                    return "\(rewrite.jsonPath) \(rewrite.operation.rawValue) \(rewrite.overrideValue.disclosureDescriptor)\(policySuffix)"
                case .set, .insert:
                    return "\(rewrite.jsonPath) \(rewrite.operation.rawValue) \(rewrite.overrideValue.disclosureDescriptor)"
                }
            }
            .joined(separator: "; ")
    }

    // MARK: - Live Probe

    private func startLiveMediaProbe(
        arguments: [String: Any],
        client: MCPClientRecord,
        mcpSessionID: String
    ) async throws -> [String: Any] {
        try requireOpenWorldAccess(client: client, capability: .liveMediaProbe)
        guard let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID not found.")
        }
        guard let liveURL = MediaDetector.primaryMediaURL(for: session) else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "Session does not have a disclosable live media URL."
            )
        }
        let host = liveURL.host ?? liveURL.absoluteString
        let disclosure = MCPOpenWorldDisclosureDTO(
            destinationHost: host,
            destinationPort: liveURL.port,
            destinationScheme: liveURL.scheme,
            method: "GET",
            includesCredentials: false,
            expectedSideEffect: "Probe the original media URL with AVFoundation (live network request).",
            riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
            targetID: sessionID.uuidString
        )
        try resolveOpenWorldApproval(
            toolName: "live_media_probe_start",
            arguments: arguments,
            client: client,
            capability: .liveMediaProbe,
            disclosure: disclosure,
            mcpSessionID: mcpSessionID
        )
        let analysesRaw = arguments["analyses"] as? [String] ?? [MCPMediaAnalysisKind.liveMediaEngine.rawValue]
        let analyses = analysesRaw.compactMap(MCPMediaAnalysisKind.init(rawValue:))
        let sampleTime = arguments["sampleTimeSeconds"] as? Double ?? 0
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let descriptor = try operationCoordinator.startLiveMediaProbe(
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            sourceSessionID: sessionID,
            liveURL: liveURL,
            analyses: analyses.isEmpty ? [.liveMediaEngine] : analyses,
            sampleTime: sampleTime,
            argumentDigest: digest
        )
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .liveProbeStarted,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: MCPCapabilityID.liveMediaProbe.rawValue,
                detail: host
            )
        )
        let dto = MCPOpenWorldLiveProbeStartDTO(
            operationID: descriptor.operationID,
            status: descriptor.status.rawValue,
            destinationHost: host,
            destinationScheme: liveURL.scheme
        )
        return try payloadDictionary(dto)
    }

    // MARK: - Approval (MUST use grant-record pattern)

    /// Validates or mints open-world approval using the server-side grant record.
    ///
    /// The client-supplied authorization is untrusted — only the nonce is used to look up
    /// ``MCPApprovalStore/grantedAuthorization(nonce:)``.
    func resolveOpenWorldApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        disclosure: MCPOpenWorldDisclosureDTO,
        mcpSessionID: String
    ) throws {
        var boundArguments = MCPArgumentDigest.dispatchArguments(arguments)
        var disclosureObject: [String: Any] = [
            "destinationHost": disclosure.destinationHost,
            "method": disclosure.method,
            "includesCredentials": disclosure.includesCredentials,
            "expectedSideEffect": disclosure.expectedSideEffect,
            "targetID": disclosure.targetID
        ]
        if let port = disclosure.destinationPort {
            disclosureObject["destinationPort"] = port
        }
        if let scheme = disclosure.destinationScheme {
            disclosureObject["destinationScheme"] = scheme
        }
        boundArguments["__openWorldDisclosure"] = disclosureObject
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
        let reason = """
        Open-world \(toolName): \(disclosure.method) \(disclosure.destinationScheme ?? "")\
        ://\(disclosure.destinationHost)\
        \(disclosure.destinationPort.map { ":\($0)" } ?? "") \
        credentials=\(disclosure.includesCredentials) — \(disclosure.expectedSideEffect)
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

    // MARK: - Helpers

    private func requireOpenWorldAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Open-world tools denied for profile.",
                kind: .openWorldDenied
            )
            throw MCPStructuredError(code: .policyDenied, message: "Open-world tools require Shareable profile.")
        }
    }

    private func disclosure(
        for request: CapturedRequest,
        includesCredentials: Bool,
        expectedSideEffect: String,
        targetID: String
    ) -> MCPOpenWorldDisclosureDTO {
        MCPOpenWorldDisclosureDTO(
            destinationHost: request.host,
            destinationPort: request.port,
            destinationScheme: request.scheme.rawValue,
            method: request.method,
            includesCredentials: includesCredentials,
            expectedSideEffect: expectedSideEffect,
            riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
            targetID: targetID
        )
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

    private func idempotencyKey(from arguments: [String: Any]) -> MCPIdempotencyKey? {
        guard let raw = arguments["idempotencyKey"] as? String, !raw.isEmpty else { return nil }
        return MCPIdempotencyKey(rawValue: raw)
    }

    private func payloadDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Payload encoding failed.")
        }
        return object
    }
}
