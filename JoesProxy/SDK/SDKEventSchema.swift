import Foundation

public enum SDKSchema {
    public static let version = 1
}

public enum SDKMessageType: String, Codable, Equatable, Sendable {
    case handshake
    case handshakeAck
    case networkEvent
    case annotationEvent
    case streamingSegmentEvent
    case drmLicenseEvent
    case manifestEvent
    case stallRiskEvent
    case piiHintEvent
    case assertionRequest
    case diagnosticReport
}

public enum SDKHandshakeRejectReason: String, Codable, Equatable, Sendable {
    case invalidToken = "invalid_token"
    case schemaVersionUnsupported = "schema_version_unsupported"
    case protocolError = "protocol_error"
}

public enum SDKCompatibilityResolution: String, Codable, Equatable, Sendable {
    case updateJoesProxy = "update_joesproxy"
    case updateSDK = "update_sdk"
    case unknown
}

public struct SDKMessageHeader: Codable, Equatable, Sendable {
    public let type: String
    public let version: Int
    public let id: UUID
    public let sentAt: Date

    public init(type: String, version: Int, id: UUID, sentAt: Date) {
        self.type = type
        self.version = version
        self.id = id
        self.sentAt = sentAt
    }
}

public struct SDKMessageEnvelope<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let type: SDKMessageType
    public let version: Int
    public let id: UUID
    public let sentAt: Date
    public let payload: Payload

    public init(type: SDKMessageType, version: Int, id: UUID, sentAt: Date, payload: Payload) {
        self.type = type
        self.version = version
        self.id = id
        self.sentAt = sentAt
        self.payload = payload
    }
}

public struct PairingHandshake: Codable, Equatable, Sendable {
    public let token: String
    public let deviceName: String
    public let bundleID: String
    public let deviceTimestamp: Date
    public let sdkVersion: String
    public let schemaVersion: Int
    public let supportedSchemaVersions: [Int]

    public init(
        token: String,
        deviceName: String,
        bundleID: String,
        deviceTimestamp: Date,
        sdkVersion: String,
        schemaVersion: Int,
        supportedSchemaVersions: [Int]
    ) {
        self.token = token
        self.deviceName = deviceName
        self.bundleID = bundleID
        self.deviceTimestamp = deviceTimestamp
        self.sdkVersion = sdkVersion
        self.schemaVersion = schemaVersion
        self.supportedSchemaVersions = supportedSchemaVersions
    }
}

