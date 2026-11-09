import OSLog

/// Shared `os_signpost` signposter for the live upstream response rewrite path (AL-4/AL-5) —
/// decode, JSON-mutation apply, and gzip re-encode. Added to diagnose CPU spikes reported when
/// complex Map Local/Rewrite rules run against large collection JSON bodies (e.g. inserting one
/// channel into one category of a large channel guide).
///
/// Filter in Instruments:
/// - Subsystem: `com.JoesProxyApp.Capture`
/// - Category: `LiveRewrite`
enum LiveRewritePerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "LiveRewrite"
    )

    static func beginTransform(bodyBytes: Int, mutationCount: Int) -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.transform", "bodyBytes=\(bodyBytes) mutations=\(mutationCount)")
    }

    static func endTransform(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.transform", state)
    }

    static func beginDecode() -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.decode")
    }

    static func endDecode(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.decode", state)
    }

    static func beginMutationApply(bodyBytes: Int, mutationCount: Int) -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.mutationApply", "bodyBytes=\(bodyBytes) mutations=\(mutationCount)")
    }

    static func endMutationApply(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.mutationApply", state)
    }

    static func beginGzipReencode(bodyBytes: Int) -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.gzipReencode", "bodyBytes=\(bodyBytes)")
    }

    static func endGzipReencode(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.gzipReencode", state)
    }

    // MARK: - Engine-internal (BookmarkJSONRewriteEngine.apply breakdown)

    static func beginParseJSON(bodyBytes: Int) -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.engine.parseJSON", "bodyBytes=\(bodyBytes)")
    }

    static func endParseJSON(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.engine.parseJSON", state)
    }

    static func beginMutationLoop(mutationCount: Int) -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.engine.mutationLoop", "mutations=\(mutationCount)")
    }

    static func endMutationLoop(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.engine.mutationLoop", state)
    }

    static func beginSerializeJSON() -> OSSignpostIntervalState {
        signposter.beginInterval("LiveRewrite.engine.serializeJSON")
    }

    static func endSerializeJSON(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LiveRewrite.engine.serializeJSON", state)
    }
}
