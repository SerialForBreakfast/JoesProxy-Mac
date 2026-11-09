import XCTest
@testable import JoesProxy

@MainActor
final class UtilityWindowPresentationTests: XCTestCase {
    func testEarlyRequestIsDeliveredOnceAndRepeatedOpenRequestsReachSameWindow() {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        state.presentAbout()
        XCTAssertEqual(state.utilityWindowRequest?.kind, .about)
        var opened: [UtilityWindowKind] = []
        state.installUtilityWindowOpener { opened.append($0) }
        XCTAssertNil(state.utilityWindowRequest)
        state.installUtilityWindowOpener { opened.append($0) }
        state.presentAbout()
        state.presentCompactApprovals()
        state.presentCompactApprovals()
        XCTAssertEqual(opened, [.about, .about, .approvals, .approvals])
    }

    func testManagementReopenPreservesNavigationUnlessDestinationIsExplicit() {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        var opened: [UtilityWindowKind] = []
        state.installUtilityWindowOpener { opened.append($0) }
        state.presentMCPManagement(destination: .clients)
        let firstID = state.mcpManagementContext?.id
        state.presentMCPManagement()
        XCTAssertEqual(state.mcpManagementContext?.id, firstID)
        state.presentMCPManagement(destination: .clients)
        XCTAssertNotEqual(state.mcpManagementContext?.id, firstID)
        state.presentMCPManagement(destination: .agentRuns)
        XCTAssertEqual(state.mcpManagementContext?.destination, .agentRuns)
        XCTAssertEqual(opened, Array(repeating: .mcpManagement, count: 4))
    }
}
