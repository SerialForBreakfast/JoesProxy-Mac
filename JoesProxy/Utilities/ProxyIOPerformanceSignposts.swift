import OSLog

/// Shared `os_signpost` signposter for proxy network I/O, parsing, and session ingestion.
///
/// Filter in Instruments:
/// - Subsystem: `com.JoesProxyApp.Capture`
/// - Category: `ProxyIO`
enum ProxyIOPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "ProxyIO"
    )

    static func beginParseRequest() -> OSSignpostIntervalState {
        signposter.beginInterval("ProxyIO.parseRequest")
    }

    static func endParseRequest(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ProxyIO.parseRequest", state)
    }

    static func beginParseResponseChunk() -> OSSignpostIntervalState {
        signposter.beginInterval("ProxyIO.parseResponseChunk")
    }

    static func endParseResponseChunk(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ProxyIO.parseResponseChunk", state)
    }

    static func beginSessionIngest() -> OSSignpostIntervalState {
        signposter.beginInterval("ProxyIO.sessionIngest")
    }

    static func endSessionIngest(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ProxyIO.sessionIngest", state)
    }

    static func beginUpstreamConnect() -> OSSignpostIntervalState {
        signposter.beginInterval("ProxyIO.upstreamConnect")
    }

    static func endUpstreamConnect(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ProxyIO.upstreamConnect", state)
    }
}
