import Foundation
import XCTest
@testable import JoesProxy

final class JSONPathResolverTests: XCTestCase {
    private let movieFixture = Data(
        """
        {
          "movie": {
            "title": "Clueless",
            "shortDescription": "Cher's world unravels.",
            "castNames": ["Alicia Silverstone"]
          }
        }
        """.utf8
    )

    func testChildPathBuildsNestedDotNotation() {
        XCTAssertEqual(JSONPathResolver.childPath(parentPath: "movie", segmentKey: "shortDescription"), "movie.shortDescription")
        XCTAssertEqual(JSONPathResolver.childPath(parentPath: "items", segmentKey: "[0]"), "items[0]")
    }

    func testPathsForLeafKeyFindsNestedField() {
        let paths = JSONPathResolver.paths(forLeafKey: "shortDescription", in: movieFixture)
        XCTAssertEqual(paths, ["movie.shortDescription"])
    }

    func testPathsForLeafKeyAndValueDisambiguates() {
        let paths = JSONPathResolver.paths(
            forLeafKey: "shortDescription",
            matchingValue: "Cher's world unravels.",
            in: movieFixture
        )
        XCTAssertEqual(paths, ["movie.shortDescription"])
    }

    func testParsePrettifiedLineExtractsKeyAndValue() {
        let parsed = JSONPathResolver.parsePrettifiedLine(
            #""shortDescription" : "Cher's world unravels.","#
        )
        XCTAssertEqual(parsed?.key, "shortDescription")
        XCTAssertEqual(parsed?.value, "Cher's world unravels.")
    }

    func testJSONContentSourceStableIDIsDeterministic() {
        let first = JSONContentSource.stableID(for: movieFixture)
        let second = JSONContentSource.stableID(for: movieFixture)
        XCTAssertEqual(first, second)
    }
}
