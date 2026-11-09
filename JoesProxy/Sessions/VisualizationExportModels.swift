import Foundation

enum VisualizationExportConstants {
    static let currentSchemaVersion = 1
}

enum VisualizationExportType: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case sessionTimeline
    case requestWaterfall
    case hostHealthSummary
    case latencyDistribution
    case errorHeatmap
    case hlsPlaybackFlow
    case mediaAssetDeliveryTimeline
    case adAndCompanionAssetTimeline
    case variantSwitchTimeline
    case timedMetadataTimeline
    case contractViolationSummary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionTimeline:
            return "Session Timeline"
        case .requestWaterfall:
            return "Request Waterfall"
        case .hostHealthSummary:
            return "Host Health Summary"
        case .latencyDistribution:
            return "Latency Distribution"
        case .errorHeatmap:
            return "Error Heatmap"
        case .hlsPlaybackFlow:
            return "HLS Playback Flow"
        case .mediaAssetDeliveryTimeline:
            return "Media Asset Delivery Timeline"
        case .adAndCompanionAssetTimeline:
            return "Ad And Companion Asset Timeline"
        case .variantSwitchTimeline:
            return "Variant Switch Timeline"
        case .timedMetadataTimeline:
            return "Timed Metadata Timeline"
        case .contractViolationSummary:
            return "Contract Violation Summary"
        }
    }

    var isInitialPNGExportType: Bool {
        switch self {
        case .sessionTimeline, .requestWaterfall, .hostHealthSummary:
            return true
        case .latencyDistribution, .errorHeatmap, .hlsPlaybackFlow, .mediaAssetDeliveryTimeline,
             .adAndCompanionAssetTimeline, .variantSwitchTimeline, .timedMetadataTimeline,
             .contractViolationSummary:
            return false
        }
    }
}

enum VisualizationExportScope: Codable, Equatable, Sendable {
    case selectedSession(UUID)
    case selectedSessions([UUID])
    case filteredResults(VisualizationExportFilterDescriptor)
    case host(String)
    case hostGroup(String)
    case manifestAssets(manifestSessionID: UUID, relatedSessionIDs: [UUID])
    case playbackFlow(String)
    case timeRange(VisualizationExportTimeRange)

    var sessionIDs: [UUID] {
        switch self {
        case .selectedSession(let id):
            return [id]
        case .selectedSessions(let ids):
            return ids
        case .manifestAssets(let manifestSessionID, let relatedSessionIDs):
            return [manifestSessionID] + relatedSessionIDs
        case .filteredResults, .host, .hostGroup, .playbackFlow, .timeRange:
            return []
        }
    }

