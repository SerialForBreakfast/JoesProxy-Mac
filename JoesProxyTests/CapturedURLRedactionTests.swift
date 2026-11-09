import XCTest
@testable import JoesProxy

final class CapturedURLRedactionTests: XCTestCase {
    func testStripsQueryAndFragmentFromDisplayURL() {
        let redacted = CapturedURLRedaction.displayString(
            for: "https://ads.example.com/vast?userid=secret&sessionid=abc#frag"
        )
        XCTAssertEqual(redacted, "https://ads.example.com/vast")
    }
}
