import Foundation

/// Explicit, disposable B/C experiment. Never selected by normal launch or persisted preferences.
struct AgentWorkspaceProfileConfiguration: Equatable {
    let root: URL
    let runID: UUID
    let proxyPort: UInt16
    let pilot: Bool

    init?(arguments: [String], environment: [String: String]) {
        guard arguments.contains("--agent-workspace-profile"),
              arguments.contains("--ui-test-suppress-launch-recovery"),
              let rawRoot = environment["JOESPROXY_AGW_ROOT"], rawRoot.hasPrefix("/"),
              rawRoot.contains("/build/HostTestResults/"), !rawRoot.contains(".."),
              let rawID = environment["JOESPROXY_PROFILE_METRICS_TOKEN"], let id = UUID(uuidString: rawID),
              let rawPort = arguments.first(where: { $0.hasPrefix("--ui-test-proxy-port=") }),
              let port = UInt16(rawPort.dropFirst("--ui-test-proxy-port=".count)), port > 0,
              let mode = environment["JOESPROXY_AGW_PROTOCOL"], ["pilot", "full"].contains(mode)
        else { return nil }
        root = URL(fileURLWithPath: rawRoot).appendingPathComponent(id.uuidString, isDirectory: true)
        runID = id
        proxyPort = port
        pilot = mode == "pilot"
    }

    var durations: [Int] { pilot ? [10, 10, 10, 15, 10] : [60, 120, 120, 180, 120] }
    static let phases = ["warmup", "empty-idle", "retained-observation", "traffic-query", "drain"]
    static let body = Data(repeating: 42, count: 32 * 1024)
    static let seedCount = 10_000
}

struct AgentWorkspaceProfileSnapshot: Codable, Sendable {
    var phase = "starting"
    var retainedSessions = 0
    var retainedBodyBytes = 0
    var pendingCaptures = 0
    var reservedCaptureBytes = 0
    var activeChannels = 0
    var rejectedCaptures = 0
    var queryCount = 0
    var lastQueryNanoseconds: UInt64 = 0
    var queryPassed = false
    var captureAccountingAvailable = false
    var publishedUptime: Double = 0
    var failure: String?
}

/// One bounded snapshot, shared between the main-actor workload and independent safety sampler.
final class AgentWorkspaceProfileMetrics: @unchecked Sendable {
    static let shared = AgentWorkspaceProfileMetrics()
    private let lock = NSLock()
    private var value: AgentWorkspaceProfileSnapshot?
    func update(_ value: AgentWorkspaceProfileSnapshot) { lock.withLock { self.value = value } }
    func snapshot() -> AgentWorkspaceProfileSnapshot? { lock.withLock { value } }
}

/// Both products use the same construction, work and persistence scope. Queries use the actual
/// MCP query owners, not an Inspector projection. This measures service latency, not MCP transport.
@MainActor
final class AgentWorkspaceProfile {
    let coordinator: AppCoordinator
    let configuration: AgentWorkspaceProfileConfiguration
    private var worker: Task<Void, Never>?
    private var snapshot = AgentWorkspaceProfileSnapshot()

    init(configuration: AgentWorkspaceProfileConfiguration) {
        self.configuration = configuration
        let defaults = UserDefaults(suiteName: "com.ShowBlender.JoesProxy.AGW.\(configuration.runID.uuidString)")!
        let settings = UserDefaultsAppConfiguration(userDefaults: defaults)
        settings.proxyPort = configuration.proxyPort
        settings.rollingCaptureAutoSaveEnabled = false
        settings.sdkEventServerEnabled = false
        settings.captureRetentionPolicy = .keepLastSessions(12_000)
        coordinator = AppCoordinator(configuration: settings,
            sessionStore: InMemorySessionStore(retentionPolicy: settings.captureRetentionPolicy),
            certificateStore: UITestCertificateStore(identity: nil),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            mcpCredentialStore: MCPInMemoryCredentialStore(),
            suppressesLaunchRecoveryOffers: true, recoveryStorageAccessEnabled: false,
            storageScope: RuntimeStorageScope(root: configuration.root, defaults: defaults))
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            for (index, phase) in AgentWorkspaceProfileConfiguration.phases.enumerated() {
                if phase == "retained-observation" { seed() }
                if phase == "traffic-query" {
                    await coordinator.proxyRuntime.start()
                    guard case .running = coordinator.proxyRuntime.currentState else {
                        throw ProfileFailure.proxyStart
                    }
                }
                snapshot.phase = phase
                for _ in 0..<configuration.durations[index] {
                    try Task.checkCancellation()
                    if phase == "traffic-query" { try query() }
                    publish()
                    try await Task.sleep(for: .seconds(1))
                }
            }
            await coordinator.proxyRuntime.stop()
            await coordinator.sessionRecorder.waitForPendingStoreFlush()
            publish()
            guard snapshot.pendingCaptures == 0, snapshot.reservedCaptureBytes == 0,
                  snapshot.activeChannels == 0, snapshot.rejectedCaptures == 0,
                  snapshot.queryPassed else { throw ProfileFailure.drain }
            snapshot.phase = "complete"
            publish()
        } catch {
            await coordinator.proxyRuntime.stop()
            snapshot.phase = "failed"
            snapshot.failure = String(describing: error)
            publish()
        }
    }

    func seed() {
        let records = (0..<AgentWorkspaceProfileConfiguration.seedCount).map { index in
            SessionRecord(
                request: CapturedRequest(method: "GET", scheme: .http, host: "example.test", port: 80,
                    path: "/agw/\(index)", headers: [], bodyData: nil, bodySize: nil),
                response: CapturedResponse(statusCode: 200, headers: [],
                    bodyData: Data("AGW synthetic seed".utf8), bodySize: 18),
                state: .completed,
                timing: SessionTiming(startedAt: Date(timeIntervalSince1970: Double(index))))
        }
        coordinator.sessionStore.update(records)
    }

    func query() throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let queries = coordinator.mcpServerController.agentQueries.snapshots
        let page = try queries.page(request: .init(limit: 10, cursor: nil, queryDigest: "agw-v2",
            orderingDigest: "capture", filter: nil), clientID: "agw-synthetic", policyRevision: .initial)
        guard page.items.count == 10,
              let record = queries.recentSessions(limit: 10).first(where: { $0.record.response != nil }),
              let indexed = queries.indexedSession(id: record.record.id),
              indexed.record.response?.bodyData == (indexed.record.request.path.hasPrefix("/agw/")
                ? Data("AGW synthetic seed".utf8) : AgentWorkspaceProfileConfiguration.body)
        else { throw ProfileFailure.query }
        snapshot.lastQueryNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        snapshot.queryCount += 1
        snapshot.queryPassed = true
    }

    private func publish() {
        let transport = coordinator.captureTransportDiagnostics.snapshot()
        snapshot.retainedSessions = coordinator.sessionStore.sessions.count
        snapshot.retainedBodyBytes = coordinator.sessionStore.retainedBodyBytes
        snapshot.pendingCaptures = transport.captureAdmission?.pendingCaptures ?? 0
        snapshot.reservedCaptureBytes = transport.captureAdmission?.reservedBytes ?? 0
        snapshot.rejectedCaptures = transport.captureAdmission?.rejectedCaptures ?? 0
        snapshot.activeChannels = transport.activeProxyChannels
        snapshot.captureAccountingAvailable = transport.captureAdmission != nil
        snapshot.publishedUptime = ProcessInfo.processInfo.systemUptime
        AgentWorkspaceProfileMetrics.shared.update(snapshot)
    }

    private enum ProfileFailure: Error { case proxyStart, query, drain }
}
