import Foundation

/// Sentinel host and method for synthetic capture timeline markers (AM workstream).
enum CaptureMarkerConstants {
    static let method = "MARKER"
    static let host = "capture-marker.joesproxy.local"
    static let hostCategory = "capture_marker"
    static let mediaCategoryLabel = "capture_marker"

    static func isMarkerRecord(_ record: SessionRecord) -> Bool {
        record.request.method == method && record.request.host == host
    }

    static func markerPath(name: String) -> String {
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = sanitized.isEmpty ? "unnamed" : sanitized
        return "/capture/marker/\(segment)"
    }
}

/// JSON payload stored in a marker session request body for MCP-readable diagnostics.
struct CaptureMarkerPayload: Equatable, Sendable, Codable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var name: String
    var reason: String
    var detail: String?
    var label: String?
    var captureEpoch: String
    var priorCaptureEpoch: String?
    var timestamp: Date
    var loadedSessionCount: Int?

    init(
        name: String,
        reason: String,
        detail: String? = nil,
        label: String? = nil,
        captureEpoch: String,
        priorCaptureEpoch: String? = nil,
        timestamp: Date = Date(),
        loadedSessionCount: Int? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.name = name
        self.reason = reason
        self.detail = detail
        self.label = label
        self.captureEpoch = captureEpoch
        self.priorCaptureEpoch = priorCaptureEpoch
        self.timestamp = timestamp
        self.loadedSessionCount = loadedSessionCount
    }
}

/// Result returned by ``capture_marker_create``.
struct MCPCaptureMarkerResultDTO: Equatable, Sendable, Codable {
    var sessionID: String
    var captureSequence: UInt64
    var captureEpoch: MCPCaptureEpoch
    var name: String
}