    var summary: String {
        switch self {
        case .selectedSession:
            return "1 selected session"
        case .selectedSessions(let ids):
            return "\(ids.count) selected sessions"
        case .filteredResults:
            return "Filtered results"
        case .host(let host):
            return "Host: \(host)"
        case .hostGroup(let pattern):
            return "Host group: \(pattern)"
        case .manifestAssets:
            return "Manifest and related assets"
        case .playbackFlow(let id):
            return "Playback flow: \(id)"
        case .timeRange(let range):
            return "Time range: \(range.summary)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sessionID, sessionIDs, filter, host, pattern, manifestSessionID, relatedSessionIDs,
             playbackFlowID, timeRange
    }

    private enum Kind: String, Codable {
        case selectedSession
        case selectedSessions
        case filteredResults
        case host
        case hostGroup
        case manifestAssets
        case playbackFlow
        case timeRange
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .selectedSession:
            self = .selectedSession(try container.decode(UUID.self, forKey: .sessionID))
        case .selectedSessions:
            self = .selectedSessions(try container.decode([UUID].self, forKey: .sessionIDs))
        case .filteredResults:
            self = .filteredResults(try container.decode(VisualizationExportFilterDescriptor.self, forKey: .filter))
        case .host:
            self = .host(try container.decode(String.self, forKey: .host))
        case .hostGroup:
            self = .hostGroup(try container.decode(String.self, forKey: .pattern))
        case .manifestAssets:
            self = .manifestAssets(
                manifestSessionID: try container.decode(UUID.self, forKey: .manifestSessionID),
                relatedSessionIDs: try container.decode([UUID].self, forKey: .relatedSessionIDs)
            )
        case .playbackFlow:
            self = .playbackFlow(try container.decode(String.self, forKey: .playbackFlowID))
        case .timeRange:
            self = .timeRange(try container.decode(VisualizationExportTimeRange.self, forKey: .timeRange))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selectedSession(let id):
            try container.encode(Kind.selectedSession, forKey: .kind)
            try container.encode(id, forKey: .sessionID)
        case .selectedSessions(let ids):
            try container.encode(Kind.selectedSessions, forKey: .kind)
            try container.encode(ids, forKey: .sessionIDs)
        case .filteredResults(let filter):
            try container.encode(Kind.filteredResults, forKey: .kind)
            try container.encode(filter, forKey: .filter)
        case .host(let host):
            try container.encode(Kind.host, forKey: .kind)
            try container.encode(host, forKey: .host)
        case .hostGroup(let pattern):
            try container.encode(Kind.hostGroup, forKey: .kind)
            try container.encode(pattern, forKey: .pattern)
        case .manifestAssets(let manifestSessionID, let relatedSessionIDs):
            try container.encode(Kind.manifestAssets, forKey: .kind)
            try container.encode(manifestSessionID, forKey: .manifestSessionID)
            try container.encode(relatedSessionIDs, forKey: .relatedSessionIDs)
        case .playbackFlow(let playbackFlowID):
            try container.encode(Kind.playbackFlow, forKey: .kind)
            try container.encode(playbackFlowID, forKey: .playbackFlowID)
        case .timeRange(let range):
            try container.encode(Kind.timeRange, forKey: .kind)
            try container.encode(range, forKey: .timeRange)
        }
    }
}

struct VisualizationExportTimeRange: Codable, Equatable, Sendable {
    var start: Date
    var end: Date

    var isValid: Bool { end >= start }

    var summary: String {
        "\(start.formatted(date: .omitted, time: .standard)) - \(end.formatted(date: .omitted, time: .standard))"
    }
}

struct VisualizationExportFilterDescriptor: Codable, Equatable, Sendable {
    var searchText: String?
    var hosts: [String]
    var statusCodes: [Int]
    var timeRange: VisualizationExportTimeRange?

    init(
        searchText: String? = nil,
        hosts: [String] = [],
        statusCodes: [Int] = [],
        timeRange: VisualizationExportTimeRange? = nil
    ) {
        self.searchText = searchText
        self.hosts = hosts
        self.statusCodes = statusCodes
        self.timeRange = timeRange
    }
}

enum VisualizationExportResolutionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd
    case qhd
    case fourK
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd:
            return "HD"
        case .qhd:
            return "QHD"
        case .fourK:
            return "4K"
        case .custom:
            return "Custom"
        }
    }
}

struct VisualizationExportDimensions: Codable, Equatable, Sendable {
    var preset: VisualizationExportResolutionPreset
    var width: Int
    var height: Int

    static let hd = VisualizationExportDimensions(preset: .hd, width: 1920, height: 1080)
    static let qhd = VisualizationExportDimensions(preset: .qhd, width: 2560, height: 1440)
    static let fourK = VisualizationExportDimensions(preset: .fourK, width: 3840, height: 2160)

    var isValid: Bool {
        width >= 640 && height >= 360
    }
}

enum VisualizationExportTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case presentation

    var id: String { rawValue }
}

struct VisualizationExportRedactionPolicy: Codable, Equatable, Sendable {
    var redactAuthHeaders: Bool
    var redactTokens: Bool
    var redactCookies: Bool
    var redactUserIdentifiers: Bool
    var redactQueryParameters: Bool
    var redactRawBodies: Bool
    var redactArtworkAndLogos: Bool
    var customSensitiveKeys: [String]
    var allowsRawValues: Bool

    static let shareableDefault = VisualizationExportRedactionPolicy(
        redactAuthHeaders: true,
        redactTokens: true,
        redactCookies: true,
        redactUserIdentifiers: true,
        redactQueryParameters: true,
        redactRawBodies: true,
        redactArtworkAndLogos: true,
        customSensitiveKeys: [],
        allowsRawValues: false
    )

    var summary: VisualizationRedactionSummary {
        VisualizationRedactionSummary(policy: self)
    }