public struct HandshakeAck: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let rejectReason: SDKHandshakeRejectReason?
    public let serverTimestamp: Date
    public let clockOffsetMs: Int
    public let selectedSchemaVersion: Int?
    public let supportedSchemaVersions: [Int]
    public let serverAppVersion: String?
    public let minimumSupportedSchemaVersion: Int?
    public let latestSupportedSchemaVersion: Int?
    public let compatibilityResolution: SDKCompatibilityResolution?
    public let compatibilityMessage: String?

    public init(
        accepted: Bool,
        rejectReason: SDKHandshakeRejectReason?,
        serverTimestamp: Date,
        clockOffsetMs: Int,
        selectedSchemaVersion: Int?,
        supportedSchemaVersions: [Int],
        serverAppVersion: String? = nil,
        minimumSupportedSchemaVersion: Int? = nil,
        latestSupportedSchemaVersion: Int? = nil,
        compatibilityResolution: SDKCompatibilityResolution? = nil,
        compatibilityMessage: String? = nil
    ) {
        self.accepted = accepted
        self.rejectReason = rejectReason
        self.serverTimestamp = serverTimestamp
        self.clockOffsetMs = clockOffsetMs
        self.selectedSchemaVersion = selectedSchemaVersion
        self.supportedSchemaVersions = supportedSchemaVersions
        self.serverAppVersion = serverAppVersion
        self.minimumSupportedSchemaVersion = minimumSupportedSchemaVersion
        self.latestSupportedSchemaVersion = latestSupportedSchemaVersion
        self.compatibilityResolution = compatibilityResolution
        self.compatibilityMessage = compatibilityMessage
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case rejectReason
        case serverTimestamp
        case clockOffsetMs
        case selectedSchemaVersion
        case supportedSchemaVersions
        case serverAppVersion
        case minimumSupportedSchemaVersion
        case latestSupportedSchemaVersion
        case compatibilityResolution
        case compatibilityMessage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accepted, forKey: .accepted)
        if let rejectReason {
            try container.encode(rejectReason, forKey: .rejectReason)
        } else {
            try container.encodeNil(forKey: .rejectReason)
        }
        try container.encode(serverTimestamp, forKey: .serverTimestamp)
        try container.encode(clockOffsetMs, forKey: .clockOffsetMs)
        if let selectedSchemaVersion {
            try container.encode(selectedSchemaVersion, forKey: .selectedSchemaVersion)
        } else {
            try container.encodeNil(forKey: .selectedSchemaVersion)
        }
        try container.encode(supportedSchemaVersions, forKey: .supportedSchemaVersions)
        try container.encodeIfPresent(serverAppVersion, forKey: .serverAppVersion)
        try container.encodeIfPresent(minimumSupportedSchemaVersion, forKey: .minimumSupportedSchemaVersion)
        try container.encodeIfPresent(latestSupportedSchemaVersion, forKey: .latestSupportedSchemaVersion)
        try container.encodeIfPresent(compatibilityResolution, forKey: .compatibilityResolution)
        try container.encodeIfPresent(compatibilityMessage, forKey: .compatibilityMessage)
    }
}

public enum NetworkEventPhase: String, Codable, Equatable, Sendable {
    case started
    case updated
    case completed
    case failed
}

public enum EventRedactionLevel: String, Codable, Equatable, Sendable {
    case fullURLNoHeadersNoBodies
    case queryRedacted
    case metadataOnly
}

public enum CDNCacheStatus: String, Codable, Equatable, Sendable {
    case hit
    case miss
    case stale
    case bypass
    case expired
    case unknown
}

public struct NetworkTiming: Codable, Equatable, Sendable {
    /// Proxy-side DNS duration. Nil for reused connections or when not captured.
    public let dns: Double?
    /// Proxy-side TCP handshake duration. Nil for reused connections or when not captured.
    public let tcp: Double?
    /// Proxy-side TLS handshake duration. Nil for reused connections, HTTP, or when not captured.
    public let tls: Double?
    /// Time from request sent by the proxy to first response byte, in seconds.
    public let ttfb: Double
    /// Time from first response byte to last response byte, in seconds.
    public let transfer: Double
    /// Full wall-clock request duration from the proxy perspective, in seconds.
    public let total: Double

    public init(dns: Double?, tcp: Double?, tls: Double?, ttfb: Double, transfer: Double, total: Double) {
        self.dns = dns
        self.tcp = tcp
        self.tls = tls
        self.ttfb = ttfb
        self.transfer = transfer
        self.total = total
    }

    private enum CodingKeys: String, CodingKey {
        case dns
        case tcp
        case tls
        case ttfb
        case transfer
        case total
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let dns {
            try container.encode(dns, forKey: .dns)
        } else {
            try container.encodeNil(forKey: .dns)
        }
        if let tcp {
            try container.encode(tcp, forKey: .tcp)
        } else {
            try container.encodeNil(forKey: .tcp)
        }
        if let tls {
            try container.encode(tls, forKey: .tls)
        } else {
            try container.encodeNil(forKey: .tls)
        }
        try container.encode(ttfb, forKey: .ttfb)
        try container.encode(transfer, forKey: .transfer)
        try container.encode(total, forKey: .total)
    }
}

public struct NetworkSizes: Codable, Equatable, Sendable {
    public let requestBytes: Int
    /// Decompressed response bytes when available; otherwise the best captured response size.
    public let responseBytes: Int
    /// Compressed response bytes. Nil when compression or raw transfer size is unknown.
    public let compressedResponseBytes: Int?

