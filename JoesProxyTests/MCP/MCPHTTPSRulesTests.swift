import XCTest
@testable import JoesProxy

final class MCPHTTPSRulesTests: XCTestCase {
    func testHostValidationAndEffectiveScope() throws {
        for invalid in ["", "https://media.example.test", "*.example.test", ".example.test", "a.test:443",
                        "127.0.0.1", "[::1]", "a..test", "a.test/path", "a.test "] {
            XCTAssertThrowsError(try MCPHTTPSRules.host(invalid), invalid)
        }
        XCTAssertEqual(try MCPHTTPSRules.host("Media.Example.Test"), "media.example.test")
        XCTAssertEqual(MCPHTTPSRules.inspection(.init(), host: "media.example.test", globalMode: .passThrough)["newConnectionMode"] as? String, "tunnel")
        XCTAssertEqual(MCPHTTPSRules.inspection(.init(), host: "media.example.test")["newConnectionMode"] as? String, "unknown")
        let rules = try MCPHTTPSRules.changed(.init(), host: "media.example.test", mode: .tunnel)
        XCTAssertEqual(MCPHTTPSRules.inspection(rules, host: "child.media.example.test")["effectiveRuleMode"] as? String, "tunnel")
        XCTAssertEqual(MCPHTTPSRules.inspection(rules, host: "other.example.test")["effectiveRuleMode"] as? String, "inspect")
        XCTAssertEqual(try MCPHTTPSRules.changed(rules, host: "media.example.test", mode: .remove), .init())
        XCTAssertThrowsError(try MCPHTTPSRules.changed(rules, host: "child.media.example.test", mode: .inspect))
        let builtIn = String(TLSInterceptionPolicy.builtInBypassDomains[0].dropFirst())
        XCTAssertThrowsError(try MCPHTTPSRules.changed(.init(), host: builtIn, mode: .inspect))
    }

    func testChangesPreserveOtherRulesAndDiscovery() throws {
        let current = TLSInterceptionRules(bypassDomains: ["unrelated.test"], interceptDomains: ["inspect.test"])
        let updated = try MCPHTTPSRules.changed(current, host: "media.example.test", mode: .tunnel)
        XCTAssertEqual(updated.bypassDomains, ["unrelated.test", "media.example.test"])
        XCTAssertEqual(updated.interceptDomains, current.interceptDomains)
        XCTAssertNotEqual(MCPHTTPSRules.revision(current), MCPHTTPSRules.revision(updated))
        for toolset in MCPToolset.allCases {
            XCTAssertTrue(toolset.includes(toolName: "https_rules_get"))
            XCTAssertTrue(toolset.includes(toolName: "https_rules_set"))
            XCTAssertTrue(toolset.includes(toolName: "https_rules_restore"))
        }
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "https_rules_set"), .httpsRulesManage)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "https_rules_restore"), .httpsRulesManage)
    }
}
