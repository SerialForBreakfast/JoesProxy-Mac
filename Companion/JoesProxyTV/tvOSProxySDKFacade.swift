import Foundation

/// Connection state exposed by the future JoesProxy SDK facade.
enum TVOSProxyConnectionState: Equatable, Sendable {
    case disconnected
    case discovering
    case connecting(TVOSDiscoveredProxy)
    case connected(TVOSDiscoveredProxy)
    case rejected(String)
}

/// Discovery abstraction for finding a Mac that is running JoesProxy.
///
/// The scaffold uses mocks. The future implementation can wrap `NWBrowser` for `_joesproxy._tcp`
/// without changing setup views.
protocol TVOSProxyDiscoveryServicing: Sendable {
    func discover() async -> [TVOSDiscoveredProxy]
}

/// Transport abstraction matching the SDK event channel.
protocol TVOSProxyTransporting: Sendable {
    func connect(to proxy: TVOSDiscoveredProxy, pairingToken: String?) async -> TVOSProxyConnectionState
    func disconnect() async
    /// Returns all SDK message headers collected since the last `connect` call.
    func collectedEvents() async -> [TVOSSDKMessageHeader]
    /// Returns parsed `networkEvent` payloads collected since the last `connect` call.
    func collectedNetworkEvents() async -> [TVOSObservedNetworkEvent]
}

/// Reachability probe for the Mac-hosted profile server.
protocol TVOSProxySetupProbing: Sendable {
    func probeProfileServer(host: String, port: Int, path: String) async -> TVOSReachabilityResult
}

/// Annotation seam for sending app/setup milestones to the Mac once SDK M0/M1 are ready.
protocol TVOSAnnotationSending: Sendable {
    func record(_ annotation: TVOSAnnotationDraft) async
}

/// Single facade consumed by tvOS views.
protocol TVOSProxySDKFacading: Sendable {
    var discoveryService: any TVOSProxyDiscoveryServicing { get }
    var transport: any TVOSProxyTransporting { get }
    var setupProbe: any TVOSProxySetupProbing { get }
    var annotationSender: any TVOSAnnotationSending { get }
}

/// Minimal SDK message header mirrored from the schema contract for fixture routing.
struct TVOSSDKMessageHeader: Codable, Equatable, Sendable {
    let type: String
    let version: Int
    let id: UUID
    let sentAt: Date
}

/// JSON codec compatible with the v1 SDK event fixture date format.
enum TVOSSDKEventJSONCodec {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 UTC date string with optional fractional seconds."
            )
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

/// Setup annotation captured locally until the live SDK transport exists.
struct TVOSAnnotationDraft: Equatable, Sendable {
    enum Kind: String, Sendable {
        case setupStarted
        case hiddenMenuReached
        case profileInstalled
        case certificateTrusted
        case setupVerificationPing
    }

    let id: UUID
    let kind: Kind
    let label: String
    let metadata: [String: String]
    let deviceTimestamp: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        metadata: [String: String] = [:],
        deviceTimestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.metadata = metadata
        self.deviceTimestamp = deviceTimestamp
    }
}
