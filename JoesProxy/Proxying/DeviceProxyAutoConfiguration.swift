import Foundation

/// Stateless device setup endpoint on the active proxy listener, never on MCP.
enum DeviceProxyAutoConfiguration {
    static let path = "/.well-known/joesproxy/proxy.pac"
    static let fallbackPath = "/.well-known/joesproxy/proxy-direct-fallback.pac"

    static func url(host: String?, port: UInt16, allowsDirect: Bool) -> URL? {
        guard let host, validIPv4(host), port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = allowsDirect ? fallbackPath : path
        return components.url
    }

    static func script(host: String, port: Int, allowsDirect: Bool) -> String? {
        guard validIPv4(host), (1...65535).contains(port) else { return nil }
        let fallback = allowsDirect ? "; DIRECT" : ""
        return "function FindProxyForURL(url, host) { return \"PROXY \(host):\(port)\(fallback)\"; }\n"
    }

    /// The destination must be this socket's local endpoint. Never intercept a remote
    /// origin merely because it has a similarly named path, or trust Host as script input.
    static func response(for request: HTTPProxyRequest, localHost: String?, localPort: Int?) -> Data? {
        let resourcePath = String(request.path.split(separator: "?", maxSplits: 1).first ?? "")
        guard request.kind == .standard,
              let localHost, let localPort,
              request.host == localHost, request.port == localPort,
              resourcePath == path || resourcePath == fallbackPath,
              let script = script(host: localHost, port: localPort,
                                  allowsDirect: resourcePath == fallbackPath) else { return nil }
        // Unknown query options cannot silently change policy or loop through this listener.
        guard request.path == resourcePath else {
            return Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        }
        let supported = request.method == "GET" || request.method == "HEAD"
        let body = supported ? script : "Use GET or HEAD.\n"
        let status = supported ? "200 OK" : "405 Method Not Allowed"
        let type = supported ? "application/x-ns-proxy-autoconfig" : "text/plain; charset=utf-8"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nAllow: GET, HEAD\r\nConnection: close\r\n\r\n"
        return Data((headers + (request.method == "HEAD" ? "" : body)).utf8)
    }

    private static func validIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.allSatisfy {
            guard let value = UInt8($0) else { return false }
            return String(value) == $0
        } && host != "0.0.0.0" && host != "255.255.255.255"
    }
}
