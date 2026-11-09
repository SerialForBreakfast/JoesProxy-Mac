import Foundation

/// Declares whether a substitution should remain conformant or intentionally violate known HLS
/// authoring requirements. Deliberate faults must be explicit in the approved proposal.
enum HLSExperimentIntent: String, Codable, Equatable, Sendable, CaseIterable {
    case conformant
    case deliberateFault
}

enum HLSLoopBoundaryTreatment: String, Codable, Equatable, Sendable, CaseIterable {
    case declareDiscontinuity
    case omitDiscontinuity
}

enum HLSSegmentURIIdentity: String, Codable, Equatable, Sendable, CaseIterable {
    case uniquePerMediaSequence
    case reuseAssetURI
}

enum HLSTargetDurationTreatment: String, Codable, Equatable, Sendable, CaseIterable {
    case source
    case underreportByOneSecond
}

enum HLSProgramDateTimeTreatment: String, Codable, Equatable, Sendable, CaseIterable {
    case include
    case omit
}

enum HLSPlaylistCachePolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case noCache
    case noStore
    case maxAge
}

/// Explicit presentation semantics for newly configured fixture runs. `nil` on
/// ``HLSPlaybackConfiguration/presentationMode`` is the decode-compatible legacy sliding-live
/// behavior and is intentionally not exposed as a selectable mode.
enum HLSPresentationMode: String, Codable, Equatable, Sendable, CaseIterable {
    case vodStatic
    case liveLoop
}

/// Bounded live time-shifting behavior. This is intentionally separate from low-latency HLS:
/// these modes control how much completed media is advertised and retained, not partial-segment
/// publication or delivery latency.
enum HLSTimeShiftMode: String, Codable, Equatable, Sendable, CaseIterable {
    case off
    case warmDVR
    case coldDVR
}

enum HLSRecommendationViolation: String, Codable, Equatable, Sendable {
    case undeclaredLoopTimestampReset
    case reusedSegmentURI
    case underreportedTargetDuration
    case missingProgramDateTime

    var summary: String {
        switch self {
        case .undeclaredLoopTimestampReset:
            return "Looped media timestamps reset without EXT-X-DISCONTINUITY."
        case .reusedSegmentURI:
            return "The same segment URI is reused for later media-sequence values."
        case .underreportedTargetDuration:
            return "EXT-X-TARGETDURATION is one second below the source value."
        case .missingProgramDateTime:
            return "The live media playlist omits EXT-X-PROGRAM-DATE-TIME."
        }
    }
}

enum HLSPlaybackConfigurationError: LocalizedError, Equatable {
    case invalidWindowSegmentCount
    case invalidPlaylistMaxAge
    case maxAgeRequiresSeconds
    case maxAgeSecondsNotAllowed
    case timeShiftRequiresLiveLoop
    case deliberateFaultIntentRequired([HLSRecommendationViolation])

    var errorDescription: String? {
        switch self {
        case .invalidWindowSegmentCount:
            return "windowSegmentCount must be between 2 and 30."
        case .invalidPlaylistMaxAge:
            return "playlistMaxAgeSeconds must be between 0 and 60."
        case .maxAgeRequiresSeconds:
            return "playlistMaxAgeSeconds is required when playlistCachePolicy is maxAge."
        case .maxAgeSecondsNotAllowed:
            return "playlistMaxAgeSeconds is only valid when playlistCachePolicy is maxAge."
        case .timeShiftRequiresLiveLoop:
            return "warmDVR and coldDVR require presentationMode=liveLoop."
        case .deliberateFaultIntentRequired(let violations):
            let names = violations.map(\.rawValue).joined(separator: ", ")
            return "Deliberate HLS faults require intent=deliberateFault: \(names)."
        }
    }
}

/// Bounded playlist/server configuration layered over immutable bundled fixture media.
///
/// Codec, container, channel layout, encryption, and physical segment-boundary changes remain
/// profile-backed because they require validated media assets. These controls change only live
/// playlist construction and cache behavior.
struct HLSPlaybackConfiguration: Codable, Equatable, Sendable {
    static let minimumWindowSegmentCount = 2
    static let maximumWindowSegmentCount = 30
    static let boundedTimeShiftSmokeWindowSegmentCount = 15

