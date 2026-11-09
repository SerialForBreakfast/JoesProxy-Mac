import Combine
import Foundation
import Security
import XCTest
@testable import JoesProxy

final class PersistentTrustInstallerIsolatedIntegrationTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoesProxyTrustInstallerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try super.tearDownWithError()
    }

    func testPersistentKeychainStorePersistsRootIdentityAcrossFreshInstances() throws {
        let configuration = IsolatedTestAppConfiguration(certificateLabel: "IsolatedRoot-\(UUID().uuidString)")
        let firstKeychain = try FileBackedCertificateKeychain(rootURL: rootURL)
        let firstStore = PersistentKeychainCertificateStore(keychainHelper: firstKeychain)
        let firstProvider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: firstStore
        )

        let createdIdentity = try firstProvider.loadOrCreateRootCertificate()

        let secondStore = PersistentKeychainCertificateStore(
            keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL)
        )
        let reloadedIdentity = try XCTUnwrap(secondStore.loadRootCertificate(label: configuration.certificateLabel))

        XCTAssertEqual(reloadedIdentity.certificateData, createdIdentity.certificateData)
        XCTAssertEqual(reloadedIdentity.privateKeyData, createdIdentity.privateKeyData)
        XCTAssertEqual(reloadedIdentity.subjectSummary, createdIdentity.subjectSummary)
    }

    func testTrustInstallerRoundTripsInstallStatusAndRemovalAcrossFreshInstances() throws {
        let configuration = IsolatedTestAppConfiguration(certificateLabel: "IsolatedTrust-\(UUID().uuidString)")
        let keychain = try FileBackedCertificateKeychain(rootURL: rootURL)
        let store = PersistentKeychainCertificateStore(keychainHelper: keychain)
        let provider = PersistentCertificateAuthorityProvider(configuration: configuration, certificateStore: store)
        let identity = try provider.loadOrCreateRootCertificate()

        let installer = PersistentTrustInstaller(
            keychainHelper: keychain,
            certificateStore: store,
            trustEvaluator: FixedTrustEvaluator(result: .installed)
        )
        try installer.install(identity)

        let reloadedInstaller = PersistentTrustInstaller(
            keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL),
            certificateStore: PersistentKeychainCertificateStore(
                keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL)
            ),
            trustEvaluator: FixedTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(reloadedInstaller.installationStatus(for: configuration.certificateLabel), .installed)

        try reloadedInstaller.removeCertificate(label: configuration.certificateLabel)

        let cleanedInstaller = PersistentTrustInstaller(
            keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL),
            certificateStore: PersistentKeychainCertificateStore(
                keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL)
            ),
            trustEvaluator: FixedTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(cleanedInstaller.installationStatus(for: configuration.certificateLabel), .notInstalled)
    }

    func testTrustInstallerReportsInvalidWhenInstalledCertificateDoesNotMatchPersistedIdentity() throws {
        let label = "Mismatch-\(UUID().uuidString)"
        let installedIdentity = try SwiftCertificateFactory().generateRootIdentity(label: label, commonName: "Installed Root")
        let currentIdentity = try SwiftCertificateFactory().generateRootIdentity(label: label, commonName: "Current Root")
        let keychain = try FileBackedCertificateKeychain(rootURL: rootURL)
        let store = PersistentKeychainCertificateStore(keychainHelper: keychain)

        try store.saveRootCertificate(currentIdentity)
        try keychain.addCertificate(makeCertificate(from: installedIdentity), label: label)

        let installer = PersistentTrustInstaller(
            keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL),
            certificateStore: PersistentKeychainCertificateStore(
                keychainHelper: try FileBackedCertificateKeychain(rootURL: rootURL)
            ),
            trustEvaluator: FixedTrustEvaluator(result: .installed)
        )

        XCTAssertEqual(
            installer.installationStatus(for: label),
            .invalid(reason: "Installed '\(label)' certificates do not match the current JoesProxy root CA. Reset Certificate State to clean up stale certificates.")
        )
    }
}

