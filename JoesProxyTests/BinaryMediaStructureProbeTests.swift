import XCTest
@testable import JoesProxy

final class BinaryMediaStructureProbeTests: XCTestCase {
    private let probe = BinaryMediaStructureProbe()

    func testDetectsTransportStreamFromSyncPackets() throws {
        let data = makeTransportStreamData()

        let structure = try XCTUnwrap(probe.inspect(data: data))

        XCTAssertEqual(structure.kind, .mpegTransportStream)
        XCTAssertEqual(structure.role, .transportSegment)
        XCTAssertEqual(structure.tsPacketSize, 188)
        XCTAssertEqual(structure.tsSyncPacketCount, 2)
        XCTAssertEqual(structure.tsProgramNumbers, [1])
        XCTAssertEqual(structure.tsStreamTypeCodes, [0x1B, 0x86])
        XCTAssertTrue(structure.scte35PIDPresent)
        XCTAssertTrue(structure.notes.contains(where: { $0.contains("PAT PID 0") }))
    }

    func testDetectsFragmentedBMFFAndPSSH() throws {
        let data = makeBMFFData(boxes: [
            ("ftyp", payload(8)),
            ("styp", payload(4)),
            ("sidx", payload(8)),
            ("emsg", makeVersion0EMSGPayload()),
            ("pssh", payload(12)),
            ("moof", payload(16)),
            ("mdat", payload(24))
        ])

        let structure = try XCTUnwrap(probe.inspect(data: data))

        XCTAssertEqual(structure.kind, .isoBMFF)
        XCTAssertEqual(structure.role, .mediaFragment)
        XCTAssertTrue(structure.likelyFragmented)
        XCTAssertTrue(structure.likelyEncrypted)
        XCTAssertTrue(structure.segmentIndexPresent)
        XCTAssertTrue(structure.eventMessagePresent)
        XCTAssertEqual(structure.eventMessages.count, 1)
        XCTAssertEqual(structure.eventMessages.first?.schemeIDURI, "urn:test:event")
        XCTAssertEqual(structure.eventMessages.first?.value, "ad-start")
        XCTAssertEqual(structure.eventMessages.first?.timescale, 1_000)
        XCTAssertEqual(structure.eventMessages.first?.eventDuration, 5_000)
        XCTAssertEqual(structure.eventMessages.first?.eventID, 7)
        XCTAssertEqual(structure.psshCount, 1)
        XCTAssertEqual(structure.topLevelBoxes.map(\.type), ["ftyp", "styp", "sidx", "emsg", "pssh", "moof", "mdat"])
    }

    func testDetectsInitializationAssetFromMoovOnlyStructure() throws {
        let data = makeBMFFData(boxes: [
            ("ftyp", payload(8)),
            ("moov", payload(24))
        ])

        let structure = try XCTUnwrap(probe.inspect(data: data))

        XCTAssertEqual(structure.kind, .isoBMFF)
        XCTAssertEqual(structure.role, .initializationAsset)
        XCTAssertFalse(structure.likelyFragmented)
    }

    func testReturnsNilForUnknownBinaryPayload() {
        let structure = probe.inspect(data: Data(repeating: 0xAA, count: 512))

        XCTAssertNil(structure)
    }

    func testDetectsNestedEmsgInsideMoof() throws {
        let nestedEmsgPayload = makeVersion0EMSGPayload()
        let moofPayload = makeBMFFData(boxes: [("emsg", nestedEmsgPayload)])
        let data = makeBMFFData(boxes: [
            ("ftyp", payload(8)),
            ("styp", payload(4)),
            ("moof", moofPayload),
            ("mdat", payload(16))
        ])

        let structure = try XCTUnwrap(probe.inspect(data: data))

        XCTAssertEqual(structure.eventMessages.count, 1)
        XCTAssertEqual(structure.eventMessages.first?.schemeIDURI, "urn:test:event")
    }

    func testParsesVersion1EmsgAndReportsEmbeddedID3FramesWithoutPayload() throws {
        let data = makeBMFFData(boxes: [
            ("ftyp", payload(8)),
            ("emsg", makeVersion1EMSGPayload())
        ])

        let event = try XCTUnwrap(probe.inspect(data: data)?.eventMessages.first)

        XCTAssertEqual(event.version, 1)
        XCTAssertEqual(event.schemeIDURI, "https://aomedia.org/emsg/ID3")
        XCTAssertEqual(event.timescale, 90_000)
        XCTAssertEqual(event.presentationTime, 180_000)
        XCTAssertEqual(event.eventDuration, 45_000)
        XCTAssertEqual(event.eventID, 42)
        XCTAssertEqual(event.embeddedID3FrameIdentifiers, ["TXXX"])
        XCTAssertGreaterThan(event.messageDataSize, 10)
    }

    private func makeTransportStreamData() -> Data {
        var data = Data()
        data.append(makePacket(pid: 0x0000, payloadUnitStart: true, payload: makePATSection()))
        data.append(makePacket(pid: 0x0100, payloadUnitStart: true, payload: makePMTSection()))
        data.append(makePacket(pid: 0x0101, payloadUnitStart: false, payload: Data(repeating: 0xAA, count: 20)))
        data.append(makePacket(pid: 0x0102, payloadUnitStart: false, payload: Data(repeating: 0xBB, count: 20)))
        return data
    }

    private func makeBMFFData(boxes: [(String, Data)]) -> Data {
        var data = Data()
        for (type, payload) in boxes {
            let size = UInt32(payload.count + 8)
            data.append(contentsOf: [
                UInt8((size >> 24) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8(size & 0xFF)
            ])
            data.append(type.data(using: .ascii)!)
            data.append(payload)
        }
        return data
    }

    private func payload(_ count: Int) -> Data {
        Data(repeating: 0, count: count)
    }

    private func makePacket(pid: Int, payloadUnitStart: Bool, payload: Data) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8(((payloadUnitStart ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)))
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10
        packet[4] = 0x00 // pointer field
        let copyCount = min(payload.count, 188 - 5)
        packet.replaceSubrange(5..<(5 + copyCount), with: payload.prefix(copyCount))
        return packet
    }

    private func makePATSection() -> Data {
        Data([
            0x00,
            0xB0, 0x0D,
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            0x00, 0x01,
            0xE1, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func makePMTSection() -> Data {
        Data([
            0x02,
            0xB0, 0x17,
            0x00, 0x01,
            0xC1,
            0x00,
            0x00,
            0xE1, 0x01,
            0xF0, 0x00,
            0x1B, 0xE1, 0x01, 0xF0, 0x00,
            0x86, 0xE1, 0x02, 0xF0, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func makeVersion0EMSGPayload() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
        data.append("urn:test:event".data(using: .utf8)!)
        data.append(0)
        data.append("ad-start".data(using: .utf8)!)
        data.append(0)
        data.append(uint32Bytes(1_000))
        data.append(uint32Bytes(0))
        data.append(uint32Bytes(5_000))
        data.append(uint32Bytes(7))
        return data
    }

    private func makeVersion1EMSGPayload() -> Data {
        var data = Data([0x01, 0x00, 0x00, 0x00])
        data.append(uint32Bytes(90_000))
        data.append(uint64Bytes(180_000))
        data.append(uint32Bytes(45_000))
        data.append(uint32Bytes(42))
        data.append("https://aomedia.org/emsg/ID3".data(using: .utf8)!)
        data.append(0)
        data.append("timed-metadata".data(using: .utf8)!)
        data.append(0)
        data.append(contentsOf: [
            0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0B,
            0x54, 0x58, 0x58, 0x58, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
        ])
        return data
    }

    private func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func uint64Bytes(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}