    /// Absence preserves runs and requests authored before explicit presentation modes existed.
    /// New clients should select `vodStatic` or `liveLoop` deliberately.
    var presentationMode: HLSPresentationMode?
    /// Optional for decode compatibility with runs authored before live time shifting existed.
    /// Absence has the same behavior as `off`.
    var timeShiftMode: HLSTimeShiftMode?
    /// Optional JIT publication state simulation for alternate audio tracks.
    var jitPublicationState: HLSJITPublicationState?
    var intent: HLSExperimentIntent
    var windowSegmentCount: Int
    var loopBoundaryTreatment: HLSLoopBoundaryTreatment
    var segmentURIIdentity: HLSSegmentURIIdentity
    var targetDurationTreatment: HLSTargetDurationTreatment
    var programDateTimeTreatment: HLSProgramDateTimeTreatment
    var playlistCachePolicy: HLSPlaylistCachePolicy
    var playlistMaxAgeSeconds: Int?

    static let conformant = HLSPlaybackConfiguration(
        presentationMode: nil,
        timeShiftMode: .off,
        jitPublicationState: nil,
        intent: .conformant,
        windowSegmentCount: 4,
        loopBoundaryTreatment: .declareDiscontinuity,
        segmentURIIdentity: .uniquePerMediaSequence,
        targetDurationTreatment: .source,
        programDateTimeTreatment: .include,
        playlistCachePolicy: .noCache,
        playlistMaxAgeSeconds: nil
    )

    /// Preserves the original low-level fixture behavior for compatibility call sites. Composite
    /// substitutions use ``conformant`` unless the caller explicitly supplies another configuration.
    static let legacyCompatible = HLSPlaybackConfiguration(
        presentationMode: nil,
        timeShiftMode: nil,
        jitPublicationState: nil,
        intent: .deliberateFault,
        windowSegmentCount: 4,
        loopBoundaryTreatment: .omitDiscontinuity,
        segmentURIIdentity: .reuseAssetURI,
        targetDurationTreatment: .source,
        programDateTimeTreatment: .omit,
        playlistCachePolicy: .noCache,
        playlistMaxAgeSeconds: nil
    )

    var recommendationViolations: [HLSRecommendationViolation] {
        var violations: [HLSRecommendationViolation] = []
        if loopBoundaryTreatment == .omitDiscontinuity {
            violations.append(.undeclaredLoopTimestampReset)
        }
        if segmentURIIdentity == .reuseAssetURI {
            violations.append(.reusedSegmentURI)
        }
        if targetDurationTreatment == .underreportByOneSecond {
            violations.append(.underreportedTargetDuration)
        }
        if programDateTimeTreatment == .omit {
            violations.append(.missingProgramDateTime)
        }
        return violations
    }

    var isDeliberatelyNonconformant: Bool { !recommendationViolations.isEmpty }

    var effectiveTimeShiftMode: HLSTimeShiftMode { timeShiftMode ?? .off }

    func validated() throws -> HLSPlaybackConfiguration {
        guard (Self.minimumWindowSegmentCount...Self.maximumWindowSegmentCount).contains(windowSegmentCount) else {
            throw HLSPlaybackConfigurationError.invalidWindowSegmentCount
        }
        if effectiveTimeShiftMode != .off, presentationMode != .liveLoop {
            throw HLSPlaybackConfigurationError.timeShiftRequiresLiveLoop
        }
        switch playlistCachePolicy {
        case .maxAge:
            guard let playlistMaxAgeSeconds else {
                throw HLSPlaybackConfigurationError.maxAgeRequiresSeconds
            }
            guard (0...60).contains(playlistMaxAgeSeconds) else {
                throw HLSPlaybackConfigurationError.invalidPlaylistMaxAge
            }
        case .noCache, .noStore:
            guard playlistMaxAgeSeconds == nil else {
                throw HLSPlaybackConfigurationError.maxAgeSecondsNotAllowed
            }
        }
        let violations = recommendationViolations
        if !violations.isEmpty, intent != .deliberateFault {
            throw HLSPlaybackConfigurationError.deliberateFaultIntentRequired(violations)
        }
        return self
    }

    var cacheControlHeader: String {
        switch playlistCachePolicy {
        case .noCache: return "no-cache"
        case .noStore: return "no-store"
        case .maxAge: return "max-age=\(playlistMaxAgeSeconds ?? 0)"
        }
    }
}
