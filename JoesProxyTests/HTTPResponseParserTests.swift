import XCTest
@testable import JoesProxy

final class HTTPResponseParserTests: XCTestCase {
    private let parser = HTTPResponseParser()

    func testDetectsContentLengthBoundedResponseAsComplete() throws {
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Length: 5\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n" +
            "hello"

        let responseData = Data(response.utf8)

        XCTAssertTrue(parser.isCompleteResponse(responseData, requestMethod: "GET"))

        let parsed = try parser.parse(responseData)
        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertEqual(parsed.body, Data("hello".utf8))
    }

    func testDetectsChunkedResponseAsComplete() {
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "4\r\nWiki\r\n" +
            "5\r\npedia\r\n" +
            "0\r\n\r\n"

        XCTAssertTrue(parser.isCompleteResponse(Data(response.utf8), requestMethod: "GET"))
    }

    func testHeadResponseCompletesAtHeaders() {
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Length: 512\r\n" +
            "\r\n"

        XCTAssertTrue(parser.isCompleteResponse(Data(response.utf8), requestMethod: "HEAD"))
    }

    func testIncompleteChunkedResponseReturnsFalse() {
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "4\r\nWiki\r\n" +
            "0\r\n"

        XCTAssertFalse(parser.isCompleteResponse(Data(response.utf8), requestMethod: "GET"))
    }
}
