import OSLog

/// Shared `os_signpost` intervals for live-capture UI refresh paths (Workstream U).
enum CapturePerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "Performance"
    )

}
