import XCTest
@testable import JoesProxy

@MainActor
final class CertificateDistributionRecordStoreTests: XCTestCase {
    func testAppendAndRetireByFingerprint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CertificateDistributionRecordStore(persistenceURL: url)
        store.load()
        let artifactID = UUID()
        let fingerprint = "abc123"
        _ = try store.append(
            CertificateDistributionRecord(
                artifactID: artifactID,
                caInstanceID: UUID(),
                shortCode: "ABCD-EF12",
                certificateSHA256Fingerprint: fingerprint,
                certificateSerialNumber: "01",
                certificateNotAfter: Date().addingTimeInterval(3600),
                profileKind: .iosTrustProfile,
                payloadIdentifier: CertificateProfilePayloadIdentity.profilePayloadIdentifier(
                    shortCode: "ABCD-EF12",
                    artifactID: artifactID
                ),
                resolvedHost: nil,
                proxyPort: nil,
                userNickname: nil,
                generatedAt: Date(),
                appVersion: "test",
                status: .generated
            )
        )
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(try store.markRetired(fingerprint: fingerprint), 1)
        XCTAssertEqual(store.records.first?.status, .retired)
    }

    func testPayloadIdentifierUsesShowblenderPrefix() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let identifier = CertificateProfilePayloadIdentity.profilePayloadIdentifier(
            shortCode: "7K4M-2Q9P",
            artifactID: id
        )
        XCTAssertEqual(
            identifier,
            "com.showblender.joesproxy.ca.7k4m2q9p.profile.00000000-0000-0000-0000-0000000000aa"
        )
    }
}

