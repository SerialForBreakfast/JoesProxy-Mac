import Foundation

/// Constants governing the `.jproxy` session recording format.
enum RecordingConstants {
    /// Maximum inline body bytes retained during live capture per request or response.
    static let liveCaptureBodySizeLimit = bodySizeLimit

    /// Maximum bytes stored per request or response body in a `.jproxy` file.
    /// Bodies exceeding this limit are truncated and flagged with `bodyTruncated`.
    static let bodySizeLimit = 1_048_576

    /// Maximum bytes stored for readable text bodies in lighter save modes.
    static let textBodySizeLimit = bodySizeLimit

    /// Maximum bytes stored for init segments in `Media Focused` recordings.
    static let mediaInitSegmentBodySizeLimit = 524_288

    /// Maximum bytes stored for ordinary media segments in `Media Focused` recordings.
    static let mediaSegmentBodySizeLimit = 262_144

    /// File-size threshold above which body decoding is deferred to session selection rather than
    /// being performed eagerly during the open phase.
    static let lazyLoadThreshold = 10_485_760

    /// The current `.jproxy` schema version written by this build.
    static let currentSchemaVersion = 2
}
