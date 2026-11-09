import Foundation

/// One immutable body revision owned by a JoesProxy-managed response draft.
///
/// Revisions are append-only: commits never overwrite prior body bytes in place.
struct ResponseDraftRevision: Equatable, Sendable, Codable, Identifiable {
    /// Stable opaque revision identifier used by Map Local (`responseRevisionID`).
    var id: UUID
    /// Zero-based order within the owning draft (0 is the original capture copy).
    var revisionIndex: Int
    /// Exact body bytes for this revision (UTF-8 text when editable).
    var bodyData: Data
    /// Hex SHA-256 of ``bodyData``.
    var bodySHA256: String
    var statusCode: Int
    var contentType: String
    /// Prior revision when this entry was produced by a commit; `nil` for the original.
    var parentRevisionID: UUID?
    var createdAt: Date
    /// Preview digest consumed to produce this revision, when applicable.
    var previewDigest: String?
}

/// Persistent, revisioned local working copy of a captured response.
///
/// Ownership is per MCP client. Map Local may bind a revision via ``ResponseDraft/boundOverrideIDsByRevisionID``.
struct ResponseDraft: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var label: String?
    var clientID: String
    var sourceSessionID: UUID
    var sourceCaptureSequence: UInt64
    /// Matcher captured at draft creation so Map Local can serve a revision after the source
    /// capture session is cleared.
    var matcher: MCPMutationMatcher
    var originalRevisionID: UUID
    var currentRevisionID: UUID
    var revisions: [ResponseDraftRevision]
    /// Override rule IDs that currently bind a revision from this draft (best-effort; pruned on read).
    var boundOverrideIDsByRevisionID: [UUID: [UUID]]
    var createdAt: Date
    var updatedAt: Date

    /// Body revision currently selected as the draft tip.
    var currentRevision: ResponseDraftRevision? {
        revisions.first(where: { $0.id == currentRevisionID })
    }
}

/// Failures from ``ResponseDraftStore`` load/mutate/persist operations.
enum ResponseDraftStoreError: Error, Equatable, Sendable {
    case notLoaded
    case corruptPersistence
    case draftNotFound
    case revisionNotFound
    case quotaExceeded(String)
    case notOwner
}

