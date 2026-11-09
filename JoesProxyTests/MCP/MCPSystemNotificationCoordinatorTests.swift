import XCTest
@testable import JoesProxy

@MainActor
final class MCPSystemNotificationCoordinatorTests: XCTestCase {
    func testEnablingRequestsAuthorizationAndPersistsIntent() async {
        let configuration = makeConfiguration()
        let center = FakeMCPSystemNotificationCenter(status: .notDetermined, requestResult: true)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )

        await coordinator.setEnabled(true)

        XCTAssertTrue(center.didRequestAuthorization)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(configuration.mcpSystemNotificationsEnabled)
        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
    }

    func testDeniedAuthorizationRevertsPreference() async {
        let configuration = makeConfiguration()
        let center = FakeMCPSystemNotificationCenter(status: .denied)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )

        await coordinator.setEnabled(true)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(configuration.mcpSystemNotificationsEnabled)
        XCTAssertEqual(coordinator.authorizationStatus, .denied)
    }

    func testNotificationPreferencePersistsAndResetsToOff() {
        let defaults = UserDefaults(suiteName: "MCPSystemNotificationPersistenceTests-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.mcpSystemNotificationsEnabled = true

        XCTAssertTrue(UserDefaultsAppConfiguration(userDefaults: defaults).mcpSystemNotificationsEnabled)

        configuration.resetToDefaults()
        XCTAssertFalse(configuration.mcpSystemNotificationsEnabled)
    }

    func testResetDefaultsSynchronizesCoordinatorAndClearsNotifications() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )
        await coordinator.refreshAuthorizationStatus()
        coordinator.handleAuthenticationBlocked(reason: "authorization_missing", credentialFingerprint: nil)
        await Task.yield()

        configuration.resetToDefaults()
        await Task.yield()

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(center.removedDeliveredIdentifiers.isEmpty)
    }

    func testForegroundSuppressesDelivery() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { true }
        )
        await coordinator.refreshAuthorizationStatus()

        coordinator.handleAuthenticationBlocked(reason: "authorization_invalid", credentialFingerprint: "private")
        await Task.yield()

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testAuthenticationFailuresAreAnonymousAndGrouped() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        var date = Date(timeIntervalSince1970: 100)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            now: { date },
            isAppActive: { false }
        )
        await coordinator.refreshAuthorizationStatus()

        coordinator.handleAuthenticationBlocked(reason: "authorization_invalid", credentialFingerprint: "secret-fingerprint")
        coordinator.handleAuthenticationBlocked(reason: "authorization_invalid", credentialFingerprint: "secret-fingerprint")
        await Task.yield()

        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(Set(center.requests.map(\.identifier)).count, 1)
        XCTAssertTrue(center.requests.last?.body.contains("2 times") == true)
        XCTAssertFalse(center.requests.last?.body.contains("secret-fingerprint") == true)
        XCTAssertFalse(center.requests.last?.body.contains("authorization_invalid") == true)

        date.addTimeInterval(61)
        coordinator.handleAuthenticationBlocked(reason: "authorization_invalid", credentialFingerprint: "secret-fingerprint")
        await Task.yield()
        XCTAssertFalse(center.requests.last?.body.contains("2 times") == true)
    }

    func testApprovalRequestsDeduplicateAndResolvedSummaryIsRemoved() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )
        await coordinator.refreshAuthorizationStatus()
        let client = makeClient()
        let request = makeApproval(clientID: client.id)

        coordinator.handlePendingApprovals([request], clients: [client])
        coordinator.handlePendingApprovals([request], clients: [client])
        await Task.yield()

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests[0].route, .approvals)
        XCTAssertTrue(center.requests[0].body.contains(client.displayName))
        XCTAssertFalse(center.requests[0].body.contains(request.argumentDigest))

        let secondRequest = MCPApprovalRequest(
            requestID: "second-approval-id",
            clientID: client.id,
            argumentDigest: "second-private-digest",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: Date().addingTimeInterval(600),
            reason: "Another sensitive operation",
            capability: .changeThrottle
        )
        coordinator.handlePendingApprovals([request, secondRequest], clients: [client])
        coordinator.handlePendingApprovals([request], clients: [client])
        await Task.yield()
        XCTAssertEqual(center.requests.count, 3)
        XCTAssertTrue(center.requests[1].body.contains("2 MCP operations"))
        XCTAssertTrue(center.requests[2].body.contains(client.displayName))

        coordinator.handlePendingApprovals([], clients: [client])
        XCTAssertEqual(center.removedDeliveredIdentifiers, [center.requests[0].identifier])
        XCTAssertEqual(center.removedPendingIdentifiers, [center.requests[0].identifier])
    }

    func testPolicyBlockNamesEnrolledClientWithoutRequestDetails() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )
        await coordinator.refreshAuthorizationStatus()
        let client = makeClient()

        coordinator.handlePolicyBlocked(client: client, capability: .changeThrottle)
        await Task.yield()

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests[0].route, .clients)
        XCTAssertTrue(center.requests[0].body.contains(client.displayName))
        XCTAssertFalse(center.requests[0].body.contains(client.id))
        XCTAssertFalse(center.requests[0].body.contains(MCPCapabilityID.changeThrottle.rawValue))
    }

    func testNotificationRoutesUseExistingPresentationDestinations() {
        let configuration = makeConfiguration()
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )
        var routes: [MCPSystemNotificationRoute] = []
        coordinator.start { routes.append($0) }

        coordinator.handleRouteForTesting(.approvals)
        coordinator.handleRouteForTesting(.clients)

        XCTAssertEqual(routes, [.approvals, .clients])
    }

    func testDisablingClearsDeliveredAndPendingNotifications() async {
        let configuration = makeConfiguration(enabled: true)
        let center = FakeMCPSystemNotificationCenter(status: .authorized)
        let coordinator = MCPSystemNotificationCoordinator(
            configuration: configuration,
            centerClient: center,
            isAppActive: { false }
        )
        await coordinator.refreshAuthorizationStatus()
        coordinator.handleAuthenticationBlocked(reason: "authorization_missing", credentialFingerprint: nil)
        await Task.yield()

        await coordinator.setEnabled(false)

        XCTAssertFalse(configuration.mcpSystemNotificationsEnabled)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(center.removedDeliveredIdentifiers, center.removedPendingIdentifiers)
        XCTAssertFalse(center.removedDeliveredIdentifiers.isEmpty)
    }

    private func makeConfiguration(enabled: Bool = false) -> UserDefaultsAppConfiguration {
        let defaults = UserDefaults(suiteName: "MCPSystemNotificationCoordinatorTests-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.mcpSystemNotificationsEnabled = enabled
        return configuration
    }

    private func makeClient() -> MCPClientRecord {
        MCPClientRecord(
            id: "client-internal-id",
            displayName: "Codex CLI",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
    }

    private func makeApproval(clientID: String) -> MCPApprovalRequest {
        MCPApprovalRequest(
            requestID: "approval-id",
            clientID: clientID,
            argumentDigest: "private-argument-digest",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: Date().addingTimeInterval(600),
            reason: "Sensitive operation",
            capability: .bodyRead
        )
    }
}

@MainActor
private final class FakeMCPSystemNotificationCenter: MCPSystemNotificationCenterClient {
    var status: MCPSystemNotificationAuthorizationStatus
    var requestResult: Bool
    var didRequestAuthorization = false
    var requests: [MCPSystemNotificationRequest] = []
    var removedPendingIdentifiers: [String] = []
    var removedDeliveredIdentifiers: [String] = []

    init(
        status: MCPSystemNotificationAuthorizationStatus,
        requestResult: Bool = false
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() async -> MCPSystemNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        didRequestAuthorization = true
        status = requestResult ? .authorized : .denied
        return requestResult
    }

    func add(_ request: MCPSystemNotificationRequest) async throws {
        requests.append(request)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }
}
