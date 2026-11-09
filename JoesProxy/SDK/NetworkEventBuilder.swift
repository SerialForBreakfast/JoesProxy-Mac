import Foundation

struct NetworkEventBuilder: Sendable {
    private let cdnHeaderReader: CDNHeaderReader
    private let classifier: any TimelineClassifying
    private let eventIDProvider: @Sendable () -> UUID

    init(
        cdnHeaderReader: CDNHeaderReader = CDNHeaderReader(),
        classifier: any TimelineClassifying = TimelineClassificationService(),
        eventIDProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.cdnHeaderReader = cdnHeaderReader
        self.classifier = classifier
        self.eventIDProvider = eventIDProvider
    }

    func build(session: SessionRecord, activeAnnotations: [String] = []) -> NetworkEvent {
        let cdnSignals = cdnHeaderReader.read(headers: session.response?.headers ?? [])
        let classification = classifier.classify(session)
        let duration = max(session.timing.duration ?? 0, 0)

        return NetworkEvent(
            id: eventIDProvider(),
            sessionID: session.id,
            phase: phase(for: session.state),
            timestamp: session.timing.completedAt ?? session.timing.startedAt,
            url: url(for: session.request),
            redactionLevel: redactionLevel(for: session.request),
            method: session.request.method,
            statusCode: session.response?.statusCode,
            timing: NetworkTiming(
                dns: nil,
                tcp: nil,
                tls: nil,
                ttfb: duration,
                transfer: 0,
                total: duration
            ),
            sizes: NetworkSizes(
                requestBytes: byteCount(bodyData: session.request.bodyData, bodySize: session.request.bodySize),
                responseBytes: byteCount(bodyData: session.response?.bodyData, bodySize: session.response?.bodySize),
                compressedResponseBytes: nil
            ),
            connectionInfo: ConnectionInfo(
                httpProtocol: session.request.inspectionKind == .tunneledTLS ? "CONNECT" : "HTTP/1.1",
                isConnectionReused: false,
                cdnRegion: cdnSignals.cdnRegion
            ),
            redirectCount: 0,
            retryCount: 0,
            cacheStatus: cdnSignals.cacheStatus,
            certificateExpiry: nil,
            annotations: activeAnnotations,
            sourceSDK: nil,
            lane: classification.lane.rawValue,
            connectionID: nil,
            parentEventID: nil
        )
    }

    private func phase(for state: SessionLifecycleState) -> NetworkEventPhase {
        switch state {
        case .pending:
            return .started
        case .completed:
            return .completed
        case .failed, .cancelled:
            return .failed
        }
    }

    private func redactionLevel(for request: CapturedRequest) -> EventRedactionLevel {
        request.inspectionKind == .tunneledTLS ? .metadataOnly : .queryRedacted
    }

    private func url(for request: CapturedRequest) -> URL {
        Self.eventURL(for: request)
    }

    /// Builds the redacted event URL used for both `NetworkEvent` and the M3 streaming
    /// event types, so all SDK-facing URLs apply the same redaction rule.
    static func eventURL(for request: CapturedRequest) -> URL {
        let baseURL = MediaDetector.absoluteURL(for: request) ?? fallbackURL(for: request)
        return redactedURL(baseURL, metadataOnly: request.inspectionKind == .tunneledTLS)
    }

    private static func redactedURL(_ url: URL, metadataOnly: Bool) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        if metadataOnly {
            components.user = nil
            components.password = nil
        }
        return components.url ?? url
    }

    private static func fallbackURL(for request: CapturedRequest) -> URL {
        var components = URLComponents()
        components.scheme = request.scheme == .https ? "https" : "http"
        components.host = request.host
        components.port = request.port
        components.path = normalizedPath(request.path)
        return components.url ??
            URL(string: "\(components.scheme ?? "https")://\(request.host)/") ??
            URL(fileURLWithPath: "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        let pathWithoutFragment = path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let pathWithoutQuery = pathWithoutFragment
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? pathWithoutFragment
        if pathWithoutQuery.isEmpty {
            return "/"
        }
        return pathWithoutQuery.hasPrefix("/") ? pathWithoutQuery : "/\(pathWithoutQuery)"
    }

    private func byteCount(bodyData: Data?, bodySize: Int?) -> Int {
        bodySize ?? bodyData?.count ?? 0
    }
}
