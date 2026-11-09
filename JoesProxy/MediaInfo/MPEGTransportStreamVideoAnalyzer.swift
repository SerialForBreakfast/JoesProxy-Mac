//
//  MPEGTransportStreamVideoAnalyzer.swift
//  JoesProxy
//
//  Performs bounded, capture-only GOP analysis for MPEG-TS video segments.
//

import Foundation

struct MPEGTransportStreamVideoAnalysis: Equatable, Sendable {
    enum Codec: String, Equatable, Sendable {
        case h264 = "H.264 / AVC"
        case h265 = "H.265 / HEVC"
    }

    let codec: Codec
    let videoPID: Int
    let bytesInspected: Int
    let accessUnitCount: Int
    let iFrameCount: Int
    let pFrameCount: Int
    let bFrameCount: Int
    let unclassifiedFrameCount: Int
    let keyFrameCount: Int
    let observedFrameRate: Double?
    let presentationTimeSpan: TimeInterval?
    let averageGOPFrameCount: Double?
    let maximumGOPFrameCount: Int?
    let averageKeyFrameInterval: TimeInterval?
    let maximumKeyFrameInterval: TimeInterval?
    let suggestedSeekTolerance: TimeInterval?
    let isInspectionLimited: Bool
}

struct MPEGTransportStreamVideoAnalysisResult: Equatable, Sendable {
    let analysis: MPEGTransportStreamVideoAnalysis?
    let diagnostics: MediaParserDiagnostics
}

struct MPEGTransportStreamVideoAnalyzer: Sendable {
    private enum FrameType: Equatable {
        case iFrame
        case pFrame
        case bFrame
        case unknown
    }

    private struct ElementaryStream {
        let type: UInt8
        let pid: Int
    }

    private struct AccessUnit {
        let frameType: FrameType
        let isKeyFrame: Bool
        let presentationTimestamp: UInt64?
    }

    private struct PendingPES {
        var presentationTimestamp: UInt64?
        var elementaryBytes: [UInt8]
    }

    private let maximumBytesToInspect: Int

    init(maximumBytesToInspect: Int = 1024 * 1024) {
        self.maximumBytesToInspect = maximumBytesToInspect
    }

    func analyze(data: Data) -> MPEGTransportStreamVideoAnalysis? {
        analyzeWithDiagnostics(data: data).analysis
    }

    func analyzeWithDiagnostics(data: Data) -> MPEGTransportStreamVideoAnalysisResult {
        analyzeWithDiagnostics(data: data, shouldCancel: { false })
    }

