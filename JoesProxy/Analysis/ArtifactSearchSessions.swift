import Foundation

/// Memory-only state for approved snapshot searches. Every lookup follows a fresh registry authority check.
@MainActor
final class ArtifactSearchSessions {
    // Internal experiment injection. Clients cannot select an implementation.
    var nativeProbe = false
    var observePage: ((Duration, Int) -> Void)?
    struct Binding: Equatable {
        let owner: ArtifactSourceRegistry.Owner
        let handle: String
        let revision: String
        let query: ArtifactSearchQuery
    }
    private struct Cursor {
        let binding: Binding
        let expires: Date
        var next: String?
        var previous: String?
        var position: ArtifactSearch.Position
        var lastPage: [String: Any]?
    }
    private struct Reference {
        let binding: Binding
        let expires: Date
        let item: ArtifactSearch.Item
    }
    private var cursors: [Cursor] = []
    private var references: [Reference] = []

    func prune(now: Date) {
        cursors.removeAll { $0.expires <= now }
        references.removeAll { $0.expires <= now }
    }

    func retire(handle: String) {
        cursors.removeAll { $0.binding.handle == handle }
        references.removeAll { $0.binding.handle == handle }
    }

    private func index(token: String, binding: Binding) throws -> Int {
        guard let index = cursors.firstIndex(where: { $0.binding == binding && ($0.next == token || $0.previous == token) }) else {
            throw ArtifactAnalysisFailure.cursorExpired
        }
        return index
    }

    func run(registry: ArtifactSourceRegistry, request: ArtifactSourceRegistry.Request, query: ArtifactSearchQuery,
             token: String?, envelopeSize: ([String: Any]) throws -> Int) async throws -> [String: Any] {
        guard let handle = request.handle else { throw ArtifactAnalysisFailure.sourceUnavailable }
        let approved = try registry.inspect(handle: handle, owner: request.owner)
        guard approved.scopes.contains("search-v1"), approved.owner.profile == .shareable,
              let revision = approved.revision, request.revision == revision, let lease = approved.expiresAt,
              let snapshot = approved.snapshot else { throw ArtifactAnalysisFailure.sourceUnavailable }
        let binding = Binding(owner: request.owner, handle: handle, revision: revision, query: query)
        let start: ArtifactSearch.Position
        let expiry: Date
        if let token {
            let cursor = cursors[try index(token: token, binding: binding)]
            if cursor.previous == token, let last = cursor.lastPage {
                let retained = Set(references.lazy.filter { $0.binding == binding }.compactMap { $0.item.matchRef })
                let rows = last["items"] as? [[String: Any]] ?? []
                guard rows.compactMap({ $0["matchRef"] as? String }).allSatisfy(retained.contains) else {
                    throw ArtifactAnalysisFailure.cursorExpired
                }
                guard try envelopeSize(last) <= 8192 else { throw ArtifactAnalysisFailure.outputLimit }
                return last
            }
            start = cursor.position
            expiry = cursor.expires
        } else {
            start = .init()
            expiry = min(lease, Date().addingTimeInterval(300))
        }
        guard !registry.worker.busy else { throw ArtifactAnalysisFailure.busy }
        registry.setInUse(request.id, true)
        defer { registry.setInUse(request.id, false) }
        let probe = nativeProbe
        let measure = observePage != nil
        let (page, elapsed) = try await registry.worker.perform {
            let began = measure ? ContinuousClock.now : nil
            let result = try ArtifactSearch.page(snapshot: snapshot, query: query, from: start, nativeProbe: probe)
            return (result, began?.duration(to: .now))
        }
        let current = try registry.inspect(handle: handle, owner: request.owner)
        guard current.revision == revision, current.scopes.contains("search-v1"), Date() < expiry else { throw ArtifactAnalysisFailure.cursorExpired }
        try Task.checkCancellation()
        let next = page.completeTraversal ? nil : UUID().uuidString
        let position = page.position
        let complete = page.completeTraversal && position.omissions.isEmpty
        let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page.items))
        let payload: [String: Any] = [
            "handle": handle, "snapshotRevision": revision, "analyzerVersion": "artifact-search-v1",
            "dataset": query.dataset.rawValue, "status": complete ? "complete" : (page.completeTraversal ? "incomplete" : "continuation"),
            "items": items, "hasMore": next != nil, "nextCursor": next as Any,
            "observedCount": position.observed, "exactTotal": complete ? position.observed as Any : NSNull(),
            "coverage": ["selectedUnits": page.domainCount, "examinedUnits": position.record, "searchedUnits": position.searched,
                         "excludedUnits": position.excluded, "remainingUnits": page.domainCount - position.record,
                         "omissions": position.omissions, "pageScannedBytes": page.scannedBytes] as [String: Any]
        ]
        let encodedSize = try envelopeSize(payload)
        guard encodedSize <= 8192 else { throw ArtifactAnalysisFailure.outputLimit }
        if let elapsed { observePage?(elapsed, encodedSize) }
        if let token {
            let i = try index(token: token, binding: binding)
            cursors[i].previous = token
            cursors[i].lastPage = payload
            cursors[i].next = next
            cursors[i].position = position
        } else if next != nil {
            if cursors.filter({ $0.binding.owner.clientID == binding.owner.clientID }).count >= 8,
               let i = cursors.firstIndex(where: { $0.binding.owner.clientID == binding.owner.clientID }) { cursors.remove(at: i) }
            if cursors.count >= 32 { cursors.removeFirst() }
            cursors.append(Cursor(binding: binding, expires: expiry, next: next, position: position))
        }
        for item in page.items where item.matchRef != nil {
            references.append(Reference(binding: binding, expires: expiry, item: item))
        }
        var excess = references.filter { $0.binding.owner.clientID == binding.owner.clientID }.count - 256
        references.removeAll { item in
            guard excess > 0 && item.binding.owner.clientID == binding.owner.clientID else { return false }
            excess -= 1
            return true
        }
        if references.count > 1024 { references.removeFirst(references.count - 1024) }
        return payload
    }
}
