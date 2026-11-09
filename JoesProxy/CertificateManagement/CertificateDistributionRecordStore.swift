import Foundation

/// Lifecycle status for one exported trust/proxy profile artifact.
enum CertificateDistributionStatus: String, Codable, Equatable, Sendable {
    case generated
    case userConfirmed
    case retired
}

/// Kind of exported device profile artifact.
enum CertificateDistributionProfileKind: String, Codable, Equatable, Sendable {
    case iosTrustProfile
    case tvOSManagedProxyProfile
}

/// One exported profile artifact tied to a CA instance fingerprint.
struct CertificateDistributionRecord: Equatable, Sendable, Codable, Identifiable {
    var id: UUID { artifactID }
    var artifactID: UUID
    var caInstanceID: UUID
    var shortCode: String
    var certificateSHA256Fingerprint: String
    var certificateSerialNumber: String?
    var certificateNotAfter: Date?
    var profileKind: CertificateDistributionProfileKind
    var payloadIdentifier: String
    var resolvedHost: String?
    var proxyPort: UInt16?
    var userNickname: String?
    var generatedAt: Date
    var appVersion: String
    var status: CertificateDistributionStatus
}

enum CertificateDistributionRecordStoreError: Error, Equatable, Sendable {
    case notLoaded
    case corruptPersistence
}

/// JSON sidecar recording profile exports for multi-Mac identity comparison (Phase B).
///
/// Concurrency: `@MainActor` — written from UI/export and profile-hosting paths on the main actor.
@MainActor
final class CertificateDistributionRecordStore {
    static let persistenceFileName = "certificate-distribution-records.json"
    static let persistenceSchemaVersion = 1

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var records: [CertificateDistributionRecord]
    }

    private(set) var records: [CertificateDistributionRecord] = []
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
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let persisted = try decoder.decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported certificate-distribution schema version.")
                    return
                }
                records = persisted.records
            } else {
                records = []
            }
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "Certificate-distribution store failed to load.")
        }
    }

    func persist() throws {
        guard isLoaded else { throw CertificateDistributionRecordStoreError.notLoaded }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PersistedState(schemaVersion: Self.persistenceSchemaVersion, records: records)
        )
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func record(artifactID: UUID) -> CertificateDistributionRecord? {
        records.first { $0.artifactID == artifactID }
    }

    func records(forFingerprint fingerprint: String) -> [CertificateDistributionRecord] {
        records.filter { $0.certificateSHA256Fingerprint == fingerprint }
    }

    @discardableResult
    func append(_ record: CertificateDistributionRecord) throws -> CertificateDistributionRecord {
        guard isLoaded else { throw CertificateDistributionRecordStoreError.notLoaded }
        records.insert(record, at: 0)
        try persist()
        return record
    }

    @discardableResult
    func markRetired(fingerprint: String) throws -> Int {
        guard isLoaded else { throw CertificateDistributionRecordStoreError.notLoaded }
        var count = 0
        for index in records.indices where records[index].certificateSHA256Fingerprint == fingerprint {
            if records[index].status != .retired {
                records[index].status = .retired
                count += 1
            }
        }
        if count > 0 {
            try persist()
        }
        return count
    }

    static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }

    private func failClosed(reason: String) {
        records = []
        isLoaded = false
        loadFailureReason = reason
    }
}

/// Builds stable CA-instance payload identifiers for exported profiles.
enum CertificateProfilePayloadIdentity: Sendable {
    /// `com.showblender.joesproxy.ca.<shortcode-lowercase>.profile.<artifact-id>`
    static func profilePayloadIdentifier(shortCode: String, artifactID: UUID) -> String {
        let code = shortCode
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "com.showblender.joesproxy.ca.\(code).profile.\(artifactID.uuidString.lowercased())"
    }

    static func displayName(shortCode: String, notAfter: Date?) -> String {
        if let notAfter {
            let expiry = notAfter.formatted(date: .abbreviated, time: .omitted)
            return "JoesProxy Root CA — \(shortCode) — expires \(expiry)"
        }
        return "JoesProxy Root CA — \(shortCode)"
    }

    static func description(shortCode: String, notAfter: Date?, platform: String) -> String {
        let expiryClause: String
        if let notAfter {
            expiryClause = " Expires \(notAfter.formatted(date: .abbreviated, time: .omitted))."
        } else {
            expiryClause = ""
        }
        return "Installs the JoesProxy root CA (\(shortCode)) for HTTPS inspection on \(platform).\(expiryClause)"
    }
}
