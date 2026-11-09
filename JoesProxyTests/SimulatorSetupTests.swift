import XCTest
@testable import JoesProxy

@MainActor
final class SimulatorSetupTests: XCTestCase {
    func testDiscoveryDecodesRuntimeKeyedDevicesAndAvailability() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: Self.simctlListJSON,
                    standardError: ""
                )
            )
        )
        let service = SimulatorDiscoveryService(commandRunner: runner)

        let devices = try await service.discoverSimulators()

        XCTAssertEqual(runner.requests.first?.executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(runner.requests.first?.arguments, ["simctl", "list", "--json", "devices", "runtimes"])
        XCTAssertEqual(devices.count, 4)

        let phone = try XCTUnwrap(devices.first { $0.udid == "IOS-BOOTED" })
        XCTAssertEqual(phone.platform, .iOS)
        XCTAssertEqual(phone.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        XCTAssertEqual(phone.runtimeName, "iOS 26.4")
        XCTAssertTrue(phone.availability.isAvailable)
        XCTAssertTrue(phone.isSelectable)

        let iPad = try XCTUnwrap(devices.first { $0.udid == "IPAD-SHUTDOWN" })
        XCTAssertEqual(iPad.platform, .iPadOS)

        let unavailable = try XCTUnwrap(devices.first { $0.udid == "TV-UNAVAILABLE" })
        XCTAssertEqual(unavailable.platform, .tvOS)
        XCTAssertFalse(unavailable.availability.isAvailable)
        XCTAssertEqual(unavailable.availability.error, "runtime profile not found")
        XCTAssertFalse(unavailable.isSelectable)

        let watch = try XCTUnwrap(devices.first { $0.udid == "WATCH-BOOTED" })
        XCTAssertEqual(watch.supportTier, .outOfScope)
        XCTAssertFalse(watch.isSelectable)
    }

    func testDiscoveryDecodesLargeDeviceList() async throws {
        // Guards that discovery handles a large simctl payload (the kind that overflows the pipe
        // buffer with a real Process — see the drain-before-wait fix in ProcessSimulatorCommandRunner).
        let deviceCount = 1000
        var deviceEntries: [String] = []
        deviceEntries.reserveCapacity(deviceCount)
        for index in 0..<deviceCount {
            deviceEntries.append("""
            {
              "state": "Shutdown",
              "isAvailable": true,
              "name": "iPhone Sim \(index)",
              "udid": "UDID-\(index)"
            }
            """)
        }
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [\(deviceEntries.joined(separator: ","))]
          },
          "runtimes": [
            { "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "name": "iOS 26.4" }
          ]
        }
        """
        XCTAssertGreaterThan(json.utf8.count, 64 * 1024, "Payload should exceed the pipe buffer size")

        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: json,
                    standardError: ""
                )
            )
        )
        let service = SimulatorDiscoveryService(commandRunner: runner)

        let devices = try await service.discoverSimulators()

        XCTAssertEqual(devices.count, deviceCount)
    }

    func testDiscoveryToleratesDuplicateRuntimeIdentifiers() async throws {
        // simctl can list the same runtime identifier twice; discovery must not trap.
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
              { "state": "Booted", "isAvailable": true, "name": "iPhone 17", "udid": "IOS-A" }
            ]
          },
          "runtimes": [
            { "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "name": "iOS 26.4" },
            { "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "name": "iOS 26.4 (duplicate)" }
          ]
        }
        """
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: json,
                    standardError: ""
                )
            )
        )
        let service = SimulatorDiscoveryService(commandRunner: runner)

        let devices = try await service.discoverSimulators()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.runtimeName, "iOS 26.4")
    }

    func testCertificateInstallerInvokesXcrunKeychainAddRootCertAndNeverReset() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: "ok",
                    standardError: ""
                )
            )
        )
        let certificateAuthority = StubSimulatorCertificateAuthority()
        let installer = SimulatorCertificateInstaller(
            commandRunner: runner,
            certificateAuthority: certificateAuthority
        )

        let result = try await installer.installCertificate(on: Self.selectableDevice)

        XCTAssertEqual(result.executablePath, "/usr/bin/xcrun")
        let arguments = try XCTUnwrap(runner.requests.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(4)), ["simctl", "keychain", Self.selectableDevice.udid, "add-root-cert"])
        XCTAssertEqual(arguments.count, 5)
        XCTAssertTrue(arguments[4].hasSuffix(".cer"))
        XCTAssertFalse(arguments.contains("reset"))
        XCTAssertEqual(certificateAuthority.loadOrCreateCount, 1)
    }

    func testVerificationInvokesOpenURLAndSucceedsWhenSessionIsCaptured() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: "",
                    standardError: ""
                )
            )
        )
        let store = InMemorySessionStore()
        let verifier = SimulatorVerificationService(
            commandRunner: runner,
            sessionStore: store,
            timeoutNanoseconds: 1_000_000_000
        )

        let verificationTask = Task {
            await verifier.verifyHTTPRouting(on: Self.selectableDevice)
        }
        await Task.yield()
        store.append(Self.makeSession(host: "captive.apple.com"))

        let result = await verificationTask.value

        XCTAssertEqual(runner.requests.first?.arguments, [
            "simctl",
            "openurl",
            Self.selectableDevice.udid,
            "http://captive.apple.com/"
        ])
        if case .captured = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected captured result, got \(result)")
        }
    }

    func testVerificationTimesOutWhenNoMatchingSessionAppears() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 0,
                    standardOutput: "",
                    standardError: ""
                )
            )
        )
        let verifier = SimulatorVerificationService(
            commandRunner: runner,
            sessionStore: InMemorySessionStore(),
            timeoutNanoseconds: 1_000_000
        )

        let result = await verifier.verifyHTTPRouting(on: Self.selectableDevice)

        XCTAssertEqual(result, .noTrafficDetected)
    }

    func testViewModelExposesFallbackCommandWhenInstallFails() async throws {
        let installer = FailingSimulatorCertificateInstaller()
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: StaticSimulatorDiscovery(devices: [Self.selectableDevice]),
            certificateInstaller: installer,
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: StubSimulatorCertificateAuthority()
        )
        await viewModel.refreshDevicesNow()

        await viewModel.installCertificateInSelectedSimulatorNow()

        if case .failed(let message, let fallbackCommand) = viewModel.installState {
            XCTAssertTrue(SimulatorSetupViewModel.isSandboxError(message))
            XCTAssertEqual(fallbackCommand?.arguments, [
                "simctl",
                "keychain",
                Self.selectableDevice.udid,
                "add-root-cert",
                "<path-to-joesproxy-root-ca.cer>"
            ])
        } else {
            XCTFail("Expected failed install state")
        }
    }

    func testRootCertificateDragURLWritesCerFileWithCertData() throws {
        let certificateAuthority = StubSimulatorCertificateAuthority()
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: StaticSimulatorDiscovery(devices: [Self.selectableDevice]),
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: certificateAuthority
        )

        let url = try XCTUnwrap(viewModel.rootCertificateDragURL())

        XCTAssertEqual(url.pathExtension, "cer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, Data("certificate".utf8))
        XCTAssertEqual(certificateAuthority.loadOrCreateCount, 1)

        try? FileManager.default.removeItem(at: url)
    }

    func testSandboxErrorDetection() {
        XCTAssertTrue(SimulatorSetupViewModel.isSandboxError(
            "xcrun: error: cannot be used within an App Sandbox."
        ))
        XCTAssertTrue(SimulatorSetupViewModel.isSandboxError(
            "xcrun: error: cannot be used within an app sandbox."
        ))
        XCTAssertFalse(SimulatorSetupViewModel.isSandboxError(
            "Command failed with exit code 1."
        ))
        XCTAssertFalse(SimulatorSetupViewModel.isSandboxError(""))
    }

    func testDiscoveryFailedWithSandboxErrorMessage() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "xcrun: error: cannot be used within an App Sandbox."
                )
            )
        )
        let service = SimulatorDiscoveryService(commandRunner: runner)
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: service,
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: StubSimulatorCertificateAuthority()
        )

        await viewModel.refreshDevicesNow()

        if case .failed(let message) = viewModel.discoveryState {
            XCTAssertTrue(SimulatorSetupViewModel.isSandboxError(message))
        } else {
            XCTFail("Expected failed discovery state, got \(viewModel.discoveryState)")
        }
    }

    func testManualSimulatorSelectionRejectsEmptyUDID() {
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: StaticSimulatorDiscovery(devices: []),
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: StubSimulatorCertificateAuthority()
        )

        viewModel.manualSimulatorUDID = "  \n "
        viewModel.selectManualSimulator()

        XCTAssertEqual(viewModel.manualSimulatorSelectionError, "Enter a simulator UDID.")
        XCTAssertNil(viewModel.selectedDevice)
        XCTAssertTrue(viewModel.devices.isEmpty)
    }

    func testManualSimulatorSelectionCreatesUsableDeviceAfterSandboxDiscoveryFailure() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "xcrun: error: cannot be used within an App Sandbox."
                )
            )
        )
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: SimulatorDiscoveryService(commandRunner: runner),
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: StubSimulatorCertificateAuthority()
        )
        await viewModel.refreshDevicesNow()

        viewModel.manualSimulatorUDID = "  MANUAL-UDID  "
        viewModel.selectManualSimulator()

        let selectedDevice = try XCTUnwrap(viewModel.selectedDevice)
        XCTAssertNil(viewModel.manualSimulatorSelectionError)
        XCTAssertEqual(selectedDevice.udid, "MANUAL-UDID")
        XCTAssertEqual(selectedDevice.name, "Manual Simulator")
        XCTAssertEqual(selectedDevice.state, "Booted")
        XCTAssertEqual(selectedDevice.platform, .unknown)
        XCTAssertEqual(selectedDevice.supportTier, .limited)
        XCTAssertTrue(selectedDevice.isSelectable)
        XCTAssertEqual(viewModel.installCommandText, "/usr/bin/xcrun simctl keychain MANUAL-UDID add-root-cert '<path-to-joesproxy-root-ca.cer>'")
        XCTAssertEqual(viewModel.verificationCommandText, "/usr/bin/xcrun simctl openurl MANUAL-UDID http://captive.apple.com/")
    }

    func testManualSimulatorSelectionUsesExistingDeviceWhenUDIDMatches() async throws {
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: StaticSimulatorDiscovery(devices: [Self.selectableDevice]),
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: StaticSimulatorVerifier(),
            certificateAuthority: StubSimulatorCertificateAuthority()
        )
        await viewModel.refreshDevicesNow()

        viewModel.manualSimulatorUDID = " \(Self.selectableDevice.udid) "
        viewModel.selectManualSimulator()

        XCTAssertNil(viewModel.manualSimulatorSelectionError)
        XCTAssertEqual(viewModel.devices.count, 1)
        XCTAssertEqual(viewModel.selectedDevice, Self.selectableDevice)
    }

    func testVerificationResultCommandFailedWithSandboxErrorMessage() async throws {
        let runner = RecordingSimulatorCommandRunner(
            result: .success(
                SimulatorCommandExecutionResult(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [],
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "xcrun: error: cannot be used within an App Sandbox."
                )
            )
        )
        let verifier = SimulatorVerificationService(
            commandRunner: runner,
            sessionStore: InMemorySessionStore(),
            timeoutNanoseconds: 1_000_000
        )
        let viewModel = SimulatorSetupViewModel(
            proxyPort: 9090,
            discoveryService: StaticSimulatorDiscovery(devices: [Self.selectableDevice]),
            certificateInstaller: FailingSimulatorCertificateInstaller(),
            verificationService: verifier,
            certificateAuthority: StubSimulatorCertificateAuthority()
        )
        await viewModel.refreshDevicesNow()

        await viewModel.verifySelectedSimulatorRoutingNow()

        if case .commandFailed(let message) = viewModel.verificationResult {
            XCTAssertTrue(SimulatorSetupViewModel.isSandboxError(message))
        } else {
            XCTFail("Expected commandFailed verification result, got \(viewModel.verificationResult)")
        }
    }

    private static let selectableDevice = SimulatorDevice(
        udid: "IOS-BOOTED",
        name: "iPhone 17",
        state: "Booted",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
        runtimeName: "iOS 26.4",
        platform: .iOS,
        supportTier: .verifiedFirst,
        availability: SimulatorAvailability(isAvailable: true, error: nil)
    )

    private static func makeSession(host: String) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: host,
                port: 80,
                path: "/",
                headers: [HTTPHeaderField(name: "Host", value: host)],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private static let simctlListJSON = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
          {
            "state": "Booted",
            "isAvailable": true,
            "name": "iPhone 17",
            "udid": "IOS-BOOTED"
          },
          {
            "state": "Shutdown",
            "isAvailable": true,
            "name": "iPad Pro 13-inch",
            "udid": "IPAD-SHUTDOWN"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-26-4": [
          {
            "state": "Shutdown",
            "isAvailable": false,
            "availabilityError": "runtime profile not found",
            "name": "Apple TV",
            "udid": "TV-UNAVAILABLE"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-26-4": [
          {
            "state": "Booted",
            "isAvailable": true,
            "name": "Apple Watch",
            "udid": "WATCH-BOOTED"
          }
        ]
      },
      "runtimes": [
        {
          "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
          "name": "iOS 26.4"
        },
        {
          "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-4",
          "name": "tvOS 26.4"
        },
        {
          "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
          "name": "watchOS 26.4"
        }
      ]
    }
    """
}

private final class RecordingSimulatorCommandRunner: SimulatorCommandRunning, @unchecked Sendable {
    struct Request: Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    private let result: Result<SimulatorCommandExecutionResult, Error>
    private(set) var requests: [Request] = []

    init(result: Result<SimulatorCommandExecutionResult, Error>) {
        self.result = result
    }

    func run(executableURL: URL, arguments: [String]) async throws -> SimulatorCommandExecutionResult {
        requests.append(Request(executableURL: executableURL, arguments: arguments))
        return try result.get()
    }
}

private final class StubSimulatorCertificateAuthority: CertificateAuthorityProviding {
    private(set) var loadOrCreateCount = 0

    func currentRootCertificate() -> RootCertificateIdentity? {
        nil
    }

    func loadOrCreateRootCertificate() throws -> RootCertificateIdentity {
        loadOrCreateCount += 1
        return RootCertificateIdentity(
            label: "JoesProxy Root CA",
            subjectSummary: "JoesProxy Root CA",
            certificateData: Data("certificate".utf8),
            privateKeyData: nil
        )
    }

    func issueLeafCertificate(for host: String) throws -> IssuedLeafCertificate {
        throw StubError.message("not used")
    }
}

private struct StaticSimulatorDiscovery: SimulatorDiscovering {
    let devices: [SimulatorDevice]

    func discoverSimulators() async throws -> [SimulatorDevice] {
        devices
    }
}

private struct FailingSimulatorCertificateInstaller: SimulatorCertificateInstalling {
    func installCertificate(on simulator: SimulatorDevice) async throws -> SimulatorSetupCommandResult {
        throw StubError.message("xcrun: error: cannot be used within an App Sandbox.")
    }

    func installCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult {
        SimulatorSetupCommandResult(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "keychain", simulator.udid, "add-root-cert", "<path-to-joesproxy-root-ca.cer>"],
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }
}

private struct StaticSimulatorVerifier: SimulatorVerifying {
    func verifyHTTPRouting(on simulator: SimulatorDevice) async -> SimulatorVerificationResult {
        .ready
    }

    func verificationCommand(for simulator: SimulatorDevice) -> SimulatorSetupCommandResult {
        SimulatorSetupCommandResult(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "openurl", simulator.udid, "http://captive.apple.com/"],
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }
}

private enum StubError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