    func redactedHeaderValue(for name: String, value: String) -> String {
        guard !allowsRawValues, shouldRedactHeader(named: name) else {
            return value
        }
        return "<redacted>"
    }

    func shouldRedactHeader(named name: String) -> Bool {
        guard !allowsRawValues else {
            return false
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if redactAuthHeaders && SensitiveDataRedaction.authHeaderNames.contains(normalizedName) {
            return true
        }
        if redactCookies && SensitiveDataRedaction.cookieHeaderNames.contains(normalizedName) {
            return true
        }
        if redactTokens && SensitiveDataRedaction.isSensitiveHeaderName(normalizedName) {
            return true
        }
        return customSensitiveKeys.contains {
            normalizedName == $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    func redactedValue(forKey key: String, value: String) -> String {
        guard !allowsRawValues, shouldRedactValue(forKey: key) else {
            return value
        }
        return "<redacted>"
    }

    func shouldRedactValue(forKey key: String) -> Bool {
        guard !allowsRawValues else {
            return false
        }

        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if customSensitiveKeys.contains(where: {
            normalizedKey == $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }) {
            return true
        }
        if redactTokens && SensitiveDataRedaction.isSensitiveKey(normalizedKey) {
            return true
        }
        if redactUserIdentifiers && SensitiveDataRedaction.isUserIdentifierKey(normalizedKey) {
            return true
        }
        return false
    }

    func redactedURLString(_ urlString: String) -> String {
        guard !allowsRawValues, redactQueryParameters else {
            return urlString
        }
        return SensitiveDataRedaction.redactedQueryURLString(urlString)
    }
}

struct VisualizationRedactionSummary: Codable, Equatable, Sendable {
    var redactedCategories: [String]
    var allowsRawValues: Bool
    var customSensitiveKeyCount: Int

    init(policy: VisualizationExportRedactionPolicy) {
        var categories: [String] = []
        if policy.redactAuthHeaders { categories.append("auth headers") }
        if policy.redactTokens { categories.append("tokens") }
        if policy.redactCookies { categories.append("cookies") }
        if policy.redactUserIdentifiers { categories.append("user identifiers") }
        if policy.redactQueryParameters { categories.append("query parameters") }
        if policy.redactRawBodies { categories.append("raw bodies") }
        if policy.redactArtworkAndLogos { categories.append("artwork and logos") }
        self.redactedCategories = categories
        self.allowsRawValues = policy.allowsRawValues
        self.customSensitiveKeyCount = policy.customSensitiveKeys.count
    }
}

struct VisualizationExportAnnotationOptions: Codable, Equatable, Sendable {
    var showRequestNames: Bool
    var showHostLabels: Bool
    var showStatusCodes: Bool
    var showDurations: Bool
    var showContentMetadata: Bool
    var showAssetTypeIcons: Bool
    var showErrorBadges: Bool
    var showWarningOverlays: Bool

    static let defaults = VisualizationExportAnnotationOptions(
        showRequestNames: true,
        showHostLabels: true,
        showStatusCodes: true,
        showDurations: true,
        showContentMetadata: false,
        showAssetTypeIcons: true,
        showErrorBadges: true,
        showWarningOverlays: true
    )
}

enum VisualizationExportGroupingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case host
    case requestRole

    var id: String { rawValue }
}

enum VisualizationExportSortMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case startTime
    case durationDescending

    var id: String { rawValue }
}

struct VisualizationExportChartConfiguration: Codable, Equatable, Sendable {
    var groupingMode: VisualizationExportGroupingMode
    var sortMode: VisualizationExportSortMode
    var showFailedOnly: Bool
    var collapseDuplicates: Bool
    var normalizeRelativeStartTime: Bool
    var optionFlags: [String: Bool]
    var optionValues: [String: String]

    static let defaults = VisualizationExportChartConfiguration(
        groupingMode: .none,
        sortMode: .startTime,
        showFailedOnly: false,
        collapseDuplicates: true,
        normalizeRelativeStartTime: true,
        optionFlags: [:],
        optionValues: [:]
    )
}

struct VisualizationExportIncludedMetadata: Codable, Equatable, Sendable {
    var includeLegend: Bool
    var includeTitleBlock: Bool
    var includeFooterMetadata: Bool
    var includeDataSummary: Bool