    func analyzeWithDiagnostics(
        data: Data,
        shouldCancel: () -> Bool
    ) -> MPEGTransportStreamVideoAnalysisResult {
        let inspectedCount = min(data.count, maximumBytesToInspect)
        let bytes = [UInt8](data.prefix(inspectedCount))
        let packetCount = bytes.count / 188
        guard bytes.count >= 188 * 3, hasTransportSync(bytes) else {
            return result(
                analysis: nil,
                outcome: .invalidContainer,
                dataCount: data.count,
                inspectedCount: inspectedCount,
                stages: ["input_bounded"],
                counters: ["transportPackets": packetCount],
                warnings: ["Three aligned MPEG-TS sync packets were not found at the start of the captured bytes."]
            )
        }

        let streams = elementaryStreams(in: bytes, shouldCancel: shouldCancel)
        if shouldCancel() {
            return result(
                analysis: nil,
                outcome: .partial,
                dataCount: data.count,
                inspectedCount: inspectedCount,
                stages: ["input_bounded", "cancelled"],
                counters: ["transportPackets": packetCount],
                warnings: ["GOP analysis was cancelled."]
            )
        }
        guard let videoStream = streams.first(where: { $0.type == 0x1B || $0.type == 0x24 }) else {
            return result(
                analysis: nil,
                outcome: .unsupportedStream,
                dataCount: data.count,
                inspectedCount: inspectedCount,
                stages: ["input_bounded", "transport_sync", "program_map_scan"],
                counters: [
                    "elementaryStreams": streams.count,
                    "transportPackets": packetCount
                ],
                warnings: ["No H.264 or HEVC elementary stream was advertised by the inspected program map."]
            )
        }

        let codec: MPEGTransportStreamVideoAnalysis.Codec = videoStream.type == 0x1B ? .h264 : .h265
        let accessUnits = accessUnits(
            in: bytes,
            videoPID: videoStream.pid,
            codec: codec,
            shouldCancel: shouldCancel
        )
        guard !accessUnits.isEmpty else {
            return result(
                analysis: nil,
                outcome: .noAccessUnits,
                dataCount: data.count,
                inspectedCount: inspectedCount,
                stages: ["input_bounded", "transport_sync", "program_map_scan", "video_pid_selected", "pes_scan"],
                counters: [
                    "elementaryStreams": streams.count,
                    "transportPackets": packetCount,
                    "videoPID": videoStream.pid
                ],
                warnings: ["The selected video PID did not yield classifiable Annex-B video access units."]
            )
        }

        let keyFrameIndices = accessUnits.indices.filter { accessUnits[$0].isKeyFrame }
        let gopFrameCounts = zip(keyFrameIndices, keyFrameIndices.dropFirst()).map { $1 - $0 }
        let keyFrameTimestamps = keyFrameIndices.compactMap { accessUnits[$0].presentationTimestamp }
        let keyFrameIntervals = zip(keyFrameTimestamps, keyFrameTimestamps.dropFirst()).compactMap(Self.interval)
        let maximumInterval = keyFrameIntervals.max()
        let presentationTimestamps = accessUnits.compactMap(\.presentationTimestamp)
        let presentationTimeSpan = Self.presentationTimeSpan(presentationTimestamps)
        let observedFrameRate: Double? = presentationTimeSpan.flatMap { span -> Double? in
            guard span > 0, presentationTimestamps.count > 1 else { return nil }
            return Double(presentationTimestamps.count - 1) / span
        }

        let analysis = MPEGTransportStreamVideoAnalysis(
            codec: codec,
            videoPID: videoStream.pid,
            bytesInspected: inspectedCount,
            accessUnitCount: accessUnits.count,
            iFrameCount: accessUnits.count(where: { $0.frameType == .iFrame }),
            pFrameCount: accessUnits.count(where: { $0.frameType == .pFrame }),
            bFrameCount: accessUnits.count(where: { $0.frameType == .bFrame }),
            unclassifiedFrameCount: accessUnits.count(where: { $0.frameType == .unknown }),
            keyFrameCount: keyFrameIndices.count,
            observedFrameRate: observedFrameRate,
            presentationTimeSpan: presentationTimeSpan,
            averageGOPFrameCount: Self.average(gopFrameCounts),
            maximumGOPFrameCount: gopFrameCounts.max(),
            averageKeyFrameInterval: Self.average(keyFrameIntervals),
            maximumKeyFrameInterval: maximumInterval,
            suggestedSeekTolerance: maximumInterval.map { $0 / 2 },
            isInspectionLimited: data.count > inspectedCount
        )
        var warnings: [String] = []
        if analysis.isInspectionLimited {
            warnings.append("Analysis reached the configured byte inspection limit.")
        }
        if analysis.unclassifiedFrameCount > 0 {
            warnings.append("Some access units could not be classified as I, P, or B frames.")
        }
        return result(
            analysis: analysis,
            outcome: warnings.isEmpty ? .success : .partial,
            dataCount: data.count,
            inspectedCount: inspectedCount,
            stages: ["input_bounded", "transport_sync", "program_map_scan", "video_pid_selected", "pes_scan", "nal_classification"],
            counters: [
                "accessUnits": analysis.accessUnitCount,
                "bFrames": analysis.bFrameCount,
                "elementaryStreams": streams.count,
                "iFrames": analysis.iFrameCount,
                "keyframes": analysis.keyFrameCount,
                "pFrames": analysis.pFrameCount,
                "transportPackets": packetCount,
                "unclassifiedFrames": analysis.unclassifiedFrameCount,
                "videoPID": analysis.videoPID
            ],
            warnings: warnings
        )
    }

    private func result(
        analysis: MPEGTransportStreamVideoAnalysis?,
        outcome: MediaParserDiagnosticOutcome,
        dataCount: Int,
        inspectedCount: Int,
        stages: [String],
        counters: [String: Int],
        warnings: [String]
    ) -> MPEGTransportStreamVideoAnalysisResult {
        MPEGTransportStreamVideoAnalysisResult(
            analysis: analysis,
            diagnostics: MediaParserDiagnostics(
                parser: "gop",
                outcome: outcome,
                bytesAvailable: dataCount,
                bytesInspected: inspectedCount,
                completedStages: stages,
                counters: counters,
                warnings: warnings
            )
        )
    }

    private func hasTransportSync(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47
    }

