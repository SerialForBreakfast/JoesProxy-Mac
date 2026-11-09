import XCTest
@testable import JoesProxy

final class MCPInstrumentsToolsTests: XCTestCase {

    func testInstrumentsToolsAreDeclaredInProductionTools() {
        let tools = MCPCapabilitiesManifestBuilder.productionTools.map(\.name)
        XCTAssertTrue(tools.contains("instruments_list_templates"))
        XCTAssertTrue(tools.contains("instruments_record_trace"))
        XCTAssertTrue(tools.contains("instruments_analyze_trace"))
        XCTAssertTrue(tools.contains("instruments_correlated_audit"))
    }

    func testInstrumentsToolsMapToValidCapabilities() {
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "instruments_list_templates"),
            .diagnosticRunInspect
        )
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "instruments_record_trace"),
            .diagnosticRunLifecycle
        )
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "instruments_analyze_trace"),
            .diagnosticRunInspect
        )
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "instruments_correlated_audit"),
            .diagnosticRunLifecycle
        )
    }
}
