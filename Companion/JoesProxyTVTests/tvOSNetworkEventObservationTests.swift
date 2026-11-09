import XCTest
@testable import JoesProxyTV

final class TVOSNetworkEventObservationTests: XCTestCase {
    func testParsesInspectedNetworkEventFixture() throws {
        let data = try verificationFixtureData(
            url: "http://captive.apple.com/hotspot-detect.html",
            method: "GET",
            redactionLevel: "queryRedacted",
            httpProtocol: "HTTP/1.1"
        )

        let event = try XCTUnwrap(TVOSNetworkEventObservation.parseEnvelopeJSON(data))

        XCTAssertEqual(event.host, "captive.apple.com")
        XCTAssertEqual(event.captureDepth, .inspected)
    }

    func testParsesTunneledNetworkEventFixture() throws {
        let data = try verificationFixtureData(
            url: "https://secure.example.com/",
            method: "CONNECT",
            redactionLevel: "metadataOnly",
            httpProtocol: "CONNECT"
        )

        let event = try XCTUnwrap(TVOSNetworkEventObservation.parseEnvelopeJSON(data))

        XCTAssertEqual(event.captureDepth, .tunneled)
    }

    func testClassifiesVerificationTrafficAsInspected() throws {
        let data = try verificationFixtureData(
            url: "http://captive.apple.com/hotspot-detect.html",
            method: "GET",
            redactionLevel: "queryRedacted",
            httpProtocol: "HTTP/1.1"
        )
        let event = try XCTUnwrap(TVOSNetworkEventObservation.parseEnvelopeJSON(data))

        XCTAssertEqual(
            TVOSNetworkEventObservation.verificationResult(from: [event]),
            .trafficInspected(host: "captive.apple.com")
        )
    }

    private func verificationFixtureData(
        url: String,
        method: String,
        redactionLevel: String,
        httpProtocol: String
    ) throws -> Data {
        let envelope: [String: Any] = [
            "type": "networkEvent",
            "version": 1,
            "id": "00000000-0000-0000-0000-000000000201",
            "sentAt": "2026-06-28T17:00:01.300Z",
            "payload": [
                "id": "00000000-0000-0000-0000-000000000301",
                "sessionID": "00000000-0000-0000-0000-000000000401",
                "phase": "completed",
                "timestamp": "2026-06-28T17:00:01.250Z",
                "url": url,
                "redactionLevel": redactionLevel,
                "method": method,
                "statusCode": 200,
                "timing": [
                    "dns": NSNull(),
                    "tcp": NSNull(),
                    "tls": NSNull(),
                    "ttfb": 0.1,
                    "transfer": 0.0,
                    "total": 0.1
                ],
                "sizes": [
                    "requestBytes": 0,
                    "responseBytes": 128,
                    "compressedResponseBytes": NSNull()
                ],
                "connectionInfo": [
                    "httpProtocol": httpProtocol,
                    "isConnectionReused": false,
                    "cdnRegion": NSNull()
                ],
                "redirectCount": 0,
                "retryCount": 0,
                "cacheStatus": NSNull(),
                "certificateExpiry": NSNull(),
                "annotations": [] as [String],
                "sourceSDK": NSNull(),
                "lane": "api",
                "connectionID": NSNull(),
                "parentEventID": NSNull()
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}