    private func elementaryStreams(in bytes: [UInt8], shouldCancel: () -> Bool) -> [ElementaryStream] {
        var pmtPIDs = Set<Int>()
        var streams: [ElementaryStream] = []

        for packetOffset in stride(from: 0, through: bytes.count - 188, by: 188) {
            if shouldCancel() { break }
            guard bytes[packetOffset] == 0x47,
                  let payload = payloadBytes(bytes, packetOffset: packetOffset) else { continue }
            let pid = packetPID(bytes, packetOffset: packetOffset)
            let payloadUnitStart = bytes[packetOffset + 1] & 0x40 != 0

            if pid == 0, payloadUnitStart, let section = psiSection(payload), section.first == 0x00 {
                pmtPIDs.formUnion(parsePAT(section))
            } else if pmtPIDs.contains(pid), payloadUnitStart,
                      let section = psiSection(payload), section.first == 0x02 {
                streams.append(contentsOf: parsePMT(section))
            }
        }

        var seenPIDs = Set<Int>()
        return streams.filter { seenPIDs.insert($0.pid).inserted }
    }

    private func accessUnits(
        in bytes: [UInt8],
        videoPID: Int,
        codec: MPEGTransportStreamVideoAnalysis.Codec,
        shouldCancel: () -> Bool
    ) -> [AccessUnit] {
        var results: [AccessUnit] = []
        var pending: PendingPES?

        func finishPending() {
            guard let current = pending,
                  let classification = classify(elementaryBytes: current.elementaryBytes, codec: codec) else {
                pending = nil
                return
            }
            results.append(AccessUnit(
                frameType: classification.frameType,
                isKeyFrame: classification.isKeyFrame,
                presentationTimestamp: current.presentationTimestamp
            ))
            pending = nil
        }

        for packetOffset in stride(from: 0, through: bytes.count - 188, by: 188) {
            if shouldCancel() { break }
            guard bytes[packetOffset] == 0x47,
                  packetPID(bytes, packetOffset: packetOffset) == videoPID,
                  let payload = payloadBytes(bytes, packetOffset: packetOffset) else { continue }

            let payloadUnitStart = bytes[packetOffset + 1] & 0x40 != 0
            if payloadUnitStart {
                finishPending()
                guard let parsed = parsePES(payload) else { continue }
                pending = PendingPES(
                    presentationTimestamp: parsed.presentationTimestamp,
                    elementaryBytes: parsed.elementaryBytes
                )
            } else if pending != nil {
                pending?.elementaryBytes.append(contentsOf: payload)
            }
        }
        finishPending()
        return results
    }

    private func classify(
        elementaryBytes: [UInt8],
        codec: MPEGTransportStreamVideoAnalysis.Codec
    ) -> (frameType: FrameType, isKeyFrame: Bool)? {
        for nalUnit in annexBNALUnits(elementaryBytes) {
            guard let nalHeader = nalUnit.first else { continue }
            switch codec {
            case .h264:
                let nalType = nalHeader & 0x1F
                guard (1...5).contains(nalType) else { continue }
                if nalType == 5 {
                    return (.iFrame, true)
                }
                return (h264SliceType(nalUnit), false)

            case .h265:
                let nalType = (nalHeader >> 1) & 0x3F
                guard nalType <= 31 else { continue }
                if (16...21).contains(nalType) {
                    return (.iFrame, true)
                }
                return (.unknown, false)
            }
        }
        return nil
    }

