import XCTest
@testable import JoesProxy

final class SystemProxyManagerTests: XCTestCase {

    // MARK: - Parsing

    func testParseProxySettingEnabled() {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 8888
        Authenticated Proxy Enabled: 0
        """
        let parsed = NetworksetupSystemProxyManager.parseProxySetting(output)
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(parsed.host, "127.0.0.1")
        XCTAssertEqual(parsed.port, 8888)
    }

    func testParseProxySettingDisabled() {
        let output = """
        Enabled: No
        Server:
        Port: 0
        Authenticated Proxy Enabled: 0
        """
        let parsed = NetworksetupSystemProxyManager.parseProxySetting(output)
        XCTAssertFalse(parsed.enabled)
        XCTAssertEqual(parsed.host, "")
        XCTAssertEqual(parsed.port, 0)
    }

    func testParseDefaultInterface() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        XCTAssertEqual(NetworksetupSystemProxyManager.parseDefaultInterface(output), "en0")
    }

    func testParseDefaultInterfaceMissing() {
        XCTAssertNil(NetworksetupSystemProxyManager.parseDefaultInterface("no interface here"))
    }

    func testParseServiceNameForDevice() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)
        """
        XCTAssertEqual(NetworksetupSystemProxyManager.parseServiceName(forDevice: "en0", serviceOrderOutput: output), "Wi-Fi")
        XCTAssertEqual(NetworksetupSystemProxyManager.parseServiceName(forDevice: "en5", serviceOrderOutput: output), "USB 10/100/1000 LAN")
        XCTAssertNil(NetworksetupSystemProxyManager.parseServiceName(forDevice: "en9", serviceOrderOutput: output))
    }

