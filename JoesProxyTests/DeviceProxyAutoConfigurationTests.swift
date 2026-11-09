import Foundation
import Network
import XCTest
@testable import JoesProxy

final class DeviceProxyAutoConfigurationTests: XCTestCase {
    func testStrictAndFallbackAreDistinctAndRejectScriptInjection() throws {
        let strict = try XCTUnwrap(DeviceProxyAutoConfiguration.url(host: "192.0.2.10", port: 9090, allowsDirect: false))
        let fallback = try XCTUnwrap(DeviceProxyAutoConfiguration.url(host: "192.0.2.10", port: 9090, allowsDirect: true))
        XCTAssertNotEqual(strict, fallback)
        XCTAssertEqual(strict.path, DeviceProxyAutoConfiguration.path)
        XCTAssertFalse(try XCTUnwrap(DeviceProxyAutoConfiguration.script(host: "192.0.2.10", port: 9090, allowsDirect: false)).contains("DIRECT"))
        XCTAssertTrue(try XCTUnwrap(DeviceProxyAutoConfiguration.script(host: "192.0.2.10", port: 9090, allowsDirect: true)).contains("; DIRECT"))
        for host in ["0.0.0.0", "example.test", "192.0.2.1\";DIRECT", "192.0.2.256", "192.0.2.01"] {
            XCTAssertNil(DeviceProxyAutoConfiguration.url(host: host, port: 9090, allowsDirect: false))
            XCTAssertNil(DeviceProxyAutoConfiguration.script(host: host, port: 9090, allowsDirect: true))
        }
        XCTAssertNil(DeviceProxyAutoConfiguration.url(host: nil, port: 9090, allowsDirect: false))
        XCTAssertNil(DeviceProxyAutoConfiguration.url(host: "192.0.2.10", port: 0, allowsDirect: false))
    }

    func testEndpointIsLocalOnlyAndDoesNotRewriteRemotePACFiles() throws {
        let parser = HTTPRequestParser()
        func response(_ method: String, host: String, port: Int = 9090) throws -> String? {
            let request = try parser.parse(Data("\(method) \(DeviceProxyAutoConfiguration.path) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8))
            return DeviceProxyAutoConfiguration.response(for: request, localHost: "192.0.2.10", localPort: 9090)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertNil(try response("GET", host: "remote.example.test"))
        XCTAssertNil(try response("GET", host: "192.0.2.10", port: 80))
        let head = try XCTUnwrap(response("HEAD", host: "192.0.2.10"))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(head.contains("FindProxyForURL"))
        XCTAssertTrue(try XCTUnwrap(response("POST", host: "192.0.2.10")).hasPrefix("HTTP/1.1 405"))
        let query = try parser.parse(Data("GET \(DeviceProxyAutoConfiguration.path)?direct=true HTTP/1.1\r\nHost: 192.0.2.10:9090\r\n\r\n".utf8))
        let rejected = try XCTUnwrap(DeviceProxyAutoConfiguration.response(for: query, localHost: "192.0.2.10", localPort: 9090))
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
    }

    func testActiveProxyServesPACOverRealSocketWithoutUpstream() async throws {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", sessionRecorder: recorder)
        try await proxy.start()
        do {
            for allowsDirect in [false, true] {
                let url = try XCTUnwrap(DeviceProxyAutoConfiguration.url(host: "127.0.0.1", port: proxy.port, allowsDirect: allowsDirect))
                let response = try await fetch(path: url.path, port: proxy.port)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
                XCTAssertTrue(response.contains("application/x-ns-proxy-autoconfig"))
                XCTAssertTrue(response.contains("Cache-Control: no-store"))
                XCTAssertTrue(response.contains("PROXY 127.0.0.1:\(proxy.port)"))
                XCTAssertEqual(response.contains("; DIRECT"), allowsDirect)
            }
            let head = try await fetch(path: DeviceProxyAutoConfiguration.path, port: proxy.port, method: "HEAD")
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
            let invalid = try await fetch(path: DeviceProxyAutoConfiguration.path + "?direct=true", port: proxy.port)
            XCTAssertTrue(invalid.hasPrefix("HTTP/1.1 400"))
            await recorder.waitForPendingStoreFlush()
            XCTAssertTrue(store.sessions.isEmpty, "Setup-file delivery must not confirm device traffic.")
            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
            await proxy.stop()
            XCTAssertFalse(proxy.isRunning)

            // Reuse the same owner with a newly allocated port; no setup-window lifetime or
            // old configured port is involved in generating the script.
            proxy.port = 0
            try await proxy.start()
            let restarted = try await fetch(path: DeviceProxyAutoConfiguration.path, port: proxy.port)
            XCTAssertTrue(restarted.contains("PROXY 127.0.0.1:\(proxy.port)"))
            await proxy.stop()
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        } catch {
            await proxy.stop()
            throw error
        }
    }

    func testPACRemainsAvailableWhenCaptureAdmissionIsSaturated() async throws {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", sessionRecorder: recorder)
        try await proxy.start()
        do {
            let reservation = try XCTUnwrap(recorder.admission.reserve(bytes: 128 * 1_024 * 1_024))
            defer { recorder.admission.release(reservation) }
            for _ in 0..<10 {
                let response = try await fetch(path: DeviceProxyAutoConfiguration.path, port: proxy.port)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
            }
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertEqual(recorder.admission.snapshot.rejectedCaptures, 0)
            recorder.admission.release(reservation)
            await proxy.stop()
            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        } catch {
            await proxy.stop()
            throw error
        }
    }

    private func fetch(path: String, port: UInt16, method: String = "GET") async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(.init(rawValue: port)), using: .tcp)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                connection.cancel()
                throw URLError(.timedOut)
            }
            group.addTask {
                try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "tests.device-pac"))
                try await NetworkConnectionIO.send(Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8), on: connection)
                var data = Data()
                while data.count < 8192 {
                    let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
                    data.append(bytes)
                    if let separator = data.range(of: Data("\r\n\r\n".utf8)) {
                        if method == "HEAD" { break }
                        let headers = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
                        let length = headers.components(separatedBy: "\r\n")
                            .first { $0.lowercased().hasPrefix("content-length:") }
                            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                        if let length, data.count - separator.upperBound >= length { break }
                    }
                    if complete { break }
                }
                return String(decoding: data, as: UTF8.self)
            }
            defer { group.cancelAll() }
            let result = try await group.next()
            return try XCTUnwrap(result)
        }
    }
}
