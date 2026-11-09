import Foundation

enum MCPMediaAnalysisKind: String, Codable, CaseIterable, Hashable, Sendable {
    case transportStructure = "transport_structure"
    case gopFrames = "gop_frames"
    case id3TimedMetadata = "id3_timed_metadata"
    case binaryContainer = "binary_container"
    case capturedMediaEngine = "captured_media_engine"
    /// Open-world live URL probe (AH-5). Must not be used on the capture-only inspection path.
    case liveMediaEngine = "live_media_engine"
}

/// Distinguishes capture-only media inspection from open-world live probes.
enum MCPOperationKind: String, Codable, Equatable, Sendable {
    case mediaInspection = "media_inspection"
    case liveProbe = "live_probe"
}

struct MCPMediaDisclosureContextDTO: Codable, Sendable, Equatable {
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var generatedAt: Date
    var removedFields: [String]
    var partialResultReason: String?
    var truncated: Bool
}

struct MCPMediaCoverageDTO: Codable, Sendable, Equatable {
    var scope: String
    var capturedBytes: Int
    var reportedOriginalBytes: Int?
    var inspectedBytes: Int
    var complete: Bool
    var limitation: String?
}

struct MCPMediaSummaryDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var captureSequence: UInt64
    var mediaType: String
    var mimeCategory: String?
    var bodyAvailable: Bool
    var bodyDeferred: Bool
    var bodyOmitted: Bool
    var bodyTruncated: Bool
    var capturedBodyBytes: Int?
    var startedAt: Date
    var durationSeconds: Double?
    var manifestKind: String?
    var containerKind: String?
    var aggregateCounts: [String: Int]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPMediaManifestStructureDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var kind: String
    var playlistKind: String?
    var version: Int?
    var presentationType: String?
    var duration: String?
    var targetDurationSeconds: Double?
    var counts: [String: Int]
    var unsupportedVariantCount: Int
    var codecs: [String]
    var resolutions: [String]
    var bandwidths: [Int]
    var protectionSchemes: [String]
    var hasContentSteering: Bool
    var hasSegmentTemplate: Bool
    var hlsVariants: [MCPHLSVariantDTO]
    var hlsRenditions: [MCPHLSRenditionDTO]
    var dashRepresentations: [MCPDASHRepresentationDTO]
    var segmentTemplates: [MCPDASHSegmentTemplateDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPHLSVariantDTO: Codable, Sendable, Equatable {
    var variantRef: String
    var bandwidth: Int?
    var averageBandwidth: Int?
    var resolution: String?
    var codecs: [String]
    var frameRate: Double?
    var videoRange: String?
    var hdcpLevel: String?
}

struct MCPHLSRenditionDTO: Codable, Sendable, Equatable {
    var type: String
    var language: String?
    var isDefault: Bool
    var autoSelect: Bool
    var isForced: Bool
}

struct MCPDASHRepresentationDTO: Codable, Sendable, Equatable {
    var contentType: String?
    var language: String?
    var mimeType: String?
    var codecs: String?
    var bandwidth: Int?
    var width: Int?
    var height: Int?
    var frameRate: String?
    var audioSamplingRate: Int?
}

struct MCPDASHSegmentTemplateDTO: Codable, Sendable, Equatable {
    var timescale: Int?
    var duration: Int?
    var startNumber: Int?
    var hasInitializationPattern: Bool
    var hasMediaPattern: Bool
}

struct MCPMediaRelatedSessionDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var captureSequence: UInt64
    var relationship: String
    var matchStrategy: String
    var mediaType: String
}

