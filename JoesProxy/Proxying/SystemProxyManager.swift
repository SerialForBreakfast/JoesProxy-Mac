import Foundation

/// Captured macOS system proxy state for a single network service, used to restore
/// the user's prior configuration after JoesProxy stops managing the proxy.
struct SystemProxySnapshot: Codable, Equatable, Sendable {
    let serviceName: String
    let httpEnabled: Bool
    let httpHost: String
    let httpPort: Int
    let httpsEnabled: Bool
    let httpsHost: String
    let httpsPort: Int
    let autoProxyEnabled: Bool
    let autoProxyURL: String

    init(
        serviceName: String,
        httpEnabled: Bool,
        httpHost: String,
        httpPort: Int,
        httpsEnabled: Bool,
        httpsHost: String,
        httpsPort: Int,
        autoProxyEnabled: Bool = false,
        autoProxyURL: String = ""
    ) {
        self.serviceName = serviceName
        self.httpEnabled = httpEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.autoProxyEnabled = autoProxyEnabled
        self.autoProxyURL = autoProxyURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        httpEnabled = try container.decode(Bool.self, forKey: .httpEnabled)
        httpHost = try container.decode(String.self, forKey: .httpHost)
        httpPort = try container.decode(Int.self, forKey: .httpPort)
        httpsEnabled = try container.decode(Bool.self, forKey: .httpsEnabled)
        httpsHost = try container.decode(String.self, forKey: .httpsHost)
        httpsPort = try container.decode(Int.self, forKey: .httpsPort)
        // Back-compat: snapshots persisted before auto-proxy support omit these.
        autoProxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoProxyEnabled) ?? false
        autoProxyURL = try container.decodeIfPresent(String.self, forKey: .autoProxyURL) ?? ""
    }
}

struct SystemProxyCommandOutput: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

protocol SystemProxyCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> SystemProxyCommandOutput
}

enum SystemProxyError: LocalizedError, Sendable {
    case commandFailed(executable: String, arguments: [String], exitCode: Int32, message: String)
    case noActiveNetworkService

    var errorDescription: String? {
        switch self {
        case .commandFailed(let executable, _, let exitCode, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(executable) exited with code \(exitCode)."
            }
            return trimmed
        case .noActiveNetworkService:
            return "JoesProxy could not determine the active macOS network service."
        }
    }
}

