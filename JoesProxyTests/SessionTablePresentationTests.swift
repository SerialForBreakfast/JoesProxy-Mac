import XCTest
@testable import JoesProxy

final class SessionTablePresentationTests: XCTestCase {
    func testDisplayedSessionsCapsNewestFirstAtVisibleLimit() {
        // Input is always ascending (oldest first). newestFirst=true takes the last N and reverses.
        let sessions = (0..<600).map { makeSession(index: $0) }

        let displayed = SessionTablePresentation.displayedSessions(
            from: sessions,
            visibleLimit: 500,
            newestFirst: true
        )

        XCTAssertEqual(displayed.count, 500)
        XCTAssertEqual(displayed.first?.request.path, "/item/599")
        XCTAssertEqual(displayed.last?.request.path, "/item/100")
    }

    func testDisplayedSessionsCapsOldestFirstAtVisibleLimit() {
        // Input is always ascending (oldest first). newestFirst=false takes the first N.
        let sessions = (0..<600).map { makeSession(index: $0) }

        let displayed = SessionTablePresentation.displayedSessions(
            from: sessions,
            visibleLimit: 500,
            newestFirst: false
        )

        XCTAssertEqual(displayed.count, 500)
        XCTAssertEqual(displayed.first?.request.path, "/item/0")
        XCTAssertEqual(displayed.last?.request.path, "/item/499")
    }

    func testHiddenSessionCountReportsRemainingRows() {
        XCTAssertEqual(SessionTablePresentation.hiddenSessionCount(totalCount: 600, visibleLimit: 500), 100)
        XCTAssertEqual(SessionTablePresentation.hiddenSessionCount(totalCount: 120, visibleLimit: 500), 0)
    }

    func testNextVisibleLimitIncrementsInPagesUntilTotal() {
        XCTAssertEqual(SessionTablePresentation.nextVisibleLimit(currentLimit: 500, totalCount: 1_200), 1_000)
        XCTAssertEqual(SessionTablePresentation.nextVisibleLimit(currentLimit: 1_000, totalCount: 1_200), 1_200)
    }

    // MARK: - isIndexWithinWindow

    func testIsIndexWithinWindowMatchesNewestFirstBoundary() {
        // 600 elements, visibleLimit 500, newestFirst: the windowed slice is indices 100...599.
        let sessions = (0..<600).map { makeSession(index: $0) }
        let displayed = SessionTablePresentation.displayedSessions(from: sessions, visibleLimit: 500, newestFirst: true)
        let displayedPaths = Set(displayed.map(\.request.path))

        for index in [0, 50, 99, 100, 101, 300, 599] {
            let expected = displayedPaths.contains(sessions[index].request.path)
            XCTAssertEqual(
                SessionTablePresentation.isIndexWithinWindow(index: index, totalCount: 600, visibleLimit: 500, newestFirst: true),
                expected,
                "index \(index) disagreed with displayedSessions(...)"
            )
        }
    }

    func testIsIndexWithinWindowMatchesOldestFirstBoundary() {
        // 600 elements, visibleLimit 500, oldest-first: the windowed slice is indices 0...499.
        let sessions = (0..<600).map { makeSession(index: $0) }
        let displayed = SessionTablePresentation.displayedSessions(from: sessions, visibleLimit: 500, newestFirst: false)
        let displayedPaths = Set(displayed.map(\.request.path))

        for index in [0, 50, 300, 499, 500, 501, 599] {
            let expected = displayedPaths.contains(sessions[index].request.path)
            XCTAssertEqual(
                SessionTablePresentation.isIndexWithinWindow(index: index, totalCount: 600, visibleLimit: 500, newestFirst: false),
                expected,
                "index \(index) disagreed with displayedSessions(...)"
            )
        }
    }

    func testIsIndexWithinWindowEverythingInWindowWhenUnderLimit() {
        for index in [0, 5, 9] {
            XCTAssertTrue(
                SessionTablePresentation.isIndexWithinWindow(index: index, totalCount: 10, visibleLimit: 500, newestFirst: true)
            )
        }
    }

    // MARK: - displayedSessionsPinningSelection

    func testDisplayedSessionsPinningSelectionAppendsExcludedOlderSessionNewestFirst() {
        let sessions = (0..<600).map { makeSession(index: $0) }

        let result = SessionTablePresentation.displayedSessionsPinningSelection(
            from: sessions,
            visibleLimit: 500,
            newestFirst: true,
            selectedIndex: 0 // oldest session, excluded by the newest-first window
        )

        XCTAssertEqual(result.count, 501)
        XCTAssertEqual(result.last?.request.path, "/item/0")
    }

    func testDisplayedSessionsPinningSelectionAppendsExcludedNewerSessionOldestFirst() {
        let sessions = (0..<600).map { makeSession(index: $0) }

        let result = SessionTablePresentation.displayedSessionsPinningSelection(
            from: sessions,
            visibleLimit: 500,
            newestFirst: false,
            selectedIndex: 599 // newest session, excluded by the oldest-first window
        )

        XCTAssertEqual(result.count, 501)
        XCTAssertEqual(result.last?.request.path, "/item/599")
    }

    func testDisplayedSessionsPinningSelectionDoesNotDuplicateWhenAlreadyInWindow() {
        let sessions = (0..<600).map { makeSession(index: $0) }

        let result = SessionTablePresentation.displayedSessionsPinningSelection(
            from: sessions,
            visibleLimit: 500,
            newestFirst: true,
            selectedIndex: 599 // newest session, already inside the newest-first window
        )

        XCTAssertEqual(result.count, 500, "selection already in-window must not be appended a second time")
        XCTAssertEqual(result.filter { $0.request.path == "/item/599" }.count, 1)
    }

    func testDisplayedSessionsPinningSelectionNoOpWhenSelectedIndexNil() {
        let sessions = (0..<600).map { makeSession(index: $0) }

        let result = SessionTablePresentation.displayedSessionsPinningSelection(
            from: sessions,
            visibleLimit: 500,
            newestFirst: true,
            selectedIndex: nil
        )

        XCTAssertEqual(result.count, 500)
    }

    func testDisplayedSessionsPinningSelectionNoOpWhenSelectedIndexOutOfRange() {
        let sessions = (0..<600).map { makeSession(index: $0) }

        let result = SessionTablePresentation.displayedSessionsPinningSelection(
            from: sessions,
            visibleLimit: 500,
            newestFirst: true,
            selectedIndex: 5_000
        )

        XCTAssertEqual(result.count, 500)
    }

    private func makeSession(index: Int) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/item/\(index)",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        )
    }
}
