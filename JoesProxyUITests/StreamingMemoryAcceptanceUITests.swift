import AppKit
import Darwin
import Network
import XCTest

private enum SoakCandidate: String {
    case baselineA = "A"
    case agentB = "B"
    case prototypeC = "C"
    case inspectorControl = "unattributed"

    init?(environment: [String: String]) throws {
        guard let rawValue = environment["JOESPROXY_STREAMING_CANDIDATE"] else {
            return nil
        }
        guard let candidate = Self(rawValue: rawValue), candidate != .inspectorControl else {
            throw SoakFailure.invalidCandidate
        }
        self = candidate
    }

    var bundleIdentifier: String {
        switch self {
        case .baselineA, .agentB, .inspectorControl: "com.ShowBlender.JoesProxy"
        case .prototypeC: "com.ShowBlender.JoesProxy.AgentPrototype"
        }
    }

    var productName: String {
        switch self {
        case .baselineA, .agentB, .inspectorControl: "JoesProxy"
        case .prototypeC: "JoesProxyAgentPrototype"
        }
    }

    var receiptName: String { rawValue }
    var usesAgentWorkspace: Bool { self == .agentB || self == .prototypeC }
    var monitoringMode: String { usesAgentWorkspace ? "Agent" : "Compact" }

    /// Legacy profiling invocations have no candidate identity. They remain valid diagnostics,
    /// but their samples must never be compared as an A/B/C experiment.
}

private struct SoakWorkloadDigest {
    let value: String?
    let availability: String

    init(environment: [String: String]) throws {
        guard let rawValue = environment["JOESPROXY_STREAMING_WORKLOAD_DIGEST"] else {
            value = nil
            availability = "unavailable"
            return
        }
        guard rawValue.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw SoakFailure.invalidWorkloadDigest
        }
        value = rawValue
        availability = "available"
    }
}

private struct SoakFixture {
    let body: Data

    static let agentWorkspaceV1 = SoakFixture(body: Data("AGW1 synthetic response body v1\n".utf8))
    static let legacy = SoakFixture(body: Data(repeating: 42, count: 256 * 1024))
    static let agentWorkspaceManifestDigest = "9de3f30e084c9ab39aaaa9398e518afad72bcbbdaef65468fef15c61c71c08c2"
}

