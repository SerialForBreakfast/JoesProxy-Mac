import Foundation

/// Short-lived proposal token bound to a normalized MCP mutation.
struct MCPProposalToken: Equatable, Sendable, Codable, Identifiable {
    var id: String { token }
    var token: String
    var clientID: String
    var capability: MCPCapabilityID
    var argumentDigest: String
    var policyRevision: MCPPolicyRevision
    var targetRevision: MCPTargetRevision?
    var targetLockKey: String
    var idempotencyKey: MCPIdempotencyKey?
    var nonce: String
    var expiresAt: Date
    var consumed: Bool
}

enum MCPProposalCoordinatorError: Error, Equatable, Sendable {
    case staleProposal
    case expired
    case reused
    case busy
    case conflict
    case journalUnavailable
}

/// Result cached for idempotent proposal apply retries.
struct MCPProposalApplyResult: Equatable, Sendable, Codable {
    var transactionID: String
    var appliedAt: Date
}

/// Cache entry binding a result to the exact request that produced it. A raw `[key: result]` cache
/// would let any caller who guesses or observes an idempotency key retrieve another client's
/// result with zero re-validation — this exists so a key "hit" is only ever honored for the same
/// client, capability, and arguments that originally produced it.
private struct MCPProposalIdempotencyRecord: Equatable, Sendable {
    var clientID: String
    var capability: MCPCapabilityID
    var argumentDigest: String
    var result: MCPProposalApplyResult
}

/// Issues proposal tokens, enforces target locks, and routes apply through the recovery journal.
///
/// Concurrency: `@MainActor` — proposal state is shared with management UI and transport handlers.
@MainActor
final class MCPProposalCoordinator {
    private var proposalsByToken: [String: MCPProposalToken] = [:]
    private var idempotencyResults: [String: MCPProposalIdempotencyRecord] = [:]
    private var lockedTargetKeys: Set<String> = []

    private let recoveryCoordinator: MCPRecoveryCoordinator
    private let policyRevisionProvider: () -> MCPPolicyRevision

    init(
        recoveryCoordinator: MCPRecoveryCoordinator,
        policyRevisionProvider: @escaping () -> MCPPolicyRevision
    ) {
        self.recoveryCoordinator = recoveryCoordinator
        self.policyRevisionProvider = policyRevisionProvider
    }

    func createProposal(
        clientID: String,
        capability: MCPCapabilityID,
        argumentDigest: String,
        targetRevision: MCPTargetRevision?,
        targetLockKey: String,
        idempotencyKey: MCPIdempotencyKey? = nil,
        lifetime: TimeInterval = MCPApprovalPolicy.proposalLifetime,
        now: Date = Date()
    ) throws -> MCPProposalToken {
        pruneExpired(now: now)
        let token = MCPProposalToken(
            token: UUID().uuidString,
            clientID: clientID,
            capability: capability,
            argumentDigest: argumentDigest,
            policyRevision: policyRevisionProvider(),
            targetRevision: targetRevision,
            targetLockKey: targetLockKey,
            idempotencyKey: idempotencyKey,
            nonce: UUID().uuidString,
            expiresAt: MCPApprovalPolicy.expiration(from: now, lifetime: lifetime),
            consumed: false
        )
        proposalsByToken[token.token] = token
        return token
    }

    /// Returns a live proposal token for apply-time validation (does not consume).
    func proposal(forToken token: String, now: Date = Date()) -> MCPProposalToken? {
        guard let proposal = proposalsByToken[token], now < proposal.expiresAt else {
            proposalsByToken.removeValue(forKey: token)
            return nil
        }
        return proposal
    }

    func extendProposal(token: String, through minimumExpiry: Date) {
        guard var proposal = proposalsByToken[token], !proposal.consumed else { return }
        if proposal.expiresAt < minimumExpiry {
            proposal.expiresAt = minimumExpiry
            proposalsByToken[token] = proposal
        }
    }

    func hasCachedApplyResult(
        idempotencyKey: MCPIdempotencyKey,
        clientID: String,
        capability: MCPCapabilityID,
        argumentDigest: String
    ) -> Bool {
        guard let cached = idempotencyResults[idempotencyKey.rawValue] else { return false }
        return cached.clientID == clientID
            && cached.capability == capability
            && cached.argumentDigest == argumentDigest
    }

