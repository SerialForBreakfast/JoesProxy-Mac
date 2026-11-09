//
//  PersistentHSplitViewObserverTests.swift
//  JoesProxyTests
//
//  Pins the resize-vs-drag classification that keeps the session/inspector split ratio
//  stable across window resizes. Before this fix, every NSSplitView.didResizeSubviewsNotification
//  — including ones caused by the window resizing, not the user dragging the divider —
//  was treated as a new user preference and persisted, corrupting the stored split fraction.
//

import XCTest
import AppKit
import SwiftUI
@testable import JoesProxy

final class PersistentHSplitViewObserverTests: XCTestCase {
    @MainActor
    func testObserverInsidePaneAttachesAndPublishesNativeAccessibility() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        split.isVertical = true
        let leading = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        split.addSubview(leading)
        split.addSubview(NSView(frame: NSRect(x: 601, y: 0, width: 599, height: 600)))
        let probe = NSView()
        leading.addSubview(probe)
        let coordinator = Coordinator(splitFraction: .constant(0.5), minLeadingWidth: 340, minTrailingWidth: 380)
        coordinator.attachIfNeeded(to: probe)
        defer { coordinator.detach() }
        XCTAssertEqual(split.accessibilityIdentifier(), "workspaceInvestigationSplit")
        XCTAssertTrue(split.isAccessibilityElement())
        XCTAssertEqual(split.accessibilityValue() as? String, "0.500")
    }

    private typealias Coordinator = PersistentHSplitViewObserver.Coordinator

    func testFirstObservationIsTreatedAsDividerDrag() {
        // No prior width to compare against yet — matches the pre-fix behavior of
        // establishing a baseline on first sight rather than reapplying a stored fraction
        // that hasn't been observed against real geometry yet.
        let kind = Coordinator.classifyResize(previousTotalWidth: nil, currentTotalWidth: 1_000)
        XCTAssertEqual(kind, .dividerDrag)
    }

    func testUnchangedTotalWidthIsTreatedAsDividerDrag() {
        let kind = Coordinator.classifyResize(previousTotalWidth: 1_000, currentTotalWidth: 1_000)
        XCTAssertEqual(kind, .dividerDrag)
    }

    func testTinySubpixelDeltaStaysWithinDragTolerance() {
        // Sub-pixel rounding jitter between layout passes must not be misread as a
        // window resize, or every drag would incorrectly reapply the stored fraction.
        let kind = Coordinator.classifyResize(previousTotalWidth: 1_000, currentTotalWidth: 1_000.2)
        XCTAssertEqual(kind, .dividerDrag)
    }

    func testWidthChangeBeyondToleranceIsTreatedAsContainerResize() {
        let grew = Coordinator.classifyResize(previousTotalWidth: 1_000, currentTotalWidth: 1_100)
        XCTAssertEqual(grew, .containerResize)

        let shrank = Coordinator.classifyResize(previousTotalWidth: 1_000, currentTotalWidth: 900)
        XCTAssertEqual(shrank, .containerResize)
    }

    func testContinuousWindowResizeStaysClassifiedAsContainerResizeThroughoutTheDrag() {
        // A live window-resize drag fires many resize notifications with progressively
        // changing total widths. Every one of them must classify as a container resize —
        // if even one were misread as a divider drag, that intermediate pixel split would
        // get persisted and the ratio would drift.
        var previousWidth: CGFloat? = 1_000
        for width: CGFloat in stride(from: 1_010, through: 1_200, by: 10) {
            let kind = Coordinator.classifyResize(previousTotalWidth: previousWidth, currentTotalWidth: width)
            XCTAssertEqual(kind, .containerResize, "width step to \(width) should classify as a container resize")
            previousWidth = width
        }
    }

    func testResizeThenSubsequentDividerDragIsClassifiedCorrectly() {
        // After a container resize settles, a genuine divider drag (total width holds
        // steady while the split point moves) must be classified as a drag again.
        let afterResize = Coordinator.classifyResize(previousTotalWidth: 1_000, currentTotalWidth: 1_100)
        XCTAssertEqual(afterResize, .containerResize)

        let subsequentDrag = Coordinator.classifyResize(previousTotalWidth: 1_100, currentTotalWidth: 1_100)
        XCTAssertEqual(subsequentDrag, .dividerDrag)
    }
}
