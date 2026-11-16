import Security
import XCTest
@testable import JoesProxy

final class PersistentTrustInstallerTests: XCTestCase {
    func testInstallationStatusReturnsNotInstalledWhenCertificateMissing() throws {
        let store = InMemoryTrustCertificateStore(identity: nil)
        let keychain = FakeCertificateKeychain()
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: store,
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(trustInstaller.installationStatus(for: "Missing"), .notInstalled)
    }

    func testInstallationStatusReturnsInvalidWhenInstalledCertificateDiffersFromStoredIdentity() throws {
        let installedIdentity = try makeRootIdentity(label: "Mismatch")
        let currentIdentity = try makeRootIdentity(label: "Mismatch")
        let store = InMemoryTrustCertificateStore(identity: currentIdentity)
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            installedIdentity.label: [try makeCertificate(from: installedIdentity)]
        ])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: store,
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(
            trustInstaller.installationStatus(for: installedIdentity.label),
            .invalid(reason: "Installed '\(installedIdentity.label)' certificates do not match the current JoesProxy root CA. Compare the certificate fingerprints in Keychain Access before choosing which root to retire.")
        )
    }

    func testInstallationStatusUsesTrustEvaluatorForMatchingInstalledCertificate() throws {
        let identity = try makeRootIdentity(label: "Installed")
        let store = InMemoryTrustCertificateStore(identity: identity)
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            identity.label: [try makeCertificate(from: identity)]
        ])
        let evaluator = FakeCertificateTrustEvaluator(result: .installed)
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: store,
            trustEvaluator: evaluator
        )

        XCTAssertEqual(trustInstaller.installationStatus(for: identity.label), .installed)
        XCTAssertEqual(evaluator.evaluatedCertificates.count, 1)
    }

    func testInstallationStatusReturnsEvaluatorFailureReason() throws {
        let identity = try makeRootIdentity(label: "Invalid")
        let store = InMemoryTrustCertificateStore(identity: identity)
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            identity.label: [try makeCertificate(from: identity)]
        ])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: store,
            trustEvaluator: FakeCertificateTrustEvaluator(result: .trustRequired(reason: "Not trusted"))
        )

        XCTAssertEqual(trustInstaller.installationStatus(for: identity.label), .trustRequired(reason: "Not trusted"))
    }

    func testInstallAddsCertificateToKeychain() throws {
        let identity = try makeRootIdentity(label: "Install")
        let keychain = FakeCertificateKeychain()
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        try trustInstaller.install(identity)

        XCTAssertEqual(keychain.addedLabels, [identity.label])
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(keychain.certificatesByLabel[identity.label]?.first)) as Data, identity.certificateData)
    }

    func testInstallThrowsWhenCertificateCannotBeReadBackAfterAdd() throws {
        let identity = try makeRootIdentity(label: "UnreadableAfterInstall")
        let keychain = FakeCertificateKeychain(simulatedReadbackMissLabels: [identity.label])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertThrowsError(try trustInstaller.install(identity)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                """
                The root CA was added, but JoesProxy could not read it back from the keychain. The certificate may have been stored outside the app's expected keychain access group or rejected by the current keychain configuration.
                """
            )
        }
    }

    func testRemoveCertificateDeletesInstalledCertificate() throws {
        let identity = try makeRootIdentity(label: "Remove")
        let certificate = try makeCertificate(from: identity)
        let keychain = FakeCertificateKeychain(certificatesByLabel: [identity.label: [certificate]])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        try trustInstaller.removeCertificate(label: identity.label)

        XCTAssertEqual(keychain.deletedLabels, [identity.label])
        XCTAssertNil(keychain.certificatesByLabel[identity.label])
    }

    func testRemoveCertificateIsNoOpWhenNothingInstalled() throws {
        let keychain = FakeCertificateKeychain()
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: nil),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        try trustInstaller.removeCertificate(label: "Missing")

        XCTAssertTrue(keychain.deletedLabels.isEmpty)
    }

    func testRepeatedRemovalOfAbsentInstalledCertificatePreservesStoredIdentity() throws {
        let identity = try makeRootIdentity(label: "MissingInstalledCertificate")
        let store = InMemoryTrustCertificateStore(identity: identity)
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: FakeCertificateKeychain(),
            certificateStore: store,
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        try trustInstaller.removeCertificate(label: identity.label)
        try trustInstaller.removeCertificate(label: identity.label)
        XCTAssertEqual(store.loadRootCertificate(label: identity.label)?.certificateData, identity.certificateData)
    }

    func testRemovalWithoutStoredIdentityPreservesInstalledCertificate() throws {
        let other = try makeRootIdentity(label: "Shared")
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            other.label: [try makeCertificate(from: other)]
        ])
        let installer = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: nil),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertThrowsError(try installer.removeCertificate(label: other.label))
        XCTAssertTrue(keychain.deletedLabels.isEmpty)
        XCTAssertEqual(try keychain.retrieveCertificates(withLabel: other.label).count, 1)
    }

    func testInstallationStatusReturnsInvalidWhenMultipleCertificatesShareLabel() throws {
        let identity = try makeRootIdentity(label: "Duplicate")
        let staleIdentity = try makeRootIdentity(label: "Duplicate")
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            identity.label: [
                try makeCertificate(from: identity),
                try makeCertificate(from: staleIdentity)
            ]
        ])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(
            trustInstaller.installationStatus(for: identity.label),
            .invalid(reason: "Multiple '\(identity.label)' certificates are installed. Compare the certificate fingerprints in Keychain Access before choosing which root to retire.")
        )
    }

    func testRemoveCertificatePreservesUnrelatedCertificateWithSharedLabel() throws {
        let identity = try makeRootIdentity(label: "CleanupAll")
        let staleIdentity = try makeRootIdentity(label: "CleanupAll")
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            identity.label: [
                try makeCertificate(from: identity),
                try makeCertificate(from: staleIdentity)
            ]
        ])
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        try trustInstaller.removeCertificate(label: identity.label)

        XCTAssertEqual(try keychain.retrieveCertificates(withLabel: identity.label).map { SecCertificateCopyData($0) as Data },
                       [staleIdentity.certificateData])
        XCTAssertEqual(keychain.deletedLabels.count, 1)
    }

    func testFingerprintRetirementPreservesOtherRootAndCanBeRepeated() throws {
        let target = try makeRootIdentity(label: "Shared")
        let other = try makeRootIdentity(label: target.label)
        let keychain = FakeCertificateKeychain(certificatesByLabel: [
            target.label: [try makeCertificate(from: target), try makeCertificate(from: other)]
        ])
        let installer = PersistentTrustInstaller(keychainHelper: keychain,
            certificateStore: InMemoryTrustCertificateStore(identity: target),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed))
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: target.certificateData)
        XCTAssertEqual(try installer.removeInstalledCertificate(matchingFingerprint: fingerprint, label: target.label), 1)
        XCTAssertEqual(try installer.removeInstalledCertificate(matchingFingerprint: fingerprint, label: target.label), 0)
        XCTAssertEqual(try keychain.retrieveCertificates(withLabel: target.label).map { SecCertificateCopyData($0) as Data },
                       [other.certificateData])
    }
}