/// JSON-backed, quota-bound repository for response drafts.
///
/// Concurrency: `@MainActor` — wired beside other MCP persistence stores and mutated only from
/// mutation/apply handlers on the main actor.
@MainActor
final class ResponseDraftStore {
    static let persistenceFileName = "response-draft-store.json"
    static let persistenceSchemaVersion = 1
    static let maxDraftsPerClient = 16
    static let maxRevisionsPerDraft = 32
    static let maxBodyBytesPerRevision = 2 * 1024 * 1024
    static let maxAggregateBytesPerClient = 16 * 1024 * 1024

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var drafts: [ResponseDraft]
    }

    private(set) var drafts: [ResponseDraft] = []
    private(set) var isLoaded = false
    private(set) var loadFailureReason: String?

    private let persistenceURL: URL
    private let fileManager: FileManager

    init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    func load() {
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported response-draft store schema version.")
                    return
                }
                drafts = persisted.drafts
            } else {
                drafts = []
            }
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "Response-draft store failed to load.")
        }
    }

    func persist() throws {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, drafts: drafts)
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func draft(id: UUID) -> ResponseDraft? {
        drafts.first(where: { $0.id == id })
    }

    func revision(id: UUID) -> (draft: ResponseDraft, revision: ResponseDraftRevision)? {
        for draft in drafts {
            if let revision = draft.revisions.first(where: { $0.id == id }) {
                return (draft, revision)
            }
        }
        return nil
    }

    func drafts(ownedBy clientID: String) -> [ResponseDraft] {
        drafts.filter { $0.clientID == clientID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func createDraft(
        id: UUID = UUID(),
        clientID: String,
        label: String?,
        sourceSessionID: UUID,
        sourceCaptureSequence: UInt64,
        matcher: MCPMutationMatcher,
        bodyData: Data,
        bodySHA256: String,
        statusCode: Int,
        contentType: String,
        now: Date = Date()
    ) throws -> ResponseDraft {
        try requireLoaded()
        try enforceCreateQuotas(clientID: clientID, bodyByteCount: bodyData.count)
        let revisionID = UUID()
        let revision = ResponseDraftRevision(
            id: revisionID,
            revisionIndex: 0,
            bodyData: bodyData,
            bodySHA256: bodySHA256,
            statusCode: statusCode,
            contentType: contentType,
            parentRevisionID: nil,
            createdAt: now,
            previewDigest: nil
        )
        let draft = ResponseDraft(
            id: id,
            label: label,
            clientID: clientID,
            sourceSessionID: sourceSessionID,
            sourceCaptureSequence: sourceCaptureSequence,
            matcher: matcher,
            originalRevisionID: revisionID,
            currentRevisionID: revisionID,
            revisions: [revision],
            boundOverrideIDsByRevisionID: [:],
            createdAt: now,
            updatedAt: now
        )
        drafts.append(draft)
        try persist()
        return draft
    }

    /// Records that an override rule serves a draft revision (for delete/referenced-by reporting).
    func bindOverride(ruleID: UUID, toRevision revisionID: UUID, clientID: String) throws {
        try requireLoaded()
        guard let index = drafts.firstIndex(where: { draft in
            draft.revisions.contains(where: { $0.id == revisionID })
        }) else {
            throw ResponseDraftStoreError.revisionNotFound
        }
        guard drafts[index].clientID == clientID else {
            throw ResponseDraftStoreError.notOwner
        }
        var bound = drafts[index].boundOverrideIDsByRevisionID[revisionID] ?? []
        if !bound.contains(ruleID) {
            bound.append(ruleID)
            drafts[index].boundOverrideIDsByRevisionID[revisionID] = bound
            drafts[index].updatedAt = Date()
            try persist()
        }
    }

    /// Override IDs still bound to any revision of the draft (caller should prune dead IDs).
    func boundOverrideIDs(forDraft id: UUID) -> [UUID] {
        guard let draft = draft(id: id) else { return [] }
        return draft.boundOverrideIDsByRevisionID.values.flatMap { $0 }
    }

    @discardableResult
    func commitRevision(
        draftID: UUID,
        clientID: String,
        bodyData: Data,
        bodySHA256: String,
        statusCode: Int,
        contentType: String,
        previewDigest: String?,
        now: Date = Date()
    ) throws -> ResponseDraft {
        try requireLoaded()
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else {
            throw ResponseDraftStoreError.draftNotFound
        }
        guard drafts[index].clientID == clientID else {
            throw ResponseDraftStoreError.notOwner
        }
        guard drafts[index].revisions.count < Self.maxRevisionsPerDraft else {
            throw ResponseDraftStoreError.quotaExceeded("This draft already has the maximum number of revisions.")
        }
        guard bodyData.count <= Self.maxBodyBytesPerRevision else {
            throw ResponseDraftStoreError.quotaExceeded("Revision body exceeds the per-revision byte quota.")
        }
        let currentAggregate = aggregateBytes(for: clientID) - (drafts[index].currentRevision?.bodyData.count ?? 0)
        guard currentAggregate + bodyData.count <= Self.maxAggregateBytesPerClient else {
            throw ResponseDraftStoreError.quotaExceeded("Client aggregate draft storage quota exceeded.")
        }
        let parentID = drafts[index].currentRevisionID
        let revision = ResponseDraftRevision(
            id: UUID(),
            revisionIndex: drafts[index].revisions.count,
            bodyData: bodyData,
            bodySHA256: bodySHA256,
            statusCode: statusCode,
            contentType: contentType,
            parentRevisionID: parentID,
            createdAt: now,
            previewDigest: previewDigest
        )
        drafts[index].revisions.append(revision)
        drafts[index].currentRevisionID = revision.id
        drafts[index].updatedAt = now
        try persist()
        return drafts[index]
    }

    func renameDraft(id: UUID, clientID: String, label: String?, now: Date = Date()) throws -> ResponseDraft {
        try requireLoaded()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            throw ResponseDraftStoreError.draftNotFound
        }
        guard drafts[index].clientID == clientID else {
            throw ResponseDraftStoreError.notOwner
        }
        drafts[index].label = label
        drafts[index].updatedAt = now
        try persist()
        return drafts[index]
    }

    func deleteDraft(id: UUID, clientID: String) throws {
        try requireLoaded()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            throw ResponseDraftStoreError.draftNotFound
        }
        guard drafts[index].clientID == clientID else {
            throw ResponseDraftStoreError.notOwner
        }
        drafts.remove(at: index)
        try persist()
    }

    func deleteAll(ownedBy clientID: String) throws {
        try requireLoaded()
        drafts.removeAll { $0.clientID == clientID }
        try persist()
    }

    private func enforceCreateQuotas(clientID: String, bodyByteCount: Int) throws {
        guard bodyByteCount <= Self.maxBodyBytesPerRevision else {
            throw ResponseDraftStoreError.quotaExceeded("Draft body exceeds the per-revision byte quota.")
        }
        let owned = drafts(ownedBy: clientID)
        guard owned.count < Self.maxDraftsPerClient else {
            throw ResponseDraftStoreError.quotaExceeded("Client draft count quota exceeded.")
        }
        guard aggregateBytes(for: clientID) + bodyByteCount <= Self.maxAggregateBytesPerClient else {
            throw ResponseDraftStoreError.quotaExceeded("Client aggregate draft storage quota exceeded.")
        }
    }

    private func aggregateBytes(for clientID: String) -> Int {
        drafts(ownedBy: clientID).reduce(0) { partial, draft in
            partial + draft.revisions.reduce(0) { $0 + $1.bodyData.count }
        }
    }

    private func requireLoaded() throws {
        guard isLoaded else {
            throw ResponseDraftStoreError.notLoaded
        }
    }

    private func failClosed(reason: String) {
        drafts = []
        isLoaded = false
        loadFailureReason = reason
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }
}
