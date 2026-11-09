import SwiftUI
import XCTest
@testable import JoesProxy

final class CompactLayoutTests: XCTestCase {
    @MainActor
    func testCompactFrameReservesUnobscuredContentAcrossTitlebarStyles() {
        let contentSize = CGSize(width: 321, height: 452)
        for fullSizeContent in [false, true] {
            var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
            if fullSizeContent { style.insert(.fullSizeContentView) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let target = CompactWindowSizing.frameSize(for: contentSize, in: window)
            window.setFrame(NSRect(origin: .zero, size: target), display: false)
            XCTAssertEqual(window.contentLayoutRect.width, contentSize.width, accuracy: 0.5)
            XCTAssertEqual(window.contentLayoutRect.height, contentSize.height, accuracy: 0.5)
            XCTAssertEqual(CompactWindowSizing.frameSize(for: contentSize, in: window), target,
                           "A repeated correction must not accumulate titlebar space")
        }
    }

    func testCompactSizingDoesNotAccumulateSubpixelResizeCorrections() throws {
        var accepted = try XCTUnwrap(CompactWindowSizing.acceptedContentSize(
            CGSize(width: 294, height: 320), previous: nil, backingScale: 2))
        for index in 0..<1_000 {
            let jitter: CGFloat = index.isMultiple(of: 2) ? 0.1 : -0.1
            accepted = try XCTUnwrap(CompactWindowSizing.acceptedContentSize(
                CGSize(width: 294 + jitter, height: 320 - jitter),
                previous: accepted, backingScale: 2))
            XCTAssertEqual(accepted, CGSize(width: 294, height: 320))
        }
    }

    func testCompactSizingStillAdaptsToNoticeGrowthAndRemoval() throws {
        let initial = CGSize(width: 294, height: 320)
        let expanded = try XCTUnwrap(CompactWindowSizing.acceptedContentSize(
            CGSize(width: 294, height: 380.2), previous: initial, backingScale: 2))
        XCTAssertEqual(expanded, CGSize(width: 294, height: 380.5))
        XCTAssertEqual(CompactWindowSizing.acceptedContentSize(
            initial, previous: expanded, backingScale: 2), initial)
    }

    func testCompactSizingRejectsTransientInvalidLayoutMeasurements() {
        let previous = CGSize(width: 294, height: 320)
        for invalid in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 320),
                        CGSize(width: 294, height: CGFloat.nan)] {
            XCTAssertNil(CompactWindowSizing.acceptedContentSize(
                invalid, previous: previous, backingScale: 2))
        }
    }

    func testWorkspaceWindowTierBoundaries() {
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 959, textScale: 1), .focused)
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 960, textScale: 1), .grouped)
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 1_379, textScale: 1), .grouped)
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 1_380, textScale: 1), .expanded)
    }

    func testWorkspaceWindowTierUsesBoundedTextScale() {
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 1_200, textScale: 1.25), .grouped)
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 1_199, textScale: 2), .focused)
        XCTAssertEqual(WorkspaceWindowTier.resolve(width: 1_725, textScale: 2), .expanded)
    }

    func testPaneLayoutModesUseContainerWidth() {
        XCTAssertEqual(PaneLayoutMode.browser(width: 449), .narrow)
        XCTAssertEqual(PaneLayoutMode.browser(width: 450), .compact)
        XCTAssertEqual(PaneLayoutMode.browser(width: 650), .roomy)
        XCTAssertEqual(PaneLayoutMode.inspector(width: 519), .compact)
        XCTAssertEqual(PaneLayoutMode.inspector(width: 520), .roomy)
    }

    func testSplitGeometryClampsWithoutChangingStoredPreference() {
        let storedFraction = 0.75
        XCTAssertEqual(
            WorkspaceSplitGeometry.dividerPosition(
                totalWidth: 800,
                storedFraction: storedFraction,
                minimumLeadingWidth: 340,
                minimumTrailingWidth: 380
            ),
            420
        )
        XCTAssertEqual(storedFraction, 0.75)

        XCTAssertEqual(
            WorkspaceSplitGeometry.dividerPosition(
                totalWidth: 1_600,
                storedFraction: storedFraction,
                minimumLeadingWidth: 340,
                minimumTrailingWidth: 380
            ),
            1_200
        )
    }

    func testSplitGeometryRejectsWidthsThatCannotFitBothPanes() {
        XCTAssertNil(
            WorkspaceSplitGeometry.dividerPosition(
                totalWidth: 720,
                storedFraction: 0.5,
                minimumLeadingWidth: 340,
                minimumTrailingWidth: 380
            )
        )
    }

    func testBackgroundSelectionNeverOpensDetail() {
        XCTAssertEqual(
            WorkspacePaneFocus.afterBackgroundSelectionChange(
                current: .browser,
                hasValidDetailDestination: true
            ),
            .browser
        )
    }

    func testInvalidDetailDestinationReturnsExistingDetailFocusToBrowser() {
        XCTAssertEqual(
            WorkspacePaneFocus.afterBackgroundSelectionChange(
                current: .detail,
                hasValidDetailDestination: false
            ),
            .browser
        )
        XCTAssertEqual(
            WorkspacePaneFocus.afterExplicitDetailEntry(
                current: .browser,
                hasValidDetailDestination: false
            ),
            .browser
        )
    }

    func testExplicitDetailEntryRequiresAValidDestination() {
        XCTAssertEqual(
            WorkspacePaneFocus.afterExplicitDetailEntry(
                current: .browser,
                hasValidDetailDestination: true
            ),
            .detail
        )
    }

    func testTrafficModificationCountExcludesSystemRouting() {
        var snapshot = TrafficModificationSnapshot.empty
        snapshot.isSystemProxyTunnelingActive = true
        XCTAssertEqual(snapshot.activeModificationCount, 0)

        snapshot.activeMapLocalCount = 2
        snapshot.activeBlockCount = 1
        snapshot.isThrottlingEnabled = true
        XCTAssertEqual(snapshot.activeModificationCount, 4)
    }

    func testSessionTableColumnVisibilityAt480ShowsCoreColumnsOnly() {
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.method, paneWidth: 480))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.domain, paneWidth: 480))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.path, paneWidth: 480))
        XCTAssertFalse(SessionTableColumnVisibility.isVisible(.status, paneWidth: 480))
        XCTAssertFalse(SessionTableColumnVisibility.isVisible(.time, paneWidth: 480))
    }

    func testSessionTableColumnVisibilityAddsColumnsAsPaneWidens() {
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.status, paneWidth: 520))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.source, paneWidth: 560))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.media, paneWidth: 600))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.duration, paneWidth: 640))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.size, paneWidth: 680))
        XCTAssertTrue(SessionTableColumnVisibility.isVisible(.time, paneWidth: 720))
    }

    func testTableColumnCustomizationRoundTripEncoding() throws {
        let customization = TableColumnCustomization<SessionSummary>()
        let encoder = JSONEncoder()
        let data = try encoder.encode(customization)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TableColumnCustomization<SessionSummary>.self, from: data)
        XCTAssertNotNil(decoded)
    }

    func testSummaryColumnPreferencesDecodeForIdentityRows() throws {
        var legacy = TableColumnCustomization<SessionSummary>()
        legacy[visibility: "source"] = .hidden
        legacy[visibility: "duration"] = .visible
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(legacy)
        let current = try JSONDecoder().decode(
            TableColumnCustomization<SessionTableRowPresentation>.self, from: data)
        XCTAssertEqual(current[visibility: "source"], .hidden)
        XCTAssertEqual(current[visibility: "duration"], .visible)
        let roundTripped = try JSONDecoder().decode(
            TableColumnCustomization<SessionSummary>.self, from: encoder.encode(current))
        XCTAssertEqual(roundTripped[visibility: "source"], .hidden)
        XCTAssertEqual(roundTripped[visibility: "duration"], .visible)
    }

    func testSessionExplorerTreeVisibleRowNavigationOrder() {
        let session1ID = UUID()
        let session2ID = UUID()

        let record1 = SessionRecord(
            id: session1ID,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/users",
                headers: [],
                bodyData: nil,
                bodySize: 0
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: Data(),
                bodySize: 1024
            ),
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.12))
        )
        let summary1 = SessionSummary(record: record1)

        let record2 = SessionRecord(
            id: session2ID,
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/auth",
                headers: [],
                bodyData: nil,
                bodySize: 128
            ),
            response: CapturedResponse(
                statusCode: 201,
                headers: [],
                bodyData: Data(),
                bodySize: 512
            ),
            timing: SessionTiming(startedAt: Date().addingTimeInterval(1), completedAt: Date().addingTimeInterval(1.25))
        )
        let summary2 = SessionSummary(record: record2)

        let leaf1 = SessionExplorerNode(
            id: "leaf:\(session1ID.uuidString)",
            kind: .leaf,
            role: .request,
            title: "GET /v1/users",
            breadcrumbs: ["api.example.com", "v1", "users"],
            ancestorIDs: ["host:api.example.com", "path:v1"],
            aggregateCount: 1,
            failedCount: 0,
            latestActivity: summary1.startedAt,
            sessionIDs: [session1ID],
            children: [],
            summary: summary1
        )

        let leaf2 = SessionExplorerNode(
            id: "leaf:\(session2ID.uuidString)",
            kind: .leaf,
            role: .request,
            title: "POST /v1/auth",
            breadcrumbs: ["api.example.com", "v1", "auth"],
            ancestorIDs: ["host:api.example.com", "path:v1"],
            aggregateCount: 1,
            failedCount: 0,
            latestActivity: summary2.startedAt,
            sessionIDs: [session2ID],
            children: [],
            summary: summary2
        )

        let pathNode = SessionExplorerNode(
            id: "path:v1",
            kind: .folder,
            role: .path,
            title: "v1",
            breadcrumbs: ["api.example.com", "v1"],
            ancestorIDs: ["host:api.example.com"],
            aggregateCount: 2,
            failedCount: 0,
            latestActivity: summary2.startedAt,
            sessionIDs: [session1ID, session2ID],
            children: [leaf1, leaf2],
            summary: nil
        )

        let rootNode = SessionExplorerNode(
            id: "host:api.example.com",
            kind: .folder,
            role: .host,
            title: "api.example.com",
            breadcrumbs: ["api.example.com"],
            ancestorIDs: [],
            aggregateCount: 2,
            failedCount: 0,
            latestActivity: summary2.startedAt,
            sessionIDs: [session1ID, session2ID],
            children: [pathNode],
            summary: nil
        )

        let tree = SessionExplorerTree(grouping: .byHost, roots: [rootNode])

        // When all collapsed: only root is visible
        let collapsedRows = tree.visibleRows(expandedNodeIDs: [])
        XCTAssertEqual(collapsedRows.count, 1)
        XCTAssertEqual(collapsedRows[0].node.id, "host:api.example.com")
        XCTAssertEqual(collapsedRows[0].depth, 0)

        // When root is expanded: root + pathNode are visible
        let rootExpandedRows = tree.visibleRows(expandedNodeIDs: ["host:api.example.com"])
        XCTAssertEqual(rootExpandedRows.count, 2)
        XCTAssertEqual(rootExpandedRows[0].node.id, "host:api.example.com")
        XCTAssertEqual(rootExpandedRows[1].node.id, "path:v1")
        XCTAssertEqual(rootExpandedRows[1].depth, 1)

        // When all expanded: root, pathNode, leaf1, leaf2 in exact visual order
        let allExpandedRows = tree.visibleRows(expandedNodeIDs: ["host:api.example.com", "path:v1"])
        XCTAssertEqual(allExpandedRows.count, 4)
        XCTAssertEqual(allExpandedRows[0].node.id, "host:api.example.com")
        XCTAssertEqual(allExpandedRows[1].node.id, "path:v1")
        XCTAssertEqual(allExpandedRows[2].node.id, "leaf:\(session1ID.uuidString)")
        XCTAssertEqual(allExpandedRows[3].node.id, "leaf:\(session2ID.uuidString)")
        XCTAssertEqual(allExpandedRows[2].depth, 2)
        XCTAssertEqual(allExpandedRows[3].depth, 2)

        // Verify leaf lookup
        XCTAssertEqual(tree.leafNodeID(for: session1ID), "leaf:\(session1ID.uuidString)")
        XCTAssertEqual(tree.leafNodeID(for: session2ID), "leaf:\(session2ID.uuidString)")
    }

    func testDisplayedSessionsPinningSelectionGuardsAgainstDuplicates() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let ids = [id1, id2, id3]

        // When all 3 are within visibleLimit (e.g. limit 5), windowed has [id3, id2, id1] (newestFirst)
        let displayed = SessionTablePresentation.displayedSessionsPinningSelection(
            from: ids,
            visibleLimit: 5,
            newestFirst: true,
            selectedIndex: 0 // refers to id1
        )
        // id1 is already in the window, must NOT be duplicated
        XCTAssertEqual(displayed.count, 3)
        XCTAssertEqual(displayed, [id3, id2, id1])

        // When windowed has limit 2 (only id3, id2), selectedIndex 0 (id1) is outside window and gets pinned
        let pinned = SessionTablePresentation.displayedSessionsPinningSelection(
            from: ids,
            visibleLimit: 2,
            newestFirst: true,
            selectedIndex: 0 // refers to id1
        )
        XCTAssertEqual(pinned.count, 3)
        XCTAssertEqual(pinned, [id3, id2, id1])

        // Verify ID uniqueness is 100% guaranteed
        let uniqueCount = Set(pinned).count
        XCTAssertEqual(uniqueCount, pinned.count)
    }
}
