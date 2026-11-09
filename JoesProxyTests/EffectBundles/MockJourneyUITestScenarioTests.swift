import XCTest
@testable import JoesProxy

@MainActor
final class MockJourneyUITestScenarioTests: XCTestCase {
    func testClientReceivesAuthoredListDetailArtworkAndRestoresBaseline() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/MockJourney-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = MockJourneyUITestScenario()
        await scenario.run(root: root)
        XCTAssertTrue(scenario.complete, scenario.status)
        XCTAssertTrue(scenario.stopped)
        XCTAssertEqual(scenario.title, "Mock item")
        XCTAssertEqual(scenario.detail, "Mock detail")
        XCTAssertNotNil(scenario.image)
        XCTAssertEqual(scenario.receivedPNG, try MockIconRenderer.seal().png)
        XCTAssertEqual(scenario.receiptCount, 3)
        await scenario.run(root: root)
        XCTAssertEqual(scenario.receiptCount, 3, "Repeated presentation must not restart the journey")
    }
}
