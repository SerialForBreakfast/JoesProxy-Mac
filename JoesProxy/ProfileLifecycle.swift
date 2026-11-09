import Foundation
import Security

enum ProfileHostStrategy: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case bonjourLocal
    case lanIP
    case manualHost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bonjourLocal:
            return ".local"
        case .lanIP:
            return "LAN IP"
        case .manualHost:
            return "Manual"
        }
    }

    var detail: String {
        switch self {
        case .bonjourLocal:
            return "Best when the Mac's DHCP address changes."
        case .lanIP:
            return "Useful when Bonjour or mDNS is unreliable."
        case .manualHost:
            return "Use a hostname or address you control."
        }
    }
}

struct ProfileHostResolution: Equatable, Sendable {
    let strategy: ProfileHostStrategy
    let requestedStrategy: ProfileHostStrategy
    let host: String
    let networkInfo: LocalNetworkInfo
    let usedFallback: Bool
}

struct ProfileHostResolver: Sendable {
    func resolve(
        strategy: ProfileHostStrategy,
        manualHost: String,
        networkInfo: LocalNetworkInfo
    ) -> ProfileHostResolution {
        let trimmedManualHost = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        switch strategy {
        case .bonjourLocal:
            if let bonjourName = networkInfo.bonjourName, !bonjourName.isEmpty {
                return ProfileHostResolution(
                    strategy: .bonjourLocal,
                    requestedStrategy: strategy,
                    host: bonjourName,
                    networkInfo: networkInfo,
                    usedFallback: false
                )
            }
            if let lanIP = networkInfo.lanIP, !lanIP.isEmpty {
                return ProfileHostResolution(
                    strategy: .lanIP,
                    requestedStrategy: strategy,
                    host: lanIP,
                    networkInfo: networkInfo,
                    usedFallback: true
                )
            }
        case .lanIP:
            if let lanIP = networkInfo.lanIP, !lanIP.isEmpty {
                return ProfileHostResolution(
                    strategy: .lanIP,
                    requestedStrategy: strategy,
                    host: lanIP,
                    networkInfo: networkInfo,
                    usedFallback: false
                )
            }
            if let bonjourName = networkInfo.bonjourName, !bonjourName.isEmpty {
                return ProfileHostResolution(
                    strategy: .bonjourLocal,
                    requestedStrategy: strategy,
                    host: bonjourName,
                    networkInfo: networkInfo,
                    usedFallback: true
                )
            }
        case .manualHost:
            if !trimmedManualHost.isEmpty {
                return ProfileHostResolution(
                    strategy: .manualHost,
                    requestedStrategy: strategy,
                    host: trimmedManualHost,
                    networkInfo: networkInfo,
                    usedFallback: false
                )
            }
            if let bonjourName = networkInfo.bonjourName, !bonjourName.isEmpty {
                return ProfileHostResolution(
                    strategy: .bonjourLocal,
                    requestedStrategy: strategy,
                    host: bonjourName,
                    networkInfo: networkInfo,
                    usedFallback: true
                )
            }
        }

        return ProfileHostResolution(
            strategy: .lanIP,
            requestedStrategy: strategy,
            host: "127.0.0.1",
            networkInfo: networkInfo,
            usedFallback: true
        )
    }
}

enum GeneratedProfileKind: String, Codable, Equatable, Sendable {
    case iosTrustProfile
    case tvOSManagedProxyProfile

    var title: String {
        switch self {
        case .iosTrustProfile:
            return "iOS Trust Profile"
        case .tvOSManagedProxyProfile:
            return "Apple TV Managed Proxy Profile"
        }
    }
}

struct GeneratedProfileSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: GeneratedProfileKind
    let generatedAt: Date
    let hostStrategy: ProfileHostStrategy
    let resolvedHost: String
    let proxyPort: UInt16
    let profileServerURL: URL?
    let certificateLabel: String
    let certificateSHA256Fingerprint: String?
    let certificateExpirationDate: Date?
    let payloadIdentifiers: [String]
    let appVersion: String
    let lastKnownLANIP: String?
    let lastKnownBonjourName: String?
    /// Stable CA-instance ID when metadata existed at export time (optional for backward decode).
    let caInstanceID: UUID?
    let certificateSerialNumber: String?
    let shortCode: String?
    /// Per-export artifact identifier when Phase B labeling is active; optional for legacy rows.
    let artifactID: UUID?
}