/// Opt-in host acceptance, not part of routine UI coverage. The runner owns only synthetic
/// loopback traffic; app data uses the existing isolated UI-test configuration.
@MainActor
final class StreamingMemoryAcceptanceUITests: XCTestCase {
    func testBoundedStreamingAndDrainCycles() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["JOESPROXY_STREAMING_SECONDS"], let duration = Double(raw),
              (60...1800).contains(duration) else {
            throw XCTSkip("Opt in with TEST_RUNNER_JOESPROXY_STREAMING_SECONDS=60...1800 after local host approval")
        }
        continueAfterFailure = false
        let requestsPerCycle: Int?
        if let rawCount = environment["JOESPROXY_STREAMING_REQUESTS_PER_CYCLE"] {
            let count = try XCTUnwrap(Int(rawCount))
            guard (1...500).contains(count) else { throw SoakFailure.response }
            requestsPerCycle = count
        } else {
            requestsPerCycle = nil
        }
        // Fixed-count acceptance needs a workload deadline independent of observation timing.
        // XCTest still owns the absolute execution ceiling, including all quiet/drain phases.
        let fixedWorkloadSeconds: Double?
        if let rawBudget = environment["JOESPROXY_STREAMING_WORKLOAD_SECONDS_PER_CYCLE"] {
            guard requestsPerCycle != nil, let budget = Double(rawBudget),
                  budget.isFinite, (1...300).contains(budget) else {
                throw SoakFailure.invalidWorkloadBudget
            }
            fixedWorkloadSeconds = budget
        } else {
            fixedWorkloadSeconds = nil
        }
        let candidate = try SoakCandidate(environment: environment)
        let freezeFollow = environment["JOESPROXY_STREAMING_FREEZE_FOLLOW"] == "1"
        let compact = candidate == .baselineA || (candidate == nil && environment["JOESPROXY_STREAMING_COMPACT"] == "1")
        let fixedMode = environment["JOESPROXY_STREAMING_FIXED_MODE"]
        if let fixedMode { guard ["Table", "Explorer", "Timeline"].contains(fixedMode) else { throw SoakFailure.response } }
        let cycleCount = Int(environment["JOESPROXY_STREAMING_CYCLES"] ?? "3") ?? 0
        guard (3...6).contains(cycleCount), !compact || fixedMode == nil,
              compact || fixedMode != nil || cycleCount == 3 else { throw SoakFailure.response }
        let isolateTransitions = environment["JOESPROXY_STREAMING_ISOLATE_TRANSITIONS"] == "1"
        guard !isolateTransitions || (!compact && fixedMode == nil) else { throw SoakFailure.response }
        let explicitLaunchEnvironment = environment["JOESPROXY_STREAMING_EXPLICIT_LAUNCH_ENV"] == "1"
        guard !explicitLaunchEnvironment || environment["XCODE_TEST_PLAN_NAME"] == "JoesProxy-Profiling" else {
            throw SoakFailure.response
        }
        let layoutProbe = environment["JOESPROXY_STREAMING_LAYOUT_PROBE"] == "1"
        // Compact has no Follow Live control. Refuse an incomparable configuration.
        guard !compact || !freezeFollow else { throw SoakFailure.response }
        guard !layoutProbe || compact else { throw SoakFailure.response }
        guard candidate?.usesAgentWorkspace != true || fixedMode == nil else { throw SoakFailure.response }
        guard candidate != .baselineA || environment["JOESPROXY_STREAMING_COMPACT"] != "0" else {
            throw SoakFailure.response
        }
        let workloadDigest = try SoakWorkloadDigest(environment: environment)
        guard candidate == nil || workloadDigest.value == SoakFixture.agentWorkspaceManifestDigest else {
            throw SoakFailure.manifestDigestMismatch
        }
        let extendedObservation = environment["JOESPROXY_STREAMING_EXTENDED_OBSERVATION"] == "1"
        // The host wrapper persists XCTest output in the repository. Metrics collection does
        // not need direct repository filesystem access from the sandboxed UI runner.
        var samples = Data()
        defer {
            let evidence = XCTAttachment(data: samples, uniformTypeIdentifier: "public.plain-text")
            evidence.name = "Streaming app process samples.jsonl"
            evidence.lifetime = .keepAlways
            add(evidence)
        }

