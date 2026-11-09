import XCTest
@testable import JoesProxy

final class MutationBufferBudgetTests: XCTestCase {
    func testReservationsBoundCollectorsAndReturnCapacityOnRelease() {
        let budget = MutationBufferBudget(limit: 2)
        var first = budget.reserve()
        var second = budget.reserve()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(budget.activeCount, 2)
        XCTAssertNil(budget.reserve())
        XCTAssertEqual(budget.rejectedCount, 1)
        first = nil
        XCTAssertEqual(budget.activeCount, 1)
        var replacement = budget.reserve()
        XCTAssertNotNil(replacement)
        XCTAssertEqual(budget.activeCount, 2)
        second = nil
        replacement = nil
        XCTAssertEqual(budget.activeCount, 0)
    }
}
