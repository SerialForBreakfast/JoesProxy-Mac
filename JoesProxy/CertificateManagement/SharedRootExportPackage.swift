import Foundation

/// Explicit shared-root import/export package (Phase D5). Contains private key material — never log.
struct SharedRootExportPackage: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var formatVersion: Int
    var label: String
    var subjectSummary: String
    var certificateDERBase64: String
    var privateKeyRawBase64: String
    var certificateSHA256Fingerprint: String
    var shortCode: String?
    var exportedAt: Date
    var appVersion: String

    /// Builds an export package from a live root identity. Fails if the private key is missing.
    static func make(
        from identity: RootCertificateIdentity,
        shortCode: String?,
        exportedAt: Date = Date(),
        appVersion: String = Bundle.main.marketingVersionOrDev
    ) throws -> SharedRootExportPackage {
        guard let privateKeyData = identity.privateKeyData else {
            throw CertificateAuthorityError.storageFailed("Root private key is unavailable for export.")
        }
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        return SharedRootExportPackage(
            formatVersion: formatVersion,
            label: identity.label,
            subjectSummary: identity.subjectSummary,
            certificateDERBase64: identity.certificateData.base64EncodedString(),
            privateKeyRawBase64: privateKeyData.base64EncodedString(),
            certificateSHA256Fingerprint: fingerprint,
            shortCode: shortCode,
            exportedAt: exportedAt,
            appVersion: appVersion
        )
    }

    func rootIdentity(relabeledAs label: String) throws -> RootCertificateIdentity {
        guard formatVersion == Self.formatVersion else {
            throw CertificateAuthorityError.storageFailed("Unsupported shared-root export format.")
        }
        guard let certificateData = Data(base64Encoded: certificateDERBase64),
              let privateKeyData = Data(base64Encoded: privateKeyRawBase64) else {
            throw CertificateAuthorityError.storageFailed("Shared-root package bytes are corrupt.")
        }
        return RootCertificateIdentity(
            label: label,
            subjectSummary: subjectSummary,
            certificateData: certificateData,
            privateKeyData: privateKeyData
        )
    }
}