struct MCPMediaRelatedSessionsPageDTO: Codable, Sendable, Equatable {
    var sourceSessionID: String
    var status: String
    var candidateCount: Int
    var skippedBodyReasons: [String: Int]
    var attemptedStrategies: [String]
    var indexedThroughSequence: UInt64
    var items: [MCPMediaRelatedSessionDTO]
    var nextCursor: String?
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPMediaParserDiagnosticsDTO: Codable, Sendable, Equatable {
    var parser: String
    var outcome: String
    var bytesAvailable: Int
    var bytesInspected: Int
    var completedStages: [String]
    var counters: [String: Int]
    var warnings: [String]
}

struct MCPMediaEventMessageDTO: Codable, Sendable, Equatable {
    var version: Int
    var schemeIDURI: String?
    var timescale: UInt32?
    var presentationTime: UInt64?
    var presentationTimeSeconds: Double?
    var eventDuration: UInt32?
    var eventID: UInt32?
    var messageDataSize: Int
    var embeddedID3FrameIdentifiers: [String]
}

struct MCPMediaBinaryStructureDTO: Codable, Sendable, Equatable {
    var kind: String
    var role: String
    var bytesInspected: Int
    var transportPacketSize: Int?
    var transportSyncPacketCount: Int?
    var programNumbers: [Int]
    var streamTypeCodes: [String]
    var scte35Present: Bool
    var topLevelBoxTypes: [String]
    var likelyFragmented: Bool
    var likelyEncrypted: Bool
    var segmentIndexPresent: Bool
    var eventMessageCount: Int
    var eventMessages: [MCPMediaEventMessageDTO]
    var protectionBoxCount: Int
}

struct MCPMediaGOPAnalysisDTO: Codable, Sendable, Equatable {
    var codec: String
    var bytesInspected: Int
    var accessUnitCount: Int
    var iFrameCount: Int
    var pFrameCount: Int
    var bFrameCount: Int
    var unclassifiedFrameCount: Int
    var keyFrameCount: Int
    var observedFrameRate: Double?
    var presentationTimeSpan: Double?
    var averageGOPFrameCount: Double?
    var maximumGOPFrameCount: Int?
    var averageKeyFrameInterval: Double?
    var maximumKeyFrameInterval: Double?
    var suggestedSeekTolerance: Double?
    var inspectionLimited: Bool
}

struct MCPMediaID3MarkerDTO: Codable, Sendable, Equatable {
    var relativePlaybackTime: Double?
    var segmentRelativeTime: Double?
    var byteOffset: Int?
    var transportPID: Int?
    var presentationTimestamp90k: UInt64?
    var presentationTimestampSeconds: Double?
    var id3MajorVersion: Int?
    var tagSize: Int?
    var frameIdentifiers: [String]
    var privateOwnerIdentifiers: [String]
    var decodeStatus: String
    var payloadPresent: Bool
    var payloadRedacted: Bool
}

struct MCPMediaID3AnalysisDTO: Codable, Sendable, Equatable {
    var containerType: String
    var markerCount: Int
    var firstPresentationTimestamp90k: UInt64?
    var lastPresentationTimestamp90k: UInt64?
    var markers: [MCPMediaID3MarkerDTO]
}

struct MCPMediaEngineInspectionDTO: Codable, Sendable, Equatable {
    var partial: Bool
    var durationSeconds: Double?
    var playable: Bool?
    var exportable: Bool?
    var protectedContent: Bool?
    var preciseTiming: Bool?
    var variantCount: Int
    var videoTrackCount: Int
    var audioTrackCount: Int
    var subtitleTrackCount: Int
    var variants: [MCPMediaEngineVariantDTO]
    var videoTracks: [MCPMediaEngineVideoTrackDTO]
    var audioTracks: [MCPMediaEngineAudioTrackDTO]
    var subtitleLanguages: [String]
    var mediaSelectionLanguages: [String]
    var player: MCPMediaEnginePlayerDTO?
    var decodedFrame: MCPDecodedFrameDTO?
    var stages: [MCPOperationStageDTO]
    var warnings: [String]
}

struct MCPMediaEngineVariantDTO: Codable, Sendable, Equatable {
    var peakBitRate: Double?
    var averageBitRate: Double?
    var videoRange: String?
    var videoCodecs: [String]
    var width: Int?
    var height: Int?
    var nominalFrameRate: Double?
    var audioFormats: [String]
}

struct MCPMediaEngineVideoTrackDTO: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var estimatedDataRate: Float
    var nominalFrameRate: Float
    var codec: String?
}

struct MCPMediaEngineAudioTrackDTO: Codable, Sendable, Equatable {
    var channels: Int?
    var sampleRate: Float?
    var language: String?
    var codec: String?
}

struct MCPMediaEnginePlayerDTO: Codable, Sendable, Equatable {
    var status: String
    var presentationWidth: Int
    var presentationHeight: Int
    var likelyToKeepUp: Bool
    var bufferEmpty: Bool
    var bufferFull: Bool
    var loadedRanges: [MCPMediaTimeRangeDTO]
    var seekableRanges: [MCPMediaTimeRangeDTO]
}

struct MCPMediaTimeRangeDTO: Codable, Sendable, Equatable {
    var start: Double
    var duration: Double
}

struct MCPDecodedFrameDTO: Codable, Sendable, Equatable {
    var requestedTime: Double
    var decodedTime: Double
    var width: Int
    var height: Int
    var pixelFormat: String
    var planar: Bool
    var planeCount: Int
    var bytesPerRow: Int
    var estimatedByteSize: Int
    var planes: [MCPDecodedFramePlaneDTO]
    var attachments: [String: String]
    var metalCompatible: Bool
    var ioSurfaceBacked: Bool
    var ioSurfaceWidth: Int?
    var ioSurfaceHeight: Int?
    var ioSurfaceBytesPerRow: Int?
    var ioSurfaceAllocationSize: Int?
}

struct MCPDecodedFramePlaneDTO: Codable, Sendable, Equatable {
    var index: Int
    var width: Int
    var height: Int
    var bytesPerRow: Int
}

struct MCPMediaInspectionResultDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var analyses: [MCPMediaAnalysisKind]
    var binaryStructure: MCPMediaBinaryStructureDTO?
    var gop: MCPMediaGOPAnalysisDTO?
    var id3: MCPMediaID3AnalysisDTO?
    var mediaEngine: MCPMediaEngineInspectionDTO?
    var diagnostics: [MCPMediaParserDiagnosticsDTO]
    var warnings: [String]
    var coverage: MCPMediaCoverageDTO? = nil
    var disclosure: MCPMediaDisclosureContextDTO
}

enum MCPOperationStatus: String, Codable, Equatable, Sendable {
    case pendingApproval = "pending_approval"
    case running
    case completed
    case partial
    case failed
    case cancelling
    case cancelled
    case expired
}

struct MCPOperationStageDTO: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var durationSeconds: Double
    var outcome: String
    var message: String?
}

struct MCPOperationDescriptorDTO: Codable, Sendable {
    var operationID: String
    var status: MCPOperationStatus
    var progress: Double
    var currentStage: String?
    var operationKind: MCPOperationKind
    var requestedAnalyses: [MCPMediaAnalysisKind]
    var stages: [MCPOperationStageDTO]
    var warnings: [String]
    var failureCode: MCPErrorCode?
    var result: MCPMediaInspectionResultDTO?
    var createdAt: Date
    var expiresAt: Date
}

struct MCPOperationStatusSummaryDTO: Codable, Sendable {
    var operationID: String
    var status: MCPOperationStatus
    var progress: Double
    var currentStage: String?
    var operationKind: MCPOperationKind
    var warningCount: Int
    var failureCode: MCPErrorCode?
    var resultAvailable: Bool
    var retryAfterMs: Int?
    var unchanged: Bool
    var stages: [MCPOperationStageDTO]?
    var warnings: [String]?
    var result: MCPMediaInspectionResultDTO?
}

struct MCPMediaRelatedCursor: Codable, Sendable {
    var clientID: String
    var sourceSessionID: String
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var highWaterSequence: UInt64
    var lastSequence: UInt64
}

struct MCPStreamingQualityWaterfallDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var manifestKind: String
    var bitrateLadder: [StreamingBitrateVariant]
    var segmentCount: Int
    var totalPlayableDurationSeconds: Double
    var averageBitrateBps: Double
    var ttffSeconds: Double?
    var slowSegmentCount: Int
    var oscillationCount: Int
    var estimatedStallCount: Int
    var cdnCacheHitRatio: Double?
    var segments: [MCPStreamingSegmentDTO]
    var switchingEvents: [MCPStreamingSwitchEventDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPStreamingSegmentDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var uri: String
    var sequenceNumber: Int?
    var mediaType: String
    var variantBandwidth: Int?
    var variantResolution: String?
    var segmentDurationSeconds: Double
    var downloadDurationSeconds: Double
    var byteCount: Int
    var downloadSpeedBps: Double
    var isSlowDownload: Bool
    var isCacheHit: Bool?
}

struct MCPStreamingSwitchEventDTO: Codable, Sendable, Equatable {
    var timestamp: Date
    var fromBandwidth: Int?
    var toBandwidth: Int?
    var fromResolution: String?
    var toResolution: String?
    var switchType: String
    var triggerSessionID: String
}

struct MCPColorSwatchDTO: Codable, Sendable, Equatable {
    var hex: String
    var weight: Double
}

struct MCPVASTCompanionAdDTO: Codable, Sendable, Equatable {
    var id: String?
    var width: Int?
    var height: Int?
    var resourceType: String?
    var resourceURLOrContent: String?
    var clickThroughURL: String?
}

struct MCPVisualAssetInspectionDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var mimeType: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var aspectRatio: Double
    var aspectRatioString: String
    var bytesPerPixel: Double
    var dominantPalette: [MCPColorSwatchDTO]
    var hasTransparency: Bool
    var isFullyTransparent: Bool
    var anomalies: [String]
    var companionAds: [MCPVASTCompanionAdDTO]?
    var disclosure: MCPMediaDisclosureContextDTO
    var inspectedFrameCount: Int = 0
    var companionCoverage: String = "not_detected_or_not_applicable"
    var totalFrameCount: Int = 0
    var orientation: Int? = nil
}

struct MCPAdBreakAlignmentDTO: Codable, Sendable, Equatable {
    var adBreakID: String
    var startTimeSeconds: Double
    var durationSeconds: Double
    var scte35Payload: String?
    var hasDiscontinuityTag: Bool
    var channelLayoutBefore: String?
    var channelLayoutDuringAd: String?
    var timelineGapMs: Double
    var hazards: [String]
}