/// Runs external commands for system proxy management via `Process`. Requires the app to be
/// unsandboxed (the App Sandbox blocks spawning `networksetup`/`route`).
struct ProcessSystemProxyCommandRunner: SystemProxyCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> SystemProxyCommandOutput {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            // Drain the pipes before waiting to avoid a deadlock if output exceeds the pipe buffer:
            // the child would block writing to a full pipe and never exit.
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return SystemProxyCommandOutput(
                exitCode: process.terminationStatus,
                standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                standardError: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

protocol SystemProxyManaging: Sendable {
    /// Returns the name of the active primary network service (e.g. "Wi-Fi").
    func activePrimaryServiceName() async throws -> String
    /// Reads the current HTTP/HTTPS proxy configuration for a service.
    func readSnapshot(serviceName: String) async throws -> SystemProxySnapshot
    /// Points the service's HTTP and HTTPS proxies at host:port and enables them (strict mode).
    func enableProxy(host: String, port: UInt16, serviceName: String) async throws
    /// Sets the service to use an automatic proxy configuration (PAC) URL and disables the static
    /// web proxies so only the PAC governs (fail-open mode).
    func enablePAC(pacURL: String, serviceName: String) async throws
    /// Restores a service's proxy configuration to a previously captured snapshot.
    func restore(_ snapshot: SystemProxySnapshot) async throws
    /// Restores synchronously, blocking the caller. For use on the quit path where async work
    /// would not complete before the process exits. Failures are swallowed (best-effort cleanup).
    func restoreSynchronously(_ snapshot: SystemProxySnapshot)
}

struct NetworksetupSystemProxyManager: SystemProxyManaging {
    private let commandRunner: any SystemProxyCommandRunning
    private let networksetupURL: URL
    private let routeURL: URL

    init(
        commandRunner: any SystemProxyCommandRunning = ProcessSystemProxyCommandRunner(),
        networksetupURL: URL = URL(fileURLWithPath: "/usr/sbin/networksetup"),
        routeURL: URL = URL(fileURLWithPath: "/sbin/route")
    ) {
        self.commandRunner = commandRunner
        self.networksetupURL = networksetupURL
        self.routeURL = routeURL
    }

    func activePrimaryServiceName() async throws -> String {
        let routeOutput = try await runNetworksetupOrRoute(
            executableURL: routeURL,
            arguments: ["-n", "get", "default"]
        )
        if let device = Self.parseDefaultInterface(routeOutput.standardOutput) {
            let order = try await runNetworksetup(arguments: ["-listnetworkserviceorder"])
            if let service = Self.parseServiceName(forDevice: device, serviceOrderOutput: order.standardOutput) {
                return service
            }
        }

        let all = try await runNetworksetup(arguments: ["-listallnetworkservices"])
        if let first = Self.parseFirstService(all.standardOutput) {
            return first
        }
        throw SystemProxyError.noActiveNetworkService
    }

    func readSnapshot(serviceName: String) async throws -> SystemProxySnapshot {
        let web = try await runNetworksetup(arguments: ["-getwebproxy", serviceName])
        let secure = try await runNetworksetup(arguments: ["-getsecurewebproxy", serviceName])
        let auto = try await runNetworksetup(arguments: ["-getautoproxyurl", serviceName])
        let http = Self.parseProxySetting(web.standardOutput)
        let https = Self.parseProxySetting(secure.standardOutput)
        let autoProxy = Self.parseAutoProxySetting(auto.standardOutput)
        return SystemProxySnapshot(
            serviceName: serviceName,
            httpEnabled: http.enabled,
            httpHost: http.host,
            httpPort: http.port,
            httpsEnabled: https.enabled,
            httpsHost: https.host,
            httpsPort: https.port,
            autoProxyEnabled: autoProxy.enabled,
            autoProxyURL: autoProxy.url
        )
    }

    func enableProxy(host: String, port: UInt16, serviceName: String) async throws {
        _ = try await runNetworksetup(arguments: ["-setwebproxy", serviceName, host, String(port)])
        _ = try await runNetworksetup(arguments: ["-setsecurewebproxy", serviceName, host, String(port)])
    }

    func enablePAC(pacURL: String, serviceName: String) async throws {
        _ = try await runNetworksetup(arguments: ["-setautoproxyurl", serviceName, pacURL])
        _ = try await runNetworksetup(arguments: ["-setautoproxystate", serviceName, "on"])
        // Ensure only the PAC governs routing.
        _ = try await runNetworksetup(arguments: ["-setwebproxystate", serviceName, "off"])
        _ = try await runNetworksetup(arguments: ["-setsecurewebproxystate", serviceName, "off"])
    }

    func restore(_ snapshot: SystemProxySnapshot) async throws {
        for arguments in Self.restoreArguments(for: snapshot) {
            _ = try await runNetworksetup(arguments: arguments)
        }
    }

    func restoreSynchronously(_ snapshot: SystemProxySnapshot) {
        for arguments in Self.restoreArguments(for: snapshot) {
            let process = Process()
            process.executableURL = networksetupURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Best-effort cleanup on quit; nothing to recover to.
            }
        }
    }

    /// The networksetup argument lists that restore a service to a captured snapshot. Shared by the
    /// async and synchronous restore paths.
    static func restoreArguments(for snapshot: SystemProxySnapshot) -> [[String]] {
        let service = snapshot.serviceName
        var commands: [[String]] = []
        if snapshot.httpEnabled, !snapshot.httpHost.isEmpty {
            commands.append(["-setwebproxy", service, snapshot.httpHost, String(snapshot.httpPort)])
        } else {
            commands.append(["-setwebproxystate", service, "off"])
        }
        if snapshot.httpsEnabled, !snapshot.httpsHost.isEmpty {
            commands.append(["-setsecurewebproxy", service, snapshot.httpsHost, String(snapshot.httpsPort)])
        } else {
            commands.append(["-setsecurewebproxystate", service, "off"])
        }
        if snapshot.autoProxyEnabled, !snapshot.autoProxyURL.isEmpty {
            commands.append(["-setautoproxyurl", service, snapshot.autoProxyURL])
            commands.append(["-setautoproxystate", service, "on"])
        } else {
            commands.append(["-setautoproxystate", service, "off"])
        }
        return commands
    }

    // MARK: - Command helpers

    private func runNetworksetup(arguments: [String]) async throws -> SystemProxyCommandOutput {
        try await runNetworksetupOrRoute(executableURL: networksetupURL, arguments: arguments)
    }

    private func runNetworksetupOrRoute(executableURL: URL, arguments: [String]) async throws -> SystemProxyCommandOutput {
        let result = try await commandRunner.run(executableURL: executableURL, arguments: arguments)
        guard result.exitCode == 0 else {
            throw SystemProxyError.commandFailed(
                executable: executableURL.lastPathComponent,
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
        return result
    }

    // MARK: - Parsing (pure, unit-testable)

    /// Parses the `interface: enN` line from `route -n get default` output.
    static func parseDefaultInterface(_ routeOutput: String) -> String? {
        for line in routeOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Maps a device (e.g. "en0") to its service name from `networksetup -listnetworkserviceorder`.
    static func parseServiceName(forDevice device: String, serviceOrderOutput: String) -> String? {
        let lines = serviceOrderOutput.split(whereSeparator: \.isNewline).map(String.init)
        var lastServiceName: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = parseServiceOrderName(trimmed) {
                lastServiceName = name
            } else if trimmed.contains("Device:"), trimmed.contains(device) {
                // Confirm an exact device token match (avoid en0 matching en05).
                let tokens = trimmed
                    .replacingOccurrences(of: ")", with: "")
                    .split(whereSeparator: { $0 == " " || $0 == "," })
                    .map(String.init)
                if tokens.contains(device) {
                    return lastServiceName
                }
            }
        }
        return nil
    }

    /// Parses a `(1) Wi-Fi` or `(2*) Ethernet` service-order header line into its name.
    private static func parseServiceOrderName(_ line: String) -> String? {
        guard line.hasPrefix("("), let closeParen = line.firstIndex(of: ")") else { return nil }
        let inside = line[line.index(after: line.startIndex)..<closeParen]
        // Only a numbered header (optionally with an asterisk) — not "(Hardware Port: ...)".
        guard inside.allSatisfy({ $0.isNumber || $0 == "*" }), inside.contains(where: \.isNumber) else {
            return nil
        }
        let name = line[line.index(after: closeParen)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Returns the first enabled service from `networksetup -listallnetworkservices`.
    static func parseFirstService(_ listAllOutput: String) -> String? {
        for line in listAllOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased().contains("denotes that a network service is disabled") { continue }
            if trimmed.hasPrefix("*") { continue } // disabled service
            return trimmed
        }
        return nil
    }

    /// Parses `Enabled:`, `Server:`, `Port:` from a `-getwebproxy`/`-getsecurewebproxy` block.
    static func parseProxySetting(_ output: String) -> (enabled: Bool, host: String, port: Int) {
        var enabled = false
        var host = ""
        var port = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = valueAfterColon(trimmed, key: "Enabled") {
                enabled = value.caseInsensitiveCompare("Yes") == .orderedSame
            } else if let value = valueAfterColon(trimmed, key: "Server") {
                host = value
            } else if let value = valueAfterColon(trimmed, key: "Port") {
                port = Int(value) ?? 0
            }
        }
        return (enabled, host, port)
    }

    /// Parses `URL:` and `Enabled:` from a `-getautoproxyurl` block. macOS reports an unset URL as
    /// `(null)`, which is normalized to an empty string.
    static func parseAutoProxySetting(_ output: String) -> (enabled: Bool, url: String) {
        var enabled = false
        var url = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = valueAfterColon(trimmed, key: "Enabled") {
                enabled = value.caseInsensitiveCompare("Yes") == .orderedSame
            } else if let value = valueAfterColon(trimmed, key: "URL") {
                url = (value == "(null)") ? "" : value
            }
        }
        return (enabled, url)
    }

    private static func valueAfterColon(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return line.dropFirst("\(key):".count).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Crash-recovery persistence

/// Persists the snapshot captured before JoesProxy changed the system proxy. A non-nil value at
/// launch means JoesProxy set the proxy and never restored it (i.e. it was force-quit while active).
protocol SystemProxyStateStore: AnyObject, Sendable {
    var pendingSnapshot: SystemProxySnapshot? { get set }
}

final class UserDefaultsSystemProxyStateStore: SystemProxyStateStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "systemProxyPendingSnapshot"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var pendingSnapshot: SystemProxySnapshot? {
        get {
            guard let data = userDefaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: key)
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
    }
}
