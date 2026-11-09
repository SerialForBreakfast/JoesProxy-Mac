import OSLog

/// Shared `os_signpost` signposter for the session browser UI layer.
///
/// **How to use in Instruments:**
/// 1. Profile with the "os_signpost" instrument (or Time Profiler which includes it).
/// 2. Filter subsystem `com.JoesProxyApp.Capture`, category `Browser`.
/// 3. Key intervals to watch:
///    - `SessionBrowser.modeSwitch` — full latency from the Table→Explorer click to the
///      explorer view being fully populated (tree built + visible rows computed).
///    - `SessionBrowser.explorerRebuild` — the detached-task lifetime that rebuilds the
///      node tree; overlaps with the existing `SessionExplorerBuilder.build` interval
///      (category: Performance) and shows the total wall-clock cost including scheduling.
///    - `SessionBrowser.summariesByNodeID` — building the per-node summary lookup table
///      inside `applyRebuiltExplorerTree`; O(n) over visible sessions.
///    - `SessionBrowser.nodeExpansion` — cost of collapsing/expanding a node in the
///      explorer tree (recomputes visible rows from the current expansion set).
///    - `SessionBrowser.summaryCache` — building or rebuilding the in-memory summary
///      cache from raw `SessionRecord` values; runs on recording load and store clear.
///
/// All existing capture-pipeline intervals live in category `Performance`.
/// Session Find intervals live in category `SessionFind`.
enum BrowserPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "Browser"
    )
}
