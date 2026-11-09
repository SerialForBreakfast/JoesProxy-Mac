import XCTest
@testable import JoesProxy

final class MPEGTransportStreamVideoAnalyzerTests: XCTestCase {
    func testReportsH264FrameMixGOPIntervalsAndSeekTolerance() throws {
        let data = makeTransportStream(frameTypes: [.iFrame, .pFrame, .bFrame, .iFrame, .pFrame, .bFrame, .iFrame])

        let analysis = try XCTUnwrap(MPEGTransportStreamVideoAnalyzer().analyze(data: data))

        XCTAssertEqual(analysis.codec, .h264)
        XCTAssertEqual(analysis.videoPID, 0x0101)
        XCTAssertEqual(analysis.accessUnitCount, 7)
        XCTAssertEqual(analysis.iFrameCount, 3)
        XCTAssertEqual(analysis.pFrameCount, 2)
        XCTAssertEqual(analysis.bFrameCount, 2)
        XCTAssertEqual(analysis.unclassifiedFrameCount, 0)
        XCTAssertEqual(analysis.keyFrameCount, 3)
        XCTAssertEqual(try XCTUnwrap(analysis.observedFrameRate), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(analysis.presentationTimeSpan), 0.2, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.averageGOPFrameCount), 3, accuracy: 0.001)
        XCTAssertEqual(analysis.maximumGOPFrameCount, 3)
        XCTAssertEqual(try XCTUnwrap(analysis.averageKeyFrameInterval), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.maximumKeyFrameInterval), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(analysis.suggestedSeekTolerance), 0.05, accuracy: 0.000_001)
        XCTAssertFalse(analysis.isInspectionLimited)
    }

    func testDoesNotSuggestToleranceFromSingleKeyFrame() throws {
        let data = makeTransportStream(frameTypes: [.iFrame, .pFrame, .bFrame])

        let analysis = try XCTUnwrap(MPEGTransportStreamVideoAnalyzer().analyze(data: data))

        XCTAssertEqual(analysis.keyFrameCount, 1)
        XCTAssertNil(analysis.averageGOPFrameCount)
        XCTAssertNil(analysis.averageKeyFrameInterval)
        XCTAssertNil(analysis.suggestedSeekTolerance)
    }

    func testDiagnosticsIdentifyInvalidTransportStream() {
        let result = MPEGTransportStreamVideoAnalyzer().analyzeWithDiagnostics(
            data: Data(repeating: 0, count: 188 * 3)
        )

        XCTAssertNil(result.analysis)
        XCTAssertEqual(result.diagnostics.outcome, .invalidContainer)
        XCTAssertEqual(result.diagnostics.counters["transportPackets"], 3)
        XCTAssertEqual(result.diagnostics.completedStages, ["input_bounded"])
    }

    func testDiagnosticsIdentifyTransportWithoutSupportedVideoStream() {
        var data = Data()
        data.append(makePacket(pid: 0, payloadUnitStart: true, payload: psiPayload(makePATSection())))
        data.append(makePacket(pid: 0x0100, payloadUnitStart: true, payload: psiPayload(makeAudioOnlyPMTSection())))
        data.append(makePacket(pid: 0x0102, payloadUnitStart: true, payload: Data(repeating: 0, count: 20)))

        let result = MPEGTransportStreamVideoAnalyzer().analyzeWithDiagnostics(data: data)

        XCTAssertNil(result.analysis)
        XCTAssertEqual(result.diagnostics.outcome, .unsupportedStream)
        XCTAssertEqual(result.diagnostics.counters["elementaryStreams"], 1)
        XCTAssertTrue(result.diagnostics.completedStages.contains("program_map_scan"))
    }

    private enum TestFrameType {
        case iFrame
        case pFrame
        case bFrame
    }

    private func makeTransportStream(frameTypes: [TestFrameType]) -> Data {
        var data = Data()
        data.append(makePacket(pid: 0, payloadUnitStart: true, payload: psiPayload(makePATSection())))
        data.append(makePacket(pid: 0x0100, payloadUnitStart: true, payload: psiPayload(makePMTSection())))

        for (index, frameType) in frameTypes.enumerated() {
            let pts = UInt64(index * 3_000)
            data.append(makePacket(
                pid: 0x0101,
                payloadUnitStart: true,
                payload: makePES(frameType: frameType, presentationTimestamp: pts)
            ))
        }
        return data
    }

    private func makePacket(pid: Int, payloadUnitStart: Bool, payload: Data) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((payloadUnitStart ? 0x40 : 0) | ((pid >> 8) & 0x1F))
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10
        let copyCount = min(payload.count, 184)
        packet.replaceSubrange(4..<(4 + copyCount), with: payload.prefix(copyCount))
        return packet
    }

    private func psiPayload(_ section: Data) -> Data {
        var payload = Data([0])
        payload.append(section)
        return payload
    }

    private func makePATSection() -> Data {
        Data([
            0x00, 0xB0, 0x0D,
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, 0xE1, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func makePMTSection() -> Data {
        Data([
            0x02, 0xB0, 0x12,
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x01, 0xF0, 0x00,
            0x1B, 0xE1, 0x01, 0xF0, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func makeAudioOnlyPMTSection() -> Data {
        Data([
            0x02, 0xB0, 0x12,
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x02, 0xF0, 0x00,
            0x0F, 0xE1, 0x02, 0xF0, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func makePES(frameType: TestFrameType, presentationTimestamp: UInt64) -> Data {
        var data = Data([0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05])
        data.append(contentsOf: encodedPTS(presentationTimestamp))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        switch frameType {
        case .iFrame:
            data.append(contentsOf: [0x65, 0xB8])
        case .pFrame:
            data.append(contentsOf: [0x41, 0xC0])
        case .bFrame:
            data.append(contentsOf: [0x41, 0xA8])
        }
        return data
    }

    private func encodedPTS(_ value: UInt64) -> [UInt8] {
        [
            UInt8(0x21 | ((value >> 29) & 0x0E)),
            UInt8((value >> 22) & 0xFF),
            UInt8(0x01 | ((value >> 14) & 0xFE)),
            UInt8((value >> 7) & 0xFF),
            UInt8(0x01 | ((value << 1) & 0xFE))
        ]
    }
}
