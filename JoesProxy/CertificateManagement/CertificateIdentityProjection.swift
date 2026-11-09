import Foundation

/// Read-only certificate identity projections for MCP/CLI (Phase C).
///
/// Concurrency: `@MainActor` — reads Application Support metadata stores owned by the UI process.
@MainActor
enum CertificateIdentityProjection {
    static func statusPayload(
        root: RootCertificateIdentity?,
        metadata: CAInstanceMetadata?,
        trustStatus: TrustInstallationStatus
    ) -> [String: Any] {
        let fingerprint = root.map {
            CertificateIdentityExtraction.sha256Fingerprint(from: $0.certificateData)
        }
        let identityStatus = CertificateIdentityExtraction.evaluateIdentityStatus(
            rootCertificateData: root?.certificateData,
            metadata: metadata
        )
        return [
            "certificateSHA256Fingerprint": fingerprint as Any,
            "serialNumber": metadata?.certificateSerialNumber
                ?? root.flatMap { CertificateIdentityExtraction.serialNumber(from: $0.certificateData) } as Any,
            "notBefore": ISO8601DateFormatter().string(from: metadata?.notBefore
                ?? root.flatMap { CertificateIdentityExtraction.notBefore(from: $0.certificateData) } ?? Date.distantPast),
            "notAfter": ISO8601DateFormatter().string(from: metadata?.notAfter
                ?? root.flatMap { CertificateIdentityExtraction.notAfter(from: $0.certificateData) } ?? Date.distantPast),
            "status": identityStatus.title,
            "storageState": metadata?.storageState.rawValue as Any,
            "trustStatus": String(describing: trustStatus),
            "nickname": metadata?.nickname as Any,
            "shortCode": metadata?.shortCode as Any,
            "caInstanceID": metadata?.id.uuidString as Any,
            "remoteTrustState": RemoteTrustState.remoteTrustInventoryUnavailable.rawValue
        ]
    }

    static func compare(fingerprintA: String, fingerprintB: String) -> [String: Any] {
        let normalizedA = fingerprintA.replacingOccurrences(of: ":", with: "").lowercased()
        let normalizedB = fingerprintB.replacingOccurrences(of: ":", with: "").lowercased()
        return [
            "matches": normalizedA == normalizedB,
            "fingerprintA": normalizedA,
            "fingerprintB": normalizedB
        ]
    }
}