    public init(requestBytes: Int, responseBytes: Int, compressedResponseBytes: Int?) {
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.compressedResponseBytes = compressedResponseBytes
    }

    private enum CodingKeys: String, CodingKey {
        case requestBytes
        case responseBytes
        case compressedResponseBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestBytes, forKey: .requestBytes)
        try container.encode(responseBytes, forKey: .responseBytes)
        if let compressedResponseBytes {
            try container.encode(compressedResponseBytes, forKey: .compressedResponseBytes)
        } else {
            try container.encodeNil(forKey: .compressedResponseBytes)
        }
    }
}

public struct ConnectionInfo: Codable, Equatable, Sendable {
    public let httpProtocol: String
    public let isConnectionReused: Bool
    public let cdnRegion: String?

    public init(httpProtocol: String, isConnectionReused: Bool, cdnRegion: String?) {
        self.httpProtocol = httpProtocol
        self.isConnectionReused = isConnectionReused
        self.cdnRegion = cdnRegion
    }

    private enum CodingKeys: String, CodingKey {
        case httpProtocol
        case isConnectionReused
        case cdnRegion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(httpProtocol, forKey: .httpProtocol)
        try container.encode(isConnectionReused, forKey: .isConnectionReused)
        if let cdnRegion {
            try container.encode(cdnRegion, forKey: .cdnRegion)
        } else {
            try container.encodeNil(forKey: .cdnRegion)
        }
    }
}

public struct NetworkEvent: Codable, Identifiable, Equatable, Sendable {
    /// Unique ID for this event snapshot.
    public let id: UUID
    /// Stable JoesProxy SessionRecord ID.
    public let sessionID: UUID
    public let phase: NetworkEventPhase
    /// Mac-adjusted event timestamp.
    public let timestamp: Date
    public let url: URL
    public let redactionLevel: EventRedactionLevel
    public let method: String
    public let statusCode: Int?
    public let timing: NetworkTiming
    public let sizes: NetworkSizes
    public let connectionInfo: ConnectionInfo
    public let redirectCount: Int
    /// Wire-level repeated attempts. Heuristic; 0 until retry correlation exists.
    public let retryCount: Int
    public let cacheStatus: CDNCacheStatus?
    public let certificateExpiry: Date?
    public let annotations: [String]
    public let sourceSDK: String?
    public let lane: String
    /// Nil until upstream connection tracking exists.
    public let connectionID: UUID?
    /// Nil unless redirect/retry/follow-up correlation is known.
    public let parentEventID: UUID?

