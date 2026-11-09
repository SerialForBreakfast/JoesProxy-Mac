import XCTest
@testable import JoesProxy

final class SessionFindPresentationTests: XCTestCase {
    func testDisplayedResultsCapsAtVisibleLimit() {
        let results = (0..<250).map { index in
            makeResult(index: index)
        }

        let displayed = SessionFindPresentation.displayedResults(
            from: results,
            visibleLimit: SessionFindPresentation.initialVisibleResultCount
        )

        XCTAssertEqual(displayed.count, 200)
        XCTAssertEqual(displayed.first?.path, "/match/0")
        XCTAssertEqual(displayed.last?.path, "/match/199")
    }

    func testHiddenResultCountReportsRemainingMatches() {
        XCTAssertEqual(
            SessionFindPresentation.hiddenResultCount(totalCount: 250, visibleLimit: 200),
            50
        )
        XCTAssertEqual(
            SessionFindPresentation.hiddenResultCount(totalCount: 120, visibleLimit: 200),
            0
        )
    }

    func testNextVisibleLimitIncrementsInPagesUntilTotal() {
        XCTAssertEqual(
            SessionFindPresentation.nextVisibleLimit(currentLimit: 200, totalCount: 450),
            400
        )
        XCTAssertEqual(
            SessionFindPresentation.nextVisibleLimit(currentLimit: 400, totalCount: 450),
            450
        )
        XCTAssertEqual(
            SessionFindPresentation.nextVisibleLimit(currentLimit: 450, totalCount: 450),
            450
        )
    }

    func testInitialVisibleLimitUsesSmallerOfCapAndTotal() {
        XCTAssertEqual(SessionFindPresentation.initialVisibleLimit(for: 450), 200)
        XCTAssertEqual(SessionFindPresentation.initialVisibleLimit(for: 12), 12)
    }

    private func makeResult(index: Int) -> SessionFindResult {
        SessionFindResult(
            sessionID: UUID(),
            location: .responseBody,
            matchCount: 1,
            method: "GET",
            host: "api.example.com",
            path: "/match/\(index)",
            statusCode: 200
        )
    }
}
