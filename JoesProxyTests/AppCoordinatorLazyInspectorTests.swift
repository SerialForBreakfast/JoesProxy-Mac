import XCTest
@testable import JoesProxy

@MainActor
final class AppCoordinatorLazyInspectorTests: XCTestCase {
    func testSharedExportCompletesAcrossInspectorDepartureAndKeepsItsReceipt() async throws {
        let coordinator = try isolatedCoordinator()
        let host = InspectorWorkspaceHost(coordinator: coordinator, forceAgent: true)
        coordinator.sessionStore.append(SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
            host: "example.test", port: 443, path: "/shared-export", headers: [], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date())))
        host.openInspector()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/AgentSwitchExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("capture.har")
        let export = coordinator.agentCaptureExportController
        let operation = Task { try await export.saveAllSessions(to: destination, asHAR: true) }
        while !export.isSaving && export.resultMessage == nil { await Task.yield() }
        XCTAssertTrue(host.returnToAgent())
        try await operation.value
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertEqual(export.resultMessage, "Saved capture.har.")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(coordinator.sessionStore.sessions.count, 1)
    }

    func testSupervisionAvailabilityTracksCaptureWithoutInspectorAndPreservesFailureReceipt() async throws {
        let coordinator = try isolatedCoordinator()
        let export = coordinator.agentCaptureExportController
        let recovery = coordinator.agentCaptureRecoveryController
        XCTAssertFalse(export.hasSessions)
        XCTAssertFalse(recovery.hasSessions)
        do {
            _ = try await recovery.restoreLatestCapture()
            XCTFail("Disabled recovery storage must fail")
        } catch { }
        let failure = try XCTUnwrap(recovery.resultMessage)
        coordinator.sessionStore.append(SessionRecord(request: CapturedRequest(method: "GET", scheme: .http,
            host: "example.test", port: 80, path: "/availability", headers: [], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date())))
        let deadline = Date().addingTimeInterval(5)
        while !export.hasSessions || !recovery.hasSessions {
            guard Date() < deadline else { XCTFail("Availability did not refresh"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.sessionStore.clear()
        XCTAssertFalse(coordinator.sessionStore.sessions.isEmpty, "Clear retains the canonical system marker")
        coordinator.sessionStore.remove(ids: Set(coordinator.sessionStore.sessions.map(\.id)))
        let clearDeadline = Date().addingTimeInterval(5)
        while export.hasSessions || recovery.hasSessions {
            guard Date() < clearDeadline else {
                XCTFail("Clear did not refresh availability: export=\(export.hasSessions), recovery=\(recovery.hasSessions), retained=\(coordinator.sessionStore.sessions.count)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recovery.resultMessage, failure)
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertFalse(coordinator.isMediaInspectionIndexConstructed)
    }

    func testLaunchChoiceIsFrozenUntilExplicitSwitchAndOverrideDoesNotPersist() throws {
        let coordinator = try isolatedCoordinator()
        coordinator.configuration.preferredWorkingView = .compact
        let host = InspectorWorkspaceHost(coordinator: coordinator, forceAgent: true)
        XCTAssertEqual(host.activeWorkspace, .agent)
        XCTAssertEqual(coordinator.configuration.launchWorkspacePreference, .inspector)
        coordinator.configuration.launchWorkspacePreference = .agent
        host.openInspector()
        coordinator.configuration.launchWorkspacePreference = .inspector
        coordinator.configuration.launchWorkspacePreference = .agent
        XCTAssertEqual(host.activeWorkspace, .inspector, "Next-launch settings are not live navigation")
        XCTAssertFalse(host.returnToAgent(presentationBlocked: true))
        XCTAssertEqual(host.activeWorkspace, .inspector)
        XCTAssertTrue(host.returnToAgent())
        coordinator.configuration.launchWorkspacePreference = .inspector
        XCTAssertEqual(host.activeWorkspace, .agent)
        XCTAssertEqual(coordinator.configuration.preferredWorkingView, .compact)
    }

    func testRepeatedSwitchesReleaseInspectorAndKeepCanonicalCaptureAndQueryOwners() async throws {
        let coordinator = try isolatedCoordinator()
        let host = InspectorWorkspaceHost(coordinator: coordinator, forceAgent: true)
        let queries = coordinator.mcpServerController.agentQueries
        let recovery = coordinator.agentCaptureRecoveryController
        let export = coordinator.agentCaptureExportController
        for index in 0..<12 {
            let session = SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
                host: "example.test", port: 443, path: "/cycle/\(index)", headers: [],
                bodyData: nil, bodySize: nil), timing: SessionTiming(startedAt: Date()))
            coordinator.sessionStore.append(session)
            host.openInspector()
            var inspector: ProxyViewModel? = host.loadInspector()
            weak var oldInspector = inspector
            inspector?.sessionSearchText = "cycle"
            host.openInspector()
            XCTAssertTrue(inspector === host.loadInspector(), "Repeated entry must not replace the graph")
            XCTAssertTrue(host.returnToAgent())
            XCTAssertTrue(host.returnToAgent(), "Repeated departure is idempotent")
            inspector = nil
            await Task.yield()
            XCTAssertNil(oldInspector)
            XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
            XCTAssertTrue(queries === coordinator.mcpServerController.agentQueries)
            XCTAssertTrue(recovery === coordinator.agentCaptureRecoveryController)
            XCTAssertTrue(export === coordinator.agentCaptureExportController)
            XCTAssertNotNil(queries.snapshots.indexedSession(id: session.id))
        }
        XCTAssertEqual(coordinator.sessionStore.sessions.count, 12)
    }

    private func isolatedCoordinator() throws -> AppCoordinator {
        let suite = "AgentLifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppCoordinator(configuration: UserDefaultsAppConfiguration(userDefaults: defaults),
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(100)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(), suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults))
    }

    private func storageScope(_ defaults: UserDefaults) -> RuntimeStorageScope {
        RuntimeStorageScope(root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/AgentWorkspaceTests-\(UUID().uuidString)"), defaults: defaults)
    }

    func testInspectorRoundTripPreservesPreferencesAndCanonicalQueries() async throws {
        let suite = "AgentRoundTrip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.preferredWorkingView = .inspector
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        let coordinator = AppCoordinator(configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: store, certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(), suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults))
        let host = InspectorWorkspaceHost(coordinator: coordinator)
        host.openInspector()
        var inspector: ProxyViewModel? = host.loadInspector()
        weak var releasedInspector = inspector
        inspector?.sessionSearchText = "synthetic"
        inspector?.isSessionSortAscending = true
        inspector?.primaryPaneMode = .bookmarks
        inspector?.sessionFindQuery = "retained query"
        let bookmarkID = UUID()
        inspector?.selectedBookmarkID = bookmarkID
        let missingID = UUID()
        inspector?.selectedSessionID = missingID
        let queries = coordinator.mcpServerController.agentQueries
        XCTAssertFalse(host.returnToAgent(presentationBlocked: true))
        XCTAssertTrue(coordinator.isInspectorViewModelConstructed)
        XCTAssertNotNil(host.transitionFailure)
        XCTAssertTrue(host.returnToAgent())
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertTrue(host.isAgentRequested)
        coordinator.compactModeController.enterAgentPresentation()
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)
        inspector = nil
        await Task.yield()
        XCTAssertNil(releasedInspector, "Returning to Agent must release the old presentation graph")
        host.openInspector()
        let restored = host.loadInspector()
        XCTAssertEqual(restored.sessionSearchText, "synthetic")
        XCTAssertTrue(restored.isSessionSortAscending)
        XCTAssertEqual(restored.primaryPaneMode, .bookmarks)
        XCTAssertEqual(restored.selectedBookmarkID, bookmarkID)
        XCTAssertEqual(restored.sessionFindQuery, "retained query")
        XCTAssertEqual(restored.selectedSessionID, missingID)
        XCTAssertNil(restored.selectedSession)
        XCTAssertTrue(queries === coordinator.mcpServerController.agentQueries)
        XCTAssertTrue(host.returnToAgent())
    }

    func testCoordinatorDefersInspectorConstructionUntilExplicitAccess() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let coordinator = AppCoordinator(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults)
        )

        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        _ = coordinator.viewModel
        XCTAssertTrue(coordinator.isInspectorViewModelConstructed)
    }

    func testStartupRuleLoadingDoesNotConstructInspector() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let coordinator = AppCoordinator(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults)
        )

        await coordinator.loadInitialResponseOverrides()

        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
    }

    func testAgentLaunchPreferenceKeepsInspectorDeferred() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.launchWorkspacePreference = .agent
        let coordinator = AppCoordinator(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults)
        )

        XCTAssertTrue(coordinator.compactModeController.isCompactModeActive)
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertFalse(coordinator.isMediaInspectionIndexConstructed)
    }

    func testAgentWorkspaceHostConstructsInspectorOnlyAfterExplicitOpen() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.launchWorkspacePreference = .agent
        let coordinator = AppCoordinator(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults)
        )
        let host = InspectorWorkspaceHost(coordinator: coordinator)

        XCTAssertFalse(host.isInspectorRequested)
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertFalse(coordinator.isMediaInspectionIndexConstructed)

        host.openInspector()

        XCTAssertTrue(host.isInspectorRequested)
        XCTAssertTrue(coordinator.isInspectorViewModelConstructed)
        XCTAssertFalse(coordinator.isMediaInspectionIndexConstructed)
    }

    func testMediaInspectionIndexIsDeferredUntilInspectorMediaRouteRequestsIt() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppCoordinator(
            configuration: UserDefaultsAppConfiguration(userDefaults: defaults),
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true,
            recoveryStorageAccessEnabled: false, storageScope: storageScope(defaults)
        )

        XCTAssertFalse(coordinator.isMediaInspectionIndexConstructed)
        _ = coordinator.mediaInspectionIndex
        XCTAssertTrue(coordinator.isMediaInspectionIndexConstructed)
    }
}
