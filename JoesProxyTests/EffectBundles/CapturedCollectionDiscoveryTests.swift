import XCTest
@testable import JoesProxy

final class CapturedCollectionDiscoveryTests: XCTestCase {
    func testResponseAvailabilityAndEncodingCannotBeBypassed() throws {
        let data = Data(#"{"items":[]}"#.utf8)
        let complete = CapturedResponse(statusCode: 200, headers: [], bodyData: data, bodySize: data.count)
        XCTAssertEqual(try CapturedCollectionDiscovery.inspect(response: complete).collections,
            [.init(pointer: "/items", count: 0)])
        let truncated = CapturedResponse(statusCode: 200, headers: [], bodyData: data,
            bodySize: data.count, bodyTruncated: true)
        XCTAssertThrowsError(try CapturedCollectionDiscovery.inspect(response: truncated))
        let malformedCompression = CapturedResponse(statusCode: 200,
            headers: [.init(name: "Content-Encoding", value: "gzip")], bodyData: data, bodySize: data.count)
        XCTAssertThrowsError(try CapturedCollectionDiscovery.inspect(response: malformedCompression))
    }

    func testNestedArraysAndEscapedPointersWithoutValues() throws {
        let result = try CapturedCollectionDiscovery.inspect(Data(#"{"a/b~c":[{"children":[]}],"empty":[],"secret":"not returned"}"#.utf8))
        XCTAssertEqual(result.collections, [
            .init(pointer: "/a~1b~0c", count: 1),
            .init(pointer: "/a~1b~0c/0/children", count: 0),
            .init(pointer: "/empty", count: 0)
        ])
        XCTAssertFalse(result.truncated)
    }

    func testRootArrayAndTraversalBudgetAreExplicit() throws {
        let input = try JSONSerialization.data(withJSONObject: Array(repeating: ["children": []], count: 100))
        let result = try CapturedCollectionDiscovery.inspect(input)
        XCTAssertEqual(result.collections.first, .init(pointer: "", count: 100))
        XCTAssertEqual(result.collections.count, 33)
        XCTAssertTrue(result.truncated)
    }

    func testMalformedAndOversizeBodiesAreRejected() {
        XCTAssertThrowsError(try CapturedCollectionDiscovery.inspect(Data("{".utf8)))
        XCTAssertThrowsError(try CapturedCollectionDiscovery.inspect(Data(repeating: 32,
            count: CollectionMockCompiler.maximumBodyBytes + 1))) {
            XCTAssertEqual($0 as? CollectionMockError, .sizeLimit)
        }
    }
}
