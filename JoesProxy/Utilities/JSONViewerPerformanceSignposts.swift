import OSLog

/// Shared `os_signpost` signposter for JSON syntax highlighting, tree parsing, and rendering.
///
/// Filter in Instruments:
/// - Subsystem: `com.JoesProxyApp.Capture`
/// - Category: `JSONViewer`
enum JSONViewerPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "JSONViewer"
    )

    static func beginHighlightTokenize() -> OSSignpostIntervalState {
        signposter.beginInterval("JSONHighlight.tokenize")
    }

    static func endHighlightTokenize(_ state: OSSignpostIntervalState) {
        signposter.endInterval("JSONHighlight.tokenize", state)
    }

    static func beginTreeParse() -> OSSignpostIntervalState {
        signposter.beginInterval("JSONTree.parse")
    }

    static func endTreeParse(_ state: OSSignpostIntervalState) {
        signposter.endInterval("JSONTree.parse", state)
    }
}