        let metrics = try SoakAppMetricsReceiver()
        let metricsPort = try await metrics.start()
        defer { metrics.stop() }
        let fixture = candidate == nil ? SoakFixture.legacy : .agentWorkspaceV1
        let origin = try SoakBinaryOrigin(body: fixture.body)
        let originPort = try await origin.start()
        defer { origin.stop() }
        // Reserve an OS-selected candidate until immediately before the app binds it.
        // App runtime readiness remains authoritative if another process wins the bind race.
        let reservationParameters = NWParameters.tcp
        reservationParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let reservation = try NWListener(using: reservationParameters)
        reservation.newConnectionHandler = { $0.cancel() }
        let proxyPort = try await SoakBinaryOrigin.startListener(reservation)
        reservation.cancel()
        let app = candidate.map { XCUIApplication(bundleIdentifier: $0.bundleIdentifier) } ?? XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-test-browser-mode=\((fixedMode ?? "Table").lowercased())", "--ui-test-proxy-port=\(proxyPort)", "--long-capture-diagnostics", "--agent-workspace-diagnostics"]
        if candidate != nil {
            app.launchArguments.append(contentsOf: ["--ui-test-fixture=demo-sessions", "--ui-test-session-count=10000"])
        }
        app.launchArguments.append("--ui-test-memory-guard")
        app.launchEnvironment["JOESPROXY_PROFILE_METRICS_PORT"] = String(metricsPort)
        app.launchEnvironment["JOESPROXY_PROFILE_METRICS_TOKEN"] = metrics.token
        app.launchEnvironment["JOESPROXY_AGENT_WORKSPACE_DIAGNOSTICS"] = "1"
        if explicitLaunchEnvironment { app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = "" }
        if compact { app.launchArguments.append("--compact-mode") }
        if candidate == .agentB { app.launchArguments.append("--agent-workspace") }
        app.launchJoesProxyForTesting()
        app.activate()
        if compact {
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 8))
            XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        }
        let expectedCandidate = candidate ?? (compact ? .baselineA : .inspectorControl)
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: expectedCandidate.bundleIdentifier)
            .first { $0.bundleURL?.path.contains("/Build/Products/Release/\(expectedCandidate.productName).app") == true },
            "Profile only the optimized app launched by this test")
        let pid = running.processIdentifier
        let toggle = app.identifiedElement("proxyToggleButton")
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.click()
        app.waitUntilProxyRuntimeIsRunning()

        let started = Date()
        var completed = 0
        func tileLabelFrames() throws -> [[String: Any]] {
            let hud = app.identifiedElement("compactMonitorRoot")
            let origin = hud.frame.origin
            return try ["Proxy", "Sessions", "Throughput", "Connections", "Errors", "History removed", "Duration", "Approvals"].map { label in
                let element = hud.staticTexts[label].firstMatch
                guard element.exists else { throw SoakFailure.missingTileLabel(label) }
                let frame = element.frame
                return ["label": label, "x": frame.minX - origin.x, "y": frame.minY - origin.y,
                        "width": frame.width, "height": frame.height]
            }
        }
        func sample(_ phase: String) throws {
            // AX frame queries perturb layout and CPU. Run this opt-in visual diagnostic
            // separately from performance measurements and label every resulting sample.
            let labelFrames = try (layoutProbe ? tileLabelFrames() : nil)
            if layoutProbe && (phase == "baseline" || phase.hasSuffix("-retained") || phase == "stopped") {
                let image = XCTAttachment(screenshot: app.identifiedElement("compactMonitorRoot").screenshot())
                image.name = "Compact layout \(phase)"
                image.lifetime = .keepAlways
                add(image)
            }
            var record = try metrics.latest(pid: pid)
            record["phase"] = phase
            record["elapsedSeconds"] = Date().timeIntervalSince(started)
            record["unixTimestamp"] = Date().timeIntervalSince1970
            record["compact"] = compact
            record["retainsHistoryBetweenCycles"] = compact
            record["completedRequests"] = completed
            record["deliveredBytes"] = completed * origin.bodySize
            record["freezeFollow"] = freezeFollow
            record["extendedObservation"] = extendedObservation
            record["candidate"] = expectedCandidate.receiptName
            record["candidateBundleIdentifier"] = expectedCandidate.bundleIdentifier
            record["candidateProduct"] = expectedCandidate.productName
            record["buildIdentity"] = (Bundle(url: running.bundleURL!)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unavailable"
            record["workloadDigest"] = workloadDigest.value ?? "unavailable"
            record["workloadDigestAvailability"] = workloadDigest.availability
            record["parityResult"] = candidate == nil ? "unavailable" : "delivery-passed-query-unavailable"
            record["metricsOwner"] = "isolated-app-self-sampler"
            record["memoryGuardLimitBytes"] = 1_610_612_736
            record["layoutProbe"] = layoutProbe
            record["fixedMode"] = fixedMode ?? "mixed"
            record["cycleCount"] = cycleCount
            if let fixedWorkloadSeconds { record["workloadSecondsPerCycle"] = fixedWorkloadSeconds }
            record["isolateTransitions"] = isolateTransitions
            record["explicitLaunchEnvironment"] = explicitLaunchEnvironment
            if let labelFrames { record["tileLabelFrames"] = labelFrames }
            let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            samples.append(line)
            samples.append(10)
            print("STREAMING_SAMPLE \(String(decoding: line, as: UTF8.self))")
            guard let footprint = record["physicalFootprintBytes"] as? UInt64,
                  footprint < 1_610_612_736 else { throw SoakFailure.memorySafetyLimit }
        }
        let baseline = min(30, duration / 12)
        // App readiness and the first independent timer tick need not arrive in the same order.
        for _ in 0..<50 {
            if let _ = try? metrics.latest(pid: pid) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try sample("baseline")
        try await Task.sleep(for: .seconds(baseline))
        let cycleDuration = (duration - baseline) / Double(cycleCount)
        // Fixed-view repeats separate first-use warming from residual growth without visiting
        // another investigation surface just to clear its capture. Cycle one is the warm-up.
        let modes = (compact || expectedCandidate.usesAgentWorkspace) ? Array(repeating: expectedCandidate.monitoringMode, count: cycleCount)
            : fixedMode.map { Array(repeating: $0, count: cycleCount) } ?? ["Table", "Explorer", "Timeline"]
        for (cycle, mode) in modes.enumerated() {
            if !compact && !expectedCandidate.usesAgentWorkspace { app.selectSessionBrowser(mode) }
            let cycleStartCount = completed
            let workloadSeconds = fixedWorkloadSeconds ?? cycleDuration * 0.8
            let deadline = ProcessInfo.processInfo.systemUptime + workloadSeconds
            var nextSample = Date()
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await SoakBinaryClient.request(proxyPort: proxyPort, originPort: originPort, expectedBody: fixture.body)
                completed += 1
                if freezeFollow, completed - cycleStartCount == 1 {
                    let follow = app.identifiedElement("followLiveToggle")
                    XCTAssertTrue(follow.waitForExistence(timeout: 5))
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: follow)
                    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
                    // Re-enable once after clear to pin the first visible row, rather than
                    // leaving nil selection's newest-row fallback moving with incoming traffic.
                    if follow.label == "Enable Follow Live" { follow.click() }
                    XCTAssertEqual(follow.label, "Disable Follow Live")
                    follow.click()
                    XCTAssertEqual(follow.label, "Enable Follow Live")
                    try sample("cycle\(cycle + 1)-follow-frozen")
                }
                if Date() >= nextSample {
                    try sample("cycle\(cycle + 1)-\(mode)-traffic")
                    nextSample = Date().addingTimeInterval(min(15, duration / 12))
                }
                try await Task.sleep(for: .milliseconds(200))
                if let requestsPerCycle, completed - cycleStartCount >= requestsPerCycle { break }
            }
            if let requestsPerCycle, completed - cycleStartCount != requestsPerCycle {
                try sample("cycle\(cycle + 1)-workload-incomplete")
                throw SoakFailure.incompleteWorkload(completed: completed - cycleStartCount,
                                                     expected: requestsPerCycle, budgetSeconds: workloadSeconds)
            }
            try sample("cycle\(cycle + 1)-retained")
            if compact || expectedCandidate.usesAgentWorkspace {
                // Keep the HUD mounted and retain capture history: switching to Table to clear
                // would contaminate the Compact-only frame/layout measurement.
                let quietDuration = extendedObservation ? 120 : cycleDuration * 0.2
                for interval in 1...4 {
                    try await Task.sleep(for: .seconds(quietDuration / 4))
                    try sample("cycle\(cycle + 1)-compact-retained-quiet-\(interval)")
                }
                XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
                XCTAssertFalse(app.identifiedElement("sessionTable").exists)
                continue
            }
            try await Task.sleep(for: .seconds(cycleDuration * 0.1))
            try sample("cycle\(cycle + 1)-\(fixedMode == nil ? "before-table" : "before-clear-surface")")
            if isolateTransitions { try await Task.sleep(for: .seconds(30)) }
            if fixedMode == nil { app.selectSessionBrowser("Table") }
            try sample("cycle\(cycle + 1)-\(fixedMode == nil ? "after-table" : "after-clear-surface")")
            if isolateTransitions { try await Task.sleep(for: .seconds(30)) }
            if requestsPerCycle != nil { try await Task.sleep(for: .seconds(15)) }
            try sample("cycle\(cycle + 1)-before-menu")
            app.identifiedElement("clearSessionsMenu").click()
            try sample("cycle\(cycle + 1)-menu-open")
            if extendedObservation { try await Task.sleep(for: .seconds(30)) }
            let clear = app.menuItems["Clear All"]
            try sample("cycle\(cycle + 1)-before-menu-query")
            XCTAssertTrue(clear.waitForExistence(timeout: 3))
            try sample("cycle\(cycle + 1)-after-menu-query")
            clear.click()
            let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Clear ' AND label ENDSWITH ' Sessions'")).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            try sample("cycle\(cycle + 1)-confirmation-visible")
            if extendedObservation { try await Task.sleep(for: .seconds(30)) }
            confirm.click()
            try sample("cycle\(cycle + 1)-clear-invoked")
            if extendedObservation {
                for interval in 1...4 {
                    try await Task.sleep(for: .seconds(30))
                    try sample("cycle\(cycle + 1)-drain-\(interval * 30)s")
                }
            } else {
                try await Task.sleep(for: .seconds(cycleDuration * 0.1))
            }
            try sample("cycle\(cycle + 1)-cleared-drained")
        }
        toggle.click()
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "stopped"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed,
                       "Wait for published stopped state before recording stopped evidence")
        try sample("stopped")
        XCTAssertGreaterThan(completed, 0)
        print("STREAMING_ACCEPTANCE_COMPLETE requests=\(completed) seconds=\(Date().timeIntervalSince(started))")
        if environment["JOESPROXY_STREAMING_VERIFY_CUTOFF"] == "1" {
            // Reuse only the exact disposable app executable verified above. A direct child
            // launch lets us assert exit status without XCTest mistaking expected exit for an AX failure.
            let executable = try XCTUnwrap(running.executableURL)
            app.terminate()
            let probe = Process()
            probe.executableURL = executable
            probe.arguments = app.launchArguments + ["--ui-test-memory-cutoff-probe"]
            probe.environment = app.launchEnvironment
            try probe.run()
            defer { if probe.isRunning { probe.terminate() } }
            let deadline = Date().addingTimeInterval(10)
            while probe.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !probe.isRunning else { throw SoakFailure.timeout }
            XCTAssertEqual(probe.terminationReason, .exit)
            XCTAssertEqual(probe.terminationStatus, 78, "The isolated self-sampler must enforce its cutoff")
            print("STREAMING_MEMORY_CUTOFF_VERIFIED exit=78 thresholdBytes=1")
        }
    }
}

