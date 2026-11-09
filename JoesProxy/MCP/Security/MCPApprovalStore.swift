import Foundation

enum MCPApprovalStoreError: Error, Equatable, Sendable, LocalizedError {
    case requestNotFound
    case requestExpired
    case requestInvalidated

    /// Without this, Swift falls back to a generic bridged-NSError description
    /// ("The operation couldn't be completed. (JoesProxy.MCPApprovalStoreError error 0.)") —
    /// a real bug hit live: the Approvals panel's `resolveApproval` catch block reads
    /// `error.localizedDescription` directly and shows it to the user verbatim.
    var errorDescription: String? {
        switch self {
        case .requestNotFound:
            return "This approval request no longer exists — it may have already been resolved or superseded by a newer request from the same client. Ask the client to retry its call."
        case .requestExpired:
            return "This approval request expired before it was resolved. Ask the client to retry its call to get a fresh request."
        case .requestInvalidated:
            return "This approval request was invalidated by a policy change since it was created. Ask the client to retry its call."
        }
    }
}

/// In-memory pending approval coordinator with one-use nonce tracking.
///
/// Concurrency: `@MainActor` because approvals are minted and resolved from the management panel
/// and transport handlers on the main actor.
@MainActor
final class MCPApprovalStore: ObservableObject {
    @Published private(set) var pendingRequests: [MCPApprovalRequest] = []

    private var pendingByID: [String: MCPApprovalRequest] = [:]
    private var usedNonces: [String: Date] = [:]
    private var expiredNonces: [String: Date] = [:]
    /// Server-side record of what was actually granted, keyed by the one-use nonce handed to the
    /// client. The retry path must validate against this — never against fields the client echoes
    /// back — or a client could fabricate its own `MCPApprovalAuthorization` and self-approve.
    private var grantedByNonce: [String: (request: MCPApprovalRequest, authorization: MCPApprovalAuthorization)] = [:]
    private struct LifecycleRecord {
        var request: MCPApprovalRequest
        var mcpSessionID: String?
        var proposalToken: String?
        var status: MCPApprovalStatus
        var updatedAt: Date
    }
    private var lifecycleByID: [String: LifecycleRecord] = [:]

    var pendingCount: Int { pendingByID.count }

    /// Creates a pending approval request for a sensitive MCP operation.
    @discardableResult
    func createPendingRequest(
        clientID: String,
        capability: MCPCapabilityID,
        argumentDigest: String,
        policyRevision: MCPPolicyRevision,
        targetRevision: MCPTargetRevision? = nil,
        mcpSessionID: String? = nil,
        proposalToken: String? = nil,
        reason: String,
        lifetime: TimeInterval? = nil,
        now: Date = Date()
    ) -> MCPApprovalRequest {
        pruneExpired(now: now)
        if let existing = lifecycleByID.values.first(where: {
            $0.status == .pending
                && $0.request.clientID == clientID
                && $0.mcpSessionID == mcpSessionID
                && $0.request.capability == capability
                && $0.request.argumentDigest == argumentDigest
                && $0.request.policyRevision == policyRevision
                && $0.request.targetRevision == targetRevision
                && $0.proposalToken == proposalToken
        }) {
            MCPLog.approvals.info("Reused pending approval request \(existing.request.requestID, privacy: .public).")
            return existing.request
        }
        let request = MCPApprovalRequest(
            requestID: UUID().uuidString,
            clientID: clientID,
            argumentDigest: argumentDigest,
            policyRevision: policyRevision,
            targetRevision: targetRevision,
            expiresAt: MCPApprovalPolicy.expiration(from: now,
                lifetime: min(max(lifetime ?? MCPApprovalPolicy.defaultLifetime, 1), MCPApprovalPolicy.defaultLifetime)),
            reason: reason,
            capability: capability
        )
        pendingByID[request.requestID] = request
        lifecycleByID[request.requestID] = LifecycleRecord(
            request: request,
            mcpSessionID: mcpSessionID,
            proposalToken: proposalToken,
            status: .pending,
            updatedAt: now
        )
        refreshPublishedPending(now: now)
        MCPLog.approvals.info("Created approval request \(request.requestID, privacy: .public) for capability \(capability.rawValue, privacy: .public).")
        return request
    }

    func pendingRequest(requestID: String) -> MCPApprovalRequest? {
        pendingByID[requestID]
    }

