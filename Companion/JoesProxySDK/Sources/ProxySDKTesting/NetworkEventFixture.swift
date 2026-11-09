import Foundation
import JoesProxySDK

/// Builds synthetic `NetworkEvent` values for use in tests without a live proxy.
public struct NetworkEventFixture {
    public static func make(
        url: URL = URL(string: "https://api.example.com/v1/users")!,
        method: String = "GET",
        statusCode: Int? = 200,
        phase: NetworkEventPhase = .completed,
        lane: String = "api",
        cacheStatus: CDNCacheStatus? = nil,
        retryCount: Int = 0,
        httpProtocol: String = "HTTP/2",
        ttfb: Double = 0.1,
        total: Double = 0.25,
        sourceSDK: String? = nil,
        annotations: [String] = [],
        timestamp: Date = Date()
    ) -> NetworkEvent {
        NetworkEvent(
            id: UUID(),
            sessionID: UUID(),
            phase: phase,
            timestamp: timestamp,
            url: url,
            redactionLevel: .queryRedacted,
            method: method,
            statusCode: statusCode,
            timing: NetworkTiming(
                dns: nil,
                tcp: nil,
                tls: nil,
                ttfb: ttfb,
                transfer: total - ttfb,
                total: total
            ),
            sizes: NetworkSizes(requestBytes: 0, responseBytes: 0, compressedResponseBytes: nil),
            connectionInfo: ConnectionInfo(
                httpProtocol: httpProtocol,
                isConnectionReused: false,
                cdnRegion: nil
            ),
            redirectCount: 0,
            retryCount: retryCount,
            cacheStatus: cacheStatus,
            certificateExpiry: nil,
            annotations: annotations,
            sourceSDK: sourceSDK,
            lane: lane,
            connectionID: nil,
            parentEventID: nil
        )
    }
}
