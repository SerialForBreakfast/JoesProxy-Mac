import NIOHTTP1

/// Estimated on-wire byte size of an `HTTPRequestHead`, used by every in-process NIOHTTP1 server in
/// this app (`MCPNIOHTTPTransport`, `HLSFixtureServer`) to enforce a "reject oversized headers"
/// limit before buffering a request further.
enum NIOHTTPRequestHeaderSize {
    static func estimatedBytes(_ head: HTTPRequestHead) -> Int {
        var total = head.method.rawValue.utf8.count + head.uri.utf8.count + 16
        for header in head.headers {
            total += header.name.utf8.count + header.value.utf8.count + 4
        }
        return total
    }
}
