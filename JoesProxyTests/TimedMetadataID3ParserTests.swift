import XCTest
@testable import JoesProxy

final class TimedMetadataID3ParserTests: XCTestCase {
    private let parser = TimedMetadataID3Parser()

    func testDetectsTextFrameInsideTransportStreamPayload() throws {
        let assetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id3Tag = makeID3Tag(frames: [
            makeTextFrame(identifier: "TIT2", text: "Chapter 1")
        ])
        let data = makeTransportStreamData(payload: id3Tag)

        let result = parser.analyze(
            data: data,
            assetID: assetID,
            assetURL: URL(string: "https://cdn.example.com/segment-1.ts"),
            segmentSequence: 4,
            relativePlaybackTime: 12.5
        )

        XCTAssertEqual(result.assetID, assetID)
        XCTAssertEqual(result.containerType, .mpegTS)
        XCTAssertEqual(result.markers.count, 1)
        XCTAssertEqual(result.markers[0].segmentID, assetID)
        XCTAssertEqual(result.markers[0].segmentSequence, 4)
        XCTAssertEqual(result.markers[0].relativePlaybackTime, 12.5)
        XCTAssertEqual(result.markers[0].frameIdentifiers, ["TIT2"])
        XCTAssertEqual(result.markers[0].payloadSummary, "TIT2: Chapter 1")
        XCTAssertEqual(result.markers[0].payloadDecodeStatus, .payloadDecoded)
        XCTAssertFalse(result.markers[0].payloadRedacted)
        XCTAssertEqual(result.diagnostics.outcome, .success)
        XCTAssertEqual(result.diagnostics.counters["markers"], 1)
        XCTAssertTrue(result.diagnostics.completedStages.contains("id3_frame_parse"))
    }

    func testPrivateFrameIsDetectedAndMarkedRedacted() throws {
        let assetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let id3Tag = makeID3Tag(frames: [
            makePrivateFrame(owner: "com.example.marker", payload: Data([0x01, 0x02, 0x03]))
        ])

        let result = parser.analyze(
            data: makeTransportStreamData(payload: id3Tag),
            assetID: assetID,
            assetURL: nil
        )

        XCTAssertEqual(result.markers.count, 1)
        XCTAssertEqual(result.markers[0].frameIdentifiers, ["PRIV"])
        XCTAssertEqual(result.markers[0].payloadSummary, "PRIV owner: com.example.marker")
        XCTAssertEqual(result.markers[0].payloadDecodeStatus, .unknownPrivatePayload)
        XCTAssertTrue(result.markers[0].payloadRedacted)
    }

    func testRawElementaryStreamFallbackDetectsID3AtStart() throws {
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let id3Tag = makeID3Tag(frames: [
            makeTextFrame(identifier: "TXXX", text: "Interstitial")
        ])

        let result = parser.analyze(data: id3Tag, assetID: assetID, assetURL: nil)

        XCTAssertEqual(result.containerType, .elementaryStream)
        XCTAssertEqual(result.markers.map(\.frameIdentifiers), [["TXXX"]])
        XCTAssertTrue(result.analysisWarnings.contains { $0.contains("raw captured bytes") })
    }

    func testNoID3ReturnsEmptyMarkersWithWarning() throws {
        let result = parser.analyze(
            data: makeTransportStreamData(payload: Data(repeating: 0xAA, count: 32)),
            assetID: UUID(),
            assetURL: nil
        )

        XCTAssertEqual(result.containerType, .mpegTS)
        XCTAssertTrue(result.markers.isEmpty)
        XCTAssertTrue(result.analysisWarnings.contains { $0.contains("No ID3") })
        XCTAssertEqual(result.diagnostics.outcome, .noMetadata)
        XCTAssertEqual(result.diagnostics.counters["markers"], 0)
        XCTAssertFalse(result.diagnostics.logMessage.contains("https://"))
    }

    func testMalformedID3HeaderReportsPartialDiagnostics() throws {
        var malformedTag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        malformedTag.append(contentsOf: [0x80, 0x00, 0x00, 0x01])

        let result = parser.analyze(data: malformedTag, assetID: UUID(), assetURL: nil)

        XCTAssertEqual(result.markers.count, 1)
        XCTAssertEqual(result.markers[0].payloadDecodeStatus, .parseFailed)
        XCTAssertEqual(result.diagnostics.outcome, .partial)
        XCTAssertEqual(result.diagnostics.counters["parseFailures"], 1)
    }

