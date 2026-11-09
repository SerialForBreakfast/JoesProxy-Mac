import Foundation

/// Path constants for JoePlayer diagnostic POSTs on reserved HLS fixture hosts.
///
/// These requests are ingested for capture only (empty 204). They share the fixture host so
/// Simulator/device traffic already routed through JoesProxy reaches the handler without a
/// separate unresolvable diagnostic hostname.
enum DiagnosticIngestionRoute {
    /// Absolute path JoePlayer POSTs JSON diagnostic batches to.
    static let eventsPath = "/joeplayer/v1/events"

    /// Returns whether `path` (request-target path, query stripped by caller if needed) is a
    /// diagnostic ingestion endpoint.
    static func matches(_ path: String) -> Bool {
        let normalized: String
        if let queryIndex = path.firstIndex(of: "?") {
            normalized = String(path[..<queryIndex])
        } else {
            normalized = path
        }
        return normalized == eventsPath
    }
}
