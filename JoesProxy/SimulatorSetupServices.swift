import Foundation
import os

protocol SimulatorCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> SimulatorCommandExecutionResult
}

protocol SimulatorDiscovering {
    func discoverSimulators() async throws -> [SimulatorDevice]
}

protocol SimulatorCertificateInstalling {
    func installCertificate(on simulator: SimulatorDevice) async throws -> SimulatorSetupCommandResult
    func installCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult
}

@MainActor
protocol SimulatorVerifying {
    func verifyHTTPRouting(on simulator: SimulatorDevice) async -> SimulatorVerificationResult
    func verificationCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult
}

enum SimulatorSetupError: LocalizedError, Sendable {
    case commandFailed(SimulatorSetupCommandResult)
    case certificateUnavailable
    case certificateWriteFailed(String)
    case discoveryDecodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let result):
            let output = result.standardError.isEmpty ? result.standardOutput : result.standardError
            return output.isEmpty ? "Command failed with exit code \(result.exitCode)." : output
        case .certificateUnavailable:
            return "JoesProxy could not load or create the Root CA certificate."
        case .certificateWriteFailed(let message):
            return "JoesProxy could not prepare the Root CA certificate for Simulator. \(message)"
        case .discoveryDecodeFailed(let message):
            return "JoesProxy could not read the simulator list. \(message)"
        }
    }
}