/// Loopback-only datagrams, one peer and one latest record. Network state stays on queue;
/// the lock protects only the small snapshot shared with the main-actor test.
final class SoakAppMetricsReceiver: @unchecked Sendable {
    let token = UUID().uuidString
    private let listener: NWListener
    private let queue = DispatchQueue(label: "joesproxy.test.metrics")
    private let lock = NSLock()
    private var snapshot: [String: Any]?
    private var connection: NWConnection?

    init() throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] peer in
            guard let self else { peer.cancel(); return }
            self.queue.async {
                guard self.connection == nil else { peer.cancel(); return }
                self.connection = peer
                peer.start(queue: self.queue)
                self.receive(peer)
            }
        }
        return try await SoakBinaryOrigin.startListener(listener)
    }

    func stop() {
        listener.cancel()
        queue.async { self.connection?.cancel(); self.connection = nil }
    }

    func latest(pid: pid_t) throws -> [String: Any] {
        lock.lock()
        let record = snapshot
        lock.unlock()
        guard var record, record["pid"] as? Int32 == pid,
              let uptime = record["sampleUptime"] as? Double,
              (0...5).contains(ProcessInfo.processInfo.systemUptime - uptime) else {
            throw SoakFailure.metricsUnavailable(ESTALE)
        }
        record.removeValue(forKey: "token")
        return record
    }

    private func receive(_ peer: NWConnection) {
        peer.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { peer.cancel(); return }
            if let data, data.count <= 2048,
               let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               record["token"] as? String == self.token {
                self.lock.lock()
                self.snapshot = record
                self.lock.unlock()
            }
            self.receive(peer)
        }
    }
}