    public init(
        id: UUID,
        sessionID: UUID,
        phase: NetworkEventPhase,
        timestamp: Date,
        url: URL,
        redactionLevel: EventRedactionLevel,
        method: String,
        statusCode: Int?,
        timing: NetworkTiming,
        sizes: NetworkSizes,
        connectionInfo: ConnectionInfo,
        redirectCount: Int,
        retryCount: Int,
        cacheStatus: CDNCacheStatus?,
        certificateExpiry: Date?,
        annotations: [String],
        sourceSDK: String?,
        lane: String,
        connectionID: UUID?,
        parentEventID: UUID?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.phase = phase
        self.timestamp = timestamp
        self.url = url
        self.redactionLevel = redactionLevel
        self.method = method
        self.statusCode = statusCode
        self.timing = timing
        self.sizes = sizes
        self.connectionInfo = connectionInfo
        self.redirectCount = redirectCount
        self.retryCount = retryCount
        self.cacheStatus = cacheStatus
        self.certificateExpiry = certificateExpiry
        self.annotations = annotations
        self.sourceSDK = sourceSDK
        self.lane = lane
        self.connectionID = connectionID
        self.parentEventID = parentEventID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case phase
        case timestamp
        case url
        case redactionLevel
        case method
        case statusCode
        case timing
        case sizes
        case connectionInfo
        case redirectCount
        case retryCount
        case cacheStatus
        case certificateExpiry
        case annotations
        case sourceSDK
        case lane
        case connectionID
        case parentEventID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(phase, forKey: .phase)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(url, forKey: .url)
        try container.encode(redactionLevel, forKey: .redactionLevel)
        try container.encode(method, forKey: .method)
        if let statusCode {
            try container.encode(statusCode, forKey: .statusCode)
        } else {
            try container.encodeNil(forKey: .statusCode)
        }
        try container.encode(timing, forKey: .timing)
        try container.encode(sizes, forKey: .sizes)
        try container.encode(connectionInfo, forKey: .connectionInfo)
        try container.encode(redirectCount, forKey: .redirectCount)
        try container.encode(retryCount, forKey: .retryCount)
        if let cacheStatus {
            try container.encode(cacheStatus, forKey: .cacheStatus)
        } else {
            try container.encodeNil(forKey: .cacheStatus)
        }
        if let certificateExpiry {
            try container.encode(certificateExpiry, forKey: .certificateExpiry)
        } else {
            try container.encodeNil(forKey: .certificateExpiry)
        }
        try container.encode(annotations, forKey: .annotations)
        if let sourceSDK {
            try container.encode(sourceSDK, forKey: .sourceSDK)
        } else {
            try container.encodeNil(forKey: .sourceSDK)
        }
        try container.encode(lane, forKey: .lane)
        if let connectionID {
            try container.encode(connectionID, forKey: .connectionID)
        } else {
            try container.encodeNil(forKey: .connectionID)
        }
        if let parentEventID {
            try container.encode(parentEventID, forKey: .parentEventID)
        } else {
            try container.encodeNil(forKey: .parentEventID)
        }
    }
}

public enum AnnotationLifecycle: String, Codable, Equatable, Sendable {
    case instant
    case begin
    case end
}

public enum AnnotationKind: String, Codable, Equatable, Sendable {
    case screen
    case feature
    case testCapture
    case launchMarker
    case readyMarker
    case playbackStart
    case playbackReady
}

public struct AnnotationEvent: Codable, Equatable, Sendable {
    public let id: UUID
    /// Pairs begin/end windows. Nil for instant markers.
    public let scopeID: UUID?
    public let label: String
    public let kind: AnnotationKind
    public let lifecycle: AnnotationLifecycle
    public let metadata: [String: String]
    public let deviceTimestamp: Date

    public init(
        id: UUID,
        scopeID: UUID?,
        label: String,
        kind: AnnotationKind,
        lifecycle: AnnotationLifecycle,
        metadata: [String: String],
        deviceTimestamp: Date
    ) {
        self.id = id
        self.scopeID = scopeID
        self.label = label
        self.kind = kind
        self.lifecycle = lifecycle
        self.metadata = metadata
        self.deviceTimestamp = deviceTimestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case scopeID
        case label
        case kind
        case lifecycle
        case metadata
        case deviceTimestamp
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let scopeID {
            try container.encode(scopeID, forKey: .scopeID)
        } else {
            try container.encodeNil(forKey: .scopeID)
        }
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(deviceTimestamp, forKey: .deviceTimestamp)
    }
}

public struct StreamingSegmentEvent: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let timestamp: Date
    public let url: URL
    public let lane: String
    public let byteCount: Int?
    /// Actual download duration in seconds.
    public let durationSeconds: Double?
    /// Manifest-declared segment duration in seconds. Nil when no manifest has been parsed yet.
    public let segmentDurationSeconds: Double?
    /// `durationSeconds / segmentDurationSeconds`. Nil unless both are known.
    public let deliveryRatio: Double?
    public let httpProtocol: String
    public let statusCode: Int?

    public init(
        sessionID: UUID,
        timestamp: Date,
        url: URL,
        lane: String,
        byteCount: Int?,
        durationSeconds: Double?,
        segmentDurationSeconds: Double?,
        deliveryRatio: Double?,
        httpProtocol: String,
        statusCode: Int?
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.url = url
        self.lane = lane
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.segmentDurationSeconds = segmentDurationSeconds
        self.deliveryRatio = deliveryRatio
        self.httpProtocol = httpProtocol
        self.statusCode = statusCode
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, timestamp, url, lane, byteCount, durationSeconds
        case segmentDurationSeconds, deliveryRatio, httpProtocol, statusCode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(url, forKey: .url)
        try container.encode(lane, forKey: .lane)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(segmentDurationSeconds, forKey: .segmentDurationSeconds)
        try container.encodeIfPresent(deliveryRatio, forKey: .deliveryRatio)
        try container.encode(httpProtocol, forKey: .httpProtocol)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
    }
}

