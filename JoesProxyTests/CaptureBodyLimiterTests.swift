import Foundation
import XCTest
@testable import JoesProxy

final class CaptureBodyLimiterTests: XCTestCase {
    func testTerminalHandoffReleasesCollectorWithoutChangingCapturedBytes() {
        let collector = BoundedCaptureAccumulator(limit: 4)
        collector.append(data: Data("abcdef".utf8))
        let captured = collector.takeFinalizedBody()
        XCTAssertEqual(captured.data, Data("abcd".utf8))
        XCTAssertEqual(captured.size, 6)
        XCTAssertTrue(captured.truncated)
        XCTAssertNil(collector.finalize().data)
        XCTAssertNil(collector.finalize().size)
    }
    func testEmptyBodyIsNotRetainedOrMarkedTruncated() {
        let retained = CaptureBodyLimiter(limit: 4).retainedBody(from: Data())

        XCTAssertNil(retained.data)
        XCTAssertNil(retained.size)
        XCTAssertFalse(retained.truncated)
    }

    func testBodyWithinLimitIsRetainedWithOriginalSize() {
        let body = Data("abcd".utf8)
        let retained = CaptureBodyLimiter(limit: 4).retainedBody(from: body)

        XCTAssertEqual(retained.data, body)
        XCTAssertEqual(retained.size, 4)
        XCTAssertFalse(retained.truncated)
    }

    func testBodyExceedingLimitIsTrimmedButReportsOriginalSize() {
        let retained = CaptureBodyLimiter(limit: 4).retainedBody(from: Data("abcdef".utf8))

        XCTAssertEqual(retained.data, Data("abcd".utf8))
        XCTAssertEqual(retained.size, 6)
        XCTAssertTrue(retained.truncated)
    }
}
