import Foundation
import XCTest
@testable import JoesProxy

final class CaptureHealthStripTests: XCTestCase {

    func testHealthLevelSafeBoundary() {
        XCTAssertEqual(HealthLevel(fraction: 0.0), .safe)
        XCTAssertEqual(HealthLevel(fraction: 0.74), .safe)
        XCTAssertEqual(HealthLevel(fraction: 0.749), .safe)
    }

    func testHealthLevelCautionBoundary() {
        XCTAssertEqual(HealthLevel(fraction: 0.75), .caution)
        XCTAssertEqual(HealthLevel(fraction: 0.99), .caution)
        XCTAssertEqual(HealthLevel(fraction: 1.0), .caution)
    }

    func testHealthLevelCriticalBoundary() {
        XCTAssertEqual(HealthLevel(fraction: 1.01), .critical)
        XCTAssertEqual(HealthLevel(fraction: 2.0), .critical)
        XCTAssertEqual(HealthLevel(fraction: 100.0), .critical)
    }

    func testHealthLevelColors() {
        XCTAssertEqual(HealthLevel.safe.color, .green)
        XCTAssertEqual(HealthLevel.caution.color, .yellow)
        XCTAssertEqual(HealthLevel.critical.color, .red)
    }
}