public struct DRMLicenseEvent: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let timestamp: Date
    public let url: URL
    /// "FairPlay", "Widevine", "ClearKey", "PlayReady". Nil when the pattern is unrecognized.
    public let drmSystem: String?
    /// Milliseconds since `.markPlaybackStart()`. Negative when the license precedes playback start.
    /// Nil if `.markPlaybackStart()` was never called for this session.
    public let relativeToPlaybackStartMs: Int?
    public let statusCode: Int?
    public let durationSeconds: Double?

    public init(
        sessionID: UUID,
        timestamp: Date,
        url: URL,
        drmSystem: String?,
        relativeToPlaybackStartMs: Int?,
        statusCode: Int?,
        durationSeconds: Double?
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.url = url
        self.drmSystem = drmSystem
        self.relativeToPlaybackStartMs = relativeToPlaybackStartMs
        self.statusCode = statusCode
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, timestamp, url, drmSystem, relativeToPlaybackStartMs, statusCode, durationSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(drmSystem, forKey: .drmSystem)
        try container.encodeIfPresent(relativeToPlaybackStartMs, forKey: .relativeToPlaybackStartMs)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }
}

public struct ManifestEvent: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let timestamp: Date
    public let url: URL
    /// "HLS" or "DASH".
    public let format: String
    /// True for the first manifest fetched for this content; false for a refresh.
    public let isInitial: Bool
    public let durationSeconds: Double?
    public let statusCode: Int?

    public init(
        sessionID: UUID,
        timestamp: Date,
        url: URL,
        format: String,
        isInitial: Bool,
        durationSeconds: Double?,
        statusCode: Int?
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.url = url
        self.format = format
        self.isInitial = isInitial
        self.durationSeconds = durationSeconds
        self.statusCode = statusCode
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, timestamp, url, format, isInitial, durationSeconds, statusCode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(url, forKey: .url)
        try container.encode(format, forKey: .format)
        try container.encode(isInitial, forKey: .isInitial)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
    }
}

/// Best-effort stream-health classification. Never treat as a guaranteed-accurate diagnosis.
public enum StallRiskSeverity: String, Codable, Equatable, Sendable {
    /// Rolling P75 delivery ratio > 0.75 across the last 10 segments.
    case warning
    /// A single segment's delivery ratio > 1.0, or rolling P75 > 1.2 across the last 3 segments.
    case critical
}

public struct StallRiskEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let currentDeliveryRatio: Double
    public let rollingP75DeliveryRatio: Double
    public let severity: StallRiskSeverity
    /// Always prefixed "Heuristic: " — this signal is best-effort, not a guaranteed diagnosis.
    public let recommendation: String

    public init(
        timestamp: Date,
        currentDeliveryRatio: Double,
        rollingP75DeliveryRatio: Double,
        severity: StallRiskSeverity,
        recommendation: String
    ) {
        self.timestamp = timestamp
        self.currentDeliveryRatio = currentDeliveryRatio
        self.rollingP75DeliveryRatio = rollingP75DeliveryRatio
        self.severity = severity
        self.recommendation = recommendation
    }
}

public enum SDKEventJSONCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter().string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = formatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected RFC3339 date with fractional seconds."
                )
            }
            return date
        }
        return decoder
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
