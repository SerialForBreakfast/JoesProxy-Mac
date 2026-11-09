import Foundation

/// Persistence classification for one known CA instance fingerprint.
enum CAStorageState: String, Codable, Equatable, Sendable, CaseIterable {
    case legacy
    case current
    case imported
    case retired
}

/// Staged renewal lifecycle for a CA instance (Phase D). Separate from ``CAStorageState``.
enum CARenewalState: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case pending
    case activePromoted
    case retired
}

/// Non-secret metadata describing one JoesProxy CA instance (fingerprint-keyed).
///
/// Private key material is never stored here — only identity fields safe for UI, MCP, and logs.
struct CAInstanceMetadata: Equatable, Sendable, Codable, Identifiable {
    /// Stable random CA-instance ID (128-bit).
    var id: UUID
    /// Human-friendly short display code derived from ``id``.
    var shortCode: String
    /// Authoritative SHA-256 fingerprint of the root certificate DER.
    var certificateSHA256Fingerprint: String
    var certificateSerialNumber: String?
    var subjectSummary: String
    var notBefore: Date?
    var notAfter: Date?
    var createdAt: Date
    var appVersionCreated: String?
    var storageState: CAStorageState
    /// User-editable presentation nickname; never used for trust or lookup.
    var nickname: String?
    /// Optional renewal machine state; defaults to ``CARenewalState/none`` for Phase A records.
    var renewalState: CARenewalState?

    /// Builds metadata for a newly generated current root.
    static func makeCurrent(
        from identity: RootCertificateIdentity,
        instanceID: UUID = UUID(),
        createdAt: Date = Date(),
        appVersion: String = Bundle.main.marketingVersionOrDev
    ) -> CAInstanceMetadata {
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        return CAInstanceMetadata(
            id: instanceID,
            shortCode: CertificateIdentityExtraction.shortCode(from: instanceID),
            certificateSHA256Fingerprint: fingerprint,
            certificateSerialNumber: CertificateIdentityExtraction.serialNumber(from: identity.certificateData),
            subjectSummary: identity.subjectSummary,
            notBefore: CertificateIdentityExtraction.notBefore(from: identity.certificateData),
            notAfter: CertificateIdentityExtraction.notAfter(from: identity.certificateData),
            createdAt: createdAt,
            appVersionCreated: appVersion,
            storageState: .current,
            nickname: nil,
            renewalState: .none
        )
    }
}

/// Failures from ``CAInstanceMetadataStore`` load/mutate/persist operations.
enum CAInstanceMetadataStoreError: Error, Equatable, Sendable {
    case notLoaded
    case corruptPersistence
    case fingerprintNotFound
}

/// JSON sidecar for known CA instance identities (Application Support).
///
/// Concurrency: `@MainActor` — mutated from setup UI and certificate lifecycle paths on the main actor.
/// Does not store secrets; retired records survive Keychain reset so multi-Mac fingerprints remain comparable.
@MainActor
final class CAInstanceMetadataStore {
    static let persistenceFileName = "ca-instance-metadata.json"
    static let persistenceSchemaVersion = 1

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var instances: [CAInstanceMetadata]
    }

    private(set) var instances: [CAInstanceMetadata] = []
    private(set) var isLoaded = false
    private(set) var loadFailureReason: String?

    private let persistenceURL: URL
    private let fileManager: FileManager

    /// - Parameter persistenceURL: Injected path for tests; defaults to Application Support.
    init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    func load() {
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let persisted = try decoder.decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported CA-instance metadata schema version.")
                    return
                }
                instances = persisted.instances
            } else {
                instances = []
            }
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "CA-instance metadata store failed to load.")
        }
    }

    func persist() throws {
        guard isLoaded else { throw CAInstanceMetadataStoreError.notLoaded }
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, instances: instances)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func metadata(forFingerprint fingerprint: String) -> CAInstanceMetadata? {
        instances.first { $0.certificateSHA256Fingerprint == fingerprint }
    }

    /// Current active instance when exactly one `.current` record exists.
    func currentInstance() -> CAInstanceMetadata? {
        instances.first { $0.storageState == .current }
    }

    /// Instances currently in a staged renewal pending state.
    func pendingRenewalInstances() -> [CAInstanceMetadata] {
        instances.filter { $0.renewalState == .pending }
    }

    @discardableResult
    func upsert(_ metadata: CAInstanceMetadata) throws -> CAInstanceMetadata {
        guard isLoaded else { throw CAInstanceMetadataStoreError.notLoaded }

        var next = metadata
        if next.storageState == .current {
            instances = instances.map { existing in
                guard existing.certificateSHA256Fingerprint != next.certificateSHA256Fingerprint,
                      existing.storageState == .current else {
                    return existing
                }
                var demoted = existing
                demoted.storageState = .retired
                return demoted
            }
        }

        if let index = instances.firstIndex(where: {
            $0.certificateSHA256Fingerprint == next.certificateSHA256Fingerprint
        }) {
            instances[index] = next
        } else {
            instances.append(next)
        }
        try persist()
        return next
    }

    /// Marks a fingerprint retired without deleting the record (used by Reset Certificate State).
    @discardableResult
    func markRetired(fingerprint: String) throws -> CAInstanceMetadata {
        guard isLoaded else { throw CAInstanceMetadataStoreError.notLoaded }
        guard let index = instances.firstIndex(where: { $0.certificateSHA256Fingerprint == fingerprint }) else {
            throw CAInstanceMetadataStoreError.fingerprintNotFound
        }
        instances[index].storageState = .retired
        if instances[index].renewalState == .pending || instances[index].renewalState == .activePromoted {
            instances[index].renewalState = .retired
        }
        try persist()
        return instances[index]
    }

    /// Explicit one-time adoption of a legacy root that had no metadata record.
    @discardableResult
    func adoptLegacy(
        identity: RootCertificateIdentity,
        createdAt: Date = Date(),
        appVersion: String = Bundle.main.marketingVersionOrDev
    ) throws -> CAInstanceMetadata {
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        if let existing = metadata(forFingerprint: fingerprint) {
            return existing
        }
        let instanceID = UUID()
        let metadata = CAInstanceMetadata(
            id: instanceID,
            shortCode: CertificateIdentityExtraction.shortCode(from: instanceID),
            certificateSHA256Fingerprint: fingerprint,
            certificateSerialNumber: CertificateIdentityExtraction.serialNumber(from: identity.certificateData),
            subjectSummary: identity.subjectSummary,
            notBefore: CertificateIdentityExtraction.notBefore(from: identity.certificateData),
            notAfter: CertificateIdentityExtraction.notAfter(from: identity.certificateData),
            createdAt: createdAt,
            appVersionCreated: appVersion,
            storageState: .current,
            nickname: nil,
            renewalState: .none
        )
        return try upsert(metadata)
    }

    /// Updates nickname only; ignores blank-only changes that match existing value.
    @discardableResult
    func updateNickname(fingerprint: String, nickname: String?) throws -> CAInstanceMetadata {
        guard isLoaded else { throw CAInstanceMetadataStoreError.notLoaded }
        guard let index = instances.firstIndex(where: { $0.certificateSHA256Fingerprint == fingerprint }) else {
            throw CAInstanceMetadataStoreError.fingerprintNotFound
        }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        instances[index].nickname = (trimmed?.isEmpty == false) ? trimmed : nil
        try persist()
        return instances[index]
    }

    static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }

    private func failClosed(reason: String) {
        instances = []
        isLoaded = false
        loadFailureReason = reason
    }
}
