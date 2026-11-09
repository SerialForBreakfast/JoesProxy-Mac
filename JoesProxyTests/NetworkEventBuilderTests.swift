import Foundation
import XCTest
@testable import JoesProxy

final class NetworkEventBuilderTests: XCTestCase {
    func testAPIJSONSessionBuildsQueryRedactedNetworkEvent() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let event = makeBuilder().build(
            session: makeSession(
                method: "POST",
                host: "api.example.com",
                path: "/v1/items?page=1#debug",
                requestBody: Data("{\"name\":\"item\"}".utf8),
                requestBodySize: nil,
                responseBody: Data("{\"ok\":true}".utf8),
                responseBodySize: 64,
                start: start,
                duration: 0.42
            ),
            activeAnnotations: ["Checkout"]
        )

        XCTAssertEqual(event.id, fixedEventID)
        XCTAssertEqual(event.phase, .completed)
        XCTAssertEqual(event.redactionLevel, .queryRedacted)
        XCTAssertEqual(event.url.absoluteString, "https://api.example.com/v1/items")
        XCTAssertEqual(event.method, "POST")
        XCTAssertEqual(event.statusCode, 200)
        XCTAssertEqual(event.timing.total, 0.42, accuracy: 0.0001)
        XCTAssertEqual(event.timing.ttfb, 0.42, accuracy: 0.0001)
        XCTAssertEqual(event.timing.transfer, 0)
        XCTAssertNil(event.timing.dns)
        XCTAssertNil(event.timing.tcp)
        XCTAssertNil(event.timing.tls)
        XCTAssertEqual(event.sizes.requestBytes, 15)
        XCTAssertEqual(event.sizes.responseBytes, 64)
        XCTAssertEqual(event.connectionInfo.httpProtocol, "HTTP/1.1")
        XCTAssertFalse(event.connectionInfo.isConnectionReused)
        XCTAssertEqual(event.annotations, ["Checkout"])
        XCTAssertEqual(event.lane, TimelineLane.api.rawValue)
    }

    func testManifestAndMediaSessionsUseTimelineLanes() {
        let manifest = makeBuilder().build(
            session: makeSession(path: "/master.m3u8", contentType: "application/vnd.apple.mpegurl")
        )
        let segment = makeBuilder().build(
            session: makeSession(path: "/segment-001.ts", contentType: "video/mp2t")
        )

        XCTAssertEqual(manifest.lane, TimelineLane.manifest.rawValue)
        XCTAssertEqual(segment.lane, TimelineLane.mediaSegments.rawValue)
    }

    func testCDNHeadersPopulateCacheStatusAndRegion() {
        let event = makeBuilder().build(
            session: makeSession(headers: [
                HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"),
                HTTPHeaderField(name: "CF-Ray", value: "89a3-IAD")
            ])
        )

        XCTAssertEqual(event.cacheStatus, .hit)
        XCTAssertEqual(event.connectionInfo.cdnRegion, "IAD")
    }

    func testFailedSessionMapsToFailedPhaseAndErrorLane() {
        let event = makeBuilder().build(
            session: makeSession(statusCode: 503, state: .failed)
        )

        XCTAssertEqual(event.phase, .failed)
        XCTAssertEqual(event.lane, TimelineLane.errorsRetries.rawValue)
    }

    func testPendingSessionMapsToStartedPhase() {
        let event = makeBuilder().build(
            session: makeSession(includeResponse: false, state: .pending, completedAt: nil)
        )

        XCTAssertEqual(event.phase, .started)
        XCTAssertNil(event.statusCode)
        XCTAssertEqual(event.timing.total, 0)
    }

    func testTunneledSessionUsesMetadataOnlyAndConnectProtocol() {
        let event = makeBuilder().build(
            session: makeSession(
                method: "CONNECT",
                inspectionKind: .tunneledTLS,
                host: "bag.itunes.apple.com",
                path: "bag.itunes.apple.com:443?token=secret#debug",
                includeResponse: false
            )
        )

        XCTAssertEqual(event.redactionLevel, .metadataOnly)
        XCTAssertEqual(event.connectionInfo.httpProtocol, "CONNECT")
        XCTAssertNil(event.statusCode)
        XCTAssertFalse(event.url.absoluteString.contains("token=secret"))
        XCTAssertFalse(event.url.absoluteString.contains("#debug"))
        XCTAssertNil(event.cacheStatus)
    }

    func testUnsupportedFieldsRemainNilAndNoRawHeadersOrBodiesAreCopied() {
        let event = makeBuilder().build(
            session: makeSession(
                requestHeaders: [HTTPHeaderField(name: "Authorization", value: "Bearer secret")],
                requestBody: Data("request-secret".utf8),
                headers: [HTTPHeaderField(name: "Set-Cookie", value: "secret=true")],
                responseBody: Data("response-secret".utf8)
            )
        )

        XCTAssertNil(event.sizes.compressedResponseBytes)
        XCTAssertNil(event.certificateExpiry)
        XCTAssertNil(event.sourceSDK)
        XCTAssertNil(event.connectionID)
        XCTAssertNil(event.parentEventID)
        XCTAssertEqual(event.redirectCount, 0)
        XCTAssertEqual(event.retryCount, 0)

        let mirror = String(describing: event)
        XCTAssertFalse(mirror.contains("Authorization"))
        XCTAssertFalse(mirror.contains("Set-Cookie"))
        XCTAssertFalse(mirror.contains("request-secret"))
        XCTAssertFalse(mirror.contains("response-secret"))
    }

    private let fixedEventID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!

    private func makeBuilder() -> NetworkEventBuilder {
        NetworkEventBuilder(eventIDProvider: { self.fixedEventID })
    }

    private func makeSession(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
        method: String = "GET",
        scheme: SessionScheme = .https,
        inspectionKind: SessionInspectionKind = .interceptedTLS,
        host: String = "www.example.com",
        port: Int? = 443,
        path: String = "/api/data.json",
        requestHeaders: [HTTPHeaderField] = [],
        requestBody: Data? = nil,
        requestBodySize: Int? = nil,
        statusCode: Int = 200,
        contentType: String = "application/json",
        headers: [HTTPHeaderField] = [],
        responseBody: Data? = nil,
        responseBodySize: Int? = nil,
        includeResponse: Bool = true,
        state: SessionLifecycleState = .completed,
        start: Date = Date(timeIntervalSinceReferenceDate: 100),
        duration: TimeInterval = 0.25,
        completedAt explicitCompletedAt: Date? = nil
    ) -> SessionRecord {
        let capturedResponse: CapturedResponse?
        if includeResponse {
            capturedResponse = CapturedResponse(
                statusCode: statusCode,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)] + headers,
                bodyData: responseBody,
                bodySize: responseBodySize ?? responseBody?.count ?? 128
            )
        } else {
            capturedResponse = nil
        }

        return SessionRecord(
            id: id,
            request: CapturedRequest(
                method: method,
                scheme: scheme,
                inspectionKind: inspectionKind,
                host: host,
                port: port,
                path: path,
                headers: requestHeaders,
                bodyData: requestBody,
                bodySize: requestBodySize
            ),
            response: capturedResponse,
            state: state,
            timing: SessionTiming(
                startedAt: start,
                completedAt: explicitCompletedAt ?? (state == .pending ? nil : start.addingTimeInterval(duration))
            )
        )
    }
}