private final class InMemoryTrustCertificateStore: CertificateStore {
    private let identity: RootCertificateIdentity?

    init(identity: RootCertificateIdentity?) {
        self.identity = identity
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        identity?.label == label ? identity : nil
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {}

    func removeRootCertificate(label: String) throws {}
}

private final class FakeCertificateKeychain: CertificateKeychainAccessing {
    private(set) var certificatesByLabel: [String: [SecCertificate]]
    private(set) var addedLabels: [String] = []
    private(set) var deletedLabels: [String] = []
    private let simulatedReadbackMissLabels: Set<String>

    init(
        certificatesByLabel: [String: [SecCertificate]] = [:],
        simulatedReadbackMissLabels: Set<String> = []
    ) {
        self.certificatesByLabel = certificatesByLabel
        self.simulatedReadbackMissLabels = simulatedReadbackMissLabels
    }

    func addCertificate(_ certificate: SecCertificate, label: String) throws {
        certificatesByLabel[label, default: []].append(certificate)
        addedLabels.append(label)
    }

    func deleteCertificate(_ certificate: SecCertificate, label: String) throws {
        certificatesByLabel[label]?.removeAll { SecCertificateCopyData($0) as Data == SecCertificateCopyData(certificate) as Data }
        if certificatesByLabel[label]?.isEmpty == true {
            certificatesByLabel[label] = nil
        }
        deletedLabels.append(label)
    }

    func retrieveCertificate(withLabel label: String) throws -> SecCertificate? {
        if simulatedReadbackMissLabels.contains(label) {
            return nil
        }

        return certificatesByLabel[label]?.first
    }

    func retrieveCertificates(withLabel label: String) throws -> [SecCertificate] {
        if simulatedReadbackMissLabels.contains(label) {
            return []
        }

        return certificatesByLabel[label] ?? []
    }

    func saveData(_ data: Data, service: String, account: String) throws {}

    func retrieveData(service: String, account: String, interactive: Bool) throws -> Data? { nil }

    func deleteData(service: String, account: String) throws {}
}

private final class FakeCertificateTrustEvaluator: CertificateTrustEvaluating {
    let result: TrustInstallationStatus
    private(set) var evaluatedCertificates: [Data] = []

    init(result: TrustInstallationStatus) {
        self.result = result
    }

    func installationStatus(for certificate: SecCertificate) -> TrustInstallationStatus {
        evaluatedCertificates.append(SecCertificateCopyData(certificate) as Data)
        return result
    }
}

private func makeRootIdentity(label: String) throws -> RootCertificateIdentity {
    try SwiftCertificateFactory().generateRootIdentity(label: label, commonName: "\(label) Root CA")
}

private func makeCertificate(from identity: RootCertificateIdentity) throws -> SecCertificate {
    try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificateData as CFData))
}
