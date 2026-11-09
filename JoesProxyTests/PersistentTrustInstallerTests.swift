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
            .invalid(reason: "Installed '\(installedIdentity.label)' certificates do not match the current JoesProxy root CA. Reset Certificate State to clean up stale certificates.")
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

    func testRemoveCertificateThrowsWhenStoredIdentityExistsButInstalledCertificateIsMissing() throws {
        let identity = try makeRootIdentity(label: "MissingInstalledCertificate")
        let trustInstaller = PersistentTrustInstaller(
            keychainHelper: FakeCertificateKeychain(),
            certificateStore: InMemoryTrustCertificateStore(identity: identity),
            trustEvaluator: FakeCertificateTrustEvaluator(result: .installed)
        )

        XCTAssertThrowsError(try trustInstaller.removeCertificate(label: identity.label)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "JoesProxy has stored root CA material for '\(identity.label)', but no matching installed certificate was found in the keychain to remove."
            )
        }
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
            .invalid(reason: "Multiple '\(identity.label)' certificates are installed. Reset Certificate State to remove stale or duplicate certificates.")
        )
    }

    func testRemoveCertificateDeletesAllCertificatesWithSharedLabel() throws {
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

        XCTAssertNil(keychain.certificatesByLabel[identity.label])
        XCTAssertEqual(keychain.deletedLabels.count, 2)
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

    func retrieveData(service: String, account: String) -> Data? { nil }

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
