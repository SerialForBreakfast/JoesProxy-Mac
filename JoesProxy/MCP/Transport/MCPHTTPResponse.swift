import Foundation
import NIO
import NIOHTTP1

/// Typed HTTP response for MCP Streamable HTTP POST and JSON-RPC reject paths.
///
/// The NIO transport writes these directly as ``HTTPServerResponsePart`` without a wire-format
/// round-trip. GET SSE listen streams use a separate native head plus ``MCPSSEWriter`` path.
struct MCPHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// When `true`, the transport emits ``Connection: keep-alive`` and does not close after write.
    var keepAlive: Bool

    init(
        status: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        keepAlive: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.keepAlive = keepAlive
    }

    /// Builds a response whose framing headers are applied at write time.
    static func response(
        status: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        keepAlive: Bool = false
    ) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers, body: body, keepAlive: keepAlive)
    }

    static func jsonResponse(
        status: Int,
        headers: [String: String] = [:],
        object: [String: Any],
        keepAlive: Bool = false
    ) -> MCPHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var merged = headers
        merged["Content-Type"] = "application/json"
        return response(status: status, headers: merged, body: body, keepAlive: keepAlive)
    }

    static func jsonRPCError(
        status: Int,
        id: Any?,
        code: Int,
        message: String,
        data: [String: Any]? = nil
    ) -> MCPHTTPResponse {
        jsonResponse(status: status, headers: [:], object: jsonRPCObject(id: id, error: (code, message), data: data))
    }

    static func jsonRPCObject(id: Any?, error: (Int, String), data: [String: Any]? = nil) -> [String: Any] {
        var errorObject: [String: Any] = [
            "code": error.0,
            "message": error.1
        ]
        if let data {
            errorObject["data"] = data
        }
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": errorObject
        ]
    }

    static func jsonRPCObject(id: Any?, error: (Int, String)) -> [String: Any] {
        jsonRPCObject(id: id, error: error, data: nil)
    }

    /// Returns the first header value for `name`, compared case-insensitively.
    func headerValue(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    func jsonBodyObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw MCPHTTPResponseDecodingError.invalidJSONBody
        }
        return object
    }

    /// Headers the transport will emit, including framing fields applied at write time.
    func wireHeaders() -> [String: String] {
        var merged = headers
        merged["Connection"] = keepAlive ? "keep-alive" : "close"
        merged["Content-Length"] = "\(body.count)"
        return merged
    }

    func httpResponseHead() -> HTTPResponseHead {
        var httpHeaders = HTTPHeaders()
        for (name, value) in wireHeaders() {
            httpHeaders.add(name: name, value: value)
        }
        return HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: status),
            headers: httpHeaders
        )
    }

    /// Writes this response on the channel event loop as native NIO HTTP/1 parts.
    ///
    /// Concurrency: must run on the channel's event loop.
    func write(to context: ChannelHandlerContext, closeAfterWrite: Bool = true) {
        context.write(NIOAny(HTTPServerResponsePart.head(httpResponseHead())), promise: nil)
        if !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
        if closeAfterWrite, !keepAlive {
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }
}

enum MCPHTTPResponseDecodingError: Error, Equatable {
    case invalidJSONBody
}
