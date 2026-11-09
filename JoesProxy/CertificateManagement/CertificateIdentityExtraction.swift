import CryptoKit
import Foundation
import Security

/// Shared certificate identity field extraction used by profile snapshots, CA metadata, and UI.
///
/// Concurrency: pure `Sendable` helpers; safe to call from any isolation domain.
enum CertificateIdentityExtraction: Sendable {
    /// Days remaining at or below which identity status becomes ``CertificateIdentityStatus/expiringSoon``.
    /// Matches ``ProfileSnapshotHealth``'s 30-day certificate warning window.
    static let expiringSoonThresholdDays: Int = 30

    /// Lowercase hex SHA-256 of the certificate DER bytes (authoritative CA identity).
    static func sha256Fingerprint(from certificateData: Data) -> String {
        SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Hex-encoded certificate serial number derived from the DER serial bytes.
    ///
    /// Uses `SecCertificateCopySerialNumberData`, which returns the integer serial as raw DER
    /// bytes; this is more reliable than `SecCertificateCopyValues`, whose serial value type
    /// varies by platform and certificate encoding.
    static func serialNumber(from certificateData: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            return nil
        }
        guard let serialData = SecCertificateCopySerialNumberData(certificate, nil) as Data?,
              !serialData.isEmpty else {
            return nil
        }
        return serialData.map { String(format: "%02x", $0) }.joined()
    }

    /// Not-before validity date when present on the certificate.
    static func notBefore(from certificateData: Data) -> Date? {
        CertificateValidity.dates(fromDER: certificateData)?.notBefore
    }

    /// Not-after validity date when present on the certificate.
    static func notAfter(from certificateData: Data) -> Date? {
        CertificateValidity.dates(fromDER: certificateData)?.notAfter
    }

    /// Human-readable short code derived from a CA instance UUID (`XXXX-XXXX`).
    static func shortCode(from instanceID: UUID) -> String {
        let hex = instanceID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .uppercased()
        let characters = Array(hex)
        guard characters.count == 8 else { return String(hex) }
        return "\(String(characters[0..<4]))-\(String(characters[4..<8]))"
    }

    /// Evaluates identity health from optional metadata and the live root DER.
    ///
    /// - Parameters:
    ///   - rootCertificateData: Live root DER when a root is loaded; `nil` means missing.
    ///   - metadata: Matching ``CAInstanceMetadata`` when the fingerprint has been adopted or minted.
    ///   - now: Evaluation clock (injectable for tests).
    static func evaluateIdentityStatus(
        rootCertificateData: Data?,
        metadata: CAInstanceMetadata?,
        now: Date = Date()
    ) -> CertificateIdentityStatus {
        guard let rootCertificateData else {
            return .missing
        }

        guard metadata != nil else {
            return .legacyIdentityUnknown
        }

        guard let notAfter = notAfter(from: rootCertificateData) else {
            return .invalidOrUnreadable(reason: "Certificate validity dates are unreadable.")
        }

        if notAfter <= now {
            return .expired
        }

        let secondsRemaining = notAfter.timeIntervalSince(now)
        let daysRemaining = Int(ceil(secondsRemaining / (24 * 60 * 60)))
        if daysRemaining <= expiringSoonThresholdDays {
            return .expiringSoon(daysRemaining: max(daysRemaining, 0))
        }

        return .valid
    }
}

/// Health of the local CA instance identity (orthogonal to trust-install status).
enum CertificateIdentityStatus: Equatable, Sendable {
    case valid
    case expiringSoon(daysRemaining: Int)
    case expired
    case invalidOrUnreadable(reason: String)
    case missing
    case legacyIdentityUnknown

    /// Short UI label for the identity card.
    var title: String {
        switch self {
        case .valid:
            return "Valid"
        case .expiringSoon(let daysRemaining):
            return "Expiring soon (\(daysRemaining)d)"
        case .expired:
            return "Expired"
        case .invalidOrUnreadable:
            return "Unreadable"
        case .missing:
            return "Missing"
        case .legacyIdentityUnknown:
            return "Legacy — adopt identity"
        }
    }
}
