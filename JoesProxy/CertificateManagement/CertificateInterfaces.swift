import Foundation
import Security

enum CertificateAuthorityError: LocalizedError {
    case identityUnavailable
    case unsupportedOperation(String)
    case generationFailed(String)
    case storageFailed(String)
    case invalidHost(String)
    case trustInstallationFailed(String)
    case trustRemovalFailed(String)
    case keychainAccessFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            return "The root certificate authority identity is unavailable."
        case .unsupportedOperation(let message):
            return message
        case .generationFailed(let message):
            return message
        case .storageFailed(let message):
            return message
        case .invalidHost(let host):
            return "The host '\(host)' is not valid for certificate issuance."
        case .trustInstallationFailed(let message):
            return message
        case .trustRemovalFailed(let message):
            return message
        case .keychainAccessFailed(let message):
            return message
        }
    }
}

struct RootCertificateIdentity: Equatable, Sendable {
    let label: String
    let subjectSummary: String
    let certificateData: Data
    let privateKeyData: Data?
}

struct IssuedLeafCertificate: Equatable, Sendable {
    let host: String
    let certificateData: Data
    let privateKeyData: Data
    /// SHA-256 of the root that signed this leaf; set by the issuing CA for CONNECT diagnostics.
    let issuerCertificateSHA256Fingerprint: String?

    /// - Parameter issuerCertificateSHA256Fingerprint: Defaults to `nil` for test doubles.
    init(
        host: String,
        certificateData: Data,
        privateKeyData: Data,
        issuerCertificateSHA256Fingerprint: String? = nil
    ) {
        self.host = host
        self.certificateData = certificateData
        self.privateKeyData = privateKeyData
        self.issuerCertificateSHA256Fingerprint = issuerCertificateSHA256Fingerprint
    }
}

enum TrustInstallationStatus: Equatable, Sendable {
    case notInstalled
    case trustRequired(reason: String)
    case installed
    case invalid(reason: String)
}

struct CertificateStatusSnapshot: Equatable, Sendable {
    let rootCertificate: RootCertificateIdentity?
    let trustStatus: TrustInstallationStatus
    /// Optional CA-instance metadata when the identity store has adopted or minted this root.
    let identityMetadata: CAInstanceMetadata?
    /// Optional identity health; orthogonal to ``trustStatus``.
    let identityStatus: CertificateIdentityStatus?

    /// - Parameters:
    ///   - identityMetadata: Defaults to `nil` so existing call sites stay source-compatible.
    ///   - identityStatus: Defaults to `nil` until a MainActor store enrichment runs.
    init(
        rootCertificate: RootCertificateIdentity?,
        trustStatus: TrustInstallationStatus,
        identityMetadata: CAInstanceMetadata? = nil,
        identityStatus: CertificateIdentityStatus? = nil
    ) {
        self.rootCertificate = rootCertificate
        self.trustStatus = trustStatus
        self.identityMetadata = identityMetadata
        self.identityStatus = identityStatus
    }
}

protocol CertificateStatusReading: Sendable {
    func readStatus() async -> CertificateStatusSnapshot
}

protocol CertificateStore: AnyObject {
    func loadRootCertificate(label: String) -> RootCertificateIdentity?
    func saveRootCertificate(_ identity: RootCertificateIdentity) throws
    func removeRootCertificate(label: String) throws
}

protocol CertificateAuthorityProviding: AnyObject {
    func currentRootCertificate() -> RootCertificateIdentity?
    func loadOrCreateRootCertificate() throws -> RootCertificateIdentity
    func issueLeafCertificate(for host: String) throws -> IssuedLeafCertificate
}

protocol TrustInstalling: AnyObject {
    func installationStatus(for label: String) -> TrustInstallationStatus
    func install(_ identity: RootCertificateIdentity) throws
    func removeCertificate(label: String) throws
}

/// Fingerprint-scoped trust cleanup, kept separate from ``TrustInstalling`` so label-wide removal
/// stays the only removal every installer must implement.
protocol CertificateFingerprintTrustCleaning: AnyObject {
    /// Removes only installed certificates whose DER SHA-256 matches, returning how many were deleted.
    @discardableResult
    func removeInstalledCertificate(matchingFingerprint fingerprint: String, label: String) throws -> Int
}

protocol CertificateKeychainAccessing: AnyObject {
    func addCertificate(_ certificate: SecCertificate, label: String) throws
    func deleteCertificate(_ certificate: SecCertificate, label: String) throws
    func retrieveCertificate(withLabel label: String) throws -> SecCertificate?
    func retrieveCertificates(withLabel label: String) throws -> [SecCertificate]
    func saveData(_ data: Data, service: String, account: String) throws
    func retrieveData(service: String, account: String) -> Data?
    func deleteData(service: String, account: String) throws
}

protocol CertificateTrustEvaluating {
    func installationStatus(for certificate: SecCertificate) -> TrustInstallationStatus
}

protocol IOSDeviceTrustProfileExporting: AnyObject {
    func exportTrustProfile(to destinationURL: URL) throws
}

protocol TVOSManagedProfileExporting: AnyObject {
    func exportManagedProfile(to destinationURL: URL, host: String, port: Int) throws
}
