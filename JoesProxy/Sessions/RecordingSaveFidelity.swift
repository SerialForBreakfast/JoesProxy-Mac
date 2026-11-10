import Foundation

/// Save-time fidelity choices for `.jproxy` recordings.
enum RecordingSaveFidelity: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case fullRecording
    case metadataOnly
    case textBodiesOnly
    case mediaFocused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullRecording:
            return "Full Recording"
        case .metadataOnly:
            return "Metadata Only"
        case .textBodiesOnly:
            return "Text Bodies Only"
        case .mediaFocused:
            return "Media Focused"
        }
    }

    var summary: String {
        switch self {
        case .fullRecording:
            return "Preserves all currently available bodies and capture evidence without further truncation. Previously missing bytes cannot be recovered by saving."
        case .metadataOnly:
            return "Keeps requests, responses, headers, timing, and status, but not bodies."
        case .textBodiesOnly:
            return "Keeps JSON, XML, playlists, and other readable bodies while omitting binary/media payloads."
        case .mediaFocused:
            return "Keeps manifests, init segments, streaming metadata, and bounded media bodies."
        }
    }

    var sizeHint: String {
        switch self {
        case .fullRecording:
            return "Largest"
        case .metadataOnly:
            return "Smallest"
        case .textBodiesOnly, .mediaFocused:
            return "Smaller"
        }
    }

    var useCaseHint: String {
        switch self {
        case .fullRecording:
            return "Best for reopening"
        case .metadataOnly, .textBodiesOnly:
            return "Best for sharing"
        case .mediaFocused:
            return "Best for streaming/media debugging"
        }
    }
}

/// Why a request or response body is absent from a saved `.jproxy` recording even though the
/// original capture had a body.
enum RecordingBodyOmissionReason: String, Codable, Equatable, Sendable {
    case metadataOnly
    case binaryExcludedFromTextMode
    case nonMediaBinaryExcluded
    case oversizedMediaExcluded
    case retentionEvicted = "retention_evicted"

    var userFacingMessage: String {
        switch self {
        case .retentionEvicted:
            return "Older body removed to stay within your history limit. Increase the retention budget or save earlier to keep future bodies."
        case .metadataOnly:
            return "Body omitted by recording mode."
        case .binaryExcludedFromTextMode:
            return "Binary body omitted by Text Bodies Only mode."
        case .nonMediaBinaryExcluded:
            return "Non-media binary body omitted by Media Focused mode."
        case .oversizedMediaExcluded:
            return "Media body omitted to keep the recording smaller."
        }
    }
}