    static let defaults = VisualizationExportIncludedMetadata(
        includeLegend: true,
        includeTitleBlock: true,
        includeFooterMetadata: true,
        includeDataSummary: true
    )
}

struct VisualizationExportProvenance: Codable, Equatable, Sendable {
    var isPartialCapture: Bool
    var hasStrippedBodies: Bool
    var hasInferredRelationships: Bool
    var hasUnknownAssetTypes: Bool
    var usesProxyOnlyData: Bool
    var usesSDKTelemetry: Bool

    static let proxyOnlyComplete = VisualizationExportProvenance(
        isPartialCapture: false,
        hasStrippedBodies: false,
        hasInferredRelationships: false,
        hasUnknownAssetTypes: false,
        usesProxyOnlyData: true,
        usesSDKTelemetry: false
    )
}

struct VisualizationExportDataSummary: Codable, Equatable, Sendable {
    var sessionCount: Int
    var hostCount: Int
    var warningCount: Int
    var errorCount: Int
    var notes: [String]

    static let empty = VisualizationExportDataSummary(
        sessionCount: 0,
        hostCount: 0,
        warningCount: 0,
        errorCount: 0,
        notes: []
    )
}

struct VisualizationExportRequest: Equatable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var exportType: VisualizationExportType
    var sourceScope: VisualizationExportScope
    var redactionPolicy: VisualizationExportRedactionPolicy
    var theme: VisualizationExportTheme
    var dimensions: VisualizationExportDimensions
    var chartConfiguration: VisualizationExportChartConfiguration
    var title: String
    var subtitle: String?
    var annotations: VisualizationExportAnnotationOptions
    var includedMetadata: VisualizationExportIncludedMetadata
    var provenance: VisualizationExportProvenance

    init(
        schemaVersion: Int = VisualizationExportConstants.currentSchemaVersion,
        id: UUID = UUID(),
        exportType: VisualizationExportType,
        sourceScope: VisualizationExportScope,
        redactionPolicy: VisualizationExportRedactionPolicy = .shareableDefault,
        theme: VisualizationExportTheme = .dark,
        dimensions: VisualizationExportDimensions = .hd,
        chartConfiguration: VisualizationExportChartConfiguration = .defaults,
        title: String? = nil,
        subtitle: String? = nil,
        annotations: VisualizationExportAnnotationOptions = .defaults,
        includedMetadata: VisualizationExportIncludedMetadata = .defaults,
        provenance: VisualizationExportProvenance = .proxyOnlyComplete
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.exportType = exportType
        self.sourceScope = sourceScope
        self.redactionPolicy = redactionPolicy
        self.theme = theme
        self.dimensions = dimensions
        self.chartConfiguration = chartConfiguration
        self.title = title ?? exportType.title
        self.subtitle = subtitle
        self.annotations = annotations
        self.includedMetadata = includedMetadata
        self.provenance = provenance
    }

    func validationIssues() -> [VisualizationExportValidationIssue] {
        var issues: [VisualizationExportValidationIssue] = []

        if schemaVersion > VisualizationExportConstants.currentSchemaVersion {
            issues.append(.unsupportedFutureSchema(schemaVersion))
        }

        if !exportType.isInitialPNGExportType {
            issues.append(.exportTypeNotAvailable(exportType))
        }

        if !dimensions.isValid {
            issues.append(.invalidDimensions(width: dimensions.width, height: dimensions.height))
        }

        if case .timeRange(let range) = sourceScope, !range.isValid {
            issues.append(.invalidTimeRange)
        }

        if !exportType.supports(sourceScope) {
            issues.append(.unsupportedScope(exportType: exportType, scopeSummary: sourceScope.summary))
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyTitle)
        }

        return issues
    }
}

