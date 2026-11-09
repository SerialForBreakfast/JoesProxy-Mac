import XCTest
@testable import JoesProxy

final class SessionFindExcerptBuilderTests: XCTestCase {
    private let builder = SessionFindExcerptBuilder()

    func testBuildsCaseInsensitiveExcerpt() throws {
        let result = builder.build(bodyData: data("alpha NEEDLE omega"), query: "needle")

        let excerpts = try excerpts(from: result)
        XCTAssertEqual(excerpts.count, 1)
        XCTAssertEqual(excerpts.first?.plainText, "alpha NEEDLE omega")
    }

    func testBuildsDiacriticInsensitiveExcerpt() throws {
        let result = builder.build(bodyData: data("cafe rendezvous"), query: "café")

        let excerpts = try excerpts(from: result)
        XCTAssertEqual(excerpts.first?.plainText, "cafe rendezvous")
    }

    func testLimitsExcerptCount() throws {
        let result = builder.build(
            bodyData: data("needle one needle two needle three needle four"),
            query: "needle",
            maxExcerptCount: 3,
            contextCharacterCount: 0
        )

        let excerpts = try excerpts(from: result)
        XCTAssertEqual(excerpts.map(\.plainText), ["needle...", "...needle...", "...needle..."])
    }

    func testPreservesOriginalCasingInExcerpt() throws {
        let result = builder.build(bodyData: data("prefix MixedCaseNeedle suffix"), query: "mixedcaseneedle")

        let excerpts = try excerpts(from: result)
        XCTAssertEqual(excerpts.first?.plainText, "prefix MixedCaseNeedle suffix")
    }

    func testReturnsNilForEmptyQueryNonUTF8AndNoMatch() {
        XCTAssertNil(builder.build(bodyData: data("needle"), query: "   "))
        XCTAssertNil(builder.build(bodyData: Data([0xff, 0xfe, 0xfd]), query: "needle"))
        XCTAssertNil(builder.build(bodyData: data("haystack"), query: "needle"))
    }

    func testReturnsTooLargeForOversizedBody() {
        let result = builder.build(bodyData: data("needle"), query: "needle", bodySizeLimit: 3)

        XCTAssertEqual(result, .tooLarge(actualBytes: 6, limitBytes: 3))
    }

    private func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func excerpts(from result: SessionFindExcerptResult?) throws -> [SessionFindExcerpt] {
        switch try XCTUnwrap(result) {
        case .excerpts(let excerpts):
            return excerpts
        case .tooLarge:
            XCTFail("Expected excerpts, got tooLarge")
            return []
        }
    }
}
