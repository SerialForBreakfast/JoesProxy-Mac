import Combine
import Foundation

/// Main-actor authority/lifetime owner. File bytes never enter capture, persistence, audit or prompts.
@MainActor
final class ArtifactSourceRegistry: ObservableObject {
    struct Owner: Equatable, Sendable {
        let clientID: String
        let generation: Int
        let policyRevision: MCPPolicyRevision
        let profile: MCPDisclosureProfileID
    }
    struct Request: Identifiable {
        var id: String { approval.requestID }
        let key: String
        let owner: Owner
        let kind: ArtifactSourceKind
        let scopes: [String]
        let ttl: Int
        let argumentDigest: String
        let approval: MCPApprovalRequest
        let deadline: Date
        let forgetAt: Date
        var state = "pending_selection"
        var localName: String?
        var localPath: String?
        var localFailure: String?
        var generation = UUID()
        var snapshot: ArtifactSnapshot?
        var handle: String?
        var revision: String?
        var expiresAt: Date?
        var reservedBytes = 0
        var lastAccess = Date()
    }

    @Published private(set) var requests: [Request] = []
    let worker: ArtifactAnalysisWorker
    let searchSessions = ArtifactSearchSessions()
    let fileCoordinator: ArtifactSourceFileCoordinator
    private let approvals: MCPApprovalStore
    struct PairReview {
        let approval: MCPApprovalRequest
        let query: SavedResponsePair
        let owner: Owner
        let session: String
        let token: String
        let clientName: String
        let baselineLabel: String
        let candidateLabel: String
    }
    @Published private(set) var pairReviews: [String: PairReview] = [:]
    var currentComparePermission: ((String) -> Bool)?
    private var preparation: [String: Task<Void, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var activeUses: [String: Int] = [:]
    var currentOwner: ((String) -> Owner?)?
    var currentCalculationPermission: ((String) -> Bool)?
    var currentBriefPermission: ((String) -> Bool)?
    var currentSearchPermission: ((String) -> Bool)?

    init(worker: ArtifactAnalysisWorker, approvals: MCPApprovalStore,
         fileCoordinator: ArtifactSourceFileCoordinator? = nil) {
        self.worker = worker
        self.approvals = approvals
        self.fileCoordinator = fileCoordinator ?? ArtifactSourceFileCoordinator()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.retireIdleSourceForMemoryPressure() }
        }
        pressure.resume()
        memoryPressure = pressure
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.prune()
            }
        }
    }

    deinit { cleanupTask?.cancel(); memoryPressure?.cancel() }

    func register(key: String, kind: ArtifactSourceKind, scopes: [String], ttl: Int, owner: Owner,
                  argumentDigest: String, sessionID: String?, now: Date = Date()) throws -> Request {
        prune(now: now)
        guard UUID(uuidString: key) != nil, (60...3600).contains(ttl),
              Set(scopes).count == scopes.count, scopes.contains("metadata-v1"),
              Set(scopes).isSubset(of: ["metadata-v1", "calculations-v1", "search-v1", "brief-v1"]),
              !scopes.contains("brief-v1") || (owner.profile == .shareable && (kind == .recording || kind == .har)),
              !scopes.contains("search-v1") || owner.profile == .shareable,
              !scopes.contains("calculations-v1") || owner.profile == .shareable else { throw ArtifactAnalysisFailure.malformedRequest }
        if let request = requests.first(where: { $0.key == key && $0.owner.clientID == owner.clientID }) {
            guard request.owner == owner, request.argumentDigest == argumentDigest else { throw ArtifactAnalysisFailure.sourceUnavailable }
            return request
        }
        guard requests.count < 256, requests.filter({ $0.owner.clientID == owner.clientID }).count < 64,
              requests.filter({ isPending($0) }).count < 4,
              requests.filter({ $0.owner.clientID == owner.clientID && isPending($0) }).count < 2 else {
            throw ArtifactAnalysisFailure.busy
        }
        let approval = approvals.createPendingRequest(clientID: owner.clientID, capability: .artifactSourceAccess,
            argumentDigest: argumentDigest, policyRevision: owner.policyRevision, mcpSessionID: sessionID,
            reason: "Select and review one local \(kind.rawValue) source; requested scopes: \(scopes.sorted().joined(separator: ", ")).", lifetime: 300, now: now)
        let request = Request(key: key, owner: owner, kind: kind, scopes: scopes.sorted(), ttl: ttl,
            argumentDigest: argumentDigest, approval: approval,
            deadline: min(now.addingTimeInterval(300), approval.expiresAt), forgetAt: now.addingTimeInterval(3600))
        requests.append(request)
        return request
    }

    func request(id: String) -> Request? { requests.first { $0.id == id } }

    func status(key: String, owner: Owner) throws -> Request {
        prune()
        guard let request = requests.first(where: { $0.key == key && $0.owner == owner }) else {
            throw ArtifactAnalysisFailure.sourceUnavailable
        }
        return request
    }

    func waitForPreparation(id: String) async { await preparation[id]?.value }

    func prepare(id: String, selection: ArtifactSourceFileCoordinator.Selection) {
        prune()
        guard let index = requests.firstIndex(where: { $0.id == id }), isPending(requests[index]),
              preparation[id] == nil, !worker.busy else { return }
        let owner = requests[index].owner
        // Replacing an unshared draft invalidates it before admitting the new preparation.
        requests[index].snapshot = nil
        let active = requests.filter { $0.snapshot != nil || $0.reservedBytes > 0 }
        guard active.count < 8, active.filter({ $0.owner.clientID == owner.clientID }).count < 4 else {
            requests[index].localFailure = ArtifactAnalysisFailure.inputLimit.rawValue; return
        }
        let total = active.reduce(0) { $0 + max($1.reservedBytes, $1.snapshot?.retainedBytes ?? 0) }
        let owned = active.filter { $0.owner.clientID == owner.clientID }.reduce(0) { $0 + max($1.reservedBytes, $1.snapshot?.retainedBytes ?? 0) }
        let available = min(128 * 1024 * 1024 - total, 64 * 1024 * 1024 - owned)
        let reservation: Int
        switch requests[index].kind {
        case .json: reservation = 36 * 1024 * 1024
        case .text: reservation = 8 * 1024 * 1024
        case .image: reservation = 40 * 1024 * 1024
        case .recording, .har: reservation = min(available, ArtifactSnapshotReader.maximumRetainedBytes)
        case .effectBundle: reservation = ArtifactSnapshotReader.maximumRetainedBytes
        }
        guard reservation > 0, reservation <= available else {
            requests[index].localFailure = ArtifactAnalysisFailure.inputLimit.rawValue; return
        }
        let generation = UUID()
        requests[index].generation = generation
        requests[index].snapshot = nil
        requests[index].localFailure = nil
        switch selection {
        case .file(let url):
            requests[index].localName = url.lastPathComponent
            requests[index].localPath = url.path
        case .synthetic:
            requests[index].localName = "Synthetic source.json"
            requests[index].localPath = nil
        }
        requests[index].state = "preparing"
        requests[index].reservedBytes = reservation
        let kind = requests[index].kind
        preparation[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.preparation[id] = nil
                if let index = self.requests.firstIndex(where: { $0.id == id }) { self.requests[index].reservedBytes = 0 }
            }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                let snapshot = try await self.worker.perform {
                    switch selection {
                    case .file(let url): return try ArtifactSnapshotReader.read(url: url, kind: kind, deadline: deadline, budget: reservation)
                    case .synthetic(let data): return try ArtifactSnapshotReader.decode(data: data, kind: kind, deadline: deadline, budget: reservation)
                    }
                }
                self.prune()
                guard let index = self.requests.firstIndex(where: { $0.id == id }),
                      self.requests[index].generation == generation, self.requests[index].state == "preparing" else { return }
                self.requests[index].snapshot = snapshot
                self.requests[index].state = "review"
            } catch {
                guard let index = self.requests.firstIndex(where: { $0.id == id }),
                      self.requests[index].generation == generation, self.requests[index].state == "preparing" else { return }
                self.requests[index].state = "pending_selection"
                self.requests[index].localFailure = (error as? ArtifactAnalysisFailure)?.rawValue ?? "preparation_failed"
            }
        }
    }

    func share(id: String, now: Date = Date()) throws {
        prune(now: now)
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].state == "review",
              requests[index].snapshot != nil, requests[index].reservedBytes == 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        // Only this local review action can approve an artifact request. Generic Allow Once rejects it.
        _ = try approvals.approve(requestID: id, now: now)
        requests[index].state = "approved_awaiting_retry"
        requests[index].revision = UUID().uuidString
    }

    func publish(id: String, owner: Owner, now: Date = Date()) throws -> Request {
        prune(now: now)
        guard let index = requests.firstIndex(where: { $0.id == id && $0.owner == owner }),
              requests[index].state == "approved_awaiting_retry", requests[index].snapshot != nil else {
            throw ArtifactAnalysisFailure.sourceUnavailable
        }
        requests[index].handle = UUID().uuidString
        requests[index].expiresAt = now.addingTimeInterval(TimeInterval(requests[index].ttl))
        requests[index].state = "ready"
        return requests[index]
    }

    func inspect(handle: String, owner: Owner) throws -> Request {
        prune()
        guard let index = requests.firstIndex(where: { $0.handle == handle && $0.owner == owner && $0.state == "ready" }),
              requests[index].snapshot != nil else { throw ArtifactAnalysisFailure.sourceUnavailable }
        requests[index].lastAccess = Date()
        return requests[index]
    }

    func setInUse(_ id: String, _ active: Bool) {
        let count = (activeUses[id] ?? 0) + (active ? 1 : -1)
        activeUses[id] = count > 0 ? count : nil
    }

    func retireIdleSourceForMemoryPressure() {
        if let request = requests.filter({ $0.snapshot != nil && activeUses[$0.id] == nil && $0.reservedBytes == 0 })
            .min(by: { $0.lastAccess < $1.lastAccess }) {
            retire(id: request.id, reason: "memory_pressure")
        }
    }

    func release(handle: String, clientID: String) throws {
        prune()
        guard let request = requests.first(where: { $0.handle == handle && $0.owner.clientID == clientID }) else {
            throw ArtifactAnalysisFailure.sourceUnavailable
        }
        retire(id: request.id, reason: "released")
    }

    func retire(id: String, reason: String = "cancelled") {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        if let handle = requests[index].handle {
            searchSessions.retire(handle: handle)
            invalidatePairs { $0.query.baseline.handle == handle || $0.query.candidate.handle == handle }
        }
        preparation[id]?.cancel()
        requests[index].generation = UUID()
        requests[index].snapshot = nil
        requests[index].localName = nil
        requests[index].localPath = nil
        requests[index].localFailure = nil
        requests[index].state = reason
        try? approvals.deny(requestID: id)
    }

    func revokeAll() {
        for id in requests.map(\.id) { retire(id: id, reason: "revoked") }
    }

    func cancelUnsharedReviews() {
        for request in requests where request.state == "preparing" || request.state == "review" {
            retire(id: request.id)
        }
    }

    func prune(now: Date = Date()) {
        searchSessions.prune(now: now)
        for (id, review) in pairReviews {
            let status = approvals.status(requestID: id, clientID: review.owner.clientID, mcpSessionID: review.session, now: now)?.status
            if status != .pending && status != .approvedAwaitingRetry {
                pairReviews.removeValue(forKey: id)
            } else if currentComparePermission?(review.owner.clientID) != true {
                approvals.invalidate(proposalToken: review.token, now: now)
                pairReviews.removeValue(forKey: id)
            }
        }
        for request in requests {
            if isTerminal(request) { continue }
            if currentOwner?(request.owner.clientID) != request.owner ||
                (request.scopes.contains("brief-v1") && currentBriefPermission?(request.owner.clientID) != true) ||
                (request.scopes.contains("search-v1") && currentSearchPermission?(request.owner.clientID) != true) ||
                (request.scopes.contains("calculations-v1") && currentCalculationPermission?(request.owner.clientID) != true) {
                retire(id: request.id, reason: "revoked")
            } else if now >= (request.state == "ready" ? request.expiresAt ?? now : request.deadline) {
                retire(id: request.id, reason: "expired")
            } else if isPending(request), approvals.pendingRequest(requestID: request.id) == nil {
                retire(id: request.id, reason: "cancelled")
            }
        }
        requests.removeAll { isTerminal($0) && $0.reservedBytes == 0 && now >= $0.forgetAt }
    }

    private func isPending(_ request: Request) -> Bool { ["pending_selection", "preparing", "review"].contains(request.state) }
    private func isTerminal(_ request: Request) -> Bool { !isPending(request) && request.state != "ready" && request.state != "approved_awaiting_retry" }

    func invalidatePairs(where predicate: (PairReview) -> Bool) {
        for (id, review) in pairReviews where predicate(review) {
            approvals.invalidate(proposalToken: review.token)
            pairReviews.removeValue(forKey: id)
        }
    }

    func pairSource(_ side: SavedResponsePair.Side, owner: Owner) throws -> Request {
        let source = try inspect(handle: side.handle, owner: owner)
        guard owner.profile == .shareable, currentComparePermission?(owner.clientID) == true,
              source.scopes.contains("brief-v1"), source.revision == side.snapshotRevision,
              source.kind == .har || source.kind == .recording else { throw ArtifactAnalysisFailure.sourceUnavailable }
        return source
    }

    func approvePair(id: String) throws {
        guard let review = pairReviews[id] else { throw ArtifactAnalysisFailure.sourceUnavailable }
        _ = try pairSource(review.query.baseline, owner: review.owner)
        _ = try pairSource(review.query.candidate, owner: review.owner)
        _ = try approvals.approve(requestID: id)
    }

    /// Only an identical retry in the proposing logical session can consume a local decision.
    func admitPair(_ query: SavedResponsePair, owner: Owner, session: String, clientName: String,
                   baseline: Request, candidate: Request) throws -> Date {
        let digest = try MCPBriefReadCache.scope([SavedResponsePair.version, owner.clientID, String(owner.generation),
            owner.policyRevision.rawValue, owner.profile.rawValue, session,
            query.baseline.handle, query.baseline.snapshotRevision, String(query.baseline.recordIndex),
            query.candidate.handle, query.candidate.snapshotRevision, String(query.candidate.recordIndex), query.pointer])
        if let existing = pairReviews.values.first(where: { $0.approval.argumentDigest == digest }) {
            if approvals.pendingRequest(requestID: existing.approval.requestID) != nil {
                throw MCPStructuredError.approvalRequired(existing.approval)
            }
            guard !worker.busy else { throw ArtifactAnalysisFailure.busy }
            guard approvals.consumeApprovedRequest(clientID: owner.clientID, mcpSessionID: session,
                capability: .artifactCompare, argumentDigest: digest, policyRevision: owner.policyRevision,
                proposalToken: existing.token) else { throw ArtifactAnalysisFailure.sourceUnavailable }
            pairReviews.removeValue(forKey: existing.approval.requestID)
            return existing.approval.expiresAt
        }
        guard !worker.busy, pairReviews.count < 4, pairReviews.values.filter({ $0.owner.clientID == owner.clientID }).count < 2 else {
            throw ArtifactAnalysisFailure.busy
        }
        let now = Date()
        guard let firstExpiry = baseline.expiresAt, let secondExpiry = candidate.expiresAt,
              min(firstExpiry, secondExpiry).timeIntervalSince(now) >= 1 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        let token = UUID().uuidString
        let approval = approvals.createPendingRequest(clientID: owner.clientID, capability: .artifactCompare,
            argumentDigest: digest, policyRevision: owner.policyRevision, mcpSessionID: session, proposalToken: token,
            reason: "Review a one-time comparison of two saved responses.", lifetime: min(firstExpiry, secondExpiry).timeIntervalSince(now), now: now)
        pairReviews[approval.requestID] = PairReview(approval: approval, query: query, owner: owner, session: session, token: token,
            clientName: clientName, baselineLabel: baseline.localName ?? baseline.kind.rawValue,
            candidateLabel: candidate.localName ?? candidate.kind.rawValue)
        throw MCPStructuredError.approvalRequired(approval)
    }
}
