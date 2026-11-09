import XCTest
@testable import JoesProxy

@MainActor
final class MCPEffectBundleToolsTests: XCTestCase {
    func testEffectBundleToolsAreDeclaredInProductionTools() {
        let tools = MCPCapabilitiesManifestBuilder.productionTools
        let names = Set(tools.map(\.name))

        let expectedTools = [
            "effect_bundle_prepare",
            "effect_bundle_retire_preparation",
            "effect_bundle_list",
            "effect_bundle_inspect",
            "effect_bundle_import",
            "propose_activate_effect_bundle",
            "apply_activate_effect_bundle",
            "effect_bundle_stop",
            "propose_discard_effect_bundle",
            "apply_discard_effect_bundle"
        ]

        for expected in expectedTools {
            XCTAssertTrue(names.contains(expected), "Missing tool: \(expected)")
        }
    }

    func testEffectBundleToolsMapToValidCapabilities() {
        let tools = MCPCapabilitiesManifestBuilder.productionTools
        let toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.capability) })

        XCTAssertEqual(toolMap["effect_bundle_list"], .overrideInspect)
        XCTAssertEqual(toolMap["effect_bundle_prepare"], .bodyRead)
        XCTAssertEqual(toolMap["effect_bundle_retire_preparation"], .overrideInspect)
        XCTAssertTrue(MCPToolset.mocking.includes(toolName: "effect_bundle_retire_preparation"))
        XCTAssertEqual(toolMap["effect_bundle_inspect"], .overrideInspect)
        XCTAssertEqual(toolMap["effect_bundle_import"], .overrideInspect)
        XCTAssertEqual(toolMap["propose_activate_effect_bundle"], .enableRule)
        XCTAssertEqual(toolMap["apply_activate_effect_bundle"], .enableRule)
        XCTAssertEqual(toolMap["effect_bundle_stop"], .disableRule)
        XCTAssertEqual(toolMap["propose_discard_effect_bundle"], .deleteRule)
        XCTAssertEqual(toolMap["apply_discard_effect_bundle"], .deleteRule)
    }
}
