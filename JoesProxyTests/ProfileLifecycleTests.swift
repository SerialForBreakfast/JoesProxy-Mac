import XCTest
@testable import JoesProxy

final class ProfileHostResolverTests: XCTestCase {
    func testResolverPrefersBonjourThenLANIPThenLoopback() {
        let resolver = ProfileHostResolver()

        let bonjour = resolver.resolve(
            strategy: .bonjourLocal,
            manualHost: "",
            networkInfo: LocalNetworkInfo(lanIP: "192.168.1.10", bonjourName: "TestMac.local")
        )
        XCTAssertEqual(bonjour.strategy, .bonjourLocal)
        XCTAssertEqual(bonjour.host, "TestMac.local")
        XCTAssertFalse(bonjour.usedFallback)

        let ipFallback = resolver.resolve(
            strategy: .bonjourLocal,
            manualHost: "",
            networkInfo: LocalNetworkInfo(lanIP: "192.168.1.10", bonjourName: nil)
        )
        XCTAssertEqual(ipFallback.strategy, .lanIP)
        XCTAssertEqual(ipFallback.host, "192.168.1.10")
        XCTAssertTrue(ipFallback.usedFallback)

        let loopbackFallback = resolver.resolve(
            strategy: .bonjourLocal,
            manualHost: "",
            networkInfo: LocalNetworkInfo(lanIP: nil, bonjourName: nil)
        )
        XCTAssertEqual(loopbackFallback.host, "127.0.0.1")
        XCTAssertTrue(loopbackFallback.usedFallback)
    }

    func testManualHostOverridesNetworkDiscoveryAndTrimsWhitespace() {
        let resolution = ProfileHostResolver().resolve(
            strategy: .manualHost,
            manualHost: "  proxy.example.test  ",
            networkInfo: LocalNetworkInfo(lanIP: "192.168.1.10", bonjourName: "TestMac.local")
        )

        XCTAssertEqual(resolution.strategy, .manualHost)
        XCTAssertEqual(resolution.host, "proxy.example.test")
        XCTAssertFalse(resolution.usedFallback)
    }
}

final class ProfileSnapshotStoreTests: XCTestCase {
    func testStoreSavesLoadsAndCapsHistory() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ProfileSnapshotStore(fileURL: fileURL, historyLimit: 2)

        try store.appendSnapshot(makeSnapshot(host: "first.local"))
        try store.appendSnapshot(makeSnapshot(host: "second.local"))
        try store.appendSnapshot(makeSnapshot(host: "third.local"))

        let snapshots = store.loadSnapshots()
        XCTAssertEqual(snapshots.map(\.resolvedHost), ["third.local", "second.local"])
    }

    func testStoreToleratesUnknownFutureFields() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let json = """
        {
          "version": 99,
          "futureField": "ignored",
          "snapshots": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "kind": "iosTrustProfile",
              "generatedAt": "2026-06-30T12:00:00Z",
              "hostStrategy": "bonjourLocal",
              "resolvedHost": "TestMac.local",
              "proxyPort": 9090,
              "profileServerURL": null,
              "certificateLabel": "JoesProxy Root CA",
              "certificateSHA256Fingerprint": "abc",
              "certificateExpirationDate": null,
              "payloadIdentifiers": ["com.apple.security.root"],
              "appVersion": "1.0",
              "lastKnownLANIP": "192.168.1.2",
              "lastKnownBonjourName": "TestMac.local"
            }
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let snapshots = ProfileSnapshotStore(fileURL: fileURL).loadSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.resolvedHost, "TestMac.local")
    }

    func testStoreDecodesSnapshotsMissingOptionalIdentityFields() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let json = """
        {
          "version": 1,
          "snapshots": [
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "kind": "iosTrustProfile",
              "generatedAt": "2026-06-30T12:00:00Z",
              "hostStrategy": "bonjourLocal",
              "resolvedHost": "Legacy.local",
              "proxyPort": 9090,
              "profileServerURL": null,
              "certificateLabel": "JoesProxy Root CA",
              "certificateSHA256Fingerprint": "deadbeef",
              "certificateExpirationDate": null,
              "payloadIdentifiers": ["com.apple.security.root"],
              "appVersion": "1.0",
              "lastKnownLANIP": "192.168.1.2",
              "lastKnownBonjourName": "Legacy.local"
            }
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let snapshots = ProfileSnapshotStore(fileURL: fileURL).loadSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots.first?.caInstanceID)
        XCTAssertNil(snapshots.first?.shortCode)
        XCTAssertNil(snapshots.first?.artifactID)
        XCTAssertEqual(snapshots.first?.resolvedHost, "Legacy.local")
    }
}

