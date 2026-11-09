import AppKit
import Darwin
import Network
import XCTest

/// Host-controlled matched B/C experiment. No private traffic, keychain access or system routing.
@MainActor
final class AgentWorkspaceProfilingUITests: XCTestCase {
    func testMatchedAgentProducts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["JOESPROXY_AGW_PROTOCOL"], ["pilot", "full"].contains(mode),
              let root = environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"] else {
            throw XCTSkip("Requires the approved host wrapper and explicit AGW protocol")
        }
        continueAfterFailure = false
        let repetitions = mode == "pilot" ? 1 : 3
        for repetition in 0..<repetitions {
            let order = repetition % 2 == 0 ? ["B", "C"] : ["C", "B"]
            for candidate in order {
                try await run(candidate: candidate, repetition: repetition, mode: mode, root: root)
            }
        }
    }

    private func run(candidate: String, repetition: Int, mode: String, root: String) async throws {
        let identifier = candidate == "B" ? "com.ShowBlender.JoesProxy" : "com.ShowBlender.JoesProxy.AgentPrototype"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw ProfileError.existingApp
        }
        let metrics = try SoakAppMetricsReceiver()
        let metricsPort = try await metrics.start()
        defer { metrics.stop() }
        let body = Data(repeating: 42, count: 32 * 1024)
        let origin = try SoakBinaryOrigin(body: body)
        let originPort = try await origin.start()
        defer { origin.stop() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let reservation = try NWListener(using: parameters)
        reservation.newConnectionHandler = { $0.cancel() }
        let port = try await SoakBinaryOrigin.startListener(reservation)
        reservation.cancel()

        let app = XCUIApplication(bundleIdentifier: identifier)
        app.launchArguments = ["--agent-workspace", "--agent-workspace-profile", "--ui-test-memory-guard",
            "--agent-workspace-diagnostics", "--ui-test-proxy-port=\(port)"]
        app.launchEnvironment = ["JOESPROXY_AGW_PROTOCOL": mode, "JOESPROXY_AGW_ROOT": root,
            "JOESPROXY_PROFILE_METRICS_PORT": String(metricsPort),
            "JOESPROXY_PROFILE_METRICS_TOKEN": metrics.token, "JOESPROXY_AGENT_WORKSPACE_DIAGNOSTICS": "1",
            "DYLD_INSERT_LIBRARIES": ""]
        let launchStart = ProcessInfo.processInfo.systemUptime
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let product = candidate == "B" ? "JoesProxy" : "JoesProxyAgentPrototype"
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.bundleURL?.path.contains("/Build/Products/Release/\(product).app") == true })
        let launchSeconds = ProcessInfo.processInfo.systemUptime - launchStart
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
            throw ProfileError.invalidCPUTimebase
        }
        var processUsage = rusage_info_v4()
        let usageStatus = withUnsafeMutableBytes(of: &processUsage) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        var unixUsage = rusage()
        guard usageStatus == 0, getrusage(RUSAGE_SELF, &unixUsage) == 0 else {
            throw ProfileError.invalidCPUTimebase
        }
        let unixSeconds = Double(unixUsage.ru_utime.tv_sec + unixUsage.ru_stime.tv_sec)
            + Double(unixUsage.ru_utime.tv_usec + unixUsage.ru_stime.tv_usec) / 1_000_000
        let scaledSeconds = (Double(processUsage.ri_user_time) + Double(processUsage.ri_system_time))
            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        XCTAssertEqual(scaledSeconds, unixSeconds, accuracy: max(0.05, unixSeconds * 0.1),
                       "CPU counter conversion must agree with independent getrusage seconds")
        var evidence = Data()
        defer {
            let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.plain-text")
            attachment.name = "AGW-v2-\(mode)-\(candidate)-\(repetition).jsonl"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        var completed = 0
        var lastSample: Double = -1
        var observedPhases = Set<String>()
        let expectedRequests = mode == "pilot" ? 50 : 700
        let deadline = ProcessInfo.processInfo.systemUptime + (mode == "pilot" ? 150 : 800)
        var firstMetric = true
        var lastMetricAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard var record = try? metrics.latest(pid: running.processIdentifier),
                  let profile = record["agentProfile"] as? [String: Any],
                  let phase = profile["phase"] as? String,
                  let uptime = record["sampleUptime"] as? Double else {
                guard !running.isTerminated,
                      ProcessInfo.processInfo.systemUptime - lastMetricAt < 15 else { throw ProfileError.timeout }
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            lastMetricAt = ProcessInfo.processInfo.systemUptime
            guard let published = profile["publishedUptime"] as? Double,
                  ProcessInfo.processInfo.systemUptime - published < 5 else { throw ProfileError.timeout }
            if firstMetric {
                firstMetric = false
                XCTAssertEqual(record["instrumentationLoaded"] as? Bool, false)
            }
            guard phase != "failed" else { throw ProfileError.workloadFailed(String(describing: profile["failure"])) }
            let diagnostics = try XCTUnwrap(record["agentWorkspaceDiagnostics"] as? [String: Any])
            XCTAssertEqual(diagnostics["inspectorModelConstructionCount"] as? Int, 0)
            XCTAssertEqual(diagnostics["inspectorSubscriptionCount"] as? Int, 0)
            observedPhases.insert(phase)
            var requestSeconds: Double?
            if phase == "traffic-query", completed < expectedRequests {
                let start = ProcessInfo.processInfo.systemUptime
                try await SoakBinaryClient.request(proxyPort: port, originPort: originPort, expectedBody: body)
                requestSeconds = ProcessInfo.processInfo.systemUptime - start
                completed += 1
            }
            if uptime != lastSample || requestSeconds != nil {
                // The legacy self-sampler names raw proc_pid_rusage counters "Nanoseconds".
                // Normalize at the evidence boundary; preserve raw values and the measured scale.
                for component in ["user", "system"] {
                    let key = "\(component)CPUTimeNanoseconds"
                    let raw = try XCTUnwrap(record[key] as? NSNumber)
                    record["\(component)CPUTimeMachAbsolute"] = raw
                    record[key] = raw.doubleValue * Double(timebase.numer) / Double(timebase.denom)
                }
                record["cpuTimeUnit"] = "nanoseconds"
                record["machTimebaseNumerator"] = timebase.numer
                record["machTimebaseDenominator"] = timebase.denom
                record["candidate"] = candidate
                record["repetition"] = repetition
                record["protocol"] = "agw-v2-\(mode)"
                record["workloadDigest"] = "50259f98208b7a6d8b3ea33cba1ff19345a522aac7e9326ce47f6c0c053ecdcd"
                record["launchToReturnSeconds"] = launchSeconds
                record["completedRequests"] = completed
                record["forwardingSeconds"] = requestSeconds
                let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                evidence.append(line)
                evidence.append(10)
                lastSample = uptime
            }
            if phase == "complete" {
                XCTAssertEqual(completed, expectedRequests)
                XCTAssertEqual(profile["queryCount"] as? Int, mode == "pilot" ? 15 : 180)
                XCTAssertEqual(profile["queryPassed"] as? Bool, true)
                XCTAssertEqual(profile["retainedSessions"] as? Int, 10_000 + completed)
                XCTAssertEqual(profile["retainedBodyBytes"] as? Int, 180_000 + completed * body.count)
                XCTAssertEqual(profile["pendingCaptures"] as? Int, 0)
                XCTAssertEqual(profile["reservedCaptureBytes"] as? Int, 0)
                XCTAssertEqual(profile["activeChannels"] as? Int, 0)
                XCTAssertEqual(profile["rejectedCaptures"] as? Int, 0)
                XCTAssertEqual(profile["captureAccountingAvailable"] as? Bool, true)
                XCTAssertTrue(Set(["warmup", "empty-idle", "retained-observation", "traffic-query", "drain"]).isSubset(of: observedPhases))
                print("AGW_COMPLETE candidate=\(candidate) repetition=\(repetition) requests=\(completed)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProfileError.timeout
    }

    private enum ProfileError: Error {
        case existingApp, timeout, invalidCPUTimebase, workloadFailed(String)
    }
}