private final class FileBackedCertificateKeychain: CertificateKeychainAccessing {
    private let certificatesDirectoryURL: URL
    private let dataDirectoryURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) throws {
        self.certificatesDirectoryURL = rootURL.appendingPathComponent("certificates", isDirectory: true)
        self.dataDirectoryURL = rootURL.appendingPathComponent("data", isDirectory: true)

        try fileManager.createDirectory(at: certificatesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
    }

    func addCertificate(_ certificate: SecCertificate, label: String) throws {
        let data = SecCertificateCopyData(certificate) as Data
        try data.write(to: certificateURL(for: label), options: .atomic)
    }

    func deleteCertificate(_ certificate: SecCertificate, label: String) throws {
        let url = certificateURL(for: label)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.removeItem(at: url)
    }

    func retrieveCertificate(withLabel label: String) throws -> SecCertificate? {
        try retrieveCertificates(withLabel: label).first
    }

    func retrieveCertificates(withLabel label: String) throws -> [SecCertificate] {
        let url = certificateURL(for: label)
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            return []
        }

        return [certificate]
    }

    func saveData(_ data: Data, service: String, account: String) throws {
        try data.write(to: dataURL(service: service, account: account), options: .atomic)
    }

    func retrieveData(service: String, account: String) -> Data? {
        try? Data(contentsOf: dataURL(service: service, account: account))
    }

    func deleteData(service: String, account: String) throws {
        let url = dataURL(service: service, account: account)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.removeItem(at: url)
    }

    private func certificateURL(for label: String) -> URL {
        certificatesDirectoryURL.appendingPathComponent("\(safeComponent(label)).der")
    }

    private func dataURL(service: String, account: String) -> URL {
        let key = "\(service)--\(account)"
        return dataDirectoryURL.appendingPathComponent("\(safeComponent(key)).bin")
    }

    private func safeComponent(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}

private struct FixedTrustEvaluator: CertificateTrustEvaluating {
    let result: TrustInstallationStatus

    func installationStatus(for certificate: SecCertificate) -> TrustInstallationStatus {
        result
    }
}

private final class IsolatedTestAppConfiguration: AppConfiguration {
    var proxyPort: UInt16 = 9090
    var logLevel: AppLogLevel = .info
    var verboseHTTPSLoggingEnabled = false
    var isFindDebugLoggingEnabled = false
    var appTextSizeRawValue = AppTextSize.standard.rawValue
    var isInspectorCopyRedactionEnabled = true
    var sessionSortFieldRawValue = "startedAt"
    var isSessionSortAscending = false
    var isSessionAutoScrollEnabled = false
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
    var sessionExplorerExpandedNodeIDs: [String] = []
    var sessionInspectorSplitFraction = 0.62
    var httpsBypassDomains: [String] = []
    var httpsInterceptDomains: [String] = []
    var isNoCachingEnabled = false
    var noCachingDomains: [String] = []
    var isSystemProxyManagementEnabled = false
    var systemProxyStrictCapture = false
    var hasAcknowledgedSystemProxyRouting = false
    var showSystemProxyMenuBarItem = true
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false
    var warnsBeforeQuittingWithUnsavedSessions = true
    var sdkEventServerEnabled = false
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue
    var manualProfileHost = ""
    var responseOverridesData: Data?
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited
    let certificateLabel: String
    var didChangePublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }

    init(certificateLabel: String) {
        self.certificateLabel = certificateLabel
    }

    func resetToDefaults() {
        proxyPort = NetworkConstants.defaultPort
        logLevel = .info
        verboseHTTPSLoggingEnabled = false
        isFindDebugLoggingEnabled = false
        appTextSizeRawValue = AppTextSize.standard.rawValue
        isInspectorCopyRedactionEnabled = true
        sessionSortFieldRawValue = "startedAt"
        isSessionSortAscending = false
        isSessionAutoScrollEnabled = false
        sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
        sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
        sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
        sessionExplorerExpandedNodeIDs = []
        sessionInspectorSplitFraction = 0.62
        httpsBypassDomains = []
        httpsInterceptDomains = []
        isNoCachingEnabled = false
        noCachingDomains = []
        isSystemProxyManagementEnabled = false
        systemProxyStrictCapture = false
        hasAcknowledgedSystemProxyRouting = false
        showSystemProxyMenuBarItem = true
        runInMenuBarOnly = false
        warnsBeforeQuittingWithUnsavedSessions = true
        sdkEventServerEnabled = false
        networkThrottleConfiguration = .defaults
        responseOverridesData = nil
    }
}

private func makeCertificate(from identity: RootCertificateIdentity) -> SecCertificate {
    SecCertificateCreateWithData(nil, identity.certificateData as CFData)!
}
