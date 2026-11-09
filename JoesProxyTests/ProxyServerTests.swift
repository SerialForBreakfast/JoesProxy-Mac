import Combine
import CryptoKit
import Network
import MachO
import NIOCore
import NIOPosix
import NIOSSL
import XCTest
@testable import JoesProxy

final class ProxyServerTests: XCTestCase {
    func testSequentialHTTPSRequestsStayIsolatedOnOneConnection() async throws {
        try await exerciseSequentialHTTPS(delayedStage: nil)
    }

    func testDelayedTLSAndOriginDoNotBlockHealthySiblingRequests() async throws {
        for stage in ["tls", "response"] { try await exerciseSequentialHTTPS(delayedStage: stage) }
    }

    private func exerciseSequentialHTTPS(delayedStage: String?) async throws {
        let authority = PersistentCertificateAuthorityProvider(configuration: TestProxyConfiguration(proxyPort: 0,
            logLevel: .info, certificateLabel: "Sequential-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let leaf = try authority.issueLeafCertificate(for: "localhost")
        for mode in ["tunnel", "inspect_without_capture", "inspect_with_capture"] {
            let gate = ScriptedDeliveryGate()
            let delayed = SimpleHTTPSTestServer(leafCertificate: leaf,
                tlsGate: delayedStage == "tls" ? gate : nil, responseGate: delayedStage == "response" ? gate : nil)
            let healthy = SimpleHTTPSTestServer(leafCertificate: leaf)
            let store = InMemorySessionStore()
            let recorder = ProxySessionRecorder(sessionStore: store)
            let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting, certificateAuthority: authority,
                sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                upstreamConnectorConfiguration: .init(trustedRootCertificates: [root.certificateData]))
            try await healthy.start()
            try await delayed.start()
            do {
                try await proxy.start()
                let client = try await InterceptingHTTPSTestClient.connect(port: proxy.port, trustedRootCertificates: [root.certificateData])
                let delayedClient = try await InterceptingHTTPSTestClient.connect(port: proxy.port, trustedRootCertificates: [root.certificateData])
                func request(_ path: String) -> String {
                    "GET \(path) HTTP/1.1\r\nHost: localhost\r\nX-Synthetic-Sequential: yes\r\nConnection: keep-alive\r\n\r\n"
                }
                let blocked: Task<Data, Error>? = delayedStage.map { _ in Task {
                    try await delayedClient.performBytes(targetHost: "localhost", targetPort: delayed.port, request: request("/delayed"))
                } }
                do {
                    if delayedStage != nil {
                        try await withTimeout(seconds: 3) {
                            while !gate.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
                        }
                    }
                    for index in 0..<6 {
                        let path = "/sequence/\(index)-" + String(repeating: "x", count: index * 97)
                        let bytes = try await withTimeout(seconds: 3) {
                            try await client.performBytes(targetHost: "localhost", targetPort: healthy.port, request: request(path))
                        }
                        let split = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
                        XCTAssertEqual(Data(bytes[split.upperBound...]), Data(path.utf8), "\(mode): response contamination")
                        if delayedStage != nil { XCTAssertTrue(gate.isWaiting, "Sibling must finish before releasing the blocked stage") }
                    }
                    gate.release()
                    if let blocked {
                        let bytes = try await blocked.value
                        let split = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
                        XCTAssertEqual(Data(bytes[split.upperBound...]), Data("/delayed".utf8))
                    }
                    try await client.close()
                    try await delayedClient.close()
                } catch {
                    gate.release()
                    try? await client.close()
                    try? await delayedClient.close()
                    _ = try? await blocked?.value
                    throw error
                }
                XCTAssertEqual(healthy.scriptedCounter.requests, 6)
                XCTAssertEqual(delayed.scriptedCounter.requests, delayedStage == nil ? 0 : 1)
                try await drainScripted(recorder, store: store)
                await proxy.stop()
                await healthy.stop()
                await delayed.stop()
            } catch {
                gate.release()
                await proxy.stop()
                await healthy.stop()
                await delayed.stop()
                throw error
            }
        }
    }

    private var scriptedConfiguration: String { _isDebugAssertConfiguration() ? "Debug" : "Optimized" }

    private func verifyScriptedRuntime() {
        let forbidden = ["libmainthreadchecker", "librpac", "libclang_rt.asan", "libclang_rt.tsan", "libclang_rt.ubsan"]
        let instrumented = (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            let path = String(cString: name).lowercased()
            return forbidden.contains { path.contains($0) }
        }
        if !_isDebugAssertConfiguration() { XCTAssertFalse(instrumented, "Optimized timing requires an uninstrumented runtime") }
        print("SCRIPTED_RUNTIME configuration=\(scriptedConfiguration) instrumented=\(instrumented)")
    }

    private func scriptedExchange(_ fixture: ScriptedTransportFixture, mode: String, port: UInt16,
                                  originPort: UInt16, root: Data, slow: Bool) async throws -> (Double, Double) {
        let connectStarted = ProcessInfo.processInfo.systemUptime
        let client = try await InterceptingHTTPSTestClient.connect(port: port, trustedRootCertificates: [root])
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await client.performBytes(targetHost: "localhost", targetPort: originPort,
                request: "\(fixture.method) /seed17/\(fixture.name) HTTP/1.1\r\nHost: localhost\r\nX-Synthetic-Case: \(fixture.name)\r\nConnection: close\r\n\r\n",
                direct: mode == "direct", slowReceiver: slow,
                expectedBodyBytes: fixture.fails ? 1_048_576 : fixture.body.count, waitForEOF: fixture.closeDelimited)
            XCTAssertFalse(fixture.fails, "seed17 \(mode) \(fixture.name): malformed/truncated response succeeded")
            let split = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
            let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 \(fixture.status) "), "\(mode) \(fixture.name): status")
            XCTAssertEqual(Data(response[split.upperBound...]), fixture.body, "seed17 \(mode) \(fixture.name): bytes")
            for (name, value) in fixture.headers where name != "Connection" {
                XCTAssertTrue(head.lowercased().contains("\(name): \(value)".lowercased()), "\(mode) \(fixture.name): \(name)")
            }
            let gap = try await client.observedReadGap()
            let stages = try await client.observedResponseStages()
            let responseFinished = ProcessInfo.processInfo.systemUptime
            try await client.close()
            let finished = ProcessInfo.processInfo.systemUptime
            if finished - connectStarted >= 0.25 {
                let record: [String: Any] = ["mode": mode, "fixture": fixture.name, "seed": 17,
                    "clientConnectSeconds": started - connectStarted,
                    "proxyConnectSeconds": client.proxyConnectSeconds,
                    "tlsInstallationSeconds": client.tlsInstallationSeconds,
                    "responseWaitSeconds": stages.waitSeconds,
                    "firstByteSeconds": stages.firstByteSeconds as Any? ?? NSNull(),
                    "bodyReadSeconds": stages.bodySeconds as Any? ?? NSNull(),
                    "responseCompletedSeconds": responseFinished - started,
                    "clientShutdownSeconds": finished - responseFinished,
                    "totalSeconds": finished - connectStarted]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print("SCRIPTED_SLOW_TRANSFER " + String(decoding: data, as: UTF8.self))
            }
            return (finished - started, gap)
        } catch {
            try? await client.close()
            if fixture.fails {
                XCTAssertFalse(error is TestTimeoutError, "Failure must terminate, not hit a deadline")
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, "seed17 \(mode) \(fixture.name)")
                return (ProcessInfo.processInfo.systemUptime - started, 0)
            }
            throw error
        }
    }

    private func drainScripted(_ recorder: ProxySessionRecorder, store: InMemorySessionStore) async throws {
        let drained = try await withTimeout(seconds: 5) {
            while true {
                await recorder.waitForPendingStoreFlush()
                let inFlight = await recorder.inFlightSessionCount
                let capture = recorder.admission.snapshot
                let relay = RelayBacklogBudget.shared.snapshot
                // Client shutdown can precede the final relay write. Observe all drain fields
                // after asynchronous store work, and assert that same checkpoint below.
                if capture.pendingCaptures == 0, capture.reservedBytes == 0,
                   relay.operations == 0, relay.bytes == 0, !relay.paused, inFlight == 0 {
                    return (capture, relay, inFlight)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await MainActor.run { store.clear() }
        XCTAssertEqual(drained.0.reservedBytes, 0)
        XCTAssertEqual(drained.1.bytes, 0)
        XCTAssertFalse(drained.1.paused)
        XCTAssertEqual(drained.2, 0)
    }

    func testScriptedBinaryFramingMatrixAcrossTransportModes() async throws {
        verifyScriptedRuntime()
        let authority = PersistentCertificateAuthorityProvider(configuration: TestProxyConfiguration(proxyPort: 0,
            logLevel: .info, certificateLabel: "Matrix-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let fixtures = ScriptedTransportFixture.cases()
        let origin = SimpleHTTPSTestServer(leafCertificate: try authority.issueLeafCertificate(for: "localhost"),
            scripted: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.wire) }))
        try await origin.start()
        do {
            for mode in ["direct", "tunnel", "inspect_without_capture", "inspect_with_capture"] {
                let store = InMemorySessionStore()
                let recorder = ProxySessionRecorder(sessionStore: store)
                let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                    httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting, certificateAuthority: authority,
                    sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                    upstreamConnectorConfiguration: .init(trustedRootCertificates: [root.certificateData]))
                if mode != "direct" { try await proxy.start() }
                do {
                    for fixture in fixtures + [fixtures[0]] {
                        _ = try await scriptedExchange(fixture, mode: mode, port: mode == "direct" ? origin.port : proxy.port,
                            originPort: origin.port, root: root.certificateData, slow: true)
                    }
                    try await drainScripted(recorder, store: store)
                    if mode != "direct" { await proxy.stop() }
                    print("SCRIPTED_MATRIX seed=17 mode=\(mode) cases=13 exactBytes=true drained=true")
                } catch { if mode != "direct" { await proxy.stop() }; throw error }
            }
            XCTAssertEqual(origin.scriptedCounter.requests, 52, "No redirect following or hidden request replay")
            await origin.stop()
        } catch { await origin.stop(); throw error }
    }

    func testScriptedMixedBurstIdleResumeDrainsWithMetrics() async throws {
        verifyScriptedRuntime()
        let authority = PersistentCertificateAuthorityProvider(configuration: TestProxyConfiguration(proxyPort: 0,
            logLevel: .info, certificateLabel: "Mixed-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let fixtures = ScriptedTransportFixture.cases().filter { ["api", "media", "binary", "gzip"].contains($0.name) }
        let origin = SimpleHTTPSTestServer(leafCertificate: try authority.issueLeafCertificate(for: "localhost"),
            scripted: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.wire) }))
        try await origin.start()
        let sampler = CurrentProcessMetricsSampler()
        do {
            for mode in ["direct", "tunnel", "inspect_without_capture", "inspect_with_capture"] {
                let store = InMemorySessionStore()
                let recorder = ProxySessionRecorder(sessionStore: store)
                let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                    httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting, certificateAuthority: authority,
                    sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                    upstreamConnectorConfiguration: .init(trustedRootCertificates: [root.certificateData]))
                if mode != "direct" { try await proxy.start() }
                do {
                    func checkpoint(_ phase: String) throws {
                        let metrics = sampler.sample()
                        guard metrics.physicalFootprintBytes < 1_610_612_736 else {
                            throw NSError(domain: "ScriptedTransportFootprintSafetyStop", code: 1)
                        }
                        let data = try JSONSerialization.data(withJSONObject: ["seed": 17, "mode": mode,
                            "phase": phase, "configuration": scriptedConfiguration, "physicalFootprint": metrics.physicalFootprintBytes,
                            "cpuPercent": metrics.cpuPercent as Any? ?? NSNull(),
                            "relayBytes": RelayBacklogBudget.shared.snapshot.bytes,
                            "captureReserved": recorder.admission.snapshot.reservedBytes,
                            "retainedSessions": store.sessions.count], options: [.sortedKeys])
                        print("SCRIPTED_METRIC " + String(decoding: data, as: UTF8.self))
                    }
                    _ = sampler.sample()
                    try checkpoint("baseline")
                    for cycle in 0..<16 {
                        if cycle == 8 { try await Task.sleep(for: .seconds(1)); try checkpoint("idle") }
                        let peakTask = Task { () -> Int in
                            var peak = 0
                            while !Task.isCancelled {
                                peak = max(peak, RelayBacklogBudget.shared.snapshot.bytes)
                                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                            }
                            return peak
                        }
                        var times: [Double] = []
                        var gaps: [Double] = []
                        do {
                            try await withThrowingTaskGroup(of: (Double, Double).self) { group in
                                for index in 0..<8 {
                                    let fixture = fixtures[(index + cycle * 17) % fixtures.count]
                                    group.addTask {
                                        try await self.scriptedExchange(fixture, mode: mode,
                                            port: mode == "direct" ? origin.port : proxy.port, originPort: origin.port,
                                            root: root.certificateData, slow: index % 2 == 0)
                                    }
                                }
                                for try await (time, gap) in group { times.append(time); gaps.append(gap) }
                            }
                        } catch { peakTask.cancel(); _ = await peakTask.value; throw error }
                        peakTask.cancel()
                        let queuePeak = await peakTask.value
                        try await drainScripted(recorder, store: store)
                        let metrics = sampler.sample()
                        guard metrics.physicalFootprintBytes < 1_610_612_736 else {
                            throw NSError(domain: "ScriptedTransportFootprintSafetyStop", code: 1)
                        }
                        XCTAssertLessThanOrEqual(queuePeak, 32 * 1_024 * 1_024 + 8 * 524_288)
                        XCTAssertLessThanOrEqual(recorder.admission.snapshot.peakReservedBytes, recorder.admission.snapshot.byteLimit)
                        let record: [String: Any] = ["seed": 17, "mode": mode, "cycle": cycle,
                            "phase": cycle < 8 ? "burst" : "resumed_burst", "completed": times.count,
                            "configuration": scriptedConfiguration, "physicalFootprint": metrics.physicalFootprintBytes,
                            "cpuPercent": metrics.cpuPercent as Any? ?? NSNull(), "sampledQueuePeak": queuePeak,
                            "relayBytes": RelayBacklogBudget.shared.snapshot.bytes,
                            "captureReserved": recorder.admission.snapshot.reservedBytes,
                            "capturePeak": recorder.admission.snapshot.peakReservedBytes,
                            "maxTransferSeconds": times.max() ?? 0, "maxClientReadGapSeconds": gaps.max() ?? 0,
                            "timingSamples": times.count, "retainedSessions": store.sessions.count,
                            "deliveredBodyBytes": fixtures.reduce(0) { $0 + $1.body.count } * 2]
                        let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                        print("SCRIPTED_METRIC " + String(decoding: json, as: UTF8.self))
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    try checkpoint("final_drain")
                    if mode != "direct" { await proxy.stop() }
                } catch { if mode != "direct" { await proxy.stop() }; throw error }
            }
            XCTAssertEqual(origin.scriptedCounter.requests, 512)
            await origin.stop()
        } catch { await origin.stop(); throw error }
    }


    func testChunkedHTTPSCompletionAndTruncationAcrossCaptureModes() async throws {
        let authority = PersistentCertificateAuthorityProvider(configuration: TestProxyConfiguration(proxyPort: 0,
            logLevel: .info, certificateLabel: "Chunked-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let upstream = SimpleHTTPSTestServer(responseBody: "unused",
            leafCertificate: try authority.issueLeafCertificate(for: "localhost"))
        try await upstream.start()
        do {
            for mode in ["direct", "tunnel", "inspect_without_capture", "inspect_with_capture", "inspect_untrusted_origin"] {
                let store = InMemorySessionStore()
                let recorder = ProxySessionRecorder(sessionStore: store)
                let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                    httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting, certificateAuthority: authority,
                    sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                    upstreamConnectorConfiguration: .init(trustedRootCertificates: mode == "inspect_untrusted_origin" ? [] : [root.certificateData]))
                if mode != "direct" { try await proxy.start() }
                do {
                    for variant in ["complete", "truncated", "complete"] {
                        let client = try await InterceptingHTTPSTestClient.connect(
                            port: mode == "direct" ? upstream.port : proxy.port,
                            trustedRootCertificates: [root.certificateData])
                        let start = ContinuousClock.now
                        do {
                            let response = try await client.performInterceptedRequest(targetHost: "localhost", targetPort: upstream.port,
                                request: "GET /chunked HTTP/1.1\r\nHost: localhost\r\nX-Synthetic-Framing: \(variant)\r\n\r\n",
                                direct: mode == "direct")
                            if mode == "inspect_untrusted_origin" {
                                XCTAssertTrue(response.hasPrefix("HTTP/1.1 502"), "Untrusted upstream must not appear successful")
                            } else {
                                XCTAssertEqual(variant, "complete", "Truncated input must not succeed")
                                XCTAssertTrue(response.hasSuffix("4;test=yes\r\ntest\r\n0\r\nChecksum: synthetic\r\n\r\n"))
                            }
                        } catch {
                            XCTAssertTrue(variant == "truncated" || mode == "inspect_untrusted_origin", "\(mode): \(error)")
                        }
                        XCTAssertLessThan(start.duration(to: .now), .seconds(3), "Must not wait for the fixture deadline")
                        try await client.close()
                    }
                    await recorder.waitForPendingStoreFlush()
                    if mode == "inspect_with_capture" {
                        try await withTimeout(seconds: 5) {
                            while recorder.admission.snapshot.pendingCaptures != 0 { try await Task.sleep(for: .milliseconds(10)) }
                        }
                        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
                    }
                    if mode != "direct" { await proxy.stop() }
                } catch { if mode != "direct" { await proxy.stop() }; throw error }
            }
            await upstream.stop()
        } catch { await upstream.stop(); throw error }
    }


    func testPacedRangeTransfersWithConcurrentSlowReceiversDrain() async throws {
        let authority = PersistentCertificateAuthorityProvider(
            configuration: TestProxyConfiguration(proxyPort: 0, logLevel: .info,
                certificateLabel: "PacedTransport-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let body = String(repeating: "0123456789abcdef", count: 32_768)
        let upstream = SimpleHTTPSTestServer(responseBody: body,
            leafCertificate: try authority.issueLeafCertificate(for: "localhost"), pacedRanges: true)
        try await upstream.start()
        do {
            for mode in ["direct", "tunnel", "inspect_without_capture", "inspect_with_capture"] {
                let store = InMemorySessionStore()
                let recorder = ProxySessionRecorder(sessionStore: store)
                let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                    httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting,
                    certificateAuthority: authority,
                    sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                    upstreamConnectorConfiguration: .init(trustedRootCertificates: [root.certificateData]))
                if mode != "direct" { try await proxy.start() }
                do {
                    for cycle in 0..<2 {
                        await MainActor.run { store.clear() }
                        let port = mode == "direct" ? upstream.port : proxy.port
                        let originPort = upstream.port
                        try await withThrowingTaskGroup(of: Void.self) { tasks in
                            for range in ["", "Range: bytes=32768-98303\r\n", "Range: bytes=999999-\r\n", "X-Synthetic-Disconnect: true\r\n"] {
                                tasks.addTask {
                                    let client = try await InterceptingHTTPSTestClient.connect(port: port,
                                        trustedRootCertificates: [root.certificateData])
                                    do {
                                        if range.contains("X-Synthetic-Disconnect") {
                                            do {
                                                _ = try await withTimeout(seconds: 10) {
                                                    try await client.performInterceptedRequest(targetHost: "localhost", targetPort: originPort,
                                                        request: "GET /interrupt HTTP/1.1\r\nHost: localhost:\(originPort)\r\n\(range)Connection: close\r\n\r\n",
                                                        direct: mode == "direct")
                                                }
                                                XCTFail("Truncated response must not appear complete")
                                            } catch {
                                                XCTAssertTrue(error is HTTPUpstreamConnectorError || error is NIOSSLError, "Expected transport failure, received \(error)")
                                            }
                                            try await client.close()
                                            return
                                        }
                                        let response = try await withTimeout(seconds: 10) {
                                            try await client.performInterceptedRequest(targetHost: "localhost", targetPort: originPort,
                                                request: "GET /paced HTTP/1.1\r\nHost: localhost:\(originPort)\r\n\(range)Connection: close\r\n\r\n",
                                                direct: mode == "direct", slowReceiver: true)
                                        }
                                        let separator = try XCTUnwrap(response.range(of: "\r\n\r\n"))
                                        let delivered = String(response[separator.upperBound...])
                                        if range.isEmpty {
                                            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), mode)
                                            XCTAssertEqual(delivered, body, mode)
                                            let readCycles = try await client.observedSlowReadCycles()
                                            XCTAssertGreaterThan(readCycles, 0, "Slow receiver must actually delay reads")
                                        } else if range.contains("32768") {
                                            XCTAssertTrue(response.hasPrefix("HTTP/1.1 206"), mode)
                                            XCTAssertTrue(response.lowercased().contains("content-range: bytes 32768-98303/524288"))
                                            XCTAssertEqual(delivered, String(body.dropFirst(32768).prefix(65536)), mode)
                                        } else {
                                            XCTAssertTrue(response.hasPrefix("HTTP/1.1 416"), mode)
                                            XCTAssertTrue(response.lowercased().contains("content-range: bytes */524288"))
                                            XCTAssertEqual(delivered, "", mode)
                                        }
                                        try await client.close()
                                    } catch { try? await client.close(); throw error }
                                }
                            }
                            try await tasks.waitForAll()
                        }
                        try await withTimeout(seconds: 5) {
                            while RelayBacklogBudget.shared.snapshot.bytes != 0 || RelayBacklogBudget.shared.snapshot.operations != 0 {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        }
                        XCTAssertFalse(RelayBacklogBudget.shared.snapshot.paused)
                        if mode == "inspect_with_capture" {
                            try await withTimeout(seconds: 5) {
                                while store.sessions.filter({ $0.response != nil }).count < 3 || recorder.admission.snapshot.pendingCaptures != 0 {
                                    try await Task.sleep(for: .milliseconds(10))
                                }
                            }
                            await recorder.waitForPendingStoreFlush()
                            XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
                            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
                            for record in store.sessions where record.response != nil {
                                let evidence = try XCTUnwrap(record.timing.wireProfile?.transport)
                                XCTAssertEqual(evidence.pendingWrites, 0)
                                XCTAssertEqual(evidence.failedWrites, 0)
                                XCTAssertEqual(evidence.deliveryState, "writes_completed")
                                XCTAssertNotNil(evidence.tlsReadySeconds)
                            }
                        }
                        print("Synthetic paced-range cycle: mode=\(mode) cycle=\(cycle) completedTransfers=3 interruptedTransfers=1 exactBodies=true relayBytes=0 relayOperations=0")
                    }
                    if mode != "direct" { await proxy.stop() }
                } catch { if mode != "direct" { await proxy.stop() }; throw error }
            }
            await upstream.stop()
        } catch { await upstream.stop(); throw error }
    }

    func testSyntheticHTTPSDeliveryComparison() async throws {
        let authority = PersistentCertificateAuthorityProvider(
            configuration: TestProxyConfiguration(proxyPort: 0, logLevel: .info,
                certificateLabel: "SyntheticTransport-\(UUID().uuidString)"),
            certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let body = String(repeating: "synthetic-media-0123456789\n", count: 10_000)
        let upstream = SimpleHTTPSTestServer(responseBody: body,
            leafCertificate: try authority.issueLeafCertificate(for: "localhost"))
        try await upstream.start()
        var measurements: [[String: Any]] = []
        do {
            for mode in ["direct", "tunnel", "inspect_without_capture", "inspect_with_capture"] {
                let store = InMemorySessionStore()
                let recorder = ProxySessionRecorder(sessionStore: store)
                let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1",
                    httpsProxyMode: mode == "tunnel" ? .passThrough : .intercepting,
                    certificateAuthority: authority,
                    sessionRecorder: mode == "inspect_with_capture" ? recorder : nil,
                    upstreamConnectorConfiguration: HTTPUpstreamConnectorConfiguration(
                        trustedRootCertificates: [root.certificateData]))
                if mode != "direct" { try await proxy.start() }
                do {
                    for iteration in 0..<3 {
                        await MainActor.run { store.clear() }
                        let client = try await InterceptingHTTPSTestClient.connect(
                            port: mode == "direct" ? upstream.port : proxy.port,
                            trustedRootCertificates: [root.certificateData])
                        let started = ContinuousClock.now
                        do {
                            let response = try await withTimeout(seconds: 10) {
                                try await client.performInterceptedRequest(targetHost: "localhost",
                                    targetPort: upstream.port,
                                    request: "GET /synthetic-segment HTTP/1.1\r\nHost: localhost:\(upstream.port)\r\nConnection: close\r\n\r\n",
                                    direct: mode == "direct")
                            }
                            let elapsed = started.duration(to: .now).components
                            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), mode)
                            let separator = try XCTUnwrap(response.range(of: "\r\n\r\n"))
                            XCTAssertEqual(String(response[separator.upperBound...]), body, mode)
                            measurements.append(["mode": mode, "iteration": iteration,
                                "bytes": body.utf8.count,
                                "seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18])
                            if mode == "inspect_with_capture" {
                                let recorded = try await waitForCompletedSession(in: store)
                                XCTAssertEqual(recorded.response?.bodyData, Data(body.utf8))
                                let evidence = try XCTUnwrap(recorded.timing.wireProfile?.transport)
                                XCTAssertNotNil(evidence.tlsReadySeconds)
                                XCTAssertEqual(evidence.deliveryState, "writes_completed")
                                XCTAssertEqual(evidence.pendingWrites, 0)
                                XCTAssertEqual(evidence.failedWrites, 0)
                            }
                            try? await client.close()
                        } catch {
                            try? await client.close()
                            throw error
                        }
                    }
                    if mode != "direct" { await proxy.stop() }
                } catch {
                    if mode != "direct" { await proxy.stop() }
                    throw error
                }
            }
            await upstream.stop()
        } catch {
            await upstream.stop()
            throw error
        }
        let receipt = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
        let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-https-delivery-comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Synthetic HTTPS comparison: " + String(decoding: receipt, as: UTF8.self))
    }

    func testHTTPSMediaCapturePressurePreservesDeliveryAndRecovers() async throws {
        let authority = PersistentCertificateAuthorityProvider(configuration: TestProxyConfiguration(proxyPort: 0,
            logLevel: .info, certificateLabel: "Pressure-\(UUID().uuidString)"), certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let fixtures = ScriptedTransportFixture.cases().filter { ["media", "gzip", "binary", "api"].contains($0.name) }
        let origin = SimpleHTTPSTestServer(leafCertificate: try authority.issueLeafCertificate(for: "localhost"),
            scripted: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.wire) }))
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", httpsProxyMode: .intercepting,
            certificateAuthority: authority, sessionRecorder: recorder,
            upstreamConnectorConfiguration: .init(trustedRootCertificates: [root.certificateData]))
        try await origin.start()
        do {
            try await proxy.start()
            for reservedMiB in [128, 127, 0] {
                let reservation = reservedMiB == 0 ? nil : try XCTUnwrap(recorder.admission.reserve(bytes: reservedMiB * 1_024 * 1_024))
                do {
                    for fixture in fixtures {
                        _ = try await scriptedExchange(fixture, mode: "inspect_with_capture", port: proxy.port,
                            originPort: origin.port, root: root.certificateData, slow: true)
                    }
                    await recorder.waitForPendingStoreFlush()
                    let sessions = await MainActor.run { store.sessions }
                    if reservedMiB == 128 {
                        XCTAssertTrue(sessions.isEmpty)
                        XCTAssertEqual(recorder.admission.snapshot.rejectedCaptures, fixtures.count)
                    } else {
                        XCTAssertEqual(sessions.count, fixtures.count)
                        for session in sessions {
                            XCTAssertEqual(session.response?.statusCode, 200)
                            if reservedMiB == 127 {
                                XCTAssertEqual(session.responseCaptureLimitedByPressure, true)
                                XCTAssertNil(session.response?.bodyData)
                            } else {
                                XCTAssertFalse(session.response?.bodyData?.isEmpty ?? true)
                            }
                        }
                    }
                    if let reservation { recorder.admission.release(reservation) }
                } catch {
                    if let reservation { recorder.admission.release(reservation) }
                    throw error
                }
                try await drainScripted(recorder, store: store)
                XCTAssertFalse(recorder.admission.snapshot.paused, "Recovery must not need another request")
            }
            XCTAssertEqual(origin.scriptedCounter.requests, 12, "Capture rejection must not replay traffic")
            await proxy.stop()
            await origin.stop()
        } catch {
            await proxy.stop()
            await origin.stop()
            throw error
        }
    }

    func testCaptureSaturationStillForwardsAndResumesRecording() async throws {
        let upstream = SimpleHTTPTestServer()
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let diagnostics = CaptureTransportDiagnostics()
        let server = ProxyServer(port: 0, sessionRecorder: recorder, transportDiagnostics: diagnostics)
        try await upstream.start()
        do {
            try await server.start()
            // Occupy the capture byte budget without allocating a large body or blocking an actor.
            let reservation = try XCTUnwrap(recorder.admission.reserve(bytes: 128 * 1_024 * 1_024))
            defer { recorder.admission.release(reservation) }
            for captureMode in ["fullBudget", "metadata", "normal"] {
                var pressureReservation: UUID?
                if captureMode != "fullBudget" { recorder.admission.release(reservation) }
                if captureMode == "metadata" {
                    pressureReservation = try XCTUnwrap(recorder.admission.reserve(bytes: 127 * 1_024 * 1_024))
                }
                defer { if let pressureReservation { recorder.admission.release(pressureReservation) } }
                let connection = NWConnection(host: "127.0.0.1",
                    port: try XCTUnwrap(NWEndpoint.Port(rawValue: server.port)), using: .tcp)
                defer { connection.cancel() }
                try await NetworkConnectionIO.start(connection,
                    on: DispatchQueue(label: "com.joesproxyapp.tests.saturated-capture"))
                let request = "GET http://127.0.0.1:\(upstream.port)/capture-pressure HTTP/1.1\r\n"
                    + "Host: 127.0.0.1:\(upstream.port)\r\nConnection: close\r\n\r\n"
                try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
                let response = try await withTimeout(seconds: 3) {
                    var received = Data()
                    while received.count < 65_536 {
                        let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
                        received.append(bytes)
                        let text = String(decoding: received, as: UTF8.self)
                        if text.contains("proxy-test-response") || complete { return text }
                    }
                    return String(decoding: received, as: UTF8.self)
                }
                XCTAssertTrue(response.contains("200 OK"))
                XCTAssertEqual(response.components(separatedBy: "\r\n\r\n").last, "proxy-test-response")
                if captureMode == "fullBudget" {
                    XCTAssertTrue(store.sessions.isEmpty)
                    XCTAssertEqual(recorder.admission.snapshot.rejectedCaptures, 1)
                    XCTAssertTrue(recorder.admission.snapshot.paused)
                } else if captureMode == "metadata" {
                    let recorded = try await waitForCompletedSession(in: store)
                    XCTAssertEqual(recorded.responseCaptureLimitedByPressure, true)
                    XCTAssertNil(recorded.response?.bodyData)
                    XCTAssertEqual(recorded.response?.bodySize, "proxy-test-response".utf8.count)
                    XCTAssertEqual(recorded.response?.statusCode, 200)
                    XCTAssertEqual(recorder.admission.snapshot.metadataOnlyCaptures, 1)
                    await MainActor.run { store.clear() }
                } else {
                    let recorded = try await waitForCompletedSession(in: store)
                    XCTAssertEqual(recorded.response?.bodyData, Data("proxy-test-response".utf8))
                    XCTAssertEqual(store.sessions.count, 1)
                }
                connection.cancel()
            }
            let progress = diagnostics.snapshot().requestProgress
            XCTAssertEqual(progress[.routingStarted]?.count, 3)
            XCTAssertEqual(progress[.upstreamStarted]?.count, 3)
            XCTAssertEqual(progress[.responseHead]?.count, 3)
            XCTAssertEqual(progress[.responseComplete]?.count, 3)
            await server.stop()
            await upstream.stop()
            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        } catch {
            await server.stop()
            await upstream.stop()
            throw error
        }
    }

    private func makeServer(
        sessionStore: (any SessionStore)? = nil,
        httpsProxyMode: HTTPSProxyMode = .passThrough,
        certificateAuthority: (any CertificateAuthorityProviding)? = nil,
        trustedRootCertificates: [Data] = [],
        responseOverrideStore: ResponseOverrideStore? = nil,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore? = nil,
        fixtureOriginRegistry: HLSFixtureOriginRegistry? = nil
    ) -> ProxyServer {
        let recorder = sessionStore.map { ProxySessionRecorder(sessionStore: $0) }
        return ProxyServer(
            port: 0,
            httpsProxyMode: httpsProxyMode,
            certificateAuthority: certificateAuthority,
            sessionRecorder: recorder,
            responseOverrideStore: responseOverrideStore,
            bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
            fixtureOriginRegistry: fixtureOriginRegistry,
            upstreamConnectorConfiguration: HTTPUpstreamConnectorConfiguration(
                trustedRootCertificates: trustedRootCertificates
            )
        )
    }

    func testServerStartStop() async throws {
        let server = makeServer()
        try await server.start()
        XCTAssertTrue(server.isRunning)

        await server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testUpstreamListenersReserveDistinctPortsWhileBothAreRunning() async throws {
        let first = SimpleHTTPTestServer()
        let second = SimpleHTTPTestServer()
        try await first.start()
        do {
            try await second.start()
            XCTAssertNotEqual(first.port, 0)
            XCTAssertNotEqual(second.port, 0)
            XCTAssertNotEqual(first.port, second.port)
        } catch {
            await first.stop()
            await second.stop()
            throw error
        }
        await first.stop()
        await second.stop()
    }

    func testHTTPProxyForwardsResponseAndRecordsSession() async throws {
        let upstreamServer = SimpleHTTPTestServer()
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/hello HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.contains("200 OK"))
        XCTAssertTrue(responseString.contains("proxy-test-response"))

        let recordingDeadline = ContinuousClock.now + .seconds(3)
        while store.sessions.isEmpty, ContinuousClock.now < recordingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.host, "127.0.0.1")
        XCTAssertEqual(store.sessions.first?.request.path, "/hello")
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 200)
        XCTAssertEqual(store.sessions.first?.state, .completed)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testHTTPProxyServesReservedFixtureOriginWithoutContactingUpstream() async throws {
        let profileDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // JoesProxyTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileDirectory.path),
            "Fixtures/HLS/baseline-aligned-codecs not present — run generate-profile.sh first."
        )

        let fixtureServer = HLSFixtureServer(profileDirectory: profileDirectory)
        let registry = HLSFixtureOriginRegistry()
        let runID = UUID()
        let reservedHost = "fixture-\(runID.uuidString.lowercased()).hls.joesproxy.invalid"
        await registry.register(host: reservedHost, runID: runID, server: fixtureServer)

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store, fixtureOriginRegistry: registry)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.fixture-client", qos: .userInitiated)
        )

        let request =
            "GET http://\(reservedHost)/master.m3u8 HTTP/1.1\r\n" +
            "Host: \(reservedHost)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.hasPrefix("HTTP/1.1 200"), "Response was: \(responseString)")
        XCTAssertTrue(responseString.contains("#EXTM3U"), "Response was: \(responseString)")
        XCTAssertTrue(responseString.contains("#EXT-X-STREAM-INF"), "Response was: \(responseString)")

        _ = try await waitForCompletedSession(in: store)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.host, reservedHost)
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 200)
        XCTAssertEqual(store.sessions.first?.response?.source, .localOverride)

        connection.cancel()
        await server.stop()
    }

    func testHTTPProxyAcceptsJoePlayerDiagnosticPOSTOnReservedFixtureHost() async throws {
        let profileDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileDirectory.path),
            "Fixtures/HLS/baseline-aligned-codecs not present — run generate-profile.sh first."
        )

        let fixtureServer = HLSFixtureServer(profileDirectory: profileDirectory)
        let registry = HLSFixtureOriginRegistry()
        let runID = UUID()
        let reservedHost = "fixture-\(runID.uuidString.lowercased()).hls.joesproxy.invalid"
        await registry.register(host: reservedHost, runID: runID, server: fixtureServer)

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store, fixtureOriginRegistry: registry)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.joeplayer-diag", qos: .userInitiated)
        )

        let body = #"[{"kind":"probe","detail":"phase1"}]"#
        let request =
            "POST http://\(reservedHost)\(DiagnosticIngestionRoute.eventsPath) HTTP/1.1\r\n" +
            "Host: \(reservedHost)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n" +
            body

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(responseString.hasPrefix("HTTP/1.1 204"), "Response was: \(responseString)")

        _ = try await waitForCompletedSession(in: store)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.method.uppercased(), "POST")
        XCTAssertEqual(store.sessions.first?.request.path, DiagnosticIngestionRoute.eventsPath)
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 204)
        XCTAssertEqual(store.sessions.first?.response?.source, .localOverride)
        XCTAssertEqual(String(data: store.sessions.first?.request.bodyData ?? Data(), encoding: .utf8), body)

        connection.cancel()
        await server.stop()
    }

    /// P2-H1: reserved fixture dispatch must beat an enabled bookmark intercept targeting the same host.
    func testReservedFixtureOriginBeatsBookmarkResponseIntercept() async throws {
        let profileDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileDirectory.path),
            "Fixtures/HLS/baseline-aligned-codecs not present — run generate-profile.sh first."
        )

        let fixtureServer = HLSFixtureServer(profileDirectory: profileDirectory)
        let registry = HLSFixtureOriginRegistry()
        let runID = UUID()
        let reservedHost = "fixture-\(runID.uuidString.lowercased()).hls.joesproxy.invalid"
        await registry.register(host: reservedHost, runID: runID, server: fixtureServer)

        let bookmarkMarker = "BOOKMARK_WOULD_WIN_IF_CONSULTED"
        let bookmarkBody = Data("{\"marker\":\"\(bookmarkMarker)\"}".utf8)
        let bookmark = Bookmark(
            name: "Fixture Host Spoof",
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: reservedHost,
                port: 80,
                path: "/master.m3u8",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: bookmarkBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "marker",
                    originalValueSnapshot: bookmarkMarker,
                    overrideValue: .string(bookmarkMarker)
                )
            ],
            responseMatchMode: .exactPath
        )

        let interceptStore = BookmarkResponseInterceptStore()
        await interceptStore.syncBookmarks([bookmark])
        await interceptStore.setEnabledBookmarkIDs([bookmark.id])

        // ResponseOverrideStore must be present so that, absent fixture precedence, the
        // bookmark store would be consulted after `.noMatch` from Map Local.
        let store = InMemorySessionStore()
        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: ResponseOverrideStore(),
            bookmarkResponseInterceptStore: interceptStore,
            fixtureOriginRegistry: registry
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.fixture-vs-bookmark", qos: .userInitiated)
        )

        let request =
            "GET http://\(reservedHost)/master.m3u8 HTTP/1.1\r\n" +
            "Host: \(reservedHost)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.hasPrefix("HTTP/1.1 200"), "Response was: \(responseString)")
        XCTAssertTrue(responseString.contains("#EXTM3U"), "Fixture master must win; got: \(responseString)")
        XCTAssertTrue(responseString.contains("#EXT-X-STREAM-INF"), "Response was: \(responseString)")
        XCTAssertFalse(
            responseString.contains(bookmarkMarker),
            "Bookmark intercept must remain inert for reserved fixture hosts; got: \(responseString)"
        )

        _ = try await waitForCompletedSession(in: store)
        XCTAssertEqual(store.sessions.first?.response?.source, .localOverride)
        XCTAssertNotEqual(store.sessions.first?.response?.source, .bookmarkResponseRewrite)

        connection.cancel()
        await server.stop()
    }

    func testHTTPProxyCompletesResponseWithoutWaitingForUpstreamClose() async throws {
        let upstreamServer = SimpleHTTPTestServer(connectionHeader: "keep-alive", closeDelay: .seconds(1))
        try await upstreamServer.start()

        let server = makeServer()
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.keepalive-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/keepalive HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 2.0) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.contains("200 OK"))
        XCTAssertTrue(responseString.contains("Connection: keep-alive"))

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testHTTPProxyForwardsFullLargeResponseButRetainsBoundedBody() async throws {
        let responseBody = String(
            repeating: "x",
            count: RecordingConstants.liveCaptureBodySizeLimit + 512
        )
        let upstreamServer = SimpleHTTPTestServer(responseBody: responseBody)
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.large-response-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/large HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "Connection: close\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 10) {
            try await NetworkConnectionIO.receiveAll(on: connection)
        }

        XCTAssertGreaterThan(responseData.count, responseBody.utf8.count)

        let recordedSession = try await waitForCompletedSession(in: store, timeout: 10)

        XCTAssertEqual(recordedSession.response?.statusCode, 200)
        XCTAssertEqual(recordedSession.response?.bodySize, responseBody.utf8.count)
        XCTAssertEqual(recordedSession.response?.bodyData?.count, RecordingConstants.liveCaptureBodySizeLimit)
        XCTAssertTrue(recordedSession.response?.bodyTruncated == true)
        XCTAssertEqual(store.retainedBodyBytes, RecordingConstants.liveCaptureBodySizeLimit)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testDelayedReceiverLoopbackPreservesBytesAndDrainsAccounting() async throws {
        let body = String(repeating: "stream-check-", count: 524_288)
        let upstream = SimpleHTTPTestServer(responseBody: body)
        try await upstream.start()
        let server = makeServer()
        let baseline = RelayBacklogBudget.shared.snapshot
        do {
            try await server.start()
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
            defer { connection.cancel() }
            try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "memory.delayed.receiver"))
            let request = "GET http://127.0.0.1:\(upstream.port)/delayed HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\nConnection: close\r\n\r\n"
            try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
            try await Task.sleep(for: .milliseconds(250))
            let delayed = RelayBacklogBudget.shared.snapshot
            let response = try await withTimeout(seconds: 15) {
                try await NetworkConnectionIO.receiveAll(on: connection)
            }
            let headerEnd = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
            XCTAssertEqual(response.suffix(from: headerEnd.upperBound), Data(body.utf8))
            await server.stop()
            await upstream.stop()
            let drained = RelayBacklogBudget.shared.snapshot
            XCTAssertEqual(drained.bytes, baseline.bytes)
            XCTAssertEqual(drained.operations, baseline.operations)
            let evidence = XCTAttachment(string: "Real loopback, delayed receiver: responseBytes=\(body.utf8.count) delayMs=250 queuedAtDelay=\(delayed.bytes) cumulativePeakQueuedBytes=\(drained.peakBytes) finalQueuedBytes=\(drained.bytes) finalOperations=\(drained.operations). Cumulative peak includes earlier work in this process; not a heap measurement or proof of sustained saturation.")
            evidence.lifetime = .keepAlways
            add(evidence)
        } catch {
            await server.stop()
            await upstream.stop()
            throw error
        }
    }

    func testBookmarkRewriteSendsSavedBookmarkRequestUpstreamAndRecordsSource() async throws {
        let upstreamServer = SimpleHTTPTestServer(responseBody: "rewrite-response")
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let rewriteBody = Data("bookmark-body".utf8)
        let liveRequest = CapturedRequest(
            method: "POST",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(upstreamServer.port),
            path: "/live",
            headers: [],
            bodyData: Data("live-body".utf8),
            bodySize: "live-body".utf8.count
        )
        let savedBookmarkRequest = CapturedRequest(
            method: "POST",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(upstreamServer.port),
            path: "/rewritten",
            headers: [
                HTTPHeaderField(name: "X-Bookmark", value: "saved")
            ],
            bodyData: rewriteBody,
            bodySize: rewriteBody.count
        )
        try await responseOverrideStore.addRule(ResponseOverrideRule(
            requestMethod: liveRequest.method,
            requestScheme: liveRequest.scheme,
            host: liveRequest.host,
            port: liveRequest.port,
            path: liveRequest.path,
            sourceKind: .bookmarkRewrite,
            sourceDescription: "Rewritten from bookmark: POST 127.0.0.1/rewritten",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            bookmarkRewriteRequest: savedBookmarkRequest
        ))

        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: responseOverrideStore
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.rewrite-client", qos: .userInitiated)
        )

        let liveBody = "live-body"
        let request =
            "POST http://127.0.0.1:\(upstreamServer.port)/live HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "Content-Length: \(liveBody.utf8.count)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n" +
            liveBody

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.contains("200 OK"))
        XCTAssertTrue(responseString.contains("rewrite-response"))

        let recordedSession = try await waitForCompletedSession(in: store)

        let upstreamRequest = try XCTUnwrap(upstreamServer.lastRequestString)
        XCTAssertTrue(upstreamRequest.contains("POST /rewritten HTTP/1.1"))
        XCTAssertTrue(upstreamRequest.contains("X-Bookmark: saved"))
        XCTAssertTrue(upstreamRequest.contains("bookmark-body"))
        XCTAssertFalse(upstreamRequest.contains("live-body"))

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(recordedSession.request.path, "/live")
        XCTAssertEqual(recordedSession.response?.source, .bookmarkRewrite)
        XCTAssertEqual(recordedSession.response?.statusCode, 200)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testLiveResponseRewritePatchesUpstreamJSONAndRecordsSource() async throws {
        let upstreamBody = #"{"flag":false}"#
        let upstreamServer = SimpleHTTPTestServer(responseBody: upstreamBody)
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let liveRequest = CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(upstreamServer.port),
            path: "/live.json",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        try await responseOverrideStore.addLiveResponseRewriteRule(
            from: liveRequest,
            label: nil,
            rewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "flag",
                    overrideValue: .bool(true),
                    operation: .set
                )
            ]
        )

        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: responseOverrideStore
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.live-rewrite-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/live.json HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        if !responseString.contains("HTTP/1.1 200") {
            XCTFail("unexpected response (\(responseData.count) bytes): \(responseString)")
        }

        let recordedSession = try await waitForCompletedSession(in: store)
        let capturedBodyData = try XCTUnwrap(recordedSession.response?.bodyData)
        let capturedObject = try JSONSerialization.jsonObject(with: capturedBodyData) as? [String: Any]
        XCTAssertEqual(
            (capturedObject?["flag"] as? NSNumber)?.boolValue,
            true,
            "captured body was: \(String(decoding: capturedBodyData, as: UTF8.self))"
        )

        let responseBody = try XCTUnwrap(httpResponseBody(from: responseString))
        let parsedBody = try JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any]
        XCTAssertEqual(
            (parsedBody?["flag"] as? NSNumber)?.boolValue,
            true,
            "wire body was: \(responseBody)"
        )

        let upstreamRequest = try XCTUnwrap(upstreamServer.lastRequestString)
        XCTAssertTrue(upstreamRequest.contains("GET /live.json HTTP/1.1"))
        XCTAssertFalse(upstreamRequest.contains("/rewritten"))

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(recordedSession.request.path, "/live.json")
        XCTAssertEqual(recordedSession.response?.source, .liveResponseRewrite)
        XCTAssertEqual(recordedSession.response?.statusCode, 200)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    /// Regression coverage for a confirmed gap: `SyntheticCollectionInjectionEngine` was fully
    /// implemented and unit-tested (`SyntheticCollectionInjectionEngineTests.swift`) and its MCP
    /// tool (`propose_inject_synthetic_item`) could arm a plan, but nothing in the live proxy path
    /// ever called `processResponse` — a registered plan had zero effect on real traffic. Fixed by
    /// wiring it into `ConnectionHandler.executeUpstreamRequest` alongside `LiveResponseTransformation`
    /// (and converting the engine from `@MainActor` to a lock-protected class, mirroring
    /// `LiveTransformationActivationTracker`, since the hot path is synchronous NIO, not main-actor).
    /// This test proves the fix end-to-end: real wire traffic through the real proxy, not a direct
    /// engine call.
    func testSyntheticInjectionMutatesLiveProxyTraffic() async throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }

        let upstreamBody = #"{"channels":[{"id":"ch1","name":"Real Channel"}]}"#
        let upstreamServer = SimpleHTTPTestServer(responseBody: upstreamBody)
        try await upstreamServer.start()

        let plan = SyntheticCollectionInjectionPlan(
            name: "Live Wire Injection Test",
            urlPattern: "*/epg/channels*",
            collectionKeypath: "$.channels",
            position: .prepend,
            fieldOverrides: ["name": "JoesProxy Synthetic Channel"],
            clientScope: .allClients
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)

        let store = InMemorySessionStore()
        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: ResponseOverrideStore()
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.synthetic-injection-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/epg/channels HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"
        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)
        if !responseString.contains("HTTP/1.1 200") {
            XCTFail("unexpected response (\(responseData.count) bytes): \(responseString)")
        }

        let responseBody = try XCTUnwrap(httpResponseBody(from: responseString))
        let parsedBody = try JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any]
        let channels = try XCTUnwrap(parsedBody?["channels"] as? [[String: Any]])
        XCTAssertEqual(channels.count, 2, "expected the real channel plus one synthetic injection, wire body was: \(responseBody)")
        XCTAssertEqual(channels.first?["name"] as? String, "JoesProxy Synthetic Channel")
        XCTAssertEqual(channels.last?["name"] as? String, "Real Channel")

        let recordedSession = try await waitForCompletedSession(in: store)
        let capturedBodyData = try XCTUnwrap(recordedSession.response?.bodyData)
        let capturedObject = try JSONSerialization.jsonObject(with: capturedBodyData) as? [String: Any]
        let capturedChannels = try XCTUnwrap(capturedObject?["channels"] as? [[String: Any]])
        XCTAssertEqual(capturedChannels.count, 2, "captured session body should reflect the injected item too")

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testLiveResponseRewriteFailOpenWhenMutationDoesNotApply() async throws {
        let upstreamBody = #"{"flag":false}"#
        let upstreamServer = SimpleHTTPTestServer(responseBody: upstreamBody)
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let liveRequest = CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(upstreamServer.port),
            path: "/live.json",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        try await responseOverrideStore.addLiveResponseRewriteRule(
            from: liveRequest,
            label: nil,
            rewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "$.missing.path",
                    overrideValue: .bool(true),
                    operation: .set
                )
            ]
        )

        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: responseOverrideStore
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.live-rewrite-failopen-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/live.json HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let responseData = try await withTimeout(seconds: 3) {
            let (data, _) = try await NetworkConnectionIO.receive(on: connection)
            return data
        }
        let responseString = String(decoding: responseData, as: UTF8.self)

        XCTAssertTrue(responseString.contains("200 OK"))
        XCTAssertTrue(responseString.contains(upstreamBody))

        let recordedSession = try await waitForCompletedSession(in: store)
        XCTAssertEqual(recordedSession.response?.source, .liveResponseRewrite)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    /// End-to-end gold-standard verification for `we-must-do-aj-2-jazzy-galaxy.md`'s Phase 9 — the
    /// literal ADR acceptance criterion: append "!" to every EPG program title via a wildcard
    /// selector, prove the change against real upstream traffic while sibling fields (ids) are
    /// untouched, prove idempotency on a repeated hit, then disable and prove fresh traffic reverts
    /// to byte-identical upstream output. The MCP tool-layer dispatch (propose/apply/preview/
    /// activate argument parsing, disclosure text, policy gating) is already covered by the
    /// wildcard-specific tests added to `MCPMutationToolsTests`/`MCPOpenWorldToolsTests` in Phase 8
    /// — this test instead proves the runtime behavior those tools ultimately trigger
    /// (`ResponseOverrideStore.setEnabled` + `ConnectionHandler`'s live-transform call site) against
    /// a real proxied HTTP round trip, which no existing test covers for a wildcard selector.
    func testEPGGoldStandardWildcardAppendStringLiveRewriteAgainstRealTraffic() async throws {
        let originalBody = #"""
        {"channels":[{"id":"c1","programs":[{"id":"p1","title":"News Hour"},{"id":"p2","title":"Morning Show"}]},{"id":"c2","programs":[{"id":"p3","title":"Late Night"}]}]}
        """#
        let upstreamServer = SimpleHTTPTestServer(responseBody: originalBody)
        try await upstreamServer.start()

        let store = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let liveRequest = CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(upstreamServer.port),
            path: "/epg.json",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "$.channels[*].programs[*].title",
            overrideValue: .string("!"),
            operation: .appendString,
            isRuleEnabled: true,
            repeatPolicy: .ifMissingSuffix
        )
        // Created disabled — mirrors what `apply_create_live_rewrite` persists before any human
        // approval to activate: no live effect until explicitly enabled below.
        let rule = ResponseOverrideRule(
            label: "epg-title-bang",
            requestMethod: liveRequest.method,
            requestScheme: liveRequest.scheme,
            host: liveRequest.host,
            port: liveRequest.port,
            path: liveRequest.path,
            matchMode: .exactPath,
            sourceKind: .liveResponseRewrite,
            sourceDescription: LiveResponseRewriteDescriptions.ruleSourceDescription(rewrites: [rewrite]),
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            liveResponseRewrites: [rewrite]
        )
        try await responseOverrideStore.addRule(rule)

        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: responseOverrideStore
        )
        try await server.start()

        func fetchEPG() async throws -> String {
            let connection = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: server.port)!,
                using: .tcp
            )
            try await NetworkConnectionIO.start(
                connection,
                on: DispatchQueue(label: "com.joesproxyapp.tests.epg-gold-standard", qos: .userInitiated)
            )
            let request =
                "GET http://127.0.0.1:\(upstreamServer.port)/epg.json HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
                "User-Agent: JoesProxyTests\r\n" +
                "\r\n"
            try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
            let responseData = try await withTimeout(seconds: 3) {
                let (data, _) = try await NetworkConnectionIO.receive(on: connection)
                return data
            }
            connection.cancel()
            let responseString = String(decoding: responseData, as: UTF8.self)
            guard responseString.contains("HTTP/1.1 200") else {
                XCTFail("unexpected response (\(responseData.count) bytes): \(responseString)")
                return ""
            }
            return try XCTUnwrap(httpResponseBody(from: responseString))
        }

        func titles(in bodyText: String) throws -> [String] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any])
            let channels = try XCTUnwrap(object["channels"] as? [[String: Any]])
            return channels.flatMap { channel -> [String] in
                let programs = channel["programs"] as? [[String: Any]] ?? []
                return programs.compactMap { $0["title"] as? String }
            }
        }

        func ids(in bodyText: String) throws -> [String] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any])
            let channels = try XCTUnwrap(object["channels"] as? [[String: Any]])
            return channels.flatMap { channel -> [String] in
                var result = [channel["id"] as? String ?? ""]
                let programs = channel["programs"] as? [[String: Any]] ?? []
                result += programs.compactMap { $0["id"] as? String }
                return result
            }
        }

        // Step 1: created disabled — real traffic through the proxy is untouched.
        let beforeActivationBody = try await fetchEPG()
        XCTAssertEqual(beforeActivationBody, originalBody)

        // Step 2: activate (mirrors `activate_live_rewrite`'s `setEnabled(true, for:)` call).
        try await responseOverrideStore.setEnabled(true, for: rule.id)

        // Step 3: real traffic now shows every title patched, sibling id fields untouched.
        let firstPatchedBody = try await fetchEPG()
        XCTAssertEqual(try titles(in: firstPatchedBody), ["News Hour!", "Morning Show!", "Late Night!"])
        XCTAssertEqual(try ids(in: firstPatchedBody), ["c1", "p1", "p2", "c2", "p3"])

        // Step 4: a second hit proves `.ifMissingSuffix` idempotency — no "!!" accumulation, since
        // the upstream itself never changes and is patched fresh on every request.
        let secondPatchedBody = try await fetchEPG()
        XCTAssertEqual(try titles(in: secondPatchedBody), ["News Hour!", "Morning Show!", "Late Night!"])

        // Step 5: deactivate (mirrors the disable-rule tool's `setEnabled(false, for:)` call) and
        // prove fresh traffic reverts to byte-identical upstream output — no residual patching.
        try await responseOverrideStore.setEnabled(false, for: rule.id)
        let afterDeactivationBody = try await fetchEPG()
        XCTAssertEqual(afterDeactivationBody, originalBody)

        await server.stop()
        await upstreamServer.stop()
    }

    func testBookmarkResponseRewriteServesPatchedSnapshotWithoutUpstream() async throws {
        let upstreamServer = SimpleHTTPTestServer(responseBody: "upstream-should-not-be-used")
        try await upstreamServer.start()

        let interceptStore = BookmarkResponseInterceptStore()
        let originalBody = Data(#"{"appConfig":{"ad_variant_keys_enabled":"true"}}"#.utf8)
        let bookmark = Bookmark(
            name: "Status",
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "127.0.0.1",
                port: Int(upstreamServer.port),
                path: "/status.json?locale=en",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: originalBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "appConfig.ad_variant_keys_enabled",
                    originalValueSnapshot: "true",
                    overrideValue: .string("false")
                )
            ],
            responseMatchMode: .ignoreQuery
        )
        await interceptStore.syncBookmarks([bookmark])
        await interceptStore.setEnabledBookmarkIDs([bookmark.id])

        let store = InMemorySessionStore()
        let server = makeServer(
            sessionStore: store,
            responseOverrideStore: ResponseOverrideStore(),
            bookmarkResponseInterceptStore: interceptStore
        )
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.bookmark-response-client", qos: .userInitiated)
        )

        let request =
            "GET http://127.0.0.1:\(upstreamServer.port)/status.json?locale=fr HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
            "Connection: close\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        let (responseData, _) = try await NetworkConnectionIO.receive(on: connection)
        let responseText = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(responseText.contains("200"))
        XCTAssertTrue(responseText.contains(#""ad_variant_keys_enabled":"false"#) || responseText.contains(#""ad_variant_keys_enabled": "false"#))

        let recordedSession = try await waitForCompletedSession(in: store)
        XCTAssertEqual(recordedSession.response?.source, .bookmarkResponseRewrite)
        XCTAssertNil(upstreamServer.lastRequestString)

        connection.cancel()
        await server.stop()
        await upstreamServer.stop()
    }

    func testConnectTunnelPassesThroughTrafficAndRecordsSession() async throws {
        let echoServer = SimpleTCPEchoServer()
        try await echoServer.start()

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store, httpsProxyMode: .passThrough)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.connect-client", qos: .userInitiated)
        )

        let connectRequest =
            "CONNECT 127.0.0.1:\(echoServer.port) HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(echoServer.port)\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(connectRequest.utf8), on: connection)
        let (establishedData, _) = try await NetworkConnectionIO.receive(on: connection)
        let establishedResponse = String(decoding: establishedData, as: UTF8.self)
        XCTAssertTrue(establishedResponse.contains("200 Connection Established"))

        for message in ["ping-1", "ping-2", "ping-3"] {
            try await NetworkConnectionIO.send(Data(message.utf8), on: connection)
            let (echoData, _) = try await NetworkConnectionIO.receive(on: connection)
            XCTAssertEqual(String(decoding: echoData, as: UTF8.self), message)
        }

        connection.cancel()
        _ = try await waitForCompletedSession(in: store)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.method, "CONNECT")
        XCTAssertEqual(store.sessions.first?.request.scheme, .https)
        XCTAssertNil(store.sessions.first?.request.bodyData)
        XCTAssertNil(store.sessions.first?.response?.bodyData)
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 200)
        XCTAssertEqual(store.retainedBodyBytes, 0)

        await server.stop()
        await echoServer.stop()
    }

    func testConnectTunnelHandlesManyPayloadsWithoutRetainingBodies() async throws {
        let echoServer = SimpleTCPEchoServer()
        try await echoServer.start()

        let store = InMemorySessionStore()
        let server = makeServer(sessionStore: store, httpsProxyMode: .passThrough)
        try await server.start()

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )

        try await NetworkConnectionIO.start(
            connection,
            on: DispatchQueue(label: "com.joesproxyapp.tests.connect-soak-client", qos: .userInitiated)
        )

        let connectRequest =
            "CONNECT 127.0.0.1:\(echoServer.port) HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(echoServer.port)\r\n" +
            "\r\n"

        try await NetworkConnectionIO.send(Data(connectRequest.utf8), on: connection)
        let (establishedData, _) = try await NetworkConnectionIO.receive(on: connection)
        XCTAssertTrue(String(decoding: establishedData, as: UTF8.self).contains("200 Connection Established"))

        for index in 0..<50 {
            let message = Data("connect-payload-\(index)-\(String(repeating: "x", count: 256))".utf8)
            try await NetworkConnectionIO.send(message, on: connection)
            let echoData = try await receiveExactly(byteCount: message.count, on: connection)
            XCTAssertEqual(echoData, message)
        }

        connection.cancel()
        _ = try await waitForCompletedSession(in: store)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.method, "CONNECT")
        XCTAssertEqual(store.sessions.first?.state, .completed)
        XCTAssertNil(store.sessions.first?.request.bodyData)
        XCTAssertNil(store.sessions.first?.response?.bodyData)
        XCTAssertEqual(store.retainedBodyBytes, 0)

        await server.stop()
        await echoServer.stop()
    }

    func testServerStartFailsWithoutChangingRequestedPortWhenPortIsInUse() async throws {
        let occupiedPort = UInt16.random(in: 20_000...60_000)
        let firstServer = ProxyServer(port: occupiedPort)
        try await firstServer.start()

        let server = ProxyServer(port: occupiedPort)

        do {
            try await server.start()
            XCTFail("Expected port bind failure")
        } catch let error as ProxyError {
            if case let .startFailed(reason) = error {
                XCTAssertFalse(reason.isEmpty)
            } else {
                XCTFail("Expected startFailed but received \(error)")
            }
            XCTAssertEqual(server.port, occupiedPort)
            XCTAssertFalse(server.isRunning)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await firstServer.stop()
    }

    func testInterceptedTLSUploadSpoolsAndPreservesBody() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/TLSUploadTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = PersistentCertificateAuthorityProvider(
            configuration: TestProxyConfiguration(proxyPort: 0, logLevel: .info,
                certificateLabel: "SyntheticUpload-\(UUID().uuidString)"),
            certificateStore: UploadTLSCertificateStore())
        let root = try authority.loadOrCreateRootCertificate()
        let upstream = SimpleHTTPSTestServer(leafCertificate: try authority.issueLeafCertificate(for: "localhost"),
                                           echoDigest: true)
        let service = UploadSpoolService(directory: directory)
        let proxy = ProxyServer(port: 0, httpsProxyMode: .intercepting, certificateAuthority: authority,
            upstreamConnectorConfiguration: HTTPUpstreamConnectorConfiguration(trustedRootCertificates: [root.certificateData]),
            uploadSpoolService: service)
        var client: InterceptingHTTPSTestClient?
        do {
            try await upstream.start()
            try await proxy.start()
            let connected = try await InterceptingHTTPSTestClient.connect(port: proxy.port,
                trustedRootCertificates: [root.certificateData])
            client = connected
            let body = String(repeating: "synthetic-upload-", count: 65_536)
            let response = try await connected.performInterceptedRequest(targetHost: "localhost", targetPort: upstream.port,
                request: "POST /upload HTTP/1.1\r\nHost: localhost:\(upstream.port)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
            let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
            XCTAssertTrue(response.hasSuffix(digest))
            try? await connected.close()
            await proxy.stop()
            await upstream.stop()
        } catch {
            try? await client?.close()
            await proxy.stop()
            await upstream.stop()
            throw error
        }
        XCTAssertEqual(service.budget.peakCount, 1)
        XCTAssertEqual(service.budget.activeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSSLHandshake() async throws {
        let certificateLabel = "InterceptingRoot-\(UUID().uuidString)"
        let configuration = TestProxyConfiguration(
            proxyPort: UInt16.random(in: 20_000...60_000),
            logLevel: .info,
            certificateLabel: certificateLabel
        )
        let certificateStore = PersistentKeychainCertificateStore()
        let certificateAuthority = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: certificateStore
        )

        let root = try certificateAuthority.loadOrCreateRootCertificate()
        let upstreamLeaf = try certificateAuthority.issueLeafCertificate(for: "127.0.0.1")
        let upstreamServer = SimpleHTTPSTestServer(leafCertificate: upstreamLeaf)
        try await upstreamServer.start()

        let sessionStore = InMemorySessionStore()
        let server = makeServer(
            sessionStore: sessionStore,
            httpsProxyMode: .intercepting,
            certificateAuthority: certificateAuthority,
            trustedRootCertificates: [root.certificateData]
        )
        try await server.start()

        let client = try await InterceptingHTTPSTestClient.connect(
            port: server.port,
            trustedRootCertificates: [root.certificateData]
        )

        let secureResponse = try await client.performInterceptedRequest(
            targetHost: "127.0.0.1",
            targetPort: upstreamServer.port,
            request:
                "GET /secure HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(upstreamServer.port)\r\n" +
                "User-Agent: JoesProxyTests\r\n" +
                "\r\n"
        )

        XCTAssertTrue(secureResponse.contains("200 OK"))
        XCTAssertTrue(secureResponse.contains("secure-response"))

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertEqual(sessionStore.sessions.first?.request.scheme, .https)
        XCTAssertEqual(sessionStore.sessions.first?.request.path, "/secure")
        XCTAssertEqual(sessionStore.sessions.first?.response?.statusCode, 200)
        XCTAssertEqual(sessionStore.sessions.first?.state, .completed)

        try await client.close()
        await server.stop()
        await upstreamServer.stop()
        try certificateStore.removeRootCertificate(label: certificateLabel)
    }

    // MARK: - AR: No-caching applied to Map Local/Block/fixture responses

    /// Previously `NoCachingPolicy` was only ever invoked for real upstream round-trips (Map
    /// Remote, live rewrite) — `serveResolvedOverride` (Map Local/Block/fixture) never called it,
    /// even when the global Settings toggle was on. This proves the global/per-domain policy now
    /// also reaches locally-served overrides.
    func testApplyingNoCachingPolicyStripsHeadersWhenGloballyEnabled() {
        let resolvedOverride = ResolvedResponseOverride(
            ruleID: UUID(),
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "image/webp"),
                HTTPHeaderField(name: "ETag", value: "\"abc123\""),
                HTTPHeaderField(name: "Cache-Control", value: "max-age=86400, public")
            ],
            bodyData: Data("stub".utf8),
            sourceKind: .localFile,
            sourceDescription: "test"
        )
        let configuration = TestProxyConfiguration(
            proxyPort: UInt16.random(in: 20_000...60_000),
            logLevel: .info,
            certificateLabel: "test-\(UUID().uuidString)"
        )
        configuration.isNoCachingEnabled = true

        let result = ProxyConnectionHandler.applyingNoCachingPolicyIfNeeded(
            to: resolvedOverride,
            requestHost: "cdn.example.com",
            configuration: configuration
        )

        XCTAssertFalse(result.headers.contains { $0.name.caseInsensitiveCompare("ETag") == .orderedSame })
        XCTAssertTrue(result.headers.contains {
            $0.name.caseInsensitiveCompare("Cache-Control") == .orderedSame && $0.value == "no-store, no-cache, must-revalidate"
        })
        // Content-Type and the body/rule identity must survive untouched.
        XCTAssertTrue(result.headers.contains { $0.name == "Content-Type" && $0.value == "image/webp" })
        XCTAssertEqual(result.bodyData, resolvedOverride.bodyData)
        XCTAssertEqual(result.ruleID, resolvedOverride.ruleID)
    }

    /// A rule's own `forceNoCache` flag must strip caching headers even when the global/per-domain
    /// Settings toggle is off — this is the actual new per-rule capability (AR), not just wiring the
    /// existing global setting through.
    func testApplyingNoCachingPolicyStripsHeadersWhenRuleForcesNoCacheRegardlessOfGlobalSetting() {
        let resolvedOverride = ResolvedResponseOverride(
            ruleID: UUID(),
            statusCode: 200,
            headers: [HTTPHeaderField(name: "ETag", value: "\"abc123\"")],
            bodyData: nil,
            sourceKind: .localFile,
            sourceDescription: "test",
            forceNoCache: true
        )
        let configuration = TestProxyConfiguration(
            proxyPort: UInt16.random(in: 20_000...60_000),
            logLevel: .info,
            certificateLabel: "test-\(UUID().uuidString)"
        )
        configuration.isNoCachingEnabled = false
        configuration.noCachingDomains = []

        let result = ProxyConnectionHandler.applyingNoCachingPolicyIfNeeded(
            to: resolvedOverride,
            requestHost: "cdn.example.com",
            configuration: configuration
        )

        XCTAssertFalse(result.headers.contains { $0.name.caseInsensitiveCompare("ETag") == .orderedSame })
    }

    /// Baseline: when neither the global setting nor the rule's own flag apply, headers pass
    /// through completely unchanged — confirms this is opt-in, not a behavior change for existing
    /// rules that never asked for it.
    func testApplyingNoCachingPolicyLeavesHeadersUntouchedWhenNeitherGlobalNorRuleApplies() {
        let originalHeaders = [HTTPHeaderField(name: "ETag", value: "\"abc123\"")]
        let resolvedOverride = ResolvedResponseOverride(
            ruleID: UUID(),
            statusCode: 200,
            headers: originalHeaders,
            bodyData: nil,
            sourceKind: .localFile,
            sourceDescription: "test"
        )
        let configuration = TestProxyConfiguration(
            proxyPort: UInt16.random(in: 20_000...60_000),
            logLevel: .info,
            certificateLabel: "test-\(UUID().uuidString)"
        )
        configuration.isNoCachingEnabled = false

        let result = ProxyConnectionHandler.applyingNoCachingPolicyIfNeeded(
            to: resolvedOverride,
            requestHost: "cdn.example.com",
            configuration: configuration
        )

        XCTAssertEqual(result.headers, originalHeaders)
    }
}

private final class SimpleHTTPTestServer {
    private let queue = DispatchQueue(label: "com.joesproxyapp.tests.upstream", qos: .userInitiated)
    private var listener: NWListener?
    private let responseBody: String
    private let connectionHeader: String
    private let closeDelay: Duration
    private let lock = NSLock()
    private var requestData: Data?

    init(
        responseBody: String = "proxy-test-response",
        connectionHeader: String = "close",
        closeDelay: Duration = .zero
    ) {
        self.responseBody = responseBody
        self.connectionHeader = connectionHeader
        self.closeDelay = closeDelay
    }

    var port: UInt16 {
        listener?.port?.rawValue ?? 0
    }

    var lastRequestString: String? {
        lock.withLock {
            requestData.flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let responseBody = self.responseBody
        let connectionHeader = self.connectionHeader
        let closeDelay = self.closeDelay

        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
                if let data {
                    self?.lock.withLock {
                        self?.requestData = data
                    }
                }
                let response =
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: text/plain\r\n" +
                    "Content-Length: \(responseBody.utf8.count)\r\n" +
                    "Connection: \(connectionHeader)\r\n" +
                    "\r\n" +
                    responseBody
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    Task {
                        if closeDelay > .zero {
                            try? await Task.sleep(for: closeDelay)
                        }
                        connection.cancel()
                    }
                })
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            let state = SimpleListenerState()

            listener.stateUpdateHandler = { stateUpdate in
                guard !state.didResume else {
                    return
                }

                switch stateUpdate {
                case .ready:
                    state.didResume = true
                    continuation.resume()
                case .failed(let error):
                    state.didResume = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.didResume = true
                    continuation.resume(throwing: ProxyError.stopFailed)
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }
}

private final class SimpleTCPEchoServer {
    private let queue = DispatchQueue(label: "com.joesproxyapp.tests.echo", qos: .userInitiated)
    private var listener: NWListener?

    var port: UInt16 {
        listener?.port?.rawValue ?? 0
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            self.receiveLoop(on: connection)
        }

        try await withCheckedThrowingContinuation { continuation in
            let state = SimpleListenerState()

            listener.stateUpdateHandler = { stateUpdate in
                guard !state.didResume else {
                    return
                }

                switch stateUpdate {
                case .ready:
                    state.didResume = true
                    continuation.resume()
                case .failed(let error):
                    state.didResume = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.didResume = true
                    continuation.resume(throwing: ProxyError.stopFailed)
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if error != nil || isComplete {
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                self.receiveLoop(on: connection)
                return
            }

            connection.send(content: data, completion: .contentProcessed { _ in
                self.receiveLoop(on: connection)
            })
        }
    }
}

private final class UploadTLSCertificateStore: CertificateStore {
    private var roots: [String: RootCertificateIdentity] = [:]
    func loadRootCertificate(label: String) -> RootCertificateIdentity? { roots[label] }
    func saveRootCertificate(_ identity: RootCertificateIdentity) throws { roots[identity.label] = identity }
    func removeRootCertificate(label: String) throws { roots.removeValue(forKey: label) }
}

private final class ScriptedDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [EventLoopPromise<Void>] = []
    private var released = false
    var isWaiting: Bool { lock.withLock { !pending.isEmpty } }
    func wait(on loop: EventLoop) -> EventLoopFuture<Void> {
        let promise = loop.makePromise(of: Void.self)
        let ready = lock.withLock {
            if released { return true }
            pending.append(promise)
            return false
        }
        if ready { promise.succeed(()) }
        return promise.futureResult
    }
    func release() {
        let promises = lock.withLock {
            released = true
            let promises = pending
            pending.removeAll()
            return promises
        }
        promises.forEach { $0.succeed(()) }
    }
}

private final class SimpleHTTPSTestServer {
    private let tlsGate: ScriptedDeliveryGate?
    private let responseGate: ScriptedDeliveryGate?
    private let scripted: [String: Data]
    let scriptedCounter = ScriptedOriginCounter()
    private let pacedRanges: Bool
    private let echoDigest: Bool
    private let responseBody: String
    private let leafCertificate: IssuedLeafCertificate
    private let requestParser = HTTPRequestParser()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    init(responseBody: String = "secure-response", leafCertificate: IssuedLeafCertificate, echoDigest: Bool = false, pacedRanges: Bool = false, scripted: [String: Data] = [:], tlsGate: ScriptedDeliveryGate? = nil, responseGate: ScriptedDeliveryGate? = nil) {
        self.tlsGate = tlsGate
        self.responseGate = responseGate
        self.scripted = scripted
        self.pacedRanges = pacedRanges
        self.echoDigest = echoDigest
        self.responseBody = responseBody
        self.leafCertificate = leafCertificate
    }

    var port: UInt16 {
        guard let port = channel?.localAddress?.port else {
            return 0
        }
        return UInt16(port)
    }

    func start() async throws {
        let certificate = try NIOSSLCertificate(bytes: Array(leafCertificate.certificateData), format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(leafCertificate.privateKeyData), format: .pem)
        let tlsContext = try NIOSSLContext(
            configuration: TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(certificate)],
                privateKey: .privateKey(privateKey)
            )
        )
        let responseBody = self.responseBody
        let requestParser = self.requestParser
        let echoDigest = self.echoDigest
        let pacedRanges = self.pacedRanges
        let scripted = self.scripted
        let counter = scriptedCounter
        let tlsGate = self.tlsGate
        let responseGate = self.responseGate

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let ready = tlsGate?.wait(on: channel.eventLoop) ?? channel.eventLoop.makeSucceededFuture(())
                return ready.flatMap { channel.pipeline.addHandlers([
                    NIOSSLServerHandler(context: tlsContext),
                    SimpleHTTPSResponder(responseBody: responseBody, requestParser: requestParser, echoDigest: echoDigest, pacedRanges: pacedRanges, scripted: scripted, counter: counter, responseGate: responseGate)
                ]) }
            }

        channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async {
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        try? await group.shutdownGracefully()
    }
}

private final class SimpleHTTPSResponder: ChannelInboundHandler {
    private let responseGate: ScriptedDeliveryGate?
    private let scripted: [String: Data]
    private let counter: ScriptedOriginCounter?
    private let pacedRanges: Bool
    private var pendingChunk: Scheduled<Void>?
    private let echoDigest: Bool
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let responseBody: String
    private let requestParser: HTTPRequestParser
    private var buffer = Data()

    init(responseBody: String, requestParser: HTTPRequestParser, echoDigest: Bool = false, pacedRanges: Bool = false, scripted: [String: Data] = [:], counter: ScriptedOriginCounter? = nil, responseGate: ScriptedDeliveryGate? = nil) {
        self.responseGate = responseGate
        self.scripted = scripted
        self.counter = counter
        self.pacedRanges = pacedRanges
        self.echoDigest = echoDigest
        self.responseBody = responseBody
        self.requestParser = requestParser
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var byteBuffer = unwrapInboundIn(data)
        if let bytes = byteBuffer.readBytes(length: byteBuffer.readableBytes) {
            buffer.append(contentsOf: bytes)
        }

        guard requestParser.isCompleteRequest(buffer) else {
            return
        }

        let framingRequest = String(decoding: buffer, as: UTF8.self)
        if framingRequest.contains("X-Synthetic-Sequential: yes") {
            guard let request = try? requestParser.parseRequestFrame(buffer).request else {
                context.close(promise: nil)
                return
            }
            let body = request.path
            buffer.removeAll()
            counter?.observe()
            let ready = responseGate?.wait(on: context.eventLoop) ?? context.eventLoop.makeSucceededFuture(())
            ready.whenSuccess {
                var wire = context.channel.allocator.buffer(capacity: 256)
                wire.writeString("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n\(body)")
                context.writeAndFlush(self.wrapOutboundOut(wire), promise: nil)
            }
            return
        }
        if let line = framingRequest.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("X-Synthetic-Case: ") }),
           let wire = scripted[String(line.dropFirst("X-Synthetic-Case: ".count))] {
            counter?.observe()
            var first = context.channel.allocator.buffer(capacity: 17)
            first.writeBytes(wire.prefix(17))
            context.writeAndFlush(wrapOutboundOut(first)).whenSuccess {
                self.pendingChunk = context.eventLoop.scheduleTask(in: .milliseconds(3)) {
                    self.pendingChunk = nil
                    self.sendPaced(wire, offset: 17, context: context)
                }
            }
            return
        }
        if framingRequest.contains("X-Synthetic-Framing:") {
            let truncated = framingRequest.contains("X-Synthetic-Framing: truncated")
            let body = truncated ? "4\r\nte" : "4;test=yes\r\ntest\r\n0\r\nChecksum: synthetic\r\n\r\n"
            var wire = context.channel.allocator.buffer(capacity: 256)
            wire.writeString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n" + body)
            context.writeAndFlush(wrapOutboundOut(wire)).whenComplete { _ in
                if truncated { context.close(promise: nil) }
            }
            return
        }
        if pacedRanges {
            let request = String(decoding: buffer, as: UTF8.self)
            let full = Data(responseBody.utf8)
            let selected: Data
            let status: String
            let rangeHeader: String
            if request.contains("Range: bytes=32768-98303") {
                selected = full.subdata(in: 32768..<98304)
                status = "206 Partial Content"
                rangeHeader = "Content-Range: bytes 32768-98303/\(full.count)\r\n"
            } else if request.contains("Range:") {
                selected = Data(); status = "416 Range Not Satisfiable"
                rangeHeader = "Content-Range: bytes */\(full.count)\r\n"
            } else { selected = full; status = "200 OK"; rangeHeader = "" }
            var wire = Data("HTTP/1.1 \(status)\r\nContent-Length: \(selected.count)\r\n\(rangeHeader)Connection: close\r\n\r\n".utf8)
            wire.append(selected)
            if request.contains("X-Synthetic-Disconnect: true") {
                var partial = context.channel.allocator.buffer(capacity: 16_384)
                partial.writeBytes(wire.prefix(16_384))
                context.writeAndFlush(wrapOutboundOut(partial)).whenComplete { _ in context.close(promise: nil) }
                return
            }
            sendPaced(wire, offset: 0, context: context)
            return
        }
        let responseBody: String
        if echoDigest, let request = try? requestParser.parseRequestFrame(buffer).request {
            responseBody = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
        } else { responseBody = self.responseBody }
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(responseBody.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n" +
            responseBody

        var outbound = context.channel.allocator.buffer(capacity: response.utf8.count)
        outbound.writeString(response)
        context.writeAndFlush(wrapOutboundOut(outbound)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
    private func sendPaced(_ wire: Data, offset: Int, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        let end = min(offset + 16_384, wire.count)
        var chunk = context.channel.allocator.buffer(capacity: end - offset)
        chunk.writeBytes(wire[offset..<end])
        context.writeAndFlush(wrapOutboundOut(chunk)).whenComplete { result in
            guard case .success = result, end < wire.count else { context.close(promise: nil); return }
            self.pendingChunk = context.eventLoop.scheduleTask(in: .milliseconds(3)) {
                self.pendingChunk = nil
                self.sendPaced(wire, offset: end, context: context)
            }
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) { pendingChunk?.cancel(); pendingChunk = nil }

}

private final class SyntheticSlowReadHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var pendingRead: Scheduled<Void>?
    private(set) var completedReads = 0
    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        guard pendingRead == nil else { return }
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
            self.pendingRead = context.eventLoop.scheduleTask(in: .milliseconds(5)) {
                self.pendingRead = nil
                self.completedReads += 1
                if context.channel.isActive { context.read() }
            }
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) { pendingRead?.cancel(); pendingRead = nil }
}

private final class InterceptingHTTPSTestClient {
    private var established = false
    // One sequential request per client. Collector timestamps are read on its event loop.
    private(set) var proxyConnectSeconds: Double = 0
    private(set) var tlsInstallationSeconds: Double = 0
    private var slowReadHandler: SyntheticSlowReadHandler?
    func observedSlowReadCycles() async throws -> Int {
        try await channel.eventLoop.submit { self.slowReadHandler?.completedReads ?? 0 }.get()
    }
    func observedReadGap() async throws -> Double {
        try await channel.eventLoop.submit { self.collector.maximumReadGap }.get()
    }
    func observedResponseStages() async throws -> (waitSeconds: Double, firstByteSeconds: Double?, bodySeconds: Double?) {
        try await channel.eventLoop.submit { self.collector.responseStages }.get()
    }
    private let trustedRootCertificates: [Data]
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let collector: TestClientCollector

    private init(
        trustedRootCertificates: [Data],
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        collector: TestClientCollector
    ) {
        self.trustedRootCertificates = trustedRootCertificates
        self.group = group
        self.channel = channel
        self.collector = collector
    }

    static func connect(port: UInt16, trustedRootCertificates: [Data]) async throws -> InterceptingHTTPSTestClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = TestClientCollector()
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(collector)
            }

        let channel = try await bootstrap.connect(host: "127.0.0.1", port: Int(port)).get()
        return InterceptingHTTPSTestClient(
            trustedRootCertificates: trustedRootCertificates,
            group: group,
            channel: channel,
            collector: collector
        )
    }

    func performInterceptedRequest(targetHost: String, targetPort: UInt16, request: String, direct: Bool = false, slowReceiver: Bool = false) async throws -> String {
        let bytes = try await performBytes(targetHost: targetHost, targetPort: targetPort, request: request,
            direct: direct, slowReceiver: slowReceiver)
        return String(decoding: bytes, as: UTF8.self)
    }

    func performBytes(targetHost: String, targetPort: UInt16, request: String, direct: Bool = false,
                      slowReceiver: Bool = false, expectedBodyBytes: Int? = nil, waitForEOF: Bool = false) async throws -> Data {
        let setupStarted = ProcessInfo.processInfo.systemUptime
        if !established {
        if !direct {
        let connectRequest =
            "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\n" +
            "Host: \(targetHost):\(targetPort)\r\n" +
            "\r\n"

        let connectResponseFuture = collector.nextData(
            matching: { $0.range(of: Data("\r\n\r\n".utf8)) != nil },
            on: channel
        )
        try await write(connectRequest)
        let connectResponse = try await connectResponseFuture.get()
        XCTAssertTrue(String(decoding: connectResponse, as: UTF8.self).contains("200 Connection Established"))
        proxyConnectSeconds = ProcessInfo.processInfo.systemUptime - setupStarted
        }

        let tlsStarted = ProcessInfo.processInfo.systemUptime
        let additionalTrustRoots = try trustedRootCertificates.map {
            try NIOSSLCertificate(bytes: Array($0), format: .der)
        }
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.trustRoots = .certificates(additionalTrustRoots)
        let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
        let tlsHandler = try NIOSSLClientHandler(context: tlsContext, serverHostname: targetHost)
        try await channel.pipeline.addHandler(tlsHandler, position: .first).get()
        tlsInstallationSeconds = ProcessInfo.processInfo.systemUptime - tlsStarted
        established = true
        }

        if slowReceiver {
            let handler = SyntheticSlowReadHandler()
            slowReadHandler = handler
            try await channel.pipeline.addHandler(handler, position: .before(collector)).get()
        }
        let responseParser = HTTPResponseParser()
        let responseFuture = collector.nextData(
            matching: { data in
                if waitForEOF { return false }
                if let expectedBodyBytes, let separator = data.range(of: Data("\r\n\r\n".utf8)) {
                    return data.count - separator.upperBound >= expectedBodyBytes
                }
                return responseParser.isCompleteResponse(data, requestMethod: String(request.prefix { $0 != " " }))
            },
            on: channel, acceptEOF: waitForEOF
        )
        try await write(request)
        let deadline = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            self.collector.timeout()
            self.channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        let responseData = try await responseFuture.get()
        return responseData
    }

    func close() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private func write(_ string: String) async throws {
        var buffer = channel.allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        try await channel.writeAndFlush(buffer).get()
    }
}

private final class TestClientCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var buffer = Data()
    private var predicate: ((Data) -> Bool)?
    private var acceptEOF = false
    private var previousRead: TimeInterval?
    private var waitStarted: TimeInterval = 0
    private var firstRead: TimeInterval?
    private var completedAt: TimeInterval?
    var responseStages: (waitSeconds: Double, firstByteSeconds: Double?, bodySeconds: Double?) {
        let end = completedAt ?? ProcessInfo.processInfo.systemUptime
        return (end - waitStarted, firstRead.map { $0 - waitStarted }, firstRead.map { end - $0 })
    }
    private(set) var maximumReadGap: Double = 0
    private var promise: EventLoopPromise<Data>?

    // Called only on the channel event loop. A local deadline is never valid upstream EOF.
    func timeout() {
        promise?.fail(TestTimeoutError(seconds: 10))
        promise = nil
        predicate = nil
    }

    func nextData(
        matching predicate: @escaping (Data) -> Bool,
        on channel: Channel, acceptEOF: Bool = false
    ) -> EventLoopFuture<Data> {
        let promise = channel.eventLoop.makePromise(of: Data.self)
        channel.eventLoop.execute {
            self.predicate = predicate
            self.acceptEOF = acceptEOF
            self.previousRead = nil
            self.waitStarted = ProcessInfo.processInfo.systemUptime
            self.firstRead = self.buffer.isEmpty ? nil : self.waitStarted
            self.completedAt = nil
            self.maximumReadGap = 0
            self.promise = promise
            self.fulfillIfPossible()
        }
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstRead == nil { firstRead = now }
        if let previousRead { maximumReadGap = max(maximumReadGap, now - previousRead) }
        previousRead = now
        var byteBuffer = unwrapInboundIn(data)
        if let bytes = byteBuffer.readBytes(length: byteBuffer.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        fulfillIfPossible()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let promise {
            completedAt = ProcessInfo.processInfo.systemUptime
            if acceptEOF && !buffer.isEmpty { promise.succeed(buffer) }
            else { promise.fail(HTTPUpstreamConnectorError.incompleteResponse) }
            buffer.removeAll()
            self.promise = nil
            self.predicate = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise {
            promise.fail(error)
            self.promise = nil
            self.predicate = nil
        }
        context.close(promise: nil)
    }

    private func fulfillIfPossible() {
        guard let predicate, let promise, predicate(buffer) else {
            return
        }

        let responseData = buffer
        completedAt = ProcessInfo.processInfo.systemUptime
        buffer.removeAll(keepingCapacity: true)
        self.predicate = nil
        self.promise = nil
        promise.succeed(responseData)
    }
}

private final class SimpleListenerState {
    var didResume = false
}

private struct TestTimeoutError: LocalizedError {
    let seconds: TimeInterval

    var errorDescription: String? {
        "Timed out after \(seconds) seconds."
    }
}

private final class TestProxyConfiguration: AppConfiguration {
    var proxyPort: UInt16
    var logLevel: AppLogLevel
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

    init(proxyPort: UInt16, logLevel: AppLogLevel, certificateLabel: String) {
        self.proxyPort = proxyPort
        self.logLevel = logLevel
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

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError(seconds: seconds)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func httpResponseBody(from responseString: String) -> String? {
    guard let separatorRange = responseString.range(of: "\r\n\r\n") else {
        return nil
    }
    return String(responseString[separatorRange.upperBound...])
}

private func waitForCompletedSession(
    in store: InMemorySessionStore,
    timeout: Double = 6
) async throws -> SessionRecord {
    try await withTimeout(seconds: timeout) {
        while true {
            if let session = store.sessions.first, session.response != nil {
                return session
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private func receiveExactly(byteCount: Int, on connection: NWConnection) async throws -> Data {
    var buffer = Data()

    while buffer.count < byteCount {
        let (data, _) = try await NetworkConnectionIO.receive(on: connection)
        buffer.append(data)
    }

    return Data(buffer.prefix(byteCount))
}