    @discardableResult
    func applyProposal(
        token: String,
        clientID: String,
        capability: MCPCapabilityID,
        argumentDigest: String,
        currentTargetRevision: MCPTargetRevision?,
        mutationIntent: MCPMutationIntent,
        performMutation: () async throws -> MCPTargetRevision? = { nil },
        idempotencyKey: MCPIdempotencyKey? = nil,
        now: Date = Date()
    ) async throws -> MCPProposalApplyResult {
        pruneExpired(now: now)

        if let idempotencyKey,
           let cached = idempotencyResults[idempotencyKey.rawValue] {
            guard cached.clientID == clientID,
                  cached.capability == capability,
                  cached.argumentDigest == argumentDigest else {
                // Same idempotency key, different request context — never honor this as a cache
                // hit. Falling through would return one caller's result to a different caller (or
                // the same caller retrying a genuinely different mutation) with no re-validation.
                throw MCPProposalCoordinatorError.staleProposal
            }
            return cached.result
        }

        guard var proposal = proposalsByToken[token] else {
            throw MCPProposalCoordinatorError.staleProposal
        }
        if proposal.consumed {
            throw MCPProposalCoordinatorError.reused
        }
        if now >= proposal.expiresAt {
            throw MCPProposalCoordinatorError.expired
        }
        if proposal.clientID != clientID
            || proposal.capability != capability
            || proposal.argumentDigest != argumentDigest {
            throw MCPProposalCoordinatorError.staleProposal
        }
        if proposal.policyRevision != policyRevisionProvider() {
            throw MCPProposalCoordinatorError.staleProposal
        }
        if proposal.targetRevision != currentTargetRevision {
            throw MCPProposalCoordinatorError.staleProposal
        }
        guard !lockedTargetKeys.contains(proposal.targetLockKey) else {
            throw MCPProposalCoordinatorError.busy
        }

        lockedTargetKeys.insert(proposal.targetLockKey)
        defer { lockedTargetKeys.remove(proposal.targetLockKey) }

        let transactionID = try recoveryCoordinator.beginMutation(mutationIntent, now: now)
        let resultingRevision: MCPTargetRevision?
        do {
            resultingRevision = try await performMutation()
        } catch {
            try? recoveryCoordinator.rollbackMutation(transactionID: transactionID)
            throw MCPProposalCoordinatorError.conflict
        }
        do {
            try recoveryCoordinator.commitMutation(transactionID: transactionID, resultingRevision: resultingRevision)
        } catch {
            try? recoveryCoordinator.markConflict(
                transactionID: transactionID,
                message: "Target store updated but effect journal commit failed."
            )
            throw MCPProposalCoordinatorError.conflict
        }

        proposal.consumed = true
        proposalsByToken[token] = proposal

        let result = MCPProposalApplyResult(transactionID: transactionID, appliedAt: now)
        if let idempotencyKey {
            idempotencyResults[idempotencyKey.rawValue] = MCPProposalIdempotencyRecord(
                clientID: clientID,
                capability: capability,
                argumentDigest: argumentDigest,
                result: result
            )
        }
        return result
    }

    func structuredError(for error: MCPProposalCoordinatorError) -> MCPStructuredError {
        switch error {
        case .staleProposal:
            return MCPStructuredError(code: .staleProposal, message: "Proposal token is no longer valid.")
        case .expired:
            return MCPStructuredError(code: .approvalExpired, message: "Proposal token expired.")
        case .reused:
            return MCPStructuredError(code: .approvalReused, message: "Proposal token already consumed.")
        case .busy:
            return MCPStructuredError(code: .busy, message: "Target is locked by another mutation.")
        case .conflict:
            return MCPStructuredError(code: .conflict, message: "Mutation could not be committed.")
        case .journalUnavailable:
            return MCPStructuredError(code: .internalFailure, message: "Effect journal unavailable.")
        }
    }

    private func pruneExpired(now: Date) {
        // Keep consumed proposals through their bounded lifetime so an apply retry can resolve the
        // proposal and return its cached result instead of manufacturing a duplicate effect.
        proposalsByToken = proposalsByToken.filter { now < $0.value.expiresAt }
    }

    /// Clears in-flight proposals, idempotency cache, and target locks during Return To Normal.
    func invalidateAll() {
        proposalsByToken.removeAll()
        idempotencyResults.removeAll()
        lockedTargetKeys.removeAll()
    }

    /// Clears unconsumed proposals and retry results owned by one disconnected client.
    func invalidate(clientID: String) {
        proposalsByToken = proposalsByToken.filter { $0.value.clientID != clientID }
        idempotencyResults = idempotencyResults.filter { $0.value.clientID != clientID }
        lockedTargetKeys = Set(proposalsByToken.values.map(\.targetLockKey))
    }
}