    func testPATPMTMetadataPIDAndPESTimestampAreReported() throws {
        let id3Tag = makeID3Tag(frames: [
            makePrivateFrame(owner: "com.example.timing", payload: Data([0x01]))
        ])
        var pes = Data([0x00, 0x00, 0x01, 0xBD, 0x00, UInt8(id3Tag.count + 8), 0x84, 0x80, 0x05])
        pes.append(ptsBytes(90_000))
        pes.append(id3Tag)
        var transport = Data()
        transport.append(makePacket(pid: 0, payload: patPayload(pmtPID: 0x0100), payloadUnitStart: true))
        transport.append(makePacket(pid: 0x0100, payload: pmtPayload(metadataPID: 0x0102), payloadUnitStart: true))
        transport.append(makePacket(pid: 0x0102, payload: pes, payloadUnitStart: true))

        let result = parser.analyze(data: transport, assetID: UUID(), assetURL: nil)

        let marker = try XCTUnwrap(result.markers.first)
        XCTAssertEqual(marker.transportPID, 0x0102)
        XCTAssertEqual(marker.presentationTimestamp90k, 90_000)
        XCTAssertEqual(marker.id3MajorVersion, 3)
        XCTAssertEqual(marker.tagSize, id3Tag.count)
        XCTAssertEqual(marker.privateOwnerIdentifiers, ["com.example.timing"])
        XCTAssertTrue(result.analysisWarnings.contains { $0.contains("PAT/PMT") })
    }

    func testDetectsM2TSAndFECFraming() throws {
        let id3 = makeID3Tag(frames: [makeTextFrame(identifier: "TIT2", text: "Marker")])
        let transport = makeTransportStreamData(payload: id3)
        let packets = stride(from: 0, to: transport.count, by: 188).map {
            transport[$0..<min($0 + 188, transport.count)]
        }
        var m2ts = Data()
        var fec = Data()
        for packet in packets {
            m2ts.append(Data(repeating: 0, count: 4))
            m2ts.append(contentsOf: packet)
            fec.append(contentsOf: packet)
            fec.append(Data(repeating: 0, count: 16))
        }
        XCTAssertEqual(parser.analyze(data: m2ts, assetID: UUID(), assetURL: nil).markers.count, 1)
        XCTAssertEqual(parser.analyze(data: fec, assetID: UUID(), assetURL: nil).markers.count, 1)
    }

    private func makeID3Tag(frames: [Data]) -> Data {
        let frameData = frames.reduce(into: Data()) { $0.append($1) }
        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33]) // ID3
        data.append(contentsOf: [0x03, 0x00, 0x00]) // v2.3, no flags
        data.append(synchsafeBytes(frameData.count))
        data.append(frameData)
        return data
    }

    private func makeTextFrame(identifier: String, text: String) -> Data {
        var payload = Data([0x03]) // UTF-8
        payload.append(text.data(using: .utf8)!)
        return makeFrame(identifier: identifier, payload: payload)
    }

    private func makePrivateFrame(owner: String, payload: Data) -> Data {
        var framePayload = owner.data(using: .utf8)!
        framePayload.append(0)
        framePayload.append(payload)
        return makeFrame(identifier: "PRIV", payload: framePayload)
    }

    private func makeFrame(identifier: String, payload: Data) -> Data {
        var data = Data()
        data.append(identifier.data(using: .ascii)!)
        data.append(uint32Bytes(UInt32(payload.count)))
        data.append(contentsOf: [0x00, 0x00])
        data.append(payload)
        return data
    }

    private func makeTransportStreamData(payload: Data) -> Data {
        var data = Data()
        data.append(makePacket(pid: 0x0101, payload: payload))
        data.append(makePacket(pid: 0x0101, payload: Data(repeating: 0xFF, count: 20)))
        return data
    }

    private func makePacket(pid: Int, payload: Data, payloadUnitStart: Bool = false) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1F) | (payloadUnitStart ? 0x40 : 0)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10
        let copyCount = min(payload.count, 188 - 4)
        packet.replaceSubrange(4..<(4 + copyCount), with: payload.prefix(copyCount))
        return packet
    }

    private func patPayload(pmtPID: Int) -> Data {
        Data([
            0x00,
            0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)), UInt8(pmtPID & 0xFF),
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func pmtPayload(metadataPID: Int) -> Data {
        Data([
            0x00,
            0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x01, 0xF0, 0x00,
            0x15, UInt8(0xE0 | ((metadataPID >> 8) & 0x1F)), UInt8(metadataPID & 0xFF), 0xF0, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func ptsBytes(_ pts: UInt64) -> Data {
        Data([
            UInt8(0x20 | ((pts >> 29) & 0x0E) | 0x01),
            UInt8((pts >> 22) & 0xFF),
            UInt8(((pts >> 14) & 0xFE) | 0x01),
            UInt8((pts >> 7) & 0xFF),
            UInt8(((pts << 1) & 0xFE) | 0x01)
        ])
    }

    private func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func synchsafeBytes(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }
}
