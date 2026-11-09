import XCTest
@testable import JoesProxy

@MainActor
final class AgentWorkspaceProfileTests: XCTestCase {
    private var root: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/HostTestResults/AGW-unit").path
    }

    private func configuration(mode: String = "pilot") throws -> AgentWorkspaceProfileConfiguration {
        try XCTUnwrap(AgentWorkspaceProfileConfiguration(arguments: ["--agent-workspace-profile",
            "--ui-test-suppress-launch-recovery", "--ui-test-proxy-port=19090"], environment: [
                "JOESPROXY_AGW_ROOT": root, "JOESPROXY_AGW_PROTOCOL": mode,
                "JOESPROXY_PROFILE_METRICS_TOKEN": UUID().uuidString]))
    }

    func testProfileRequiresExplicitDisposableConfiguration() throws {
        XCTAssertNil(AgentWorkspaceProfileConfiguration(arguments: [], environment: [:]))
        XCTAssertNil(AgentWorkspaceProfileConfiguration(arguments: ["--agent-workspace-profile"], environment: [:]))
        XCTAssertTrue(try configuration().root.path.hasPrefix(root + "/"))
        XCTAssertEqual(try configuration(mode: "full").durations, [60, 120, 120, 180, 120])
    }

    func testSharedFactoryAndBoundedQueriesDoNotConstructInspector() throws {
        let configuration = try configuration()
        let profile = AgentWorkspaceProfile(configuration: configuration)
        let coordinator = profile.coordinator
        defer { UserDefaults(suiteName: "com.ShowBlender.JoesProxy.AGW.\(configuration.runID.uuidString)")?
            .removePersistentDomain(forName: "com.ShowBlender.JoesProxy.AGW.\(configuration.runID.uuidString)") }
        XCTAssertEqual(coordinator.configuration.proxyPort, 19090)
        XCTAssertFalse(coordinator.configuration.rollingCaptureAutoSaveEnabled)
        XCTAssertFalse(coordinator.configuration.sdkEventServerEnabled)
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        XCTAssertTrue(coordinator.mcpServerController.clientRegistry.persistenceURL.path.hasPrefix(configuration.root.path))
        profile.seed()
        XCTAssertEqual(coordinator.sessionStore.sessions.count, 10_000)
        XCTAssertNoThrow(try profile.query())
        XCTAssertFalse(coordinator.isInspectorViewModelConstructed)
        var damaged = try XCTUnwrap(coordinator.sessionStore.sessions.last)
        damaged.response = CapturedResponse(statusCode: 200, headers: [],
            bodyData: Data("incorrect".utf8), bodySize: 9)
        coordinator.sessionStore.update(damaged)
        XCTAssertThrowsError(try profile.query(), "A matching count must not hide incorrect captured bytes")
        coordinator.sessionStore.clear()
        XCTAssertThrowsError(try profile.query())
    }

    func testPrototypeIncludesTheSameFixtureResourceFolder() throws {
        let projectURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JoesProxy.xcodeproj/project.pbxproj")
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: projectURL), options: [], format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let target = try XCTUnwrap(objects["C40000032F00000100844D6D"])
        let phase = try XCTUnwrap(objects["C40000062F00000100844D6D"])
        let fixture = try XCTUnwrap(objects["C40000162F00000100844D6D"])
        XCTAssertTrue(try XCTUnwrap(target["buildPhases"] as? [String]).contains("C40000062F00000100844D6D"))
        XCTAssertTrue(try XCTUnwrap(phase["files"] as? [String]).contains("C40000162F00000100844D6D"))
        XCTAssertEqual(fixture["fileRef"] as? String, "A2B300022F20000100844D6D")
    }
}
