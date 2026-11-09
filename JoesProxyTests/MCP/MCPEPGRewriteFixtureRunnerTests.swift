import XCTest
@testable import JoesProxy

@MainActor
final class MCPEPGRewriteFixtureRunnerTests: XCTestCase {
    func testRunnerProducesTransformedAndRestoredTitlesThroughRealProxy() async throws {
        let result = try await MCPEPGRewriteFixtureRunner().run()

        XCTAssertEqual(result.transformedTitles, ["Morning News!", "World Report!", "Live Match!"])
        XCTAssertEqual(result.restoredTitles, ["Morning News", "World Report", "Live Match"])
        XCTAssertTrue(result.unrelatedResponseWasUnchanged)
        XCTAssertTrue(result.attributionWasRecorded)
    }
}