    /// Approves a pending request and returns a one-use authorization for an exact-argument retry.
    func approve(requestID: String, now: Date = Date()) throws -> MCPApprovalAuthorization {
        pruneExpired(now: now)
        guard let request = pendingByID[requestID] else {
            if lifecycleByID[requestID]?.status == .expired {
                throw MCPApprovalStoreError.requestExpired
            }
            if lifecycleByID[requestID]?.status == .invalidated {
                throw MCPApprovalStoreError.requestInvalidated
            }
            throw MCPApprovalStoreError.requestNotFound
        }
        if MCPApprovalPolicy.isInvalidated(request: request, currentPolicyRevision: request.policyRevision, now: now) {
            pendingByID.removeValue(forKey: requestID)
            refreshPublishedPending(now: now)
            throw MCPApprovalStoreError.requestInvalidated
        }
        pendingByID.removeValue(forKey: requestID)
        lifecycleByID[requestID]?.status = .approvedAwaitingRetry
        lifecycleByID[requestID]?.updatedAt = now
        refreshPublishedPending(now: now)
        let authorization = MCPApprovalAuthorization(
            requestID: request.requestID,
            clientID: request.clientID,
            capability: request.capability,
            argumentDigest: request.argumentDigest,
            policyRevision: request.policyRevision,
            targetRevision: request.targetRevision,
            nonce: UUID().uuidString,
            expiresAt: request.expiresAt
        )
        grantedByNonce[authorization.nonce] = (request: request, authorization: authorization)
        MCPLog.approvals.info("Approved request \(requestID, privacy: .public); awaiting exact retry.")
        return authorization
    }

    /// Consumes a human-approved exact retry without requiring clients to receive a nonce from UI.
    func consumeApprovedRequest(
        clientID: String,
        mcpSessionID: String?,
        capability: MCPCapabilityID,
        argumentDigest: String,
        policyRevision: MCPPolicyRevision,
        targetRevision: MCPTargetRevision? = nil,
        proposalToken: String? = nil,
        now: Date = Date()
    ) -> Bool {
        pruneExpired(now: now)
        guard let match = lifecycleByID.first(where: { _, record in
            record.status == .approvedAwaitingRetry
                && record.request.clientID == clientID
                && record.mcpSessionID == mcpSessionID
                && record.request.capability == capability
                && record.request.argumentDigest == argumentDigest
                && record.request.policyRevision == policyRevision
                && record.request.targetRevision == targetRevision
                && record.proposalToken == proposalToken
        }) else { return false }
        lifecycleByID[match.key]?.status = .consumed
        lifecycleByID[match.key]?.updatedAt = now
        grantedByNonce = grantedByNonce.filter { $0.value.request.requestID != match.key }
        MCPLog.approvals.info("Consumed approved request \(match.key, privacy: .public) by exact retry.")
        return true
    }

    func status(requestID: String, clientID: String, mcpSessionID: String?, now: Date = Date()) -> MCPApprovalStatusDTO? {
        pruneExpired(now: now)
        guard let record = lifecycleByID[requestID],
              record.request.clientID == clientID,
              record.mcpSessionID == mcpSessionID else { return nil }
        return MCPApprovalStatusDTO(
            requestID: requestID,
            status: record.status,
            capability: record.request.capability,
            expiresAt: record.request.expiresAt,
            updatedAt: record.updatedAt,
            retryInstruction: record.status == .approvedAwaitingRetry
                ? "Retry the identical tool call; approval will be consumed once."
                : nil
        )
    }

    /// Lists every currently-pending approval request for a client, across all of that client's
    /// logical MCP sessions — the same client-wide scope `clientCleanupStatus`'s
    /// `pendingApprovalCount` already uses, generalized from a count to the full list with
    /// `capability`/`reason` included. Backs the `approvals_list` tool, added because the only prior
    /// way to discover a pending request's capability/reason was the single `requestID` surfaced by
    /// whichever specific tool call happened to trigger it.
    func pendingList(clientID: String, now: Date = Date()) -> [MCPApprovalPendingItemDTO] {
        pruneExpired(now: now)
        return pendingRequests
            .filter { $0.clientID == clientID }
            .sorted { $0.expiresAt < $1.expiresAt }
            .map {
                MCPApprovalPendingItemDTO(
                    requestID: $0.requestID,
                    capability: $0.capability,
                    reason: $0.reason,
                    expiresAt: $0.expiresAt
                )
            }
    }