private enum SoakFailure: Error {
    case invalidCandidate, invalidWorkloadBudget, invalidWorkloadDigest, manifestDigestMismatch
    case incompleteWorkload(completed: Int, expected: Int, budgetSeconds: Double)
    case listener, response, timeout, metricsUnavailable(Int32), memorySafetyLimit
    case missingTileLabel(String)
}

/// Listener and connection state is confined to queue; stop dispatches onto that same queue.
final class SoakBinaryOrigin: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "joesproxy.synthetic.origin")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let body: Data
    private let chunk: Data
    var bodySize: Int { body.count }

    init(body: Data) throws {
        guard !body.isEmpty else { throw SoakFailure.response }
        self.body = body
        chunk = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    static func startListener(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: SoakFailure.listener) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "joesproxy.synthetic.listener"))
        }
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async {
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.readHead(connection, header: Data())
            }
        }
        return try await Self.startListener(listener)
    }
    func stop() {
        listener.cancel()
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
    private func readHead(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            guard error == nil, let data, header.count + data.count <= 4096 else { self.close(connection); return }
            let bytes = header + data
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(self.bodySize)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { error in
                    if error != nil { self.close(connection) } else { self.sendChunk(connection, remaining: self.bodySize) }
                })
            } else if done { self.close(connection) }
            else { self.readHead(connection, header: bytes) }
        }
    }
    private func sendChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { close(connection); return }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil { self.close(connection) }
            else { self.sendChunk(connection, remaining: remaining - self.chunk.count) }
        })
    }
}

