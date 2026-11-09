import XCTest
@testable import JoesProxy

final class AgentWorkspaceDiagnosticsTests: XCTestCase {
    private let arguments = ["--agent-workspace-diagnostics"]
    private let environment = ["JOESPROXY_AGENT_WORKSPACE_DIAGNOSTICS": "1"]

    func testConfigurationRejectsNormalAndIncompleteLaunches() {
        XCTAssertNil(AgentWorkspaceDiagnosticsConfiguration(
            arguments: arguments,
            environment: environment,
            isolated: false
        ))
        XCTAssertNil(AgentWorkspaceDiagnosticsConfiguration(
            arguments: [],
            environment: environment,
            isolated: true
        ))
        XCTAssertNil(AgentWorkspaceDiagnosticsConfiguration(
            arguments: arguments,
            environment: [:],
            isolated: true
        ))
    }

    func testDisabledRecorderProducesNoSnapshot() {
        let diagnostics = AgentWorkspaceDiagnostics()
        diagnostics.configure(arguments: arguments, environment: environment, isolated: false)
        diagnostics.recordInspectorModelConstruction()
        XCTAssertNil(diagnostics.currentSnapshot())
    }

    func testRecorderSeparatesPresentationFromExplicitAgentAnalysis() throws {
        let diagnostics = AgentWorkspaceDiagnostics()
        diagnostics.configure(arguments: arguments, environment: environment, isolated: true)
        diagnostics.recordInspectorModelConstruction()
        diagnostics.recordInspectorSubscription()
        diagnostics.recordInspectorPresentation(active: false)
        diagnostics.recordInspectorPresentation(active: true)
        diagnostics.recordExplicitAgentAnalysis()
        diagnostics.recordInspectorModelRelease()

        XCTAssertEqual(try XCTUnwrap(diagnostics.currentSnapshot()), AgentWorkspaceDiagnosticSnapshot(
            inspectorModelConstructionCount: 1,
            inspectorModelReleaseCount: 1,
            inspectorSubscriptionCount: 1,
            inspectorPresentationActivationCount: 1,
            inspectorPresentationDeactivationCount: 1,
            explicitAgentAnalysisCount: 1
        ))
    }

    func testRecordingDoesNotRetainAnOwner() {
        let diagnostics = AgentWorkspaceDiagnostics()
        diagnostics.configure(arguments: arguments, environment: environment, isolated: true)
        weak var owner: NSObject?
        autoreleasepool {
            let temporaryOwner = NSObject()
            owner = temporaryOwner
            diagnostics.recordInspectorModelConstruction()
        }
        XCTAssertNil(owner)
    }
}
