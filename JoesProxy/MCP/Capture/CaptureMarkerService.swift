import Foundation

/// Inserts synthetic capture-marker sessions into ``SessionStore`` without upstream traffic.
///
/// Concurrency: `@MainActor` — appends through the main-actor session store like live capture.
@MainActor
final class CaptureMarkerService {
    private let sessionStore: any SessionStore
    private let encoder: JSONEncoder

    init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    /// Creates a user- or agent-authored timeline marker.
    @discardableResult
    func insertUserMarker(
        name: String,
        detail: String?,
        label: String?,
        captureEpoch: MCPCaptureEpoch
    ) throws -> SessionRecord {
        try insertMarker(
            name: name,
            reason: "user_created",
            detail: detail,
            label: label,
            captureEpoch: captureEpoch,
            priorCaptureEpoch: nil,
            loadedSessionCount: nil
        )
    }

    /// Creates a system marker after capture lifecycle events (clear, load, restore).
    @discardableResult
    func insertSystemMarker(
        name: String,
        reason: String,
        detail: String?,
        captureEpoch: MCPCaptureEpoch,
        priorCaptureEpoch: MCPCaptureEpoch?,
        loadedSessionCount: Int? = nil
    ) throws -> SessionRecord {
        try insertMarker(
            name: name,
            reason: reason,
            detail: detail,
            label: nil,
            captureEpoch: captureEpoch,
            priorCaptureEpoch: priorCaptureEpoch,
            loadedSessionCount: loadedSessionCount
        )
    }

    private func insertMarker(
        name: String,
        reason: String,
        detail: String?,
        label: String?,
        captureEpoch: MCPCaptureEpoch,
        priorCaptureEpoch: MCPCaptureEpoch?,
        loadedSessionCount: Int?
    ) throws -> SessionRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CaptureMarkerError.emptyName
        }
        let payload = CaptureMarkerPayload(
            name: trimmedName,
            reason: reason,
            detail: detail,
            label: label,
            captureEpoch: captureEpoch.rawValue,
            priorCaptureEpoch: priorCaptureEpoch?.rawValue,
            loadedSessionCount: loadedSessionCount
        )
        let bodyData = try encoder.encode(payload)
        let now = Date()
        let record = SessionRecord(
            request: CapturedRequest(
                method: CaptureMarkerConstants.method,
                scheme: .https,
                host: CaptureMarkerConstants.host,
                port: 443,
                path: CaptureMarkerConstants.markerPath(name: trimmedName),
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json"),
                    HTTPHeaderField(name: "X-JoesProxy-Marker", value: reason)
                ],
                bodyData: bodyData,
                bodySize: bodyData.count
            ),
            response: CapturedResponse(
                statusCode: 204,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: nil,
                bodySize: 0
            ),
            state: .completed,
            timing: SessionTiming(startedAt: now, completedAt: now)
        )
        sessionStore.append(record)
        return record
    }
}

enum CaptureMarkerError: Error, Equatable, Sendable {
    case emptyName
}
