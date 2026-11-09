import XCTest
@testable import JoesProxy

/// Coverage for MCP client-kind inference used after credential rotate.
final class MCPClientKindTests: XCTestCase {
    func testInferredExactDefaultDisplayNames() {
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "joesproxy-cli"), .joesProxyCLI)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "claude-code"), .claudeCode)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "claude-desktop"), .claudeDesktop)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "codex"), .codexCLI)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "cursor"), .cursor)
    }

    func testInferredUniqueDisplayNameSuffix() {
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "joesproxy-cli (2)"), .joesProxyCLI)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "claude-code (3)"), .claudeCode)
    }

    func testInferredUnrecognizedNameIsOther() {
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "My Agent"), .other)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: ""), .other)
        XCTAssertEqual(MCPClientKind.inferred(fromDisplayName: "  "), .other)
    }
}