    func testParseServiceNameDoesNotMatchPartialDeviceToken() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en05)
        """
        // en0 must not match en05.
        XCTAssertNil(NetworksetupSystemProxyManager.parseServiceName(forDevice: "en0", serviceOrderOutput: output))
        XCTAssertEqual(NetworksetupSystemProxyManager.parseServiceName(forDevice: "en05", serviceOrderOutput: output), "Wi-Fi")
    }

    func testParseFirstServiceSkipsHeaderAndDisabled() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        *Thunderbolt Bridge
        Wi-Fi
        USB 10/100/1000 LAN
        """
        XCTAssertEqual(NetworksetupSystemProxyManager.parseFirstService(output), "Wi-Fi")
    }

    // MARK: - Command sequencing

    func testActivePrimaryServiceNameUsesRouteThenServiceOrder() async throws {
        let runner = StubSystemProxyCommandRunner { _, arguments in
            if arguments.contains("get") {
                return .ok("  interface: en0\n")
            }
            if arguments.contains("-listnetworkserviceorder") {
                return .ok("(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n")
            }
            return .ok("")
        }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let service = try await manager.activePrimaryServiceName()
        XCTAssertEqual(service, "Wi-Fi")
    }

    func testActivePrimaryServiceNameFallsBackToFirstService() async throws {
        let runner = StubSystemProxyCommandRunner { _, arguments in
            if arguments.contains("get") {
                return .ok("no interface\n")
            }
            if arguments.contains("-listallnetworkservices") {
                return .ok("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n")
            }
            return .ok("")
        }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let service = try await manager.activePrimaryServiceName()
        XCTAssertEqual(service, "Wi-Fi")
    }

    func testReadSnapshotCombinesWebAndSecure() async throws {
        let runner = StubSystemProxyCommandRunner { _, arguments in
            if arguments.first == "-getwebproxy" {
                return .ok("Enabled: Yes\nServer: 10.0.0.1\nPort: 3128\n")
            }
            if arguments.first == "-getsecurewebproxy" {
                return .ok("Enabled: No\nServer:\nPort: 0\n")
            }
            return .ok("")
        }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let snapshot = try await manager.readSnapshot(serviceName: "Wi-Fi")
        XCTAssertEqual(snapshot.serviceName, "Wi-Fi")
        XCTAssertTrue(snapshot.httpEnabled)
        XCTAssertEqual(snapshot.httpHost, "10.0.0.1")
        XCTAssertEqual(snapshot.httpPort, 3128)
        XCTAssertFalse(snapshot.httpsEnabled)
        XCTAssertEqual(snapshot.httpsHost, "")
        XCTAssertEqual(snapshot.httpsPort, 0)
    }

    func testEnableProxyIssuesSetWebAndSecureCommands() async throws {
        let runner = StubSystemProxyCommandRunner { _, _ in .ok("") }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        try await manager.enableProxy(host: "127.0.0.1", port: 9090, serviceName: "Wi-Fi")

        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
            ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"]
        ])
    }

    func testRestoreEnabledSnapshotReappliesServers() async throws {
        let runner = StubSystemProxyCommandRunner { _, _ in .ok("") }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let snapshot = SystemProxySnapshot(
            serviceName: "Wi-Fi",
            httpEnabled: true, httpHost: "10.0.0.1", httpPort: 3128,
            httpsEnabled: true, httpsHost: "10.0.0.2", httpsPort: 3129
        )
        try await manager.restore(snapshot)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["-setwebproxy", "Wi-Fi", "10.0.0.1", "3128"],
            ["-setsecurewebproxy", "Wi-Fi", "10.0.0.2", "3129"],
            ["-setautoproxystate", "Wi-Fi", "off"]
        ])
    }

    func testRestoreDisabledSnapshotTurnsProxyOff() async throws {
        let runner = StubSystemProxyCommandRunner { _, _ in .ok("") }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let snapshot = SystemProxySnapshot(
            serviceName: "Wi-Fi",
            httpEnabled: false, httpHost: "", httpPort: 0,
            httpsEnabled: false, httpsHost: "", httpsPort: 0
        )
        try await manager.restore(snapshot)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setautoproxystate", "Wi-Fi", "off"]
        ])
    }

    func testRestoreReappliesPriorAutoProxy() async throws {
        let runner = StubSystemProxyCommandRunner { _, _ in .ok("") }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        let snapshot = SystemProxySnapshot(
            serviceName: "Wi-Fi",
            httpEnabled: false, httpHost: "", httpPort: 0,
            httpsEnabled: false, httpsHost: "", httpsPort: 0,
            autoProxyEnabled: true, autoProxyURL: "http://pac.example/proxy.pac"
        )
        try await manager.restore(snapshot)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setautoproxyurl", "Wi-Fi", "http://pac.example/proxy.pac"],
            ["-setautoproxystate", "Wi-Fi", "on"]
        ])
    }

    func testEnablePACSetsAutoProxyAndDisablesStatic() async throws {
        let runner = StubSystemProxyCommandRunner { _, _ in .ok("") }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        try await manager.enablePAC(pacURL: "http://127.0.0.1:5050/joesproxy.pac", serviceName: "Wi-Fi")
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["-setautoproxyurl", "Wi-Fi", "http://127.0.0.1:5050/joesproxy.pac"],
            ["-setautoproxystate", "Wi-Fi", "on"],
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"]
        ])
    }

    func testParseAutoProxySetting() {
        let enabled = NetworksetupSystemProxyManager.parseAutoProxySetting("URL: http://x/y.pac\nEnabled: Yes\n")
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.url, "http://x/y.pac")

        let disabled = NetworksetupSystemProxyManager.parseAutoProxySetting("URL: (null)\nEnabled: No\n")
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.url, "")
    }

    func testPACScriptContainsDirectFallback() {
        let script = PACHostingServer.pacScript(proxyPort: 9090)
        XCTAssertTrue(script.contains("PROXY 127.0.0.1:9090; DIRECT"))
        XCTAssertTrue(script.contains("FindProxyForURL"))
    }

    func testNonZeroExitThrowsCommandFailed() async {
        let runner = StubSystemProxyCommandRunner { _, _ in
            SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "boom")
        }
        let manager = NetworksetupSystemProxyManager(commandRunner: runner)
        do {
            _ = try await manager.readSnapshot(serviceName: "Wi-Fi")
            XCTFail("Expected throw")
        } catch let error as SystemProxyError {
            XCTAssertEqual(error.localizedDescription, "boom")
        } catch {
            XCTFail("Expected SystemProxyError, got \(error)")
        }
    }
}

private final class StubSystemProxyCommandRunner: SystemProxyCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private let handler: (URL, [String]) -> SystemProxyCommandOutput

    init(handler: @escaping (URL, [String]) -> SystemProxyCommandOutput) {
        self.handler = handler
    }

    func run(executableURL: URL, arguments: [String]) async throws -> SystemProxyCommandOutput {
        invocations.append(Invocation(executable: executableURL.lastPathComponent, arguments: arguments))
        return handler(executableURL, arguments)
    }
}

private extension SystemProxyCommandOutput {
    static func ok(_ stdout: String) -> SystemProxyCommandOutput {
        SystemProxyCommandOutput(exitCode: 0, standardOutput: stdout, standardError: "")
    }
}
