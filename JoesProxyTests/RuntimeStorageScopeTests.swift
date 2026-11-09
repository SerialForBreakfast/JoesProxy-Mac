import XCTest
@testable import JoesProxy

@MainActor
final class RuntimeStorageScopeTests: XCTestCase {
    func testUITestStorageRejectsMissingUnsafeAndUnpreparedRoots() throws {
        for path in [nil, "relative", "/", "/tmp/run-artifacts", "/build/HostTestResults/../run-artifacts",
                     "/build/HostTestResults/\(UUID().uuidString)-artifacts"] as [String?] {
            let environment = path.map { ["JOESPROXY_UI_ARTIFACT_DIRECTORY": $0] } ?? [:]
            XCTAssertThrowsError(try RuntimeStorageScope.uiTest(environment: environment))
        }
    }

    func testUITestLaunchesUseFreshStoresAndRejectReusedNamespaces() throws {
        let parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/HostTestResults/storage-\(UUID().uuidString)-artifacts")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let environment = ["JOESPROXY_UI_ARTIFACT_DIRECTORY": parent.path]
        let id = UUID()
        let first = try RuntimeStorageScope.uiTest(environment: environment, runID: id)
        first.defaults.set("first launch", forKey: "sentinel")
        try Data("synthetic saved data".utf8).write(to: first.file("effect-bundles.json"))
        XCTAssertThrowsError(try RuntimeStorageScope.uiTest(environment: environment, runID: id))
        let second = try RuntimeStorageScope.uiTest(environment: environment)
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertNil(second.defaults.string(forKey: "sentinel"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.file("effect-bundles.json").path))
        XCTAssertEqual(second.root.deletingLastPathComponent().path, parent.path)
        let repository = EffectBundleRepository(persistenceURL: second.file("effect-bundles.json"),
                                               packagesRootURL: second.file("EffectBundles"))
        XCTAssertTrue(repository.records.isEmpty)
        let coordinator = AppCoordinator(
            configuration: UserDefaultsAppConfiguration(userDefaults: second.defaults),
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true, recoveryStorageAccessEnabled: false,
            storageScope: second, hlsFixtureProfileRoot: parent.appendingPathComponent("packaged-fixtures"))
        XCTAssertEqual(coordinator.hlsSubstitutionCoordinator.persistenceURL, second.file("hls-substitutions.json"))
        XCTAssertTrue(coordinator.hlsSubstitutionCoordinator.experiments.isEmpty)
        XCTAssertEqual(coordinator.mcpServerController.fixtureRunStore.profilesRoot,
                       parent.appendingPathComponent("packaged-fixtures"))
    }

    func testMCPBootstrapAndReloadStayInExplicitNamespace() throws {
        let suite = "RuntimeStorageScope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/RuntimeStorageScope-\(UUID().uuidString)")
        let scope = RuntimeStorageScope(root: root, defaults: defaults)
        let first = MCPServerController(sessionStore: InMemorySessionStore(),
            credentialStore: MCPInMemoryCredentialStore(), userDefaults: defaults, storageScope: scope)
        first.bootstrap()
        XCTAssertEqual(first.clientRegistry.persistenceURL, scope.file("mcp-clients.json"))
        XCTAssertTrue(first.policyStore.isLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scope.file("mcp-policy.json").path))
        let second = MCPServerController(sessionStore: InMemorySessionStore(),
            credentialStore: MCPInMemoryCredentialStore(), userDefaults: defaults, storageScope: scope)
        second.bootstrap()
        XCTAssertEqual(first.policyStore.policyRevision, second.policyStore.policyRevision)
        XCTAssertTrue(second.clientRegistry.clients.isEmpty)
        XCTAssertEqual(second.fixtureRunStore.profilesRoot, scope.file("FixtureProfiles"))
        XCTAssertTrue(second.approvalStore.pendingRequests.isEmpty)
    }
}