enum ProfileSnapshotHealth: Equatable, Sendable {
    case current
    case ipChanged(previous: String, current: String)
    case bonjourChanged(previous: String, current: String)
    case proxyPortChanged(previous: UInt16, current: UInt16)
    case certificateChanged
    case certificateExpired
    case certificateExpiringSoon
    case manualHostConfigured
    case unknown

    var title: String {
        switch self {
        case .current:
            return "Current"
        case .ipChanged:
            return "IP changed"
        case .bonjourChanged:
            return ".local changed"
        case .proxyPortChanged:
            return "Port changed"
        case .certificateChanged:
            return "Certificate changed"
        case .certificateExpired:
            return "Certificate expired"
        case .certificateExpiringSoon:
            return "Certificate expiring soon"
        case .manualHostConfigured:
            return "Manual host"
        case .unknown:
            return "Unknown"
        }
    }

    var isStale: Bool {
        switch self {
        case .current, .manualHostConfigured:
            return false
        case .ipChanged, .bonjourChanged, .proxyPortChanged, .certificateChanged, .certificateExpired,
             .certificateExpiringSoon, .unknown:
            return true
        }
    }
}

struct ProfileSnapshotDiagnosis: Equatable, Sendable {
    let health: ProfileSnapshotHealth
    let message: String

    static func evaluate(
        snapshot: GeneratedProfileSnapshot?,
        currentNetworkInfo: LocalNetworkInfo,
        currentProxyPort: UInt16,
        currentCertificateFingerprint: String?,
        now: Date = Date()
    ) -> ProfileSnapshotDiagnosis {
        guard let snapshot else {
            return ProfileSnapshotDiagnosis(
                health: .unknown,
                message: "No device profile has been generated yet."
            )
        }

        if let expiration = snapshot.certificateExpirationDate {
            if expiration <= now {
                return ProfileSnapshotDiagnosis(
                    health: .certificateExpired,
                    message: "The root certificate used by this profile has expired. Regenerate the certificate and profile."
                )
            }
            if expiration.timeIntervalSince(now) <= 30 * 24 * 60 * 60 {
                return ProfileSnapshotDiagnosis(
                    health: .certificateExpiringSoon,
                    message: "The root certificate used by this profile expires soon. Plan to regenerate and reinstall profiles."
                )
            }
        }

        if let snapshotFingerprint = snapshot.certificateSHA256Fingerprint,
           let currentCertificateFingerprint,
           snapshotFingerprint != currentCertificateFingerprint {
            return ProfileSnapshotDiagnosis(
                health: .certificateChanged,
                message: "The current JoesProxy root certificate differs from the one used by this profile. Regenerate and reinstall the profile."
            )
        }

        if snapshot.proxyPort != currentProxyPort {
            return ProfileSnapshotDiagnosis(
                health: .proxyPortChanged(previous: snapshot.proxyPort, current: currentProxyPort),
                message: "This profile uses proxy port \(snapshot.proxyPort), but JoesProxy is configured for \(currentProxyPort). Regenerate the profile."
            )
        }

        if snapshot.hostStrategy == .lanIP,
           let previous = snapshot.lastKnownLANIP,
           let current = currentNetworkInfo.lanIP,
           previous != current {
            let fallback = currentNetworkInfo.bonjourName.map { " Regenerate using \($0) if your network supports it." } ?? ""
            return ProfileSnapshotDiagnosis(
                health: .ipChanged(previous: previous, current: current),
                message: "This profile was generated for \(previous), but this Mac is now \(current).\(fallback)"
            )
        }

        if snapshot.hostStrategy == .bonjourLocal,
           let previous = snapshot.lastKnownBonjourName,
           let current = currentNetworkInfo.bonjourName,
           previous != current {
            return ProfileSnapshotDiagnosis(
                health: .bonjourChanged(previous: previous, current: current),
                message: "This profile used \(previous), but this Mac now reports \(current). Regenerate the profile."
            )
        }

        if snapshot.hostStrategy == .manualHost {
            return ProfileSnapshotDiagnosis(
                health: .manualHostConfigured,
                message: "This profile uses the manual host \(snapshot.resolvedHost). Confirm that name still reaches this Mac."
            )
        }

        return ProfileSnapshotDiagnosis(
            health: .current,
            message: "The latest generated profile matches the current host, port, and root certificate metadata."
        )
    }
}