final class ProfileSnapshotDiagnosisTests: XCTestCase {
    func testDiagnosisDetectsLANIPPortCertificateAndExpirationDrift() {
        let snapshot = makeSnapshot(
            host: "192.168.1.2",
            strategy: .lanIP,
            lanIP: "192.168.1.2",
            fingerprint: "old"
        )

        XCTAssertEqual(
            ProfileSnapshotDiagnosis.evaluate(
                snapshot: snapshot,
                currentNetworkInfo: LocalNetworkInfo(lanIP: "192.168.1.3", bonjourName: "TestMac.local"),
                currentProxyPort: 9090,
                currentCertificateFingerprint: "old"
            ).health,
            .ipChanged(previous: "192.168.1.2", current: "192.168.1.3")
        )

        XCTAssertEqual(
            ProfileSnapshotDiagnosis.evaluate(
                snapshot: snapshot,
                currentNetworkInfo: LocalNetworkInfo(lanIP: "192.168.1.2", bonjourName: "TestMac.local"),
                currentProxyPort: 9091,
                currentCertificateFingerprint: "old"
            ).health,
            .proxyPortChanged(previous: 9090, current: 9091)
        )

        XCTAssertEqual(
            ProfileSnapshotDiagnosis.evaluate(
                snapshot: snapshot,
                currentNetworkInfo: LocalNetworkInfo(lanIP: "192.168.1.2", bonjourName: "TestMac.local"),
                currentProxyPort: 9090,
                currentCertificateFingerprint: "new"
            ).health,
            .certificateChanged
        )

        let expired = makeSnapshot(
            host: "TestMac.local",
            expiration: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            ProfileSnapshotDiagnosis.evaluate(
                snapshot: expired,
                currentNetworkInfo: LocalNetworkInfo(lanIP: "192.168.1.2", bonjourName: "TestMac.local"),
                currentProxyPort: 9090,
                currentCertificateFingerprint: "abc",
                now: Date(timeIntervalSince1970: 20)
            ).health,
            .certificateExpired
        )
    }
}

final class ProfileHostConfigurationTests: XCTestCase {
    func testHostStrategyAndManualHostPersistAndReset() {
        let suiteName = "ProfileHostConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.profileHostStrategyRawValue, ProfileHostStrategy.bonjourLocal.rawValue)
        XCTAssertEqual(configuration.manualProfileHost, "")

        configuration.profileHostStrategyRawValue = ProfileHostStrategy.manualHost.rawValue
        configuration.manualProfileHost = "proxy.example.test"

        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertEqual(reloaded.profileHostStrategyRawValue, ProfileHostStrategy.manualHost.rawValue)
        XCTAssertEqual(reloaded.manualProfileHost, "proxy.example.test")

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.profileHostStrategyRawValue, ProfileHostStrategy.bonjourLocal.rawValue)
        XCTAssertEqual(reloaded.manualProfileHost, "")
    }
}

private func makeSnapshot(
    host: String,
    strategy: ProfileHostStrategy = .bonjourLocal,
    lanIP: String? = "192.168.1.2",
    bonjourName: String? = "TestMac.local",
    fingerprint: String? = "abc",
    expiration: Date? = nil
) -> GeneratedProfileSnapshot {
    GeneratedProfileSnapshot(
        id: UUID(),
        kind: .tvOSManagedProxyProfile,
        generatedAt: Date(timeIntervalSince1970: 100),
        hostStrategy: strategy,
        resolvedHost: host,
        proxyPort: 9090,
        profileServerURL: nil,
        certificateLabel: "JoesProxy Root CA",
        certificateSHA256Fingerprint: fingerprint,
        certificateExpirationDate: expiration,
        payloadIdentifiers: ["com.apple.proxy.http.global", "com.apple.security.root"],
        appVersion: "Test",
        lastKnownLANIP: lanIP,
        lastKnownBonjourName: bonjourName,
        caInstanceID: nil,
        certificateSerialNumber: nil,
        shortCode: nil,
        artifactID: nil
    )
}
