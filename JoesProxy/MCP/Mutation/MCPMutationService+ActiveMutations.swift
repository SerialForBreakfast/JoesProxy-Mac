import Foundation

extension MCPMutationService {
    // MARK: - Enable override

    func proposeEnableRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .enableRule, kind: .ruleEnabled)
        try requireActiveMutatingAccess(client: client, capability: .enableRule)
        let overrideID = try MCPActiveMutationValidator.parseOverrideID(from: arguments)
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("overrideID not found."))
        }
        try MCPActiveMutationValidator.validateEnableRule(rule)
        let matcher = MCPMutationMatcher(
            method: rule.requestMethod,
            scheme: rule.requestScheme,
            host: rule.host,
            port: rule.port,
            path: rule.path,
            matchMode: rule.matchMode,
            graphQLOperationName: rule.graphQLOperationName,
            matchQueryKey: rule.matchQueryKey,
            matchQueryValue: rule.matchQueryValue,
            sourceClientAddress: rule.sourceClientAddress
        )
        let evaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: overrideID)
        try requireAcceptedConfoundersIfNeeded(
            evaluation: evaluation,
            matcher: matcher,
            arguments: arguments
        )
        let plan = MCPMutationPlan(
            capability: .enableRule,
            activeTarget: .responseOverride(overrideID),
            matcher: matcher,
            proposedTargetID: overrideID,
            effectKind: effectKind(for: rule.sourceKind),
            effectSummary: "Enable MCP override \(overrideID.uuidString) affecting \(rule.requestMethod) \(rule.host)\(rule.path).",
            priorEnabledState: rule.isEnabled,
            targetRevision: rule.mcpTargetRevision
        )
        return try await proposeActive(
            plan: plan,
            client: client,
            arguments: arguments,
            targetRevision: rule.mcpTargetRevision,
            conflicts: evaluation.conflictingEnabledRuleIDs,
            matcherScopeDisclosure: matcherScopeDisclosure(matcher: matcher, evaluation: evaluation)
        )
    }

    func applyEnableRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .enableRule, kind: .ruleEnabled)
        try requireActiveMutatingAccess(client: client, capability: .enableRule)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .enableRule, client: client)
        guard case .responseOverride(let overrideID) = plan.activeTarget else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .staleProposal, message: "Override no longer exists.")
        }
        try resolveActiveMutationApproval(
            toolName: "apply_enable_rule",
            arguments: arguments,
            client: client,
            capability: .enableRule,
            currentTargetRevision: rule.mcpTargetRevision
        )
        if proposal.targetRevision != rule.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Override changed since proposal.")
        }
        let matcher = MCPMutationMatcher(
            method: rule.requestMethod,
            scheme: rule.requestScheme,
            host: rule.host,
            port: rule.port,
            path: rule.path,
            matchMode: rule.matchMode,
            graphQLOperationName: rule.graphQLOperationName,
            matchQueryKey: rule.matchQueryKey,
            matchQueryValue: rule.matchQueryValue,
            sourceClientAddress: rule.sourceClientAddress
        )
        let evaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: overrideID)
        try requireAcceptedConfoundersIfNeeded(
            evaluation: evaluation,
            matcher: matcher,
            arguments: arguments
        )
        let rollbackData = try MCPRollbackSnapshotReader.encodeRuleRollback(
            MCPRuleRollbackSnapshot(
                isEnabled: rule.isEnabled,
                mcpTargetRevision: rule.mcpTargetRevision?.rawValue
            )
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .enableRule,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
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
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .enableRule, targetID: overrideID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: overrideID.uuidString, isEnabled: true))
    }

    // MARK: - Disable override

    func proposeDisableRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .disableRule, kind: .ruleDisabled)
        try requireActiveMutatingAccess(client: client, capability: .disableRule)
        let overrideID = try MCPActiveMutationValidator.parseOverrideID(from: arguments)
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("overrideID not found."))
        }
        try MCPActiveMutationValidator.validateDisableRule(rule)
        let plan = MCPMutationPlan(
            capability: .disableRule,
            activeTarget: .responseOverride(overrideID),
            matcher: MCPMutationMatcher(
                method: rule.requestMethod,
                scheme: rule.requestScheme,
                host: rule.host,
                port: rule.port,
                path: rule.path,
                matchMode: rule.matchMode,
                graphQLOperationName: rule.graphQLOperationName,
                matchQueryKey: rule.matchQueryKey,
                matchQueryValue: rule.matchQueryValue,
                sourceClientAddress: rule.sourceClientAddress
            ),
            proposedTargetID: overrideID,
            effectKind: effectKind(for: rule.sourceKind),
            effectSummary: "Disable MCP override \(overrideID.uuidString) for \(rule.requestMethod) \(rule.host)\(rule.path).",
            priorEnabledState: rule.isEnabled,
            targetRevision: rule.mcpTargetRevision
        )
        return try await proposeActive(plan: plan, client: client, arguments: arguments, targetRevision: rule.mcpTargetRevision)
    }

    func applyDisableRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .disableRule, kind: .ruleDisabled)
        try requireActiveMutatingAccess(client: client, capability: .disableRule)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .disableRule, client: client)
        guard case .responseOverride(let overrideID) = plan.activeTarget else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .staleProposal, message: "Override no longer exists.")
        }
        // Risk-reducing stop: skip interactive approval (same pattern as hls_fixture_stop /
        // cleanup_test_scenario) while keeping policy gates, staleness checks, and audit.
        if proposal.targetRevision != rule.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Override changed since proposal.")
        }
        let rollbackData = try MCPRollbackSnapshotReader.encodeRuleRollback(
            MCPRuleRollbackSnapshot(
                isEnabled: rule.isEnabled,
                mcpTargetRevision: rule.mcpTargetRevision?.rawValue
            )
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .disableRule,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try await self.responseOverrideStore.setEnabled(false, for: overrideID)
                let rules = await self.responseOverrideStore.rules()
                return rules.first(where: { $0.id == overrideID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .disableRule, targetID: overrideID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: overrideID.uuidString, isEnabled: false))
    }

    // MARK: - Delete override

    /// Proposes permanent deletion of an MCP-owned override.
    ///
    /// Concurrency: `@MainActor` via ``MCPMutationService``; awaits the override store.
    func proposeDeleteRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .deleteRule, kind: .ruleDeleted)
        try requireActiveMutatingAccess(client: client, capability: .deleteRule)
        let overrideID = try MCPActiveMutationValidator.parseOverrideID(from: arguments)
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("overrideID not found."))
        }
        try MCPActiveMutationValidator.validateDeleteRule(rule)
        let plan = MCPMutationPlan(
            capability: .deleteRule,
            activeTarget: .responseOverride(overrideID),
            matcher: MCPMutationMatcher(
                method: rule.requestMethod,
                scheme: rule.requestScheme,
                host: rule.host,
                port: rule.port,
                path: rule.path,
                matchMode: rule.matchMode,
                graphQLOperationName: rule.graphQLOperationName,
                matchQueryKey: rule.matchQueryKey,
                matchQueryValue: rule.matchQueryValue,
                sourceClientAddress: rule.sourceClientAddress
            ),
            proposedTargetID: overrideID,
            effectKind: effectKind(for: rule.sourceKind),
            effectSummary: "Permanently delete MCP override \(overrideID.uuidString) (\(rule.sourceKind.rawValue)) for \(rule.requestMethod) \(rule.host)\(rule.path).",
            priorEnabledState: rule.isEnabled,
            targetRevision: rule.mcpTargetRevision
        )
        return try await proposeActive(plan: plan, client: client, arguments: arguments, targetRevision: rule.mcpTargetRevision)
    }

    /// Applies a proposed MCP-owned override delete after in-app approval.
    ///
    /// Concurrency: `@MainActor` via ``MCPMutationService``; awaits the override store.
    func applyDeleteRule(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .deleteRule, kind: .ruleDeleted)
        try requireActiveMutatingAccess(client: client, capability: .deleteRule)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .deleteRule, client: client)
        guard case .responseOverride(let overrideID) = plan.activeTarget else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == overrideID }) else {
            throw MCPStructuredError(code: .staleProposal, message: "Override no longer exists.")
        }
        try resolveActiveMutationApproval(
            toolName: "apply_delete_rule",
            arguments: arguments,
            client: client,
            capability: .deleteRule,
            currentTargetRevision: rule.mcpTargetRevision
        )
        if proposal.targetRevision != rule.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Override changed since proposal.")
        }
        let persistedJSON = try await responseOverrideStore.mcpDeleteRollbackData(for: overrideID)
        let rollbackData = try MCPRollbackSnapshotReader.encodeDeletedRuleRollback(
            MCPDeletedRuleRollbackSnapshot(persistedRuleJSON: persistedJSON)
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .deleteRule,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: rule.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                await self.responseOverrideStore.removeRule(id: overrideID)
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .deleteRule, targetID: overrideID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: overrideID.uuidString, isEnabled: false))
    }

    // MARK: - Enable rewrite

    func proposeEnableRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .enableRule, kind: .ruleEnabled)
        try requireActiveMutatingAccess(client: client, capability: .enableRule)
        let (bookmarkID, rewriteID) = try MCPActiveMutationValidator.parseBookmarkRewriteIDs(from: arguments)
        let (bookmark, rewrite) = try resolvedBookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID)
        try MCPActiveMutationValidator.validateEnableRewrite(bookmark: bookmark, rewrite: rewrite)
        let plan = MCPMutationPlan(
            capability: .enableRule,
            activeTarget: .bookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID),
            proposedTargetID: rewriteID,
            effectKind: .bookmarkRewrite,
            effectSummary: "Enable MCP bookmark rewrite \(rewrite.jsonPath) on bookmark \(bookmark.name).",
            priorEnabledState: rewrite.isRuleEnabled,
            targetRevision: bookmark.mcpTargetRevision,
            bookmarkID: bookmarkID,
            rewriteID: rewriteID
        )
        return try await proposeActive(plan: plan, client: client, arguments: arguments, targetRevision: bookmark.mcpTargetRevision)
    }

    func applyEnableRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .enableRule, kind: .ruleEnabled)
        try requireActiveMutatingAccess(client: client, capability: .enableRule)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .enableRule, client: client)
        guard case .bookmarkRewrite(let bookmarkID, let rewriteID) = plan.activeTarget else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let (bookmark, rewrite) = try resolvedBookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID)
        try resolveActiveMutationApproval(
            toolName: "apply_enable_rewrite",
            arguments: arguments,
            client: client,
            capability: .enableRule,
            currentTargetRevision: bookmark.mcpTargetRevision
        )
        if proposal.targetRevision != bookmark.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Bookmark changed since proposal.")
        }
        let rollbackData = try MCPRollbackSnapshotReader.encodeBookmarkRewriteRollback(
            MCPBookmarkRewriteRollbackSnapshot(
                isRuleEnabled: rewrite.isRuleEnabled,
                bookmarkMcpTargetRevision: bookmark.mcpTargetRevision?.rawValue
            )
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .enableRule,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: bookmark.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try self.persistBookmarkRewriteEnabled(
                    bookmarkID: bookmarkID,
                    rewriteID: rewriteID,
                    isEnabled: true
                )
                return self.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .enableRule, targetID: rewriteID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: rewriteID.uuidString, isEnabled: true))
    }

    // MARK: - Disable rewrite

    func proposeDisableRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .disableRule, kind: .ruleDisabled)
        try requireActiveMutatingAccess(client: client, capability: .disableRule)
        let (bookmarkID, rewriteID) = try MCPActiveMutationValidator.parseBookmarkRewriteIDs(from: arguments)
        let (bookmark, rewrite) = try resolvedBookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID)
        try MCPActiveMutationValidator.validateDisableRewrite(bookmark: bookmark, rewrite: rewrite)
        let plan = MCPMutationPlan(
            capability: .disableRule,
            activeTarget: .bookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID),
            proposedTargetID: rewriteID,
            effectKind: .bookmarkRewrite,
            effectSummary: "Disable MCP bookmark rewrite \(rewrite.jsonPath) on bookmark \(bookmark.name).",
            priorEnabledState: rewrite.isRuleEnabled,
            targetRevision: bookmark.mcpTargetRevision,
            bookmarkID: bookmarkID,
            rewriteID: rewriteID
        )
        return try await proposeActive(plan: plan, client: client, arguments: arguments, targetRevision: bookmark.mcpTargetRevision)
    }

    func applyDisableRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .disableRule, kind: .ruleDisabled)
        try requireActiveMutatingAccess(client: client, capability: .disableRule)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .disableRule, client: client)
        guard case .bookmarkRewrite(let bookmarkID, let rewriteID) = plan.activeTarget else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let (bookmark, rewrite) = try resolvedBookmarkRewrite(bookmarkID: bookmarkID, rewriteID: rewriteID)
        // Risk-reducing stop: skip interactive approval (same pattern as hls_fixture_stop /
        // cleanup_test_scenario) while keeping policy gates, staleness checks, and audit.
        if proposal.targetRevision != bookmark.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Bookmark changed since proposal.")
        }
        let rollbackData = try MCPRollbackSnapshotReader.encodeBookmarkRewriteRollback(
            MCPBookmarkRewriteRollbackSnapshot(
                isRuleEnabled: rewrite.isRuleEnabled,
                bookmarkMcpTargetRevision: bookmark.mcpTargetRevision?.rawValue
            )
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .disableRule,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: bookmark.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try self.persistBookmarkRewriteEnabled(
                    bookmarkID: bookmarkID,
                    rewriteID: rewriteID,
                    isEnabled: false
                )
                return self.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .disableRule, targetID: rewriteID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: rewriteID.uuidString, isEnabled: false))
    }

    // MARK: - Throttle

    func proposeChangeThrottle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .changeThrottle, kind: .throttleChanged)
        try requireActiveMutatingAccess(client: client, capability: .changeThrottle)
        let current = normalizedThrottleConfiguration()
        let merged = try MCPActiveMutationValidator.mergedThrottleConfiguration(arguments: arguments, current: current)
        let plan = MCPMutationPlan(
            capability: .changeThrottle,
            activeTarget: .throttle,
            proposedTargetID: UUID(),
            effectKind: .throttle,
            effectSummary: throttleEffectSummary(for: merged),
            priorEnabledState: current.isEnabled,
            targetRevision: current.mcpTargetRevision,
            throttleConfiguration: merged
        )
        return try await proposeActive(plan: plan, client: client, arguments: arguments, targetRevision: current.mcpTargetRevision)
    }

    func applyChangeThrottle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        recordActiveMutationAttempt(client: client, capability: .changeThrottle, kind: .throttleChanged)
        try requireActiveMutatingAccess(client: client, capability: .changeThrottle)
        let current = normalizedThrottleConfiguration()
        try resolveActiveMutationApproval(
            toolName: "apply_change_throttle",
            arguments: arguments,
            client: client,
            capability: .changeThrottle,
            currentTargetRevision: current.mcpTargetRevision
        )
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .changeThrottle, client: client)
        guard plan.activeTarget == .throttle, let targetConfiguration = plan.throttleConfiguration else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        if proposal.targetRevision != current.mcpTargetRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Throttle configuration changed since proposal.")
        }
        let provenance = current.mcpProvenance ?? makeProvenance(clientID: client.id, capability: .changeThrottle)
        let rollbackData = try MCPRollbackSnapshotReader.encodeThrottleRollback(
            MCPThrottleRollbackSnapshot(configuration: current)
        )
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .changeThrottle,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: current.mcpTargetRevision,
            mutationIntent: activeMutationIntent(
                plan: plan,
                clientID: client.id,
                digest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                let normalized = MCPThrottleStoreSupport.normalizedConfiguration(
                    targetConfiguration,
                    provenance: provenance,
                    origin: .mcp
                )
                self.throttleConfigurationWriter(normalized)
                return normalized.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        await refreshLiveEffectSummary()
        recordApplied(client: client, capability: .changeThrottle, targetID: "throttle", detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: "throttle", isEnabled: targetConfiguration.isEnabled))
    }

    // MARK: - Shared active helpers

    func refreshLiveEffectSummary() async {
        let rules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        let throttle = normalizedThrottleConfiguration()
        let summary = MCPEffectStateScanner.summarize(
            rules: rules,
            bookmarks: bookmarks,
            throttleConfiguration: throttle
        )
        recoveryCoordinator.updateCachedLiveEffectSummary(summary)
    }

    private func normalizedThrottleConfiguration() -> NetworkThrottleConfiguration {
        MCPTargetRevisionFingerprint.throttleByApplyingRevision(throttleConfigurationReader())
    }

    private func proposeActive(
        plan: MCPMutationPlan,
        client: MCPClientRecord,
        arguments: [String: Any],
        targetRevision: MCPTargetRevision?,
        conflicts: [String] = [],
        matcherScopeDisclosure: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let targetRevision else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("Target revision is required."))
        }
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let lockKey = activeTargetLockKey(for: plan)
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: plan.capability,
            argumentDigest: digest,
            targetRevision: targetRevision,
            targetLockKey: lockKey,
            idempotencyKey: idempotencyKey(from: arguments)
        )
        plansByProposalToken[proposal.token] = plan
        let payload = MCPMutationProposalPayload(
            proposalToken: proposal.token,
            expiresAt: proposal.expiresAt,
            targetLockKey: lockKey,
            effectSummary: plan.effectSummary,
            matchScope: matchScope(for: plan),
            conflicts: conflicts,
            riskTier: plan.capability.riskTier.rawValue,
            defaultEnabled: plan.capability == .enableRule,
            targetRevision: targetRevision.rawValue,
            priorEnabledState: plan.priorEnabledState,
            proposedTargetID: plan.proposedTargetID.uuidString
        )
        recordProposalCreated(client: client, capability: plan.capability, detail: plan.effectSummary)
        var result = try payloadDictionary(payload)
        if let matcherScopeDisclosure {
            result["matcherScope"] = matcherScopeDisclosure
        }
        return result
    }

    private func activeMutationIntent(
        plan: MCPMutationPlan,
        clientID: String,
        digest: String,
        rollbackSnapshot: Data,
        expiresAt: Date
    ) -> MCPMutationIntent {
        MCPMutationIntent(
            clientID: clientID,
            targetKind: plan.effectKind,
            targetID: activeTargetID(for: plan),
            baselineRevision: plan.targetRevision,
            intendedChangeDigest: digest,
            rollbackSnapshot: rollbackSnapshot,
            expiresAt: expiresAt
        )
    }

    private func activeTargetLockKey(for plan: MCPMutationPlan) -> String {
        switch plan.activeTarget {
        case .responseOverride(let id):
            return "override:\(id.uuidString)"
        case .bookmarkRewrite(let bookmarkID, let rewriteID):
            return "bookmark:\(bookmarkID.uuidString):rewrite:\(rewriteID.uuidString)"
        case .throttle:
            return "throttle:configuration"
        case .createNew:
            return targetLockKey(for: plan)
        }
    }

    private func activeTargetID(for plan: MCPMutationPlan) -> String {
        switch plan.activeTarget {
        case .responseOverride(let id):
            return id.uuidString
        case .bookmarkRewrite(let bookmarkID, let rewriteID):
            return "\(bookmarkID.uuidString):\(rewriteID.uuidString)"
        case .throttle:
            return "throttle"
        case .createNew:
            return plan.proposedTargetID.uuidString
        }
    }

    private func resolvedBookmarkRewrite(
        bookmarkID: UUID,
        rewriteID: UUID
    ) throws -> (Bookmark, BookmarkResponseFieldRewrite) {
        guard let bookmark = bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("bookmarkID not found."))
        }
        guard let rewrite = bookmark.responseRewrites.first(where: { $0.id == rewriteID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("rewriteID not found."))
        }
        return (bookmark, rewrite)
    }

    private func persistBookmarkRewriteEnabled(
        bookmarkID: UUID,
        rewriteID: UUID,
        isEnabled: Bool
    ) throws {
        try MCPBookmarkRewritePersistence.setRewriteEnabled(
            bookmarkID: bookmarkID,
            rewriteID: rewriteID,
            isEnabled: isEnabled,
            bookmarkStore: bookmarkStore
        )
    }

    /// Profile/Always-Deny gate for enable/disable/throttle active mutations.
    ///
    /// Shared with create+enable bundling in ``MCPMutationService/applyCreateMapLocal`` so the
    /// highest-severity member (``.enableRule``) is checked before any rule is persisted.
    func requireActiveMutatingAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Active mutations denied for profile."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Active mutations require Shareable profile.")
        }
    }

    private func resolveActiveMutationApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        currentTargetRevision: MCPTargetRevision? = nil
    ) throws {
        let digest = MCPArgumentDigest.normalized(arguments)
        let mcpSessionID = arguments["__mcpInternalSessionID"] as? String
        let proposalToken = arguments["proposalToken"] as? String
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
                currentTargetRevision: currentTargetRevision,
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
            targetRevision: currentTargetRevision,
            proposalToken: proposalToken
        ) {
            return
        }
        if policyEvaluator.skipsApprovalNonce(capability: capability, client: client) {
            return
        }
        let reason = "Active mutation \(toolName) requires in-app approval."
        if let proposalToken {
            proposalCoordinator.extendProposal(
                token: proposalToken,
                through: Date().addingTimeInterval(MCPApprovalPolicy.defaultLifetime)
            )
        }
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            targetRevision: currentTargetRevision,
            mcpSessionID: mcpSessionID,
            proposalToken: proposalToken,
            reason: reason
        )
        throw MCPStructuredError.approvalRequired(request)
    }

    private func recordActiveMutationAttempt(
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        kind: MCPAuditEventKind
    ) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: kind,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: capability.rawValue,
                detail: nil
            )
        )
    }

    private func throttleEffectSummary(for configuration: NetworkThrottleConfiguration) -> String {
        if configuration.isEnabled, let preset = configuration.effectivePreset() {
            return "Apply MCP throttle preset \(preset.name) (\(preset.downstreamKbps)/\(preset.upstreamKbps) kbps, \(preset.latencyMs) ms latency)."
        }
        return "Disable MCP network throttling."
    }

    private func effectKind(for sourceKind: ResponseOverrideSourceKind) -> MCPEffectKind {
        switch sourceKind {
        case .block:
            return .block
        case .mapRemote:
            return .mapRemote
        case .bookmarkRewrite:
            return .bookmarkRewrite
        case .liveResponseRewrite:
            return .liveResponseRewrite
        case .collectionMock:
            return .collectionMock
        case .capturedResponse, .inlineText, .localFile, .fixtureRun, .localDirectory:
            return .mapLocal
        }
    }
}
