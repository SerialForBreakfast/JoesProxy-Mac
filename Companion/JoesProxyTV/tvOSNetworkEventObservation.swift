import Foundation

/// How deeply JoesProxy captured a proxied request, as exposed by the SDK `NetworkEvent` payload.
enum TVOSCaptureDepth: Equatable, Sendable {
    case inspected
    case tunneled
    case unknown
}

/// Lightweight view of a `networkEvent` message received from the Mac SDK event server.
struct TVOSObservedNetworkEvent: Equatable, Sendable {
    let host: String
    let path: String
    let method: String
    let captureDepth: TVOSCaptureDepth
}

/// Parses and classifies SDK `networkEvent` envelopes for tvOS setup verification.
enum TVOSNetworkEventObservation {
    /// Decodes a v1 SDK envelope JSON blob into an observed network event.
    static func parseEnvelopeJSON(_ data: Data) -> TVOSObservedNetworkEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "networkEvent",
              let payload = json["payload"] as? [String: Any],
              let urlString = payload["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host else {
            return nil
        }

        let method = payload["method"] as? String ?? ""
        let redactionLevel = payload["redactionLevel"] as? String ?? ""
        let connectionInfo = payload["connectionInfo"] as? [String: Any]
        let httpProtocol = connectionInfo?["httpProtocol"] as? String ?? ""

        let captureDepth: TVOSCaptureDepth
        if redactionLevel == "metadataOnly" || httpProtocol == "CONNECT" || method == "CONNECT" {
            captureDepth = .tunneled
        } else if redactionLevel == "queryRedacted" {
            captureDepth = .inspected
        } else {
            captureDepth = .unknown
        }

        return TVOSObservedNetworkEvent(
            host: host,
            path: url.path.isEmpty ? "/" : url.path,
            method: method,
            captureDepth: captureDepth
        )
    }

    /// Returns the best verification outcome when a matching verification request appears in the stream.
    static func verificationResult(from events: [TVOSObservedNetworkEvent]) -> TVOSTrafficVerificationResult? {
        guard let event = events.last(where: isVerificationTraffic) else {
            return nil
        }

        switch event.captureDepth {
        case .inspected:
            return .trafficInspected(host: event.host)
        case .tunneled:
            return .trafficTunneled(host: event.host)
        case .unknown:
            return .trafficObserved(host: event.host)
        }
    }

    private static func isVerificationTraffic(_ event: TVOSObservedNetworkEvent) -> Bool {
        if event.host == "captive.apple.com" {
            return true
        }
        return event.path.localizedCaseInsensitiveContains("hotspot-detect")
    }
}
