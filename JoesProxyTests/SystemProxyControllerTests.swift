import XCTest
@testable import JoesProxy

@MainActor
final class SystemProxyControllerTests: XCTestCase {

    func testStrictEnableUsesStaticProxyAndPersistsSnapshot() async {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        let pac = StubPACHosting()
        let controller = SystemProxyController(manager: manager, stateStore: store, pacServer: pac, host: "127.0.0.1")

        await controller.enable(port: 9090, mode: .strictStatic)

        XCTAssertEqual(controller.status, .active(host: "127.0.0.1", port: 9090, service: "Wi-Fi"))
        XCTAssertEqual(store.pendingSnapshot, prior)
        XCTAssertEqual(manager.enableCalls.count, 1)
        XCTAssertEqual(manager.enableCalls.first?.port, 9090)
        XCTAssertTrue(manager.pacEnableCalls.isEmpty)
        XCTAssertEqual(pac.startCount, 0)
    }

    func testPACEnableStartsServerAndCallsEnablePAC() async {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        let pac = StubPACHosting(pacURL: "http://127.0.0.1:55555/joesproxy.pac")
        let controller = SystemProxyController(manager: manager, stateStore: store, pacServer: pac, host: "127.0.0.1")

        await controller.enable(port: 9090, mode: .pacFailOpen)

        XCTAssertEqual(controller.status, .active(host: "127.0.0.1", port: 9090, service: "Wi-Fi"))
        XCTAssertEqual(store.pendingSnapshot, prior)
        XCTAssertEqual(pac.startCount, 1)
        XCTAssertEqual(pac.lastProxyPort, 9090)
        XCTAssertEqual(manager.pacEnableCalls, ["http://127.0.0.1:55555/joesproxy.pac"])
        XCTAssertTrue(manager.enableCalls.isEmpty)
    }

    func testDisableRestoresAndClears() async {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        store.pendingSnapshot = prior
        let controller = SystemProxyController(manager: manager, stateStore: store)

        await controller.disable()

        XCTAssertEqual(controller.status, .inactive)
        XCTAssertNil(store.pendingSnapshot)
        XCTAssertEqual(manager.restoreCalls, [prior])
    }

    func testDisableWithoutSnapshotIsNoOp() async {
        let manager = StubSystemProxyManager(snapshot: Self.priorSnapshot)
        let store = InMemorySystemProxyStateStore()
        let controller = SystemProxyController(manager: manager, stateStore: store)

        await controller.disable()

        XCTAssertEqual(controller.status, .inactive)
        XCTAssertTrue(manager.restoreCalls.isEmpty)
    }

    func testEnableFailureBeforePersistLeavesNoSnapshot() async {
        let manager = StubSystemProxyManager(snapshot: Self.priorSnapshot)
        manager.serviceError = StubError.message("no service")
        let store = InMemorySystemProxyStateStore()
        let controller = SystemProxyController(manager: manager, stateStore: store, pacServer: StubPACHosting())

        await controller.enable(port: 9090, mode: .strictStatic)

        if case .failed(let message) = controller.status {
            XCTAssertTrue(message.contains("no service"))
        } else {
            XCTFail("Expected failed status, got \(controller.status)")
        }
        XCTAssertNil(store.pendingSnapshot)
        XCTAssertTrue(manager.enableCalls.isEmpty)
    }

    func testCleanUpForQuitRestoresSynchronouslyAndClears() {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        store.pendingSnapshot = prior
        let controller = SystemProxyController(manager: manager, stateStore: store)

        controller.cleanUpForQuit()

        XCTAssertEqual(manager.synchronousRestoreCalls, [prior])
        XCTAssertNil(store.pendingSnapshot)
        XCTAssertEqual(controller.status, .inactive)
    }