struct ProcessSimulatorCommandRunner: SimulatorCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> SimulatorCommandExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            // Drain the pipes before waiting. `simctl list --json` output exceeds the ~64KB pipe
            // buffer, so reading only after waitUntilExit() would deadlock: the child blocks writing
            // to a full pipe and never exits.
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return SimulatorCommandExecutionResult(
                executableURL: executableURL,
                arguments: arguments,
                exitCode: process.terminationStatus,
                standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                standardError: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

struct SimulatorDiscoveryService: SimulatorDiscovering {
    private let commandRunner: any SimulatorCommandRunning
    private let xcrunURL: URL
    private let logger = Logger(subsystem: "com.JoesProxyApp.SimulatorSetup", category: "Discovery")

    init(
        commandRunner: any SimulatorCommandRunning = ProcessSimulatorCommandRunner(),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.commandRunner = commandRunner
        self.xcrunURL = xcrunURL
    }

    func discoverSimulators() async throws -> [SimulatorDevice] {
        let arguments = ["simctl", "list", "--json", "devices", "runtimes"]
        logger.info("Simulator setup: discovery started (\(self.xcrunURL.path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public))")
        let result = try await commandRunner.run(executableURL: xcrunURL, arguments: arguments)
        guard result.exitCode == 0 else {
            logger.error("Simulator setup: discovery command failed exitCode=\(result.exitCode, privacy: .public) stderr=\(result.standardError, privacy: .public)")
            throw SimulatorSetupError.commandFailed(result.setupResult)
        }

        do {
            let decoded = try JSONDecoder().decode(SimctlListResponse.self, from: Data(result.standardOutput.utf8))
            let devices = decoded.flattenedDevices()
            logger.info("Simulator setup: discovered \(devices.count, privacy: .public) device(s)")
            return devices
        } catch {
            logger.error("Simulator setup: discovery decode failed: \(error.localizedDescription, privacy: .public)")
            throw SimulatorSetupError.discoveryDecodeFailed(error.localizedDescription)
        }
    }
}

struct SimulatorCertificateInstaller: SimulatorCertificateInstalling {
    private let commandRunner: any SimulatorCommandRunning
    private let certificateAuthority: any CertificateAuthorityProviding
    private let xcrunURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.JoesProxyApp.SimulatorSetup", category: "CertificateInstall")

    init(
        commandRunner: any SimulatorCommandRunning = ProcessSimulatorCommandRunner(),
        certificateAuthority: any CertificateAuthorityProviding,
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.certificateAuthority = certificateAuthority
        self.xcrunURL = xcrunURL
        self.fileManager = fileManager
    }

    func installCertificate(on simulator: SimulatorDevice) async throws -> SimulatorSetupCommandResult {
        logger.info("Simulator setup: certificate install started udid=\(simulator.udid, privacy: .public)")
        let identity = try certificateAuthority.loadOrCreateRootCertificate()
        let certificateURL = fileManager.temporaryDirectory
            .appendingPathComponent("JoesProxy-Root-CA-\(UUID().uuidString)")
            .appendingPathExtension("cer")

        do {
            try identity.certificateData.write(to: certificateURL, options: [.atomic])
        } catch {
            logger.error("Simulator setup: certificate write failed: \(error.localizedDescription, privacy: .public)")
            throw SimulatorSetupError.certificateWriteFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: certificateURL) }

        let result = try await commandRunner.run(
            executableURL: xcrunURL,
            arguments: installArguments(simulatorUDID: simulator.udid, certificatePath: certificateURL.path)
        )
        guard result.exitCode == 0 else {
            logger.error("Simulator setup: certificate install failed udid=\(simulator.udid, privacy: .public) exitCode=\(result.exitCode, privacy: .public) stderr=\(result.standardError, privacy: .public)")
            throw SimulatorSetupError.commandFailed(result.setupResult)
        }
        logger.info("Simulator setup: certificate install succeeded udid=\(simulator.udid, privacy: .public)")
        return result.setupResult
    }

    func installCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult {
        SimulatorSetupCommandResult(
            executablePath: xcrunURL.path,
            arguments: installArguments(simulatorUDID: simulator.udid, certificatePath: "<path-to-joesproxy-root-ca.cer>"),
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }

    private func installArguments(simulatorUDID: String, certificatePath: String) -> [String] {
        ["simctl", "keychain", simulatorUDID, "add-root-cert", certificatePath]
    }
}

@MainActor
final class SimulatorVerificationService: SimulatorVerifying {
    static let verificationURL = URL(string: "http://captive.apple.com/")!
    static let verificationHost = "captive.apple.com"

    private let commandRunner: any SimulatorCommandRunning
    private let sessionStore: any SessionStore
    private let xcrunURL: URL
    private let timeoutNanoseconds: UInt64
    private let logger = Logger(subsystem: "com.JoesProxyApp.SimulatorSetup", category: "Verification")

    init(
        commandRunner: any SimulatorCommandRunning = ProcessSimulatorCommandRunner(),
        sessionStore: any SessionStore,
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        timeoutNanoseconds: UInt64 = 12_000_000_000
    ) {
        self.commandRunner = commandRunner
        self.sessionStore = sessionStore
        self.xcrunURL = xcrunURL
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func verifyHTTPRouting(on simulator: SimulatorDevice) async -> SimulatorVerificationResult {
        logger.info("Simulator setup: verification openurl started udid=\(simulator.udid, privacy: .public) url=\(Self.verificationURL.absoluteString, privacy: .public)")
        do {
            let result = try await commandRunner.run(
                executableURL: xcrunURL,
                arguments: verificationArguments(simulatorUDID: simulator.udid)
            )
            guard result.exitCode == 0 else {
                let setupResult = result.setupResult
                let errorMessage = setupResult.standardError.isEmpty ? setupResult.standardOutput : setupResult.standardError
                logger.error("Simulator setup: verification command failed exitCode=\(result.exitCode, privacy: .public) message=\(errorMessage, privacy: .public)")
                return .commandFailed(errorMessage.isEmpty ? "Command failed with exit code \(result.exitCode)." : errorMessage)
            }
        } catch {
            logger.error("Simulator setup: verification command threw: \(error.localizedDescription, privacy: .public)")
            return .commandFailed(error.localizedDescription)
        }

        if let existing = sessionStore.sessions.last(where: Self.matchesVerificationHost(_:)) {
            logger.info("Simulator setup: verification captured existing session id=\(String(describing: existing.id), privacy: .public)")
            return .captured(existing.id)
        }

        let result = await waitForVerificationSession()
        switch result {
        case .captured(let id):
            logger.info("Simulator setup: verification captured session id=\(String(describing: id), privacy: .public)")
        case .noTrafficDetected:
            logger.error("Simulator setup: verification timed out with no captive.apple.com traffic")
        default:
            break
        }
        return result
    }

    func verificationCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult {
        SimulatorSetupCommandResult(
            executablePath: xcrunURL.path,
            arguments: verificationArguments(simulatorUDID: simulator.udid),
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }

    private func verificationArguments(simulatorUDID: String) -> [String] {
        ["simctl", "openurl", simulatorUDID, Self.verificationURL.absoluteString]
    }

    private func waitForVerificationSession() async -> SimulatorVerificationResult {
        let pollInterval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0

        while elapsed < timeoutNanoseconds {
            if let session = sessionStore.sessions.last(where: Self.matchesVerificationHost(_:)) {
                return .captured(session.id)
            }
            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval
        }

        return .noTrafficDetected
    }

    private static func matchesVerificationHost(_ session: SessionRecord) -> Bool {
        session.request.host.caseInsensitiveCompare(verificationHost) == .orderedSame
    }
}

private struct SimctlListResponse: Decodable {
    let devices: [String: [SimctlDevice]]
    let runtimes: [SimctlRuntime]

    func flattenedDevices() -> [SimulatorDevice] {
        // simctl can report duplicate runtime identifiers (e.g. multiple builds of the same OS),
        // so tolerate collisions instead of trapping with Dictionary(uniqueKeysWithValues:).
        let runtimeNamesByIdentifier = Dictionary(
            runtimes.map { ($0.identifier, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return devices
            .flatMap { runtimeIdentifier, devices in
                devices.map { device in
                    let platform = SimulatorPlatform.infer(
                        runtimeIdentifier: runtimeIdentifier,
                        deviceName: device.name
                    )
                    return SimulatorDevice(
                        udid: device.udid,
                        name: device.name,
                        state: device.state,
                        runtimeIdentifier: runtimeIdentifier,
                        runtimeName: runtimeNamesByIdentifier[runtimeIdentifier],
                        platform: platform,
                        supportTier: SimulatorSupportTier.forPlatform(platform),
                        availability: SimulatorAvailability(
                            isAvailable: device.isAvailable,
                            error: device.availabilityError
                        )
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.platform.title == rhs.platform.title {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.platform.title.localizedStandardCompare(rhs.platform.title) == .orderedAscending
            }
    }
}

private struct SimctlDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let availabilityError: String?
}

private struct SimctlRuntime: Decodable {
    let identifier: String
    let name: String
}

private extension SimulatorPlatform {
    static func infer(runtimeIdentifier: String, deviceName: String) -> SimulatorPlatform {
        let normalizedRuntime = runtimeIdentifier.lowercased()
        let normalizedName = deviceName.lowercased()

        if normalizedRuntime.contains("tvos") {
            return .tvOS
        }
        if normalizedRuntime.contains("visionos") {
            return .visionOS
        }
        if normalizedRuntime.contains("watchos") {
            return .watchOS
        }
        if normalizedRuntime.contains("ios") {
            return normalizedName.contains("ipad") ? .iPadOS : .iOS
        }
        return .unknown
    }
}

private extension SimulatorSupportTier {
    static func forPlatform(_ platform: SimulatorPlatform) -> SimulatorSupportTier {
        switch platform {
        case .iOS, .iPadOS:
            return .verifiedFirst
        case .tvOS, .visionOS:
            return .expected
        case .watchOS:
            return .outOfScope
        case .unknown:
            return .limited
        }
    }
}