    private func h264SliceType(_ nalUnit: ArraySlice<UInt8>) -> FrameType {
        guard nalUnit.count > 1 else { return .unknown }
        let escapedPayload = Array(nalUnit.dropFirst())
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(escapedPayload.count)
        var zeroCount = 0
        for byte in escapedPayload {
            if zeroCount >= 2, byte == 0x03 {
                zeroCount = 0
                continue
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }

        var reader = ExpGolombReader(bytes: rbsp)
        guard reader.readUnsigned() != nil,
              let rawSliceType = reader.readUnsigned() else { return .unknown }
        switch rawSliceType % 5 {
        case 0: return .pFrame
        case 1: return .bFrame
        case 2: return .iFrame
        default: return .unknown
        }
    }

    private func annexBNALUnits(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(offset: Int, prefixLength: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else if index + 4 <= bytes.count,
                      bytes[index] == 0, bytes[index + 1] == 0,
                      bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else {
                index += 1
            }
        }

        return starts.indices.compactMap { startIndex in
            let payloadStart = starts[startIndex].offset + starts[startIndex].prefixLength
            let payloadEnd = startIndex + 1 < starts.count ? starts[startIndex + 1].offset : bytes.count
            guard payloadStart < payloadEnd else { return nil }
            return bytes[payloadStart..<payloadEnd]
        }
    }

    private func parsePES(_ payload: [UInt8]) -> (presentationTimestamp: UInt64?, elementaryBytes: [UInt8])? {
        guard payload.count >= 9,
              payload[0] == 0, payload[1] == 0, payload[2] == 1 else { return nil }
        let headerLength = Int(payload[8])
        let elementaryStart = 9 + headerLength
        guard elementaryStart <= payload.count else { return nil }
        let hasPTS = payload[7] & 0x80 != 0
        let pts = hasPTS && payload.count >= 14 ? parsePTS(Array(payload[9..<14])) : nil
        return (pts, Array(payload[elementaryStart...]))
    }

    private func parsePTS(_ bytes: [UInt8]) -> UInt64? {
        guard bytes.count == 5 else { return nil }
        return (UInt64((bytes[0] >> 1) & 0x07) << 30)
            | (UInt64(bytes[1]) << 22)
            | (UInt64((bytes[2] >> 1) & 0x7F) << 15)
            | (UInt64(bytes[3]) << 7)
            | UInt64((bytes[4] >> 1) & 0x7F)
    }

    private func payloadBytes(_ bytes: [UInt8], packetOffset: Int) -> [UInt8]? {
        let adaptationControl = (bytes[packetOffset + 3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else { return nil }
        var payloadStart = packetOffset + 4
        if adaptationControl == 3 {
            payloadStart += 1 + Int(bytes[payloadStart])
        }
        guard payloadStart < packetOffset + 188 else { return nil }
        return Array(bytes[payloadStart..<(packetOffset + 188)])
    }

    private func packetPID(_ bytes: [UInt8], packetOffset: Int) -> Int {
        (Int(bytes[packetOffset + 1] & 0x1F) << 8) | Int(bytes[packetOffset + 2])
    }

    private func psiSection(_ payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty else { return nil }
        let sectionStart = 1 + Int(payload[0])
        guard sectionStart + 3 <= payload.count else { return nil }
        let sectionLength = Int(payload[sectionStart + 1] & 0x0F) << 8 | Int(payload[sectionStart + 2])
        let sectionEnd = min(payload.count, sectionStart + 3 + sectionLength)
        return Array(payload[sectionStart..<sectionEnd])
    }

    private func parsePAT(_ section: [UInt8]) -> [Int] {
        guard section.count >= 12 else { return [] }
        var pids: [Int] = []
        var cursor = 8
        let end = section.count - 4
        while cursor + 4 <= end {
            let program = Int(section[cursor]) << 8 | Int(section[cursor + 1])
            if program != 0 {
                pids.append(Int(section[cursor + 2] & 0x1F) << 8 | Int(section[cursor + 3]))
            }
            cursor += 4
        }
        return pids
    }

    private func parsePMT(_ section: [UInt8]) -> [ElementaryStream] {
        guard section.count >= 16 else { return [] }
        let programInfoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var cursor = 12 + programInfoLength
        let end = section.count - 4
        var streams: [ElementaryStream] = []
        while cursor + 5 <= end {
            let type = section[cursor]
            let pid = Int(section[cursor + 1] & 0x1F) << 8 | Int(section[cursor + 2])
            let infoLength = Int(section[cursor + 3] & 0x0F) << 8 | Int(section[cursor + 4])
            streams.append(ElementaryStream(type: type, pid: pid))
            cursor += 5 + infoLength
        }
        return streams
    }

    private static func interval(_ pair: (UInt64, UInt64)) -> TimeInterval? {
        let wrap = UInt64(1) << 33
        let delta = pair.1 >= pair.0 ? pair.1 - pair.0 : wrap - pair.0 + pair.1
        guard delta > 0 else { return nil }
        return TimeInterval(delta) / 90_000
    }

    private static func average<T: BinaryInteger>(_ values: [T]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + Double($1) } / Double(values.count)
    }

    private static func average(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func presentationTimeSpan(_ timestamps: [UInt64]) -> TimeInterval? {
        guard let minimum = timestamps.min(), let maximum = timestamps.max(), maximum > minimum else {
            return nil
        }
        return TimeInterval(maximum - minimum) / 90_000
    }
}

private struct ExpGolombReader {
    let bytes: [UInt8]
    var bitOffset = 0

    mutating func readUnsigned() -> UInt? {
        var leadingZeroCount = 0
        while let bit = readBit(), bit == 0 {
            leadingZeroCount += 1
            guard leadingZeroCount < UInt.bitWidth else { return nil }
        }
        guard leadingZeroCount > 0 else { return 0 }

        var suffix: UInt = 0
        for _ in 0..<leadingZeroCount {
            guard let bit = readBit() else { return nil }
            suffix = (suffix << 1) | UInt(bit)
        }
        return (UInt(1) << UInt(leadingZeroCount)) - 1 + suffix
    }

    private mutating func readBit() -> UInt8? {
        guard bitOffset < bytes.count * 8 else { return nil }
        let byte = bytes[bitOffset / 8]
        let shift = 7 - (bitOffset % 8)
        bitOffset += 1
        return (byte >> shift) & 1
    }
}
