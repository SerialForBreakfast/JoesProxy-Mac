import XCTest
@testable import JoesProxy

final class MockInstrumentsCommandRunner: InstrumentsCommandRunning, @unchecked Sendable {
    var capturedExecutableURL: URL?
    var capturedArguments: [String] = []
    var stubbedResult: InstrumentsCommandExecutionResult = InstrumentsCommandExecutionResult(
        executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [],
        exitCode: 0,
        standardOutput: "",
        standardError: ""
    )

    func run(executableURL: URL, arguments: [String]) async throws -> InstrumentsCommandExecutionResult {
        capturedExecutableURL = executableURL
        capturedArguments = arguments
        return stubbedResult
    }
}

final class InstrumentsTraceCoordinatorTests: XCTestCase {

    func testListTemplatesParsesCLIOutput() async throws {
        let runner = MockInstrumentsCommandRunner()
        runner.stubbedResult = InstrumentsCommandExecutionResult(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xctrace", "list", "templates"],
            exitCode: 0,
            standardOutput: """
            == Standard Templates: ==
            Time Profiler
            Hangs / Hitches
            Allocations
            SwiftUI
            """,
            standardError: ""
        )

        let coordinator = InstrumentsTraceCoordinator(commandRunner: runner)
        let templates = try await coordinator.listTemplates()

        XCTAssertEqual(runner.capturedArguments, ["xctrace", "list", "templates"])
        XCTAssertEqual(templates.count, 4)
        XCTAssertEqual(templates.map(\.name), ["Time Profiler", "Hangs / Hitches", "Allocations", "SwiftUI"])
    }

    func testListDevicesParsesSimulatorsAndHost() async throws {
        let runner = MockInstrumentsCommandRunner()
        runner.stubbedResult = InstrumentsCommandExecutionResult(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xctrace", "list", "devices"],
            exitCode: 0,
            standardOutput: """
            == Devices: ==
            Mac Host (00008103-0001)

            == Simulator Devices: ==
            iPhone 16 Pro (A1B2C3D4-E5F6)
            Apple TV 4K (3rd generation) (D4C3B2A1-F6E5)
            """,
            standardError: ""
        )

        let coordinator = InstrumentsTraceCoordinator(commandRunner: runner)
        let devices = try await coordinator.listDevices()

        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].name, "Mac Host")
        XCTAssertFalse(devices[0].isSimulator)
        XCTAssertEqual(devices[1].name, "iPhone 16 Pro")
        XCTAssertTrue(devices[1].isSimulator)
        XCTAssertEqual(devices[1].identifier, "A1B2C3D4-E5F6")
    }

    func testRecordTraceBuildsCorrectArguments() async throws {
        let runner = MockInstrumentsCommandRunner()
        runner.stubbedResult = InstrumentsCommandExecutionResult(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [],
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_out.trace")
        let coordinator = InstrumentsTraceCoordinator(commandRunner: runner)
        let config = InstrumentsTraceSessionConfig(
            templateName: "Hangs / Hitches",
            targetProcess: "TargetApp",
            targetDeviceIdentifier: "booted",
            timeLimitSeconds: 15,
            outputTraceURL: tempURL
        )

        let result = try await coordinator.recordTrace(config: config)

        XCTAssertEqual(result.traceURL, tempURL)
        XCTAssertTrue(runner.capturedArguments.contains("xctrace"))
        XCTAssertTrue(runner.capturedArguments.contains("record"))
        XCTAssertTrue(runner.capturedArguments.contains("Hangs / Hitches"))
        XCTAssertTrue(runner.capturedArguments.contains("15s"))
        XCTAssertTrue(runner.capturedArguments.contains("TargetApp"))
    }
}
