import Foundation
import XCTest
@testable import JoesProxy

final class SDKEventSchemaTests: XCTestCase {
    func testHandshakeFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<PairingHandshake> = try decodeFixture("handshake-v1")

        XCTAssertEqual(envelope.type, .handshake)
        XCTAssertEqual(envelope.version, SDKSchema.version)
        XCTAssertEqual(envelope.payload.schemaVersion, SDKSchema.version)
        XCTAssertEqual(envelope.payload.supportedSchemaVersions, [SDKSchema.version])
        XCTAssertEqual(envelope.payload.bundleID, "com.example.StreamingApp")

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-v1")
    }

    func testHandshakeAckFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<HandshakeAck> = try decodeFixture("handshake-ack-v1")

        XCTAssertEqual(envelope.type, .handshakeAck)
        XCTAssertTrue(envelope.payload.accepted)
        XCTAssertNil(envelope.payload.rejectReason)
        XCTAssertEqual(envelope.payload.selectedSchemaVersion, SDKSchema.version)
        XCTAssertEqual(envelope.payload.clockOffsetMs, 42)
        XCTAssertEqual(envelope.payload.serverAppVersion, "1.0.0")
        XCTAssertEqual(envelope.payload.minimumSupportedSchemaVersion, SDKSchema.version)
        XCTAssertEqual(envelope.payload.latestSupportedSchemaVersion, SDKSchema.version)

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-ack-v1")
    }

    func testUnsupportedSchemaHandshakeAckMapsRejectReason() throws {
        let envelope: SDKMessageEnvelope<HandshakeAck> = try decodeFixture("handshake-ack-unsupported-schema-v1")

        XCTAssertFalse(envelope.payload.accepted)
        XCTAssertEqual(envelope.payload.rejectReason, .schemaVersionUnsupported)
        XCTAssertNil(envelope.payload.selectedSchemaVersion)
        XCTAssertEqual(envelope.payload.compatibilityResolution, .updateSDK)
        XCTAssertEqual(envelope.payload.serverAppVersion, "1.0.0")
        XCTAssertTrue(try XCTUnwrap(envelope.payload.compatibilityMessage).contains("Update the JoesProxySDK package"))

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-ack-unsupported-schema-v1")
    }

    func testCompletedNetworkEventFixtureDecodesAndPreservesV1Placeholders() throws {
        let envelope: SDKMessageEnvelope<NetworkEvent> = try decodeFixture("network-event-completed-v1")
        let event = envelope.payload

        XCTAssertEqual(envelope.type, .networkEvent)
        XCTAssertEqual(event.phase, .completed)
        XCTAssertEqual(event.redactionLevel, .queryRedacted)
        XCTAssertEqual(event.method, "GET")
        XCTAssertEqual(event.statusCode, 200)
        XCTAssertEqual(event.cacheStatus, .hit)
        XCTAssertEqual(event.connectionInfo.cdnRegion, "IAD")
        XCTAssertEqual(event.timing.total, 0.361, accuracy: 0.0001)
        XCTAssertNil(event.timing.dns)
        XCTAssertNil(event.timing.tcp)
        XCTAssertNil(event.timing.tls)
        XCTAssertNil(event.sizes.compressedResponseBytes)
        XCTAssertNil(event.certificateExpiry)
        XCTAssertNil(event.sourceSDK)
        XCTAssertNil(event.connectionID)
        XCTAssertNil(event.parentEventID)

        try assertSemanticRoundTrip(envelope, fixtureName: "network-event-completed-v1")
    }

    func testMetadataOnlyNetworkEventFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<NetworkEvent> = try decodeFixture("network-event-metadata-only-v1")
        let event = envelope.payload

        XCTAssertEqual(event.phase, .completed)
        XCTAssertEqual(event.redactionLevel, .metadataOnly)
        XCTAssertEqual(event.method, "CONNECT")
        XCTAssertNil(event.statusCode)
        XCTAssertEqual(event.sizes.requestBytes, 0)
        XCTAssertEqual(event.sizes.responseBytes, 0)

        try assertSemanticRoundTrip(envelope, fixtureName: "network-event-metadata-only-v1")
    }

    func testAnnotationFixturesDecodeAndRoundTrip() throws {
        let instant: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-instant-v1")
        XCTAssertEqual(instant.type, .annotationEvent)
        XCTAssertEqual(instant.payload.lifecycle, .instant)
        XCTAssertNil(instant.payload.scopeID)
        XCTAssertEqual(instant.payload.metadata["contentID"], "ep-42")
        try assertSemanticRoundTrip(instant, fixtureName: "annotation-instant-v1")

        let begin: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-window-begin-v1")
        XCTAssertEqual(begin.payload.lifecycle, .begin)
        XCTAssertNotNil(begin.payload.scopeID)
        try assertSemanticRoundTrip(begin, fixtureName: "annotation-window-begin-v1")

        let end: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-window-end-v1")
        XCTAssertEqual(end.payload.lifecycle, .end)
        XCTAssertEqual(end.payload.scopeID, begin.payload.scopeID)
        try assertSemanticRoundTrip(end, fixtureName: "annotation-window-end-v1")
    }

    func testHeaderDecodesUnknownMessageTypeWithoutThrowing() throws {
        let header: SDKMessageHeader = try decodeFixture("unsupported-message-v1")

        XCTAssertEqual(header.type, "futureEvent")
        XCTAssertEqual(header.version, 99)
        XCTAssertNil(SDKMessageType(rawValue: header.type))
    }

    func testKnownEnvelopeWithMalformedPayloadThrows() throws {
        let malformed = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000999",
              "payload": {
                "sessionID": "00000000-0000-0000-0000-000000000401"
              },
              "sentAt": "2026-06-28T17:00:01.300Z",
              "type": "networkEvent",
              "version": 1
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try SDKEventJSONCodec.makeDecoder().decode(SDKMessageEnvelope<NetworkEvent>.self, from: malformed)
        )
    }

    func testDateCodecPreservesFractionalSeconds() throws {
        let envelope: SDKMessageEnvelope<PairingHandshake> = try decodeFixture("handshake-v1")
        XCTAssertEqual(envelope.sentAt, envelope.payload.deviceTimestamp)

        let encoded = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        let encodedString = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(encodedString.contains("2026-06-28T17:00:00.125Z"))
    }

    private func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL(name))
        return try SDKEventJSONCodec.makeDecoder().decode(T.self, from: data)
    }

    private func assertSemanticRoundTrip<T: Codable & Equatable & Sendable>(
        _ value: SDKMessageEnvelope<T>,
        fixtureName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try SDKEventJSONCodec.makeEncoder().encode(value)
        let decoded = try SDKEventJSONCodec.makeDecoder().decode(SDKMessageEnvelope<T>.self, from: encoded)
        XCTAssertEqual(decoded, value, file: file, line: line)

        let fixtureObject = try JSONObject(data: try Data(contentsOf: fixtureURL(fixtureName)))
        let encodedObject = try JSONObject(data: encoded)
        XCTAssertEqual(encodedObject, fixtureObject, file: file, line: line)
    }

    private func JSONObject(data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data, options: []) as? NSObject ?? NSObject()
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("SDKEventSchema")
            .appendingPathComponent(name)
            .appendingPathExtension("json")
    }
}