    func recentStatuses(clientID: String, limit: Int = 10, now: Date = Date()) -> [MCPApprovalStatusDTO] {
        pruneExpired(now: now)
        return lifecycleByID.values
            .filter { $0.request.clientID == clientID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, min(limit, 32)))
            .map { record in
                MCPApprovalStatusDTO(
                    requestID: record.request.requestID,
                    status: record.status,
                    capability: record.request.capability,
                    expiresAt: record.request.expiresAt,
                    updatedAt: record.updatedAt,
                    retryInstruction: record.status == .approvedAwaitingRetry
                        ? "Retry the identical tool call; approval will be consumed once."
                        : nil
                )
            }
    }

    /// Looks up the server-recorded grant for a nonce a client presents on retry. Returns `nil` for
    /// a nonce that was never actually granted by `approve(requestID:)` — including a fabricated one
    /// — so the caller can reject it the same way as a missing approval, never trusting the client's
    /// own copy of the request/authorization fields.
    func grantedAuthorization(nonce: String) -> (request: MCPApprovalRequest, authorization: MCPApprovalAuthorization)? {
        grantedByNonce[nonce]
    }

    func deny(requestID: String, now: Date = Date()) throws {
        pruneExpired(now: now)
        guard pendingByID.removeValue(forKey: requestID) != nil else {
            throw MCPApprovalStoreError.requestNotFound
        }
        lifecycleByID[requestID]?.status = .denied
        lifecycleByID[requestID]?.updatedAt = now
        refreshPublishedPending(now: now)
        MCPLog.approvals.info("Denied approval request \(requestID, privacy: .public).")
    }

    /// Returns `true` when the nonce was already consumed.
    func nonceAlreadyUsed(_ nonce: String, now: Date = Date()) -> Bool {
        pruneExpired(now: now)
        return usedNonces[nonce] != nil
    }

    func nonceExpired(_ nonce: String, now: Date = Date()) -> Bool {
        pruneExpired(now: now)
        return expiredNonces[nonce] != nil
    }

    func consumeNonce(_ nonce: String, now: Date = Date()) {
        pruneExpired(now: now)
        usedNonces[nonce] = now
        if let requestID = grantedByNonce[nonce]?.request.requestID {
            lifecycleByID[requestID]?.status = .consumed
            lifecycleByID[requestID]?.updatedAt = now
        }
        grantedByNonce.removeValue(forKey: nonce)
    }

    func invalidateAllPending(now: Date = Date()) {
        for requestID in pendingByID.keys {
            lifecycleByID[requestID]?.status = .invalidated
            lifecycleByID[requestID]?.updatedAt = now
        }
        pendingByID.removeAll()
        refreshPublishedPending(now: now)
    }

    func invalidate(proposalToken: String, now: Date = Date()) {
        let requestIDs = lifecycleByID.compactMap { requestID, record in
            record.proposalToken == proposalToken
                && (record.status == .pending || record.status == .approvedAwaitingRetry)
                ? requestID
                : nil
        }
        for requestID in requestIDs {
            pendingByID.removeValue(forKey: requestID)
            lifecycleByID[requestID]?.status = .invalidated
            lifecycleByID[requestID]?.updatedAt = now
            grantedByNonce = grantedByNonce.filter { $0.value.request.requestID != requestID }
        }
        refreshPublishedPending(now: now)
    }

    /// Clears pending approvals and server-side grant records during Return To Normal.
    func clearAllForRecovery(now: Date = Date()) {
        invalidateAllPending(now: now)
        grantedByNonce.removeAll()
        usedNonces.removeAll()
        expiredNonces.removeAll()
        lifecycleByID.removeAll()
    }

    func prunePending(for clientID: String, now: Date = Date()) {
        pendingByID = pendingByID.filter { $0.value.clientID != clientID }
        grantedByNonce = grantedByNonce.filter { $0.value.request.clientID != clientID }
        lifecycleByID = lifecycleByID.filter { $0.value.request.clientID != clientID }
        refreshPublishedPending(now: now)
    }

    func pruneExpired(now: Date = Date()) {
        for (nonce, grant) in grantedByNonce where now >= grant.authorization.expiresAt {
            expiredNonces[nonce] = now
        }
        let expiredIDs = lifecycleByID.compactMap { requestID, record in
            (record.status == .pending || record.status == .approvedAwaitingRetry)
                && now >= record.request.expiresAt ? requestID : nil
        }
        for requestID in expiredIDs {
            pendingByID.removeValue(forKey: requestID)
            lifecycleByID[requestID]?.status = .expired
            lifecycleByID[requestID]?.updatedAt = now
            grantedByNonce = grantedByNonce.filter { $0.value.request.requestID != requestID }
            MCPLog.approvals.info("Expired approval request \(requestID, privacy: .public).")
        }
        let cutoff = now.addingTimeInterval(-MCPApprovalPolicy.defaultLifetime)
        usedNonces = usedNonces.filter { $0.value >= cutoff }
        expiredNonces = expiredNonces.filter {
            now.timeIntervalSince($0.value) < MCPApprovalPolicy.terminalRetention
        }
        grantedByNonce = grantedByNonce.filter { now < $0.value.authorization.expiresAt }
        lifecycleByID = lifecycleByID.filter { _, record in
            record.status == .pending || record.status == .approvedAwaitingRetry
                || now.timeIntervalSince(record.updatedAt) < MCPApprovalPolicy.terminalRetention
        }
        let grouped = Dictionary(grouping: lifecycleByID, by: { $0.value.request.clientID })
        for records in grouped.values where records.count > MCPApprovalPolicy.maxTerminalRecordsPerClient {
            let removable = records
                .filter { $0.value.status != .pending && $0.value.status != .approvedAwaitingRetry }
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
            for record in removable.prefix(records.count - MCPApprovalPolicy.maxTerminalRecordsPerClient) {
                lifecycleByID.removeValue(forKey: record.key)
            }
        }
        refreshPublishedPending(now: now)
    }

    private func refreshPublishedPending(now: Date) {
        pendingRequests = pendingByID.values.sorted { $0.expiresAt < $1.expiresAt }
    }
}
