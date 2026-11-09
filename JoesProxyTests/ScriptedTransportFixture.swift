import Foundation
@testable import JoesProxy

/// Seeded local wire fixtures; no public endpoints or device navigation.
struct ScriptedTransportFixture: Sendable {
    let name: String
    let status: Int
    let body: Data
    let headers: [String: String]
    let wire: Data
    var method = "GET"
    var closeDelimited = false
    var fails = false

    static func cases() -> [Self] {
        let binary = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        let media = Data(repeating: 0xA5, count: 524_288)
        func fixed(_ name: String, status: Int = 200, body: Data, headers: [String: String] = [:],
                   declaredLength: Int? = nil) -> Self {
            var fields = headers
            fields["Content-Length"] = String(declaredLength ?? body.count)
            fields["Connection"] = "close"
            let head = "HTTP/1.1 \(status) Synthetic\r\n" + fields.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            return Self(name: name, status: status, body: body, headers: fields, wire: Data(head.utf8) + body)
        }
        var head = fixed("head", body: Data(), declaredLength: 4096)
        head.method = "HEAD"
        let chunks = Data("3;fixture=seed17\r\nabc\r\n2\r\nde\r\n0\r\nX-Checksum: seed17\r\n\r\n".utf8)
        let chunked = Self(name: "chunked", status: 200, body: chunks,
            headers: ["Transfer-Encoding": "chunked"],
            wire: Data("HTTP/1.1 200 Synthetic\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n".utf8) + chunks)
        var malformed = Self(name: "malformed", status: 200, body: Data(), headers: [:],
            wire: Data("HTTP/1.1 200 Synthetic\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX0\r\n\r\n".utf8))
        malformed.fails = true
        var truncated = fixed("truncated", body: binary.prefix(123), declaredLength: binary.count)
        truncated.fails = true
        var eof = Self(name: "eof", status: 200, body: binary, headers: ["Connection": "close"],
            wire: Data("HTTP/1.1 200 Synthetic\r\nConnection: close\r\n\r\n".utf8) + binary)
        eof.closeDelimited = true
        // Fixed gzip member for "hello": preserves encoded binary bytes independently of the decoder.
        let gzip = Data([31,139,8,0,0,0,0,0,0,3,203,72,205,201,201,7,0,134,166,16,54,5,0,0,0])
        return [fixed("binary", body: binary), fixed("api", body: Data("{\"seed\":17,\"ok\":true}".utf8)),
                fixed("media", body: media), fixed("gzip", body: gzip, headers: ["Content-Encoding": "gzip"]),
                fixed("redirect", status: 302, body: Data(), headers: ["Location": "/not-followed?seed=17"]),
                head, fixed("empty", status: 204, body: Data()),
                fixed("not-modified", status: 304, body: Data(), headers: ["ETag": "\"seed17\""]),
                eof, chunked, truncated, malformed]
    }
}

final class ScriptedOriginCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func observe() { lock.withLock { count += 1 } }
    var requests: Int { lock.withLock { count } }
}
