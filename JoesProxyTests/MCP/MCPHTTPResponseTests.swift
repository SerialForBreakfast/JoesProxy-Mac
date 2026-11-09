import NIOHTTP1
import XCTest
@testable import JoesProxy

final class MCPHTTPResponseTests: XCTestCase {
    func testResponseAppliesFramingHeadersAtWriteTime() {
        let response = MCPHTTPResponse.response(status: 404, headers: [:], body: Data())
        let wire = response.wireHeaders()
        XCTAssertEqual(wire["Connection"], "close")
        XCTAssertEqual(wire["Content-Length"], "0")
    }

    func testJsonResponseAddsContentType() throws {
        let response = MCPHTTPResponse.jsonResponse(
            status: 200,
            headers: [MCPNetworkConstants.sessionIDHeader: "abc"],
            object: ["jsonrpc": "2.0", "id": 1, "result": [:]]
        )
        XCTAssertEqual(response.headerValue(named: "Content-Type"), "application/json")
        XCTAssertEqual(response.headerValue(named: MCPNetworkConstants.sessionIDHeader), "abc")
        let object = try response.jsonBodyObject()
        XCTAssertEqual(object["id"] as? Int, 1)
    }

    func testJsonRPCErrorBody() throws {
        let response = MCPHTTPResponse.jsonRPCError(
            status: 400,
            id: nil,
            code: -32600,
            message: "Invalid Request."
        )
        let object = try response.jsonBodyObject()
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
        XCTAssertEqual(error["message"] as? String, "Invalid Request.")
    }

    func testHTTPResponseHeadUsesStatusAndHeaders() {
        let response = MCPHTTPResponse.response(
            status: 401,
            headers: ["Content-Type": "text/plain"],
            body: Data("Unauthorized".utf8)
        )
        let head = response.httpResponseHead()
        XCTAssertEqual(head.status, HTTPResponseStatus(statusCode: 401))
        XCTAssertEqual(head.headers.first(name: "Content-Type"), "text/plain")
        XCTAssertEqual(head.headers.first(name: "Content-Length"), "12")
        XCTAssertEqual(head.headers.first(name: "Connection"), "close")
    }

    func testKeepAliveResponseUsesKeepAliveConnectionHeader() {
        let response = MCPHTTPResponse.response(status: 200, body: Data(), keepAlive: true)
        XCTAssertEqual(response.wireHeaders()["Connection"], "keep-alive")
    }
}