    func testCleanUpForQuitIsNoOpWithoutSnapshot() {
        let manager = StubSystemProxyManager(snapshot: Self.priorSnapshot)
        let store = InMemorySystemProxyStateStore()
        let controller = SystemProxyController(manager: manager, stateStore: store)

        controller.cleanUpForQuit()

        XCTAssertTrue(manager.synchronousRestoreCalls.isEmpty)
    }

    func testRecoverIfNeededSurfacesPendingSnapshot() {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        store.pendingSnapshot = prior
        let controller = SystemProxyController(manager: manager, stateStore: store)

        controller.recoverIfNeeded()

        XCTAssertEqual(controller.pendingRecovery, prior)
    }

    func testConfirmRecoveryRestoresAndClears() async {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        store.pendingSnapshot = prior
        let controller = SystemProxyController(manager: manager, stateStore: store)
        controller.recoverIfNeeded()

        await controller.confirmRecovery()

        XCTAssertNil(controller.pendingRecovery)
        XCTAssertNil(store.pendingSnapshot)
        XCTAssertEqual(manager.restoreCalls, [prior])
    }

    func testDismissRecoveryClearsWithoutRestoring() {
        let prior = Self.priorSnapshot
        let manager = StubSystemProxyManager(snapshot: prior)
        let store = InMemorySystemProxyStateStore()
        store.pendingSnapshot = prior
        let controller = SystemProxyController(manager: manager, stateStore: store)
        controller.recoverIfNeeded()

        controller.dismissRecovery()

        XCTAssertNil(controller.pendingRecovery)
        XCTAssertNil(store.pendingSnapshot)
        XCTAssertTrue(manager.restoreCalls.isEmpty)
    }

    private static let priorSnapshot = SystemProxySnapshot(
        serviceName: "Wi-Fi",
        httpEnabled: false, httpHost: "", httpPort: 0,
        httpsEnabled: false, httpsHost: "", httpsPort: 0
    )
}

private final class StubSystemProxyManager: SystemProxyManaging, @unchecked Sendable {
    private let snapshot: SystemProxySnapshot
    var serviceName = "Wi-Fi"
    var serviceError: Error?
    var enableError: Error?
    var restoreError: Error?

    private(set) var enableCalls: [(host: String, port: UInt16, service: String)] = []
    private(set) var restoreCalls: [SystemProxySnapshot] = []

    init(snapshot: SystemProxySnapshot) {
        self.snapshot = snapshot
    }

    func activePrimaryServiceName() async throws -> String {
        if let serviceError { throw serviceError }
        return serviceName
    }

    func readSnapshot(serviceName: String) async throws -> SystemProxySnapshot {
        snapshot
    }

    private(set) var pacEnableCalls: [String] = []
    func enableProxy(host: String, port: UInt16, serviceName: String) async throws {
        if let enableError { throw enableError }
        enableCalls.append((host, port, serviceName))
    }

    func enablePAC(pacURL: String, serviceName: String) async throws {
        if let enableError { throw enableError }
        pacEnableCalls.append(pacURL)
    }

    func restore(_ snapshot: SystemProxySnapshot) async throws {
        if let restoreError { throw restoreError }
        restoreCalls.append(snapshot)
    }

    private(set) var synchronousRestoreCalls: [SystemProxySnapshot] = []
    func restoreSynchronously(_ snapshot: SystemProxySnapshot) {
        synchronousRestoreCalls.append(snapshot)
    }
}

private final class InMemorySystemProxyStateStore: SystemProxyStateStore, @unchecked Sendable {
    var pendingSnapshot: SystemProxySnapshot?
}

private final class StubPACHosting: PACHosting, @unchecked Sendable {
    private let pacURL: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastProxyPort: UInt16?

    init(pacURL: String = "http://127.0.0.1:0/joesproxy.pac") {
        self.pacURL = pacURL
    }

    func start(proxyPort: UInt16) async throws -> String {
        startCount += 1
        lastProxyPort = proxyPort
        return pacURL
    }

    func stop() async {
        stopCount += 1
    }
}

private enum StubError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
