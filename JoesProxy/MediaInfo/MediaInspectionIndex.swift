import Combine
import Foundation

/// Bounded related-capture projection. Ordinary media segments never invalidate manifest parsing.
@MainActor
final class MediaInspectionIndex: ObservableObject {
    let manifestModel = MediaManifestModel()
    @Published private(set) var selectedRevision: UInt64 = 0
    private var selectedID: UUID?
    private let store: any SessionStore
    @Published private(set) var browsingOlder = false
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var hasOmittedCandidates = false
    private var subscription: AnyCancellable?
    private var records: [UUID: SessionRecord] = [:]
    private var order: [UUID] = []
    private var bytes = 0
    private let maxRecords = 128
    private let maxBytes = 16 * 1_024 * 1_024

    init(store: any SessionStore) {
        self.store = store
        replace(store.sessions)
        subscription = store.sessionChangesPublisher.sink { [weak self] change in
            self?.consume(change)
        }
    }

    private func consume(_ change: SessionStoreChange) {
        switch change {
        case .appended(let record, let dropped):
            let removed = remove(dropped)
            if upsert(record) || removed { publish() }
        case .updated(let record, _):
            if record.id == selectedID { selectedRevision &+= 1 }
            if upsert(record) { publish() }
        case .updatedBatch(let batch, _), .bodiesStripped(let batch):
            if batch.contains(where: { $0.id == selectedID }) { selectedRevision &+= 1 }
            var changed = false
            for record in batch { if upsert(record) { changed = true } }
            if changed { publish() }
        case .removed(let ids):
            if remove(ids) { publish() }
        case .cleared:
            selectedRevision &+= 1
            selectedID = nil
            manifestModel.reset()
            replace([])
        case .loaded(let batch, _):
            selectedRevision &+= 1
            manifestModel.reset()
            replace(batch)
        }
    }

    private func replace(_ batch: [SessionRecord]) {
        browsingOlder = false
        records = [:]; order = []; bytes = 0; hasOmittedCandidates = false
        for record in batch { _ = upsert(record) }
        publish()
    }

    private func upsert(_ record: SessionRecord) -> Bool {
        if browsingOlder && records[record.id] == nil { return false }
        let path = record.request.path.lowercased()
        let mime = record.response?.headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        let relevant = path.contains(".m3u") || path.contains(".mpd") || mime.contains("mpegurl")
            || mime.contains("dash+xml") || path.contains("license") || path.contains("fps")
            || path.contains("fairplay") || path.contains("widevine") || path.contains("getcertificate")
        guard relevant else { return remove([record.id]) }
        _ = remove([record.id])
        let cost = (record.request.bodyData?.count ?? 0) + (record.response?.bodyData?.count ?? 0)
        guard cost <= maxBytes else { hasOmittedCandidates = true; return true }
        records[record.id] = record; order.append(record.id); bytes += cost
        while order.count > maxRecords || bytes > maxBytes {
            guard let oldest = order.first else { break }
            _ = remove([oldest]); hasOmittedCandidates = true
        }
        return true
    }

    private func remove(_ ids: Set<UUID>) -> Bool {
        var changed = false
        for id in ids {
            if let record = records.removeValue(forKey: id) {
                bytes -= (record.request.bodyData?.count ?? 0) + (record.response?.bodyData?.count ?? 0)
                changed = true
            }
        }
        if changed { order.removeAll { ids.contains($0) } }
        return changed
    }

    private func publish() {
        sessions = order.compactMap { records[$0] }
        revision &+= 1
    }

    func select(_ id: UUID) {
        if selectedID != id { selectedID = id; selectedRevision &+= 1 }
    }

    func showLatest() {
        browsingOlder = false
        replace(store.sessions)
    }

    func showOlder() {
        guard let oldest = order.first,
              let index = store.sessions.firstIndex(where: { $0.id == oldest }), index > 0 else { return }
        browsingOlder = false
        replace(Array(store.sessions.prefix(index)))
        browsingOlder = true
    }
}
