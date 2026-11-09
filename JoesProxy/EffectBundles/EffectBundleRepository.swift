import Combine
import Foundation

/// Owns validated, managed copies of imported effect bundles.
///
/// Concurrency: main-actor isolated because records are presented directly by the app and lifecycle
/// transitions must be serialized with activation. Import never enables an effect. A process launch
/// converts any formerly-serving record to stopped before exposing it.
@MainActor
final class EffectBundleRepository: ObservableObject {
    static let persistenceSchemaVersion = 1
    static let persistenceFileName = "effect-bundles.json"
    static let packagesDirectoryName = "EffectBundles"

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var records: [EffectBundleRecord]
    }

    @Published private(set) var records: [EffectBundleRecord] = []

    private let persistenceURL: URL
    private let packagesRootURL: URL
    private let fileManager: FileManager
    private let packageEngine: EffectBundlePackageEngine
    private let clock: () -> Date
    private var pendingPreparedImports: Set<UUID> = []

    init(
        persistenceURL: URL? = nil,
        packagesRootURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        let appSupportRoot = Self.defaultApplicationSupportRoot(fileManager: fileManager)
        self.persistenceURL = persistenceURL
            ?? appSupportRoot.appendingPathComponent(Self.persistenceFileName, isDirectory: false)
        self.packagesRootURL = packagesRootURL
            ?? appSupportRoot.appendingPathComponent(Self.packagesDirectoryName, isDirectory: true)
        self.packageEngine = EffectBundlePackageEngine(fileManager: fileManager)
        self.clock = clock
        loadFailClosed()
    }

    func record(id: UUID) -> EffectBundleRecord? {
        records.first(where: { $0.id == id })
    }

    /// Reviewed metadata only. Import and activation retain their separate disk validation.
    func metadataRecord(id: UUID, requestingOwnerID: String? = nil) throws -> EffectBundleRecord {
        try ownedRecord(id: id, requestingOwnerID: requestingOwnerID)
    }

    /// Captures metadata only; disk inspection belongs to the cancellable recovery worker.
    func recoveryAssetTarget(_ resource: EffectBundleResourceIdentity) throws -> EffectBundleAssetRecoveryTarget {
        let record = try ownedRecord(id: resource.bundleID, requestingOwnerID: nil)
        guard (record.manifest.authoring?.revisionID ?? record.id) == resource.revisionID,
              record.manifest.responseEffects.contains(where: {
                  $0.id == resource.resourceID && $0.bodySource.assetIDs.contains(resource.assetID)
              }),
              let asset = record.manifest.assets.first(where: {
                  $0.id == resource.assetID && $0.sha256 == resource.expectedSHA256
              }) else { throw EffectBundleError.bundleNotFound }
        return .init(packageURL: try managedPackageURL(for: record), asset: asset)
    }

    func records(ownedBy ownerID: String) -> [EffectBundleRecord] {
        records.filter { $0.owner.ownerID == ownerID }
            .sorted { $0.importedAt > $1.importedAt }
    }

    func inspect(id: UUID, requestingOwnerID: String? = nil) throws -> EffectBundleInspection {
        let record = try ownedRecord(id: id, requestingOwnerID: requestingOwnerID)
        return try packageEngine.inspectPackage(at: try managedPackageURL(for: record)).inspection
    }

    /// Copies a validated external package into managed storage and retains it as inactive.
    @discardableResult
    func importPackage(
        at sourceURL: URL,
        owner: EffectBundleOwner
    ) throws -> EffectBundleRecord {
        guard records.count + pendingPreparedImports.count < EffectBundleBudget.maxRetainedBundles else {
            throw EffectBundleError.retainedBundleLimitReached
        }
        let source = try packageEngine.inspectPackage(at: sourceURL)
        guard !records.contains(where: { $0.id == source.manifest.id }),
              !pendingPreparedImports.contains(source.manifest.id) else {
            throw EffectBundleError.duplicateIdentifier(source.manifest.id.uuidString)
        }

        try fileManager.createDirectory(at: packagesRootURL, withIntermediateDirectories: true)
        let packageName = Self.managedPackageName(id: source.manifest.id)
        let destinationURL = packagesRootURL.appendingPathComponent(packageName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw EffectBundleError.destinationExists
        }
        let stagingName = ".effect-bundle-import-\(UUID().uuidString)"
        let stagingURL = packagesRootURL.appendingPathComponent(stagingName, isDirectory: true)

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            let staged = try packageEngine.inspectPackage(at: stagingURL)
            guard staged.manifest == source.manifest else {
                throw EffectBundleError.assetDigestMismatch("package-copy")
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)

            let record = EffectBundleRecord(
                id: source.manifest.id,
                owner: owner,
                manifest: source.manifest,
                managedPackagePath: packageName,
                state: .inactive,
                importedAt: clock(),
                activatedAt: nil,
                expiresAt: nil,
                stoppedAt: nil,
                cleanupMessage: nil
            )
            records.append(record)
            do {
                try persist()
            } catch {
                records.removeAll { $0.id == record.id }
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
            return record
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    /// Publishes an owner-checked immutable revision without activating it. Bulk hashing and asset I/O
    /// run off-main; the main actor reserves capacity across the suspension and commits lifecycle state.
    /// Cancellation is checked before publication, after the bounded writer has finished.
    @discardableResult
    func importPreparedRevision(
        id: UUID,
        owner: EffectBundleOwner,
        authoringService: CollectionMockAuthoringService
    ) async throws -> EffectBundleRecord {
        let package = try await authoringService.inspectCapturedPackage(id: id, ownerID: owner.ownerID)
        try Task.checkCancellation()
        if let existing = records.first(where: { $0.id == id }) {
            guard existing.owner.ownerID == owner.ownerID else { throw EffectBundleError.notOwner }
            guard existing.manifest == package.manifest else {
                throw EffectBundleError.assetDigestMismatch("prepared-revision")
            }
            // A retry must not reset a serving/stopped revision or extend its lifetime.
            return existing
        }
        guard !pendingPreparedImports.contains(id) else {
            throw EffectBundleError.duplicateIdentifier(id.uuidString)
        }
        guard records.count + pendingPreparedImports.count < EffectBundleBudget.maxRetainedBundles else {
            throw EffectBundleError.retainedBundleLimitReached
        }
        pendingPreparedImports.insert(id)
        defer { pendingPreparedImports.remove(id) }
        let packageName = Self.managedPackageName(id: id)
        let destination = packagesRootURL.appendingPathComponent(packageName, isDirectory: true)
        // No actor state crosses into the writer. A failed write cleans only its own staging directory.
        try await Task.detached(priority: .utility) {
            try EffectBundlePackageEngine().writePackage(manifest: package.manifest,
                assetDataByID: package.assetDataByID, to: destination)
        }.value
        do {
            try Task.checkCancellation()
            let record = EffectBundleRecord(id: id, owner: owner, manifest: package.manifest,
                managedPackagePath: packageName, state: .inactive, importedAt: clock(),
                activatedAt: nil, expiresAt: nil, stoppedAt: nil, cleanupMessage: nil)
            records.append(record)
            do { try persist() }
            catch {
                records.removeAll { $0.id == id }
                throw error
            }
            return record
        } catch {
            // The writer returned successfully, so this exact destination belongs to this operation.
            do { try fileManager.removeItem(at: destination) }
            catch { throw EffectBundleError.cleanupRequired(error.localizedDescription) }
            throw error
        }
    }

    /// Deletes one exact managed package. Serving bundles must be stopped first.
    func discard(id: UUID, requestingOwnerID: String? = nil) throws {
        let record = try ownedRecord(id: id, requestingOwnerID: requestingOwnerID)
        guard !record.isServing else {
            throw EffectBundleError.bundleIsServing
        }
        let packageURL = try managedPackageURL(for: record)
        do {
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }
        } catch {
            try? setCleanupRequired(id: id, message: error.localizedDescription)
            throw EffectBundleError.cleanupRequired(error.localizedDescription)
        }
        records.removeAll { $0.id == id }
        try persist()
    }

    func manifestAndPackageURL(
        id: UUID,
        requestingOwnerID: String? = nil
    ) throws -> (manifest: EffectBundleManifest, packageURL: URL) {
        let record = try ownedRecord(id: id, requestingOwnerID: requestingOwnerID)
        let packageURL = try managedPackageURL(for: record)
        let inspected = try packageEngine.inspectPackage(at: packageURL)
        guard inspected.manifest.id == record.id else {
            throw EffectBundleError.assetDigestMismatch("manifest-id")
        }
        guard inspected.manifest == record.manifest else {
            throw EffectBundleError.assetDigestMismatch("manifest-revision")
        }
        return (inspected.manifest, packageURL)
    }

    @discardableResult
    func markServing(id: UUID, activatedAt: Date, expiresAt: Date) throws -> EffectBundleRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw EffectBundleError.bundleNotFound
        }
        records[index].state = .serving
        records[index].terminationReason = nil
        records[index].activatedAt = activatedAt
        records[index].expiresAt = expiresAt
        records[index].stoppedAt = nil
        records[index].cleanupMessage = nil
        try persist()
        return records[index]
    }

    @discardableResult
    func markStopped(id: UUID, at date: Date, expired: Bool = false,
                     reason: EffectBundleTerminationReason? = nil) throws -> EffectBundleRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw EffectBundleError.bundleNotFound
        }
        records[index].state = expired ? .expired : .stopped
        records[index].terminationReason = reason ?? (expired ? .expired : .stopped)
        records[index].stoppedAt = date
        records[index].expiresAt = nil
        records[index].cleanupMessage = nil
        try persist()
        return records[index]
    }

    @discardableResult
    func setCleanupRequired(id: UUID, message: String) throws -> EffectBundleRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw EffectBundleError.bundleNotFound
        }
        records[index].state = .cleanupRequired
        records[index].cleanupMessage = message
        records[index].stoppedAt = clock()
        try persist()
        return records[index]
    }

    private func ownedRecord(id: UUID, requestingOwnerID: String?) throws -> EffectBundleRecord {
        guard let record = records.first(where: { $0.id == id }) else {
            throw EffectBundleError.bundleNotFound
        }
        if let requestingOwnerID, record.owner.ownerID != requestingOwnerID {
            throw EffectBundleError.notOwner
        }
        return record
    }

    private func managedPackageURL(for record: EffectBundleRecord) throws -> URL {
        let expectedName = Self.managedPackageName(id: record.id)
        guard record.managedPackagePath == expectedName else {
            throw EffectBundleError.unsafePath(record.managedPackagePath)
        }
        return packagesRootURL.appendingPathComponent(expectedName, isDirectory: true)
    }

    private func loadFailClosed() {
        guard fileManager.fileExists(atPath: persistenceURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard state.schemaVersion == Self.persistenceSchemaVersion else {
                records = []
                return
            }
            let now = clock()
            records = state.records.prefix(EffectBundleBudget.maxRetainedBundles).map { stored in
                var record = stored
                if record.isServing {
                    record.state = .stopped
                    record.stoppedAt = now
                    record.expiresAt = nil
                }
                do {
                    let packageURL = try managedPackageURL(for: record)
                    let inspected = try packageEngine.inspectPackage(at: packageURL)
                    guard inspected.manifest.id == record.id,
                          inspected.manifest == record.manifest else {
                        throw EffectBundleError.assetDigestMismatch("manifest-record")
                    }
                } catch {
                    record.state = .cleanupRequired
                    record.cleanupMessage = error.localizedDescription
                    record.stoppedAt = now
                    record.expiresAt = nil
                }
                return record
            }
            try? persist()
        } catch {
            records = []
        }
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state = PersistedState(
            schemaVersion: Self.persistenceSchemaVersion,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: persistenceURL, options: .atomic)
    }

    private static func managedPackageName(id: UUID) -> String {
        "\(id.uuidString.lowercased()).jproxy-effects"
    }

    private static func defaultApplicationSupportRoot(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent("JoesProxy", isDirectory: true)
    }
}