struct MCPVariantRenditionSummaryDTO: Codable, Sendable, Equatable {
    var uri: String
    var bandwidth: Int?
    var resolution: String?
    var segmentCount: Int
    var discontinuityCount: Int
    var totalDurationSeconds: Double
    var accumulatedDriftMs: Double
}

struct MCPMultiRenditionAlignmentDTO: Codable, Sendable, Equatable {
    var masterURI: String
    var variantCount: Int
    var isMultiplexed: Bool
    var audioTrackCount: Int
    var subtitleTrackCount: Int
    var isSwitchingSafe: Bool
    var totalAccumulatedDriftMs: Double
    var variants: [MCPVariantRenditionSummaryDTO]
    var adBreaks: [MCPAdBreakAlignmentDTO]
    var hazards: [String]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPCMCDTelemetryDTO: Codable, Sendable, Equatable {
    var encodedBitrateKbps: Int?
    var objectDurationMs: Int?
    var objectType: String?
    var topBitrateKbps: Int?
    var bufferLengthMs: Int?
    var deadlineMs: Int?
    var measuredThroughputKbps: Int?
    var requestedThroughputKbps: Int?
    var bufferStarvation: Bool?
    var isStartup: Bool?
    var sessionID: String?
    var contentID: String?
    var playbackRate: Double?
    var streamingFormat: String?
    var streamType: String?
}

struct MCPCMSDTelemetryDTO: Codable, Sendable, Equatable {
    var estimatedThroughputKbps: Int?
    var responseDelayMs: Int?
    var roundTripTimeMs: Int?
    var maxBitrateKbps: Int?
}

struct MCPCMCDSessionReportDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var requestPath: String
    var transportMethod: String
    var cmcd: MCPCMCDTelemetryDTO
    var cmsd: MCPCMSDTelemetryDTO?
    var throughputHeadroomPercentage: Double?
    var healthScore: Double
    var anomalies: [String]
}

struct MCPCMCDInspectionResultDTO: Codable, Sendable, Equatable {
    var totalSessionsInspected: Int
    var sessionsWithCMCDCount: Int
    var criticalAnomaliesCount: Int
    var averageHealthScore: Double
    var reports: [MCPCMCDSessionReportDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPWebVTTCueDTO: Codable, Sendable, Equatable {
    var id: String
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var durationSeconds: Double
    var startTimeString: String
    var endTimeString: String
    var maxLineLength: Int
    var text: String
}

struct MCPWebVTTTrackReportDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var cueCount: Int
    var totalDurationSeconds: Double
    var hasTimestampMap: Bool
    var mpegtsOffsetPTS: Int?
    var syncDriftMs: Double?
    var qualityScore: Double
    var isSyncSafe: Bool
    var defects: [String]
    var cues: [MCPWebVTTCueDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPDRMKeyInfoDTO: Codable, Sendable, Equatable {
    var method: String
    var keyFormat: String?
    var contentID: String?
    var uri: String?
    var iv: String?
}

struct MCPPSSHBoxDTO: Codable, Sendable, Equatable {
    var systemID: String
    var systemName: String
    var version: Int
    var keyIDs: [String]
    var dataSize: Int
}

struct MCPDRMLicenseExchangeDTO: Codable, Sendable, Equatable {
    var requestURL: String
    var drmSystem: String
    var requestMethod: String
    var statusCode: Int
    var durationSeconds: Double
    var contentID: String?
    var hasAuthToken: Bool
    var isHTTPS: Bool
}

struct MCPDRMAuditReportDTO: Codable, Sendable, Equatable {
    var drmSystem: String
    var keyInfo: MCPDRMKeyInfoDTO?
    var psshBoxes: [MCPPSSHBoxDTO]
    var licenseExchanges: [MCPDRMLicenseExchangeDTO]
    var defects: [String]
    var handshakeLatencyMs: Double?
    var qualityScore: Double
    var isHandshakeHealthy: Bool
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPByteRangeTransactionDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var requestURL: String
    var requestMethod: String
    var rangeHeader: String
    var contentRangeHeader: String?
    var statusCode: Int
    var transferredBytes: Int64
    var requestedBytes: Int64
    var redundantBytes: Int64
    var wasteRatio: Double
    var cacheStatus: String
    var cacheAgeSeconds: Int?
    var edgePOP: String?
}

struct MCPByteRangeEfficiencyReportDTO: Codable, Sendable, Equatable {
    var totalTransactions: Int
    var partialContent206Count: Int
    var fullContent200Count: Int
    var totalRequestedBytes: Int64
    var totalTransferredBytes: Int64
    var totalRedundantBytes: Int64
    var overallWastePercentage: Double
    var cacheHitRatio: Double
    var defects: [String]
    var transactions: [MCPByteRangeTransactionDTO]
    var efficiencyScore: Double
    var isEfficient: Bool
    var disclosure: MCPMediaDisclosureContextDTO
}