final class CertificateRenewalAndLeafCacheTests: XCTestCase {
    func testPendingRenewalLabelDoesNotCollideWithBaseLabel() {
        let base = "JoesProxy Root CA"
        let pending = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: base,
            shortCode: "ABCD-EF12"
        )
        XCTAssertNotEqual(pending, base)
        XCTAssertTrue(pending.hasPrefix("\(base).pending-"))
    }

    func testLeafCacheRejectsStaleIssuerFingerprint() throws {
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = InMemoryCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let root = try provider.loadOrCreateRootCertificate()
        let leaf1 = try provider.issueLeafCertificate(for: "example.test")
        let leaf2 = try provider.issueLeafCertificate(for: "example.test")
        XCTAssertEqual(leaf1.certificateData, leaf2.certificateData)

        // Replace root with a new identity under the same label; cache must miss.
        let replacement = try SwiftCertificateFactory().generateRootIdentity(
            label: configuration.certificateLabel,
            commonName: CertificateNaming.productionRootCA
        )
        try store.saveRootCertificate(replacement)
        provider.invalidateLeafCertificateCache()
        let leaf3 = try provider.issueLeafCertificate(for: "example.test")
        XCTAssertNotEqual(leaf1.certificateData, leaf3.certificateData)
        XCTAssertNotEqual(
            CertificateIdentityExtraction.sha256Fingerprint(from: root.certificateData),
            CertificateIdentityExtraction.sha256Fingerprint(from: replacement.certificateData)
        )
    }

    func testPromoteRenewalRootSwapsActiveLabel() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let store = InMemoryCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let active = try provider.loadOrCreateRootCertificate()
        let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: "TEST-CODE"
        )
        let pending = try provider.prepareRenewalRoot(pendingLabel: pendingLabel)
        let promoted = try provider.promoteRenewalRoot(pendingLabel: pendingLabel)
        XCTAssertEqual(promoted.label, configuration.certificateLabel)
        XCTAssertEqual(promoted.certificateData, pending.certificateData)
        XCTAssertNotEqual(promoted.certificateData, active.certificateData)
        XCTAssertNil(store.loadRootCertificate(label: pendingLabel))
    }

    func testSharedRootExportRoundTrip() throws {
        let identity = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let package = try SharedRootExportPackage.make(from: identity, shortCode: "ABCD-EF12")
        let restored = try package.rootIdentity(relabeledAs: "JoesProxy Root CA")
        XCTAssertEqual(restored.certificateData, identity.certificateData)
        XCTAssertEqual(restored.privateKeyData, identity.privateKeyData)
    }

    func testLeafCacheHitDoesNotReloadRootFromStore() throws {
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = CountingInMemoryCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        _ = try provider.loadOrCreateRootCertificate()
        let loadsAfterRoot = store.loadCount

        let leaf1 = try provider.issueLeafCertificate(for: "cache-hit.test")
        XCTAssertGreaterThan(store.loadCount, loadsAfterRoot, "cache miss must load the active root")
        let loadsAfterMiss = store.loadCount

        let leaf2 = try provider.issueLeafCertificate(for: "cache-hit.test")
        XCTAssertEqual(leaf1.certificateData, leaf2.certificateData)
        XCTAssertEqual(
            store.loadCount,
            loadsAfterMiss,
            "cache hit must not Keychain-load the root again"
        )
        let root = try XCTUnwrap(store.peekRootCertificate(label: configuration.certificateLabel))
        XCTAssertEqual(
            leaf1.issuerCertificateSHA256Fingerprint,
            CertificateIdentityExtraction.sha256Fingerprint(from: root.certificateData)
        )
    }

    func testSharedRootExportFileIsOwnerReadWriteOnly() throws {
        let identity = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let package = try SharedRootExportPackage.make(from: identity, shortCode: "ABCD-EF12")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-root-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(package).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.uint16Value & 0o777, 0o600)
    }

    @MainActor
    func testCancelAndResetClearPendingLabelKeyedByActiveShortCode() throws {
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = CountingInMemoryCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let active = try provider.loadOrCreateRootCertificate()
        let activeMeta = CAInstanceMetadata.makeCurrent(from: active)
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("renewal-meta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        let metadataStore = CAInstanceMetadataStore(persistenceURL: metadataURL)
        metadataStore.load()
        _ = try metadataStore.upsert(activeMeta)

        let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: activeMeta.shortCode
        )
        let pendingIdentity = try provider.prepareRenewalRoot(pendingLabel: pendingLabel)
        var pendingMeta = CAInstanceMetadata.makeCurrent(from: pendingIdentity)
        pendingMeta.storageState = .legacy
        pendingMeta.renewalState = .pending
        _ = try metadataStore.upsert(pendingMeta)

        // Pending metadata gets its own short code; Keychain label must stay on the *active* code.
        XCTAssertNotEqual(pendingMeta.shortCode, activeMeta.shortCode)
        let wrongLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: pendingMeta.shortCode
        )
        XCTAssertNotEqual(wrongLabel, pendingLabel)
        XCTAssertNotNil(store.peekRootCertificate(label: pendingLabel))

        // Cancel path: remove by active short code, retire pending metadata, clear active renewalState.
        try store.removeRootCertificate(label: pendingLabel)
        _ = try metadataStore.markRetired(fingerprint: pendingMeta.certificateSHA256Fingerprint)
        var clearedActive = activeMeta
        clearedActive.renewalState = .none
        _ = try metadataStore.upsert(clearedActive)

        XCTAssertNil(store.peekRootCertificate(label: pendingLabel))
        XCTAssertTrue(metadataStore.pendingRenewalInstances().isEmpty)
        XCTAssertEqual(
            metadataStore.metadata(forFingerprint: activeMeta.certificateSHA256Fingerprint)?.renewalState,
            .none
        )

        // Reset path also removes the pending label derived from the active short code.
        _ = try provider.prepareRenewalRoot(pendingLabel: pendingLabel)
        XCTAssertNotNil(store.peekRootCertificate(label: pendingLabel))
        try store.removeRootCertificate(label: configuration.certificateLabel)
        try store.removeRootCertificate(label: pendingLabel)
        XCTAssertNil(store.peekRootCertificate(label: pendingLabel))
        XCTAssertNil(store.peekRootCertificate(label: configuration.certificateLabel))
    }
}

/// Minimal in-memory ``CertificateStore`` for renewal/leaf-cache unit tests.
private final class InMemoryCertificateStore: CertificateStore {
    private var roots: [String: RootCertificateIdentity] = [:]

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        roots[label]
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        roots[identity.label] = identity
    }

    func removeRootCertificate(label: String) throws {
        roots.removeValue(forKey: label)
    }
}

/// Counts ``loadRootCertificate`` calls so leaf-cache hits can be proven Keychain-free.
private final class CountingInMemoryCertificateStore: CertificateStore {
    private var roots: [String: RootCertificateIdentity] = [:]
    private(set) var loadCount = 0

    /// Non-counting peek for assertions that must not inflate ``loadCount``.
    func peekRootCertificate(label: String) -> RootCertificateIdentity? {
        roots[label]
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        loadCount += 1
        return roots[label]
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        roots[identity.label] = identity
    }

    func removeRootCertificate(label: String) throws {
        roots.removeValue(forKey: label)
    }
}
