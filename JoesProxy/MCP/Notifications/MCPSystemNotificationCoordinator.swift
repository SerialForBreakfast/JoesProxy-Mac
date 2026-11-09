import AppKit
import Combine
import Foundation
import UserNotifications

enum MCPSystemNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct MCPSystemNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let route: MCPSystemNotificationRoute
}

enum MCPSystemNotificationRoute: String, Equatable, Sendable, Codable {
    case approvals
    case clients
    case agentRuns
}

enum MCPOperatorAttention: Equatable, Sendable, Codable {
    case policyBlocked(capability: MCPCapabilityID)
}

@MainActor
protocol MCPSystemNotificationCenterClient: AnyObject {
    func authorizationStatus() async -> MCPSystemNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: MCPSystemNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class UNMCPSystemNotificationCenterClient: MCPSystemNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> MCPSystemNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func add(_ request: MCPSystemNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.userInfo = [MCPSystemNotificationCoordinator.routeUserInfoKey: request.route.rawValue]
        content.threadIdentifier = request.route.rawValue
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Delivers privacy-bounded local notifications for operator-actionable MCP events.
///
/// Concurrency: main actor only. MCP stores, application activity, presentation routing, and
/// `UNUserNotificationCenterDelegate` callbacks all converge on the app's main actor.
@MainActor
final class MCPSystemNotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let routeUserInfoKey = "mcpNotificationRoute"

    private enum Identifier {
        static let approvals = "mcp.approvals"
        static let authenticationPrefix = "mcp.authentication."
        static let policyPrefix = "mcp.policy."
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorizationStatus: MCPSystemNotificationAuthorizationStatus = .notDetermined

    private let configuration: AppConfiguration
    private let centerClient: any MCPSystemNotificationCenterClient
    private let now: () -> Date
    private let isAppActive: () -> Bool
    private var routeHandler: ((MCPSystemNotificationRoute) -> Void)?
    private var configurationObservation: AnyCancellable?
    private var seenApprovalRequestIDs: Set<String> = []
    private var blockedEventWindows: [String: (startedAt: Date, count: Int)] = [:]
    private var blockedNotificationIdentifierOrder: [String] = []

    private static let blockedEventWindow: TimeInterval = 60
    private static let maxRetainedBlockedNotificationIdentifiers = 256

    init(
        configuration: AppConfiguration,
        centerClient: (any MCPSystemNotificationCenterClient)? = nil,
        now: @escaping () -> Date = Date.init,
        isAppActive: (() -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.centerClient = centerClient ?? UNMCPSystemNotificationCenterClient()
        self.now = now
        self.isAppActive = isAppActive ?? { NSApp?.isActive == true }
        self.isEnabled = configuration.mcpSystemNotificationsEnabled
        super.init()
        configurationObservation = configuration.didChangePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let configuredValue = self.configuration.mcpSystemNotificationsEnabled
                if self.isEnabled, !configuredValue {
                    self.clearAllNotifications()
                }
                self.isEnabled = configuredValue
            }
    }

    var authorizationStatusDescription: String {
        switch authorizationStatus {
        case .notDetermined:
            return isEnabled ? "Permission has not been requested." : "Off"
        case .denied:
            return isEnabled
                ? "Enabled in JoesProxy, but blocked in System Settings."
                : "Permission is blocked in System Settings."
        case .authorized:
            return isEnabled ? "On — silent notifications" : "Off"
        }
    }

    func start(routeHandler: @escaping (MCPSystemNotificationRoute) -> Void) {
        self.routeHandler = routeHandler
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await centerClient.authorizationStatus()
    }

    func setEnabled(_ enabled: Bool) async {
        if !enabled {
            configuration.mcpSystemNotificationsEnabled = false
            isEnabled = false
            clearAllNotifications()
            await refreshAuthorizationStatus()
            return
        }

        let currentStatus = await centerClient.authorizationStatus()
        authorizationStatus = currentStatus
        let granted: Bool
        switch currentStatus {
        case .authorized:
            granted = true
        case .denied:
            granted = false
        case .notDetermined:
            granted = (try? await centerClient.requestAuthorization()) == true
            authorizationStatus = await centerClient.authorizationStatus()
        }
        guard granted else {
            configuration.mcpSystemNotificationsEnabled = false
            isEnabled = false
            return
        }
        configuration.mcpSystemNotificationsEnabled = true
        isEnabled = true
    }

    func handlePendingApprovals(_ requests: [MCPApprovalRequest], clients: [MCPClientRecord]) {
        let currentIDs = Set(requests.map(\.requestID))
        let didChange = currentIDs != seenApprovalRequestIDs
        let newIDs = currentIDs.subtracting(seenApprovalRequestIDs)
        seenApprovalRequestIDs = currentIDs

        guard !requests.isEmpty else {
            removeNotification(identifier: Identifier.approvals)
            return
        }
        guard didChange else { return }

        let newest = requests.first { newIDs.contains($0.requestID) } ?? requests[0]
        let clientName = clients.first(where: { $0.id == newest.clientID })?.displayName ?? "An enrolled MCP client"
        let body: String
        if requests.count == 1 {
            body = "\(clientName) is waiting to \(newest.capability.notificationActionDescription)."
        } else {
            body = "\(requests.count) MCP operations are waiting for review."
        }
        post(
            MCPSystemNotificationRequest(
                identifier: Identifier.approvals,
                title: requests.count == 1 ? "MCP approval needed" : "MCP approvals needed",
                body: body,
                route: .approvals
            )
        )
    }

    func handleAuthenticationBlocked(reason: String, credentialFingerprint: String?) {
        let internalIdentity = "\(reason)|\(credentialFingerprint ?? "none")"
        let identifier = Identifier.authenticationPrefix + stableIdentifier(internalIdentity)
        let count = recordBlockedEvent(identity: identifier)
        post(
            MCPSystemNotificationRequest(
                identifier: identifier,
                title: "MCP connection blocked",
                body: count == 1
                    ? "An MCP client could not authenticate with JoesProxy."
                    : "An MCP client was blocked \(count) times while trying to authenticate.",
                route: .clients
            )
        )
    }

    func handlePolicyBlocked(client: MCPClientRecord, capability: MCPCapabilityID) {
        let identifier = Identifier.policyPrefix + stableIdentifier("\(client.id)|\(capability.rawValue)")
        let count = recordBlockedEvent(identity: identifier)
        post(
            MCPSystemNotificationRequest(
                identifier: identifier,
                title: "MCP access blocked",
                body: count == 1
                    ? "\(client.displayName) was blocked from trying to \(capability.notificationActionDescription)."
                    : "\(client.displayName) was blocked \(count) times from trying to \(capability.notificationActionDescription).",
                route: .clients
            )
        )
    }

    /// Opens Agent Runs when a diagnostic run needs cleanup or human attention (AN-6).
    func handleDiagnosticRunAttention(runID: DiagnosticRunID, status: DiagnosticRunStatus) {
        let identifier = "diagnostic-run-\(runID.rawValue.uuidString)"
        post(
            MCPSystemNotificationRequest(
                identifier: identifier,
                title: "Diagnostic run needs attention",
                body: "Run \(runID.rawValue.uuidString.prefix(8))… is \(status.rawValue).",
                route: .agentRuns
            )
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let rawRoute = response.notification.request.content.userInfo[Self.routeUserInfoKey] as? String,
              let route = MCPSystemNotificationRoute(rawValue: rawRoute) else { return }
        routeHandler?(route)
    }

    func handleRouteForTesting(_ route: MCPSystemNotificationRoute) {
        routeHandler?(route)
    }

    private func post(_ request: MCPSystemNotificationRequest) {
        guard isEnabled, authorizationStatus == .authorized, !isAppActive() else { return }
        Task { try? await centerClient.add(request) }
    }

    private func recordBlockedEvent(identity: String) -> Int {
        let eventDate = now()
        blockedEventWindows = blockedEventWindows.filter {
            eventDate.timeIntervalSince($0.value.startedAt) < Self.blockedEventWindow
        }
        if let existing = blockedEventWindows[identity],
           eventDate.timeIntervalSince(existing.startedAt) < Self.blockedEventWindow {
            let nextCount = existing.count + 1
            blockedEventWindows[identity] = (existing.startedAt, nextCount)
            return nextCount
        }
        if !blockedNotificationIdentifierOrder.contains(identity) {
            blockedNotificationIdentifierOrder.append(identity)
            if blockedNotificationIdentifierOrder.count > Self.maxRetainedBlockedNotificationIdentifiers {
                let evictedIdentifier = blockedNotificationIdentifierOrder.removeFirst()
                removeNotification(identifier: evictedIdentifier)
            }
        }
        blockedEventWindows[identity] = (eventDate, 1)
        return 1
    }

    private func stableIdentifier(_ value: String) -> String {
        String(value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }, radix: 16)
    }

    private func removeNotification(identifier: String) {
        centerClient.removePendingRequests(withIdentifiers: [identifier])
        centerClient.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func clearAllNotifications() {
        let identifiers = [Identifier.approvals]
            + blockedNotificationIdentifierOrder
        centerClient.removePendingRequests(withIdentifiers: identifiers)
        centerClient.removeDeliveredNotifications(withIdentifiers: identifiers)
        blockedEventWindows.removeAll()
        blockedNotificationIdentifierOrder.removeAll()
        seenApprovalRequestIDs.removeAll()
    }
}

private extension MCPCapabilityID {
    var notificationActionDescription: String {
        switch riskTier {
        case .passiveResource:
            return "access MCP status"
        case .readOnlyTool:
            return "inspect captured data"
        case .sensitiveReadTool:
            return "read sensitive captured data"
        case .expensiveInspection:
            return "run media inspection"
        case .mutatingTool:
            return "change proxy behavior"
        case .openWorldTool:
            return "make an external network request"
        case .destructiveTool:
            return "perform destructive cleanup"
        }
    }
}