protocol ProfileSnapshotStoring: AnyObject {
    func loadSnapshots() -> [GeneratedProfileSnapshot]
    func appendSnapshot(_ snapshot: GeneratedProfileSnapshot) throws
}

final class ProfileSnapshotStore: ProfileSnapshotStoring {
    private struct Container: Codable {
        let version: Int
        var snapshots: [GeneratedProfileSnapshot]
    }

    private let fileURL: URL
    private let historyLimit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL, historyLimit: Int = 20) {
        self.fileURL = fileURL
        self.historyLimit = historyLimit
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    static func defaultStore() -> ProfileSnapshotStore {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return ProfileSnapshotStore(
            fileURL: baseURL
                .appendingPathComponent("JoesProxy", isDirectory: true)
                .appendingPathComponent("ProfileSnapshots.json")
        )
    }

    func loadSnapshots() -> [GeneratedProfileSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let container = try? decoder.decode(Container.self, from: data) else {
            return []
        }
        return container.snapshots
    }

    func appendSnapshot(_ snapshot: GeneratedProfileSnapshot) throws {
        var snapshots = loadSnapshots()
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > historyLimit {
            snapshots = Array(snapshots.prefix(historyLimit))
        }
        let container = Container(version: 1, snapshots: snapshots)
        let data = try encoder.encode(container)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

enum ProfileSnapshotFactory {
    static func makeSnapshot(
        kind: GeneratedProfileKind,
        identity: RootCertificateIdentity?,
        resolution: ProfileHostResolution,
        proxyPort: UInt16,
        profileServerURL: URL?,
        certificateLabel: String,
        appVersion: String = Bundle.main.marketingVersionOrDev,
        caInstanceMetadata: CAInstanceMetadata? = nil,
        artifactID: UUID? = nil
    ) -> GeneratedProfileSnapshot {
        GeneratedProfileSnapshot(
            id: UUID(),
            kind: kind,
            generatedAt: Date(),
            hostStrategy: resolution.strategy,
            resolvedHost: resolution.host,
            proxyPort: proxyPort,
            profileServerURL: profileServerURL,
            certificateLabel: certificateLabel,
            certificateSHA256Fingerprint: identity.map { certificateFingerprint(from: $0.certificateData) },
            certificateExpirationDate: identity.flatMap { certificateExpirationDate(from: $0.certificateData) },
            payloadIdentifiers: payloadIdentifiers(for: kind),
            appVersion: appVersion,
            lastKnownLANIP: resolution.networkInfo.lanIP,
            lastKnownBonjourName: resolution.networkInfo.bonjourName,
            caInstanceID: caInstanceMetadata?.id,
            certificateSerialNumber: caInstanceMetadata?.certificateSerialNumber
                ?? identity.flatMap { CertificateIdentityExtraction.serialNumber(from: $0.certificateData) },
            shortCode: caInstanceMetadata?.shortCode,
            artifactID: artifactID
        )
    }

    static func certificateFingerprint(from certificateData: Data) -> String {
        CertificateIdentityExtraction.sha256Fingerprint(from: certificateData)
    }

    private static func certificateExpirationDate(from certificateData: Data) -> Date? {
        CertificateIdentityExtraction.notAfter(from: certificateData)
    }

    private static func payloadIdentifiers(for kind: GeneratedProfileKind) -> [String] {
        switch kind {
        case .iosTrustProfile:
            return ["com.apple.security.root"]
        case .tvOSManagedProxyProfile:
            return ["com.apple.proxy.http.global", "com.apple.security.root"]
        }
    }
}
