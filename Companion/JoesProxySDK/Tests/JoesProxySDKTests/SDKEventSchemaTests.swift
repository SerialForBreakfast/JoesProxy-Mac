import Foundation
import Testing
@testable import JoesProxySDK

@Suite("SDK Event Schema")
struct SDKEventSchemaTests {
    @Test func handshakeFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<PairingHandshake> = try decodeFixture("handshake-v1")

        #expect(envelope.type == .handshake)
        #expect(envelope.version == SDKSchema.version)
        #expect(envelope.payload.schemaVersion == SDKSchema.version)
        #expect(envelope.payload.supportedSchemaVersions == [SDKSchema.version])
        #expect(envelope.payload.bundleID == "com.example.StreamingApp")

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-v1")
    }

    @Test func handshakeAckFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<HandshakeAck> = try decodeFixture("handshake-ack-v1")

        #expect(envelope.type == .handshakeAck)
        #expect(envelope.payload.accepted)
        #expect(envelope.payload.rejectReason == nil)
        #expect(envelope.payload.selectedSchemaVersion == SDKSchema.version)
        #expect(envelope.payload.clockOffsetMs == 42)
        #expect(envelope.payload.serverAppVersion == "1.0.0")
        #expect(envelope.payload.minimumSupportedSchemaVersion == SDKSchema.version)
        #expect(envelope.payload.latestSupportedSchemaVersion == SDKSchema.version)

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-ack-v1")
    }

    @Test func unsupportedSchemaHandshakeAckMapsRejectReason() throws {
        let envelope: SDKMessageEnvelope<HandshakeAck> = try decodeFixture("handshake-ack-unsupported-schema-v1")

        #expect(!envelope.payload.accepted)
        #expect(envelope.payload.rejectReason == .schemaVersionUnsupported)
        #expect(envelope.payload.selectedSchemaVersion == nil)
        #expect(envelope.payload.compatibilityResolution == .updateSDK)
        #expect(envelope.payload.serverAppVersion == "1.0.0")
        #expect(envelope.payload.compatibilityMessage?.contains("Update the JoesProxySDK package") == true)

        try assertSemanticRoundTrip(envelope, fixtureName: "handshake-ack-unsupported-schema-v1")
    }

    @Test func completedNetworkEventFixtureDecodesAndPreservesV1Placeholders() throws {
        let envelope: SDKMessageEnvelope<NetworkEvent> = try decodeFixture("network-event-completed-v1")
        let event = envelope.payload

        #expect(envelope.type == .networkEvent)
        #expect(event.phase == .completed)
        #expect(event.redactionLevel == .queryRedacted)
        #expect(event.method == "GET")
        #expect(event.statusCode == 200)
        #expect(event.cacheStatus == .hit)
        #expect(event.connectionInfo.cdnRegion == "IAD")
        #expect(abs(event.timing.total - 0.361) < 0.0001)
        #expect(event.timing.dns == nil)
        #expect(event.timing.tcp == nil)
        #expect(event.timing.tls == nil)
        #expect(event.sizes.compressedResponseBytes == nil)
        #expect(event.certificateExpiry == nil)
        #expect(event.sourceSDK == nil)
        #expect(event.connectionID == nil)
        #expect(event.parentEventID == nil)

        try assertSemanticRoundTrip(envelope, fixtureName: "network-event-completed-v1")
    }

    @Test func metadataOnlyNetworkEventFixtureDecodesAndRoundTrips() throws {
        let envelope: SDKMessageEnvelope<NetworkEvent> = try decodeFixture("network-event-metadata-only-v1")
        let event = envelope.payload

        #expect(event.phase == .completed)
        #expect(event.redactionLevel == .metadataOnly)
        #expect(event.method == "CONNECT")
        #expect(event.statusCode == nil)
        #expect(event.sizes.requestBytes == 0)
        #expect(event.sizes.responseBytes == 0)

        try assertSemanticRoundTrip(envelope, fixtureName: "network-event-metadata-only-v1")
    }

    @Test func annotationFixturesDecodeAndRoundTrip() throws {
        let instant: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-instant-v1")
        #expect(instant.type == .annotationEvent)
        #expect(instant.payload.lifecycle == .instant)
        #expect(instant.payload.scopeID == nil)
        #expect(instant.payload.metadata["contentID"] == "ep-42")
        try assertSemanticRoundTrip(instant, fixtureName: "annotation-instant-v1")

        let begin: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-window-begin-v1")
        #expect(begin.payload.lifecycle == .begin)
        #expect(begin.payload.scopeID != nil)
        try assertSemanticRoundTrip(begin, fixtureName: "annotation-window-begin-v1")

        let end: SDKMessageEnvelope<AnnotationEvent> = try decodeFixture("annotation-window-end-v1")
        #expect(end.payload.lifecycle == .end)
        #expect(end.payload.scopeID == begin.payload.scopeID)
        try assertSemanticRoundTrip(end, fixtureName: "annotation-window-end-v1")
    }

    @Test func headerDecodesUnknownMessageTypeWithoutThrowing() throws {
        let header: SDKMessageHeader = try decodeFixture("unsupported-message-v1")

        #expect(header.type == "futureEvent")
        #expect(header.version == 99)
        #expect(SDKMessageType(rawValue: header.type) == nil)
    }

    @Test func knownEnvelopeWithMalformedPayloadThrows() {
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

        #expect(throws: DecodingError.self) {
            try SDKEventJSONCodec.makeDecoder().decode(SDKMessageEnvelope<NetworkEvent>.self, from: malformed)
        }
    }

    @Test func dateCodecPreservesFractionalSeconds() throws {
        let envelope: SDKMessageEnvelope<PairingHandshake> = try decodeFixture("handshake-v1")
        #expect(envelope.sentAt == envelope.payload.deviceTimestamp)

        let encoded = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        #expect(encodedString.contains("2026-06-28T17:00:00.125Z"))
    }

    private func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL(name))
        return try SDKEventJSONCodec.makeDecoder().decode(T.self, from: data)
    }

    private func assertSemanticRoundTrip<T: Codable & Equatable & Sendable>(
        _ value: SDKMessageEnvelope<T>,
        fixtureName: String
    ) throws {
        let encoded = try SDKEventJSONCodec.makeEncoder().encode(value)
        let decoded = try SDKEventJSONCodec.makeDecoder().decode(SDKMessageEnvelope<T>.self, from: encoded)
        #expect(decoded == value)

        let fixtureObject = try JSONObject(data: try Data(contentsOf: fixtureURL(fixtureName)))
        let encodedObject = try JSONObject(data: encoded)
        #expect(encodedObject == fixtureObject)
    }

    private func JSONObject(data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data, options: []) as? NSObject ?? NSObject()
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SDKEventSchema")!
    }
}
