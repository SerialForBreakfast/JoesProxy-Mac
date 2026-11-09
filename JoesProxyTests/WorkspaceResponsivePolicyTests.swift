import SwiftUI
import XCTest
@testable import JoesProxy

final class WorkspaceResponsivePolicyTests: XCTestCase {
    func testExpansionHasHysteresisButCollapseIsImmediate() {
        let focused = WorkspaceLayoutState(tier: .focused, height: .constrained)
        let held = WorkspaceResponsivePolicy.window(size: CGSize(width: 975, height: 655), textScale: 1, previous: focused)
        XCTAssertEqual(held, focused)
        let expanded = WorkspaceResponsivePolicy.window(size: CGSize(width: 976, height: 656), textScale: 1, previous: held)
        XCTAssertEqual(expanded, WorkspaceLayoutState(tier: .grouped, height: .normal))
        XCTAssertEqual(WorkspaceResponsivePolicy.window(size: CGSize(width: 959, height: 639), textScale: 1, previous: expanded), focused)
    }

    func testInitialMeasurementUsesExactBreakpoints() {
        XCTAssertEqual(WorkspaceResponsivePolicy.window(size: CGSize(width: 1380, height: 640), textScale: 1, previous: nil),
                       WorkspaceLayoutState(tier: .expanded, height: .normal))
        XCTAssertEqual(WorkspaceResponsivePolicy.window(size: CGSize(width: 720, height: 560), textScale: 1, previous: nil).tier, .focused)
    }

    func testPanePolicyAccountsForPaddingAndTextScale() {
        XCTAssertEqual(WorkspaceResponsivePolicy.pane(width: 666, textScale: 1, kind: .browser, previous: nil), .roomy)
        XCTAssertEqual(WorkspaceResponsivePolicy.pane(width: 666, textScale: 1.5, kind: .browser, previous: nil), .narrow)
        XCTAssertEqual(WorkspaceResponsivePolicy.pane(width: 536, textScale: 1, kind: .inspector, previous: .compact), .compact)
        XCTAssertEqual(WorkspaceResponsivePolicy.pane(width: 552, textScale: 1, kind: .inspector, previous: .compact), .roomy)
    }

    func testRepeatedSubthresholdResizesDoNotChangeComposition() {
        var state = WorkspaceLayoutState(tier: .grouped, height: .normal)
        for width in 1000...1300 {
            let next = WorkspaceResponsivePolicy.window(size: CGSize(width: width, height: 700), textScale: 1, previous: state)
            XCTAssertEqual(next, state)
            state = next
        }
    }

    func testTextScalingIsBoundedForWindowButNotPaneFit() {
        XCTAssertEqual(WorkspaceResponsivePolicy.window(size: CGSize(width: 1200, height: 760), textScale: 2, previous: nil).tier, .grouped)
        XCTAssertEqual(WorkspaceResponsivePolicy.pane(width: 650, textScale: 2, kind: .browser, previous: nil), .narrow)
    }
}
