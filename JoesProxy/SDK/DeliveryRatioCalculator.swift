import Foundation

/// Computes how a media segment's actual download time compares to its declared playback
/// duration. A ratio > 1.0 means the segment took longer to download than it takes to play,
/// which is the leading indicator of playback stall risk used by `StallRiskMonitor`.
struct DeliveryRatioCalculator: Sendable {
    /// `cachedSegmentDuration` is the most recently parsed manifest-declared segment duration
    /// in seconds for this content, in seconds. Returns nil when either value is unknown or
    /// the segment duration is non-positive.
    func ratio(session: SessionRecord, cachedSegmentDuration: Double?) -> Double? {
        guard let download = session.timing.duration,
              let segmentDuration = cachedSegmentDuration,
              segmentDuration > 0 else {
            return nil
        }
        return download / segmentDuration
    }
}