extension VisualizationExportRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, exportType, sourceScope, redactionPolicy, theme, dimensions,
             chartConfiguration, title, subtitle, annotations, includedMetadata, provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: (try? container.decode(Int.self, forKey: .schemaVersion))
                ?? VisualizationExportConstants.currentSchemaVersion,
            id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
            exportType: try container.decode(VisualizationExportType.self, forKey: .exportType),
            sourceScope: try container.decode(VisualizationExportScope.self, forKey: .sourceScope),
            redactionPolicy: (try? container.decode(
                VisualizationExportRedactionPolicy.self,
                forKey: .redactionPolicy
            )) ?? .shareableDefault,
            theme: (try? container.decode(VisualizationExportTheme.self, forKey: .theme)) ?? .dark,
            dimensions: (try? container.decode(VisualizationExportDimensions.self, forKey: .dimensions)) ?? .hd,
            chartConfiguration: (try? container.decode(
                VisualizationExportChartConfiguration.self,
                forKey: .chartConfiguration
            )) ?? .defaults,
            title: try container.decodeIfPresent(String.self, forKey: .title),
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle),
            annotations: (try? container.decode(
                VisualizationExportAnnotationOptions.self,
                forKey: .annotations
            )) ?? .defaults,
            includedMetadata: (try? container.decode(
                VisualizationExportIncludedMetadata.self,
                forKey: .includedMetadata
            )) ?? .defaults,
            provenance: (try? container.decode(
                VisualizationExportProvenance.self,
                forKey: .provenance
            )) ?? .proxyOnlyComplete
        )
    }
}

enum VisualizationExportValidationIssue: Equatable, Sendable {
    case unsupportedFutureSchema(Int)
    case exportTypeNotAvailable(VisualizationExportType)
    case unsupportedScope(exportType: VisualizationExportType, scopeSummary: String)
    case invalidDimensions(width: Int, height: Int)
    case invalidTimeRange
    case emptyTitle

    var message: String {
        switch self {
        case .unsupportedFutureSchema(let schemaVersion):
            return "Export schema \(schemaVersion) is newer than this version of JoesProxy supports."
        case .exportTypeNotAvailable(let exportType):
            return "\(exportType.title) is planned for a later visualization phase."
        case .unsupportedScope(let exportType, let scopeSummary):
            return "\(exportType.title) does not support \(scopeSummary)."
        case .invalidDimensions(let width, let height):
            return "Export dimensions must be at least 640 x 360 px. Current size is \(width) x \(height) px."
        case .invalidTimeRange:
            return "Export time range must end at or after its start time."
        case .emptyTitle:
            return "Export title cannot be empty."
        }
    }
}

struct VisualizationExportResult: Codable, Equatable, Sendable {
    var requestID: UUID
    var exportType: VisualizationExportType
    var imageFileURL: URL?
    var imageByteCount: Int
    var dimensions: VisualizationExportDimensions
    var metadata: VisualizationExportResultMetadata
    var redactionSummary: VisualizationRedactionSummary
    var dataSummary: VisualizationExportDataSummary
    var sourceDescriptor: VisualizationExportSourceDescriptor
}

struct VisualizationExportResultMetadata: Codable, Equatable, Sendable {
    var generatedAt: Date
    var appVersion: String
    var exportSchemaVersion: Int
}

struct VisualizationExportSourceDescriptor: Codable, Equatable, Sendable {
    var scopeSummary: String
    var sessionIDs: [UUID]
    var provenance: VisualizationExportProvenance

    init(request: VisualizationExportRequest) {
        self.scopeSummary = request.sourceScope.summary
        self.sessionIDs = request.sourceScope.sessionIDs
        self.provenance = request.provenance
    }
}

private extension VisualizationExportType {
    func supports(_ scope: VisualizationExportScope) -> Bool {
        switch self {
        case .sessionTimeline:
            switch scope {
            case .selectedSession, .selectedSessions, .filteredResults, .timeRange:
                return true
            case .host, .hostGroup, .manifestAssets, .playbackFlow:
                return false
            }
        case .requestWaterfall:
            switch scope {
            case .selectedSession, .selectedSessions, .host, .hostGroup, .timeRange:
                return true
            case .filteredResults, .manifestAssets, .playbackFlow:
                return false
            }
        case .hostHealthSummary:
            switch scope {
            case .filteredResults, .host, .hostGroup, .timeRange:
                return true
            case .selectedSession, .selectedSessions, .manifestAssets, .playbackFlow:
                return false
            }
        case .latencyDistribution, .errorHeatmap, .hlsPlaybackFlow, .mediaAssetDeliveryTimeline,
             .adAndCompanionAssetTimeline, .variantSwitchTimeline, .timedMetadataTimeline,
             .contractViolationSummary:
            return false
        }
    }
}
