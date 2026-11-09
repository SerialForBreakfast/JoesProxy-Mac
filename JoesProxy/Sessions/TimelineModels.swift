import Foundation

enum TimelineLane: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case api
    case authConfig
    case manifest
    case drmLicense
    case mediaSegments
    case imagesAssets
    case adsAnalytics
    case errorsRetries
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .api: return "API"
        case .authConfig: return "Auth / Config"
        case .manifest: return "Manifest"
        case .drmLicense: return "DRM / License"
        case .mediaSegments: return "Media Segments"
        case .imagesAssets: return "Images / Assets"
        case .adsAnalytics: return "Ads / Analytics"
        case .errorsRetries: return "Errors / Retries"
        case .pinned: return "Pinned"
        }
    }
}

enum TimelineLabel: String, Codable, Equatable, Hashable, Sendable {
    case api
    case playbackAPI
    case manifest
    case hls
    case dash
    case drmLicense
    case mediaSegment
    case initSegment
    case imageAsset
    case adAnalytics
    case error
    case gzipDecoded
    case pinned

    var title: String {
        switch self {
        case .api: return "API"
        case .playbackAPI: return "Playback API"
        case .manifest: return "Manifest"
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .drmLicense: return "DRM"
        case .mediaSegment: return "Segment"
        case .initSegment: return "Init"
        case .imageAsset: return "Asset"
        case .adAnalytics: return "Ads/Analytics"
        case .error: return "Error"
        case .gzipDecoded: return "Decoded"
        case .pinned: return "Pinned"
        }
    }
}

enum TimelineSeverity: String, Codable, Equatable, Sendable {
    case info
    case attention
    case high
}

enum TimelineConfidence: String, Codable, Equatable, Sendable {
    case observed
    case likely
    case possible
}

enum TimelineStatusFilter: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case all
    case success
    case redirect
    case clientError
    case serverError
    case failures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Status"
        case .success: return "2xx"
        case .redirect: return "3xx"
        case .clientError: return "4xx"
        case .serverError: return "5xx"
        case .failures: return "Failures"
        }
    }
}

enum TimelineAroundSelectionWindow: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case off
    case fiveSeconds
    case fifteenSeconds
    case thirtySeconds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "All Time"
        case .fiveSeconds: return "+/-5s"
        case .fifteenSeconds: return "+/-15s"
        case .thirtySeconds: return "+/-30s"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .fiveSeconds: return 5
        case .fifteenSeconds: return 15
        case .thirtySeconds: return 30
        }
    }
}

struct TimelineFilterState: Codable, Equatable, Sendable {
    var lane: TimelineLane?
    var hostOrPathContains: String
    var statusFilter: TimelineStatusFilter
    var minimumDuration: TimeInterval?
    var pinnedOnly: Bool
    var aroundSelection: TimelineAroundSelectionWindow

    init(
        lane: TimelineLane? = nil,
        hostOrPathContains: String = "",
        statusFilter: TimelineStatusFilter = .all,
        minimumDuration: TimeInterval? = nil,
        pinnedOnly: Bool = false,
        aroundSelection: TimelineAroundSelectionWindow = .off
    ) {
        self.lane = lane
        self.hostOrPathContains = hostOrPathContains
        self.statusFilter = statusFilter
        self.minimumDuration = minimumDuration
        self.pinnedOnly = pinnedOnly
        self.aroundSelection = aroundSelection
    }

    static let empty = TimelineFilterState()

    var isEmpty: Bool {
        lane == nil &&
        hostOrPathContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        statusFilter == .all &&
        minimumDuration == nil &&
        !pinnedOnly &&
        aroundSelection == .off
    }
}

enum TimelinePin: Codable, Equatable, Identifiable, Sendable {
    case request(SessionRecord.ID)
    case timeRange(id: UUID, start: Date, end: Date)

    var id: String {
        switch self {
        case .request(let id): return "request:\(id.uuidString)"
        case .timeRange(let id, _, _): return "range:\(id.uuidString)"
        }
    }
}

struct TimelineEvent: Identifiable, Equatable, Sendable {
    let sessionID: SessionRecord.ID
    var id: SessionRecord.ID { sessionID }
    let lane: TimelineLane
    let labels: Set<TimelineLabel>
    let startedAt: Date
    let duration: TimeInterval
    let method: String
    let statusCode: Int?
    let host: String
    let pathSummary: String
    let byteCount: Int?
    let inspectionKind: SessionInspectionKind
    let isPinned: Bool
    let normalizedStart: Double
    let normalizedDuration: Double

    var completedAt: Date {
        startedAt.addingTimeInterval(duration)
    }
}

enum TimelineGapReason: String, Codable, Equatable, Sendable {
    case idle
    case mediaSegmentGap
    case playbackStartupGap

    var title: String {
        switch self {
        case .idle: return "Idle gap"
        case .mediaSegmentGap: return "Segment gap"
        case .playbackStartupGap: return "Playback setup gap"
        }
    }
}

struct TimelineGap: Identifiable, Equatable, Sendable {
    let id: UUID
    let lane: TimelineLane?
    let start: Date
    let duration: TimeInterval
    let previousSessionID: SessionRecord.ID?
    let nextSessionID: SessionRecord.ID?
    let reason: TimelineGapReason
    let severity: TimelineSeverity
}

struct TimelineFinding: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let severity: TimelineSeverity
    let confidence: TimelineConfidence
    let evidenceSessionIDs: [SessionRecord.ID]
    let evidenceRange: DateInterval
}

struct SegmentCadenceSummary: Equatable, Sendable {
    let segmentCount: Int
    let slowestSegmentDuration: TimeInterval?
    let longestSegmentGap: TimeInterval?
    let failedSegmentCount: Int
}

struct MediaTimelineSummary: Equatable, Sendable {
    let playbackAPISessionID: SessionRecord.ID?
    let manifestSessionIDs: [SessionRecord.ID]
    let licenseSessionIDs: [SessionRecord.ID]
    let mediaSegmentSessionIDs: [SessionRecord.ID]
    let firstManifestDelay: TimeInterval?
    let firstLicenseDelay: TimeInterval?
    let firstSegmentDelay: TimeInterval?
    let cadence: SegmentCadenceSummary?
}

struct TimelineAnalysisResult: Equatable, Sendable {
    let events: [TimelineEvent]
    let visibleEvents: [TimelineEvent]
    let renderedEvents: [TimelineEvent]
    let gaps: [TimelineGap]
    let findings: [TimelineFinding]
    let mediaSummary: MediaTimelineSummary?
    let captureStart: Date?
    let captureEnd: Date?
    let filteredEventCount: Int
    let renderedEventCount: Int
    let renderLimit: Int
    /// `renderedEvents` grouped by lane — precomputed so the view avoids O(lanes × N) filtering on every render.
    let eventsByLane: [TimelineLane: [TimelineEvent]]
    /// `gaps` grouped by lane — same reason.
    let gapsByLane: [TimelineLane: [TimelineGap]]

    static let empty = TimelineAnalysisResult(
        events: [],
        visibleEvents: [],
        renderedEvents: [],
        gaps: [],
        findings: [],
        mediaSummary: nil,
        captureStart: nil,
        captureEnd: nil,
        filteredEventCount: 0,
        renderedEventCount: 0,
        renderLimit: TimelineRenderPolicy.defaultVisibleEventLimit,
        eventsByLane: [:],
        gapsByLane: [:]
    )
}

enum TimelineRenderPolicy {
    static let defaultVisibleEventLimit = 500
}

extension TimeInterval {
    func formattedAsSeconds() -> String { String(format: "%.1fs", self) }
}