/// Each request has one connection and a ten-second deadline. Mutable state stays on queue.
final class SoakBinaryClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "joesproxy.synthetic.client")
    private var finish: ((Result<Void, Error>) -> Void)?
    private var header = Data()
    private var readingBody = false
    private var body = Data()
    private let expectedBody: Data
    private var timeout: DispatchWorkItem?
    private init(proxyPort: UInt16, expectedBody: Data) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        self.expectedBody = expectedBody
    }
    static func request(proxyPort: UInt16, originPort: UInt16, expectedBody: Data) async throws {
        let client = SoakBinaryClient(proxyPort: proxyPort, expectedBody: expectedBody)
        try await withCheckedThrowingContinuation { continuation in
            client.finish = { continuation.resume(with: $0) }
            client.connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let head = Data("GET http://127.0.0.1:\(originPort)/segment.bin HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n".utf8)
                    client.connection.send(content: head, completion: .contentProcessed { error in
                        if let error { client.complete(.failure(error)) } else { client.read() }
                    })
                } else if case .failed(let error) = state { client.complete(.failure(error)) }
            }
            let timeout = DispatchWorkItem { [weak client] in client?.complete(.failure(SoakFailure.timeout)) }
            client.timeout = timeout
            client.queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            client.connection.start(queue: client.queue)
        }
    }
    private func complete(_ result: Result<Void, Error>) {
        guard let finish else { return }
        self.finish = nil
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        finish(result)
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, done, error in
            if let error { self.complete(.failure(error)); return }
            var body = data ?? Data()
            if !self.readingBody {
                self.header.append(body)
                if let separator = self.header.range(of: Data("\r\n\r\n".utf8)) {
                    guard String(decoding: self.header.prefix(separator.lowerBound), as: UTF8.self).hasPrefix("HTTP/1.1 200") else {
                        self.complete(.failure(SoakFailure.response)); return
                    }
                    body = self.header.subdata(in: separator.upperBound..<self.header.count)
                    self.header.removeAll()
                    self.readingBody = true
                } else {
                    guard self.header.count <= 4096, !done else { self.complete(.failure(SoakFailure.response)); return }
                    self.read(); return
                }
            }
            self.body.append(body)
            guard self.body.count <= self.expectedBody.count else { self.complete(.failure(SoakFailure.response)); return }
            if done {
                self.complete(self.body == self.expectedBody ? .success(()) : .failure(SoakFailure.response))
            } else { self.read() }
        }
    }
}
