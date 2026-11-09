import XCTest
@testable import JoesProxy

final class ProfilingMemoryGuardTests: XCTestCase {
    private let arguments = ["--ui-test-memory-guard", "--ui-test-suppress-launch-recovery"]
    private let environment = ["JOESPROXY_PROFILE_METRICS_PORT": "12345",
                               "JOESPROXY_PROFILE_METRICS_TOKEN": "930F12CD-07DF-44E1-8BFE-02179C11497F"]

    func testCannotEnableForNormalOrNonisolatedLaunch() {
        XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: arguments, environment: environment, isolated: false))
        XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: [], environment: environment, isolated: true))
        XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: [arguments[0]], environment: environment, isolated: true))
    }

    func testRejectsInvalidEndpointAndToken() {
        for port in ["0", "65536", "invalid"] {
            var invalid = environment
            invalid["JOESPROXY_PROFILE_METRICS_PORT"] = port
            XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: arguments, environment: invalid, isolated: true))
        }
        var invalid = environment
        invalid["JOESPROXY_PROFILE_METRICS_TOKEN"] = ""
        XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: arguments, environment: invalid, isolated: true))
    }

    func testSafetyIsFailClosedAtCeilingAndUnavailableMetrics() throws {
        let configuration = try XCTUnwrap(ProfilingMemoryGuardConfiguration(arguments: arguments, environment: environment, isolated: true))
        XCTAssertNil(configuration.stopExitCode(footprint: configuration.limit - 1))
        XCTAssertEqual(configuration.stopExitCode(footprint: configuration.limit), 78)
        XCTAssertEqual(configuration.stopExitCode(footprint: nil), 77)
        XCTAssertEqual(configuration.stopExitCode(footprint: 0), 77)
    }

    func testCutoffProbeRequiresSameIsolationContract() throws {
        let probe = arguments + ["--ui-test-memory-cutoff-probe"]
        XCTAssertNil(ProfilingMemoryGuardConfiguration(arguments: probe, environment: environment, isolated: false))
        let configuration = try XCTUnwrap(ProfilingMemoryGuardConfiguration(arguments: probe, environment: environment, isolated: true))
        XCTAssertEqual(configuration.stopExitCode(footprint: 1), 78)
    }
}
