import Foundation

/// Shared preparation and serving bounds; independent of the network-server implementation.
enum HLSFixtureLimits {
    static let concurrentConnections = 8
    static let maxRequestHeaderBytes = 8 * 1024
    /// Fixture bound, not a limit on production proxy traffic.
    static let maxServedFileBytes = 16 * 1024 * 1024
    static let maxRenderedPlaylistBytes = 64 * 1024
    static let maxAdvertisedDurationSeconds: TimeInterval = 300
}
