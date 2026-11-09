import XCTest
@testable import JoesProxy

final class HTTPRequestParserTests: XCTestCase {
    private let parser = HTTPRequestParser()

    func testParsesAbsoluteFormRequest() throws {
        let request =
            "GET http://example.com:8080/api/items?limit=10 HTTP/1.1\r\n" +
            "Host: example.com:8080\r\n" +
            "User-Agent: JoesProxyTests\r\n" +
            "\r\n"

        let parsed = try parser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.version, "HTTP/1.1")
        XCTAssertEqual(parsed.host, "example.com")
        XCTAssertEqual(parsed.port, 8080)
        XCTAssertEqual(parsed.path, "/api/items?limit=10")
        XCTAssertEqual(parsed.headers.first?.name, "Host")
    }

    func testParsesOriginFormRequestUsingHostHeader() throws {
        let request =
            "POST /submit HTTP/1.1\r\n" +
            "Host: localhost:9090\r\n" +
            "Content-Length: 4\r\n" +
            "\r\n" +
            "test"

        XCTAssertTrue(parser.isCompleteRequest(Data(request.utf8)))

        let parsed = try parser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.host, "localhost")
        XCTAssertEqual(parsed.port, 9090)
        XCTAssertEqual(parsed.path, "/submit")
        XCTAssertEqual(parsed.body, Data("test".utf8))
    }

    func testParsesConnectRequests() throws {
        let request =
            "CONNECT example.com:443 HTTP/1.1\r\n" +
            "Host: example.com:443\r\n" +
            "\r\n"

        let parsed = try parser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.kind, .connect)
        XCTAssertEqual(parsed.method, "CONNECT")
        XCTAssertEqual(parsed.host, "example.com")
        XCTAssertEqual(parsed.port, 443)
        XCTAssertEqual(parsed.path, "example.com:443")
    }

    func testIncompleteRequestReturnsFalseUntilBodyArrives() {
        let partialRequest =
            "POST /items HTTP/1.1\r\n" +
            "Host: example.com\r\n" +
            "Content-Length: 8\r\n" +
            "\r\n" +
            "1234"

        XCTAssertFalse(parser.isCompleteRequest(Data(partialRequest.utf8)))
    }

    func testAnalysisReportsExpectedLengthOnceHeaderDelimiterArrives() {
        // Headers + delimiter = 58 bytes; body = 8 bytes; total expected = 66 bytes.
        let headers =
            "POST /upload HTTP/1.1\r\n" +
            "Host: example.com\r\n" +
            "Content-Length: 8\r\n" +
            "\r\n"
        let headersData = Data(headers.utf8)
        let fullRequest = headersData + Data("12345678".utf8)
        let expectedTotal = fullRequest.count

        // Partial: headers arrived but only 4 of 8 body bytes.
        let partial = headersData + Data("1234".utf8)
        let analysis = parser.isCompleteRequestAnalysis(partial)

        XCTAssertFalse(analysis.isComplete)
        XCTAssertEqual(analysis.contentLength, 8)
        XCTAssertEqual(analysis.expectedLength, expectedTotal,
            "expectedLength must equal header bytes + Content-Length so the handler can cache it")

        // Full frame should be complete.
        XCTAssertTrue(parser.isCompleteRequest(fullRequest))
    }

    func testAnalysisReturnsNilExpectedLengthBeforeHeaderDelimiterArrives() {
        // Only the first line of headers — delimiter not yet present.
        let fragment = Data("POST /upload HTTP/1.1\r\n".utf8)
        let analysis = parser.isCompleteRequestAnalysis(fragment)

        XCTAssertFalse(analysis.isComplete)
        // Without the delimiter the handler should not cache an expectedLength.
        XCTAssertNil(analysis.expectedLength,
            "expectedLength must be nil until the header delimiter is found")
    }
}
