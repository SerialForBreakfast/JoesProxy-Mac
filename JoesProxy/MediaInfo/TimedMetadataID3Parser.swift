//
//  TimedMetadataID3Parser.swift
//  JoesProxy
//
//  Capture-driven ID3 timed metadata inspection for Media Info.
//

import Foundation

/// Container family used for captured timed-metadata inspection.
enum TimedMetadataContainerType: String, Sendable, Equatable {
    case mpegTS = "MPEG-TS"
    case elementaryStream = "Elementary Stream"
    case unknown = "Unknown"
}

/// Source for a timed-metadata analysis result.
enum TimedMetadataAnalysisSource: String, Sendable, Equatable {
    case proxySegmentParser = "Proxy segment parser"
}

/// How far the parser got when decoding an ID3 marker.
enum TimedMetadataDecodeStatus: String, Sendable, Equatable {
    case detectedOnly = "Detected only"
    case frameHeadersParsed = "Frame headers parsed"
    case payloadPartiallyDecoded = "Payload partially decoded"
    case payloadDecoded = "Payload decoded"
    case unknownPrivatePayload = "Unknown private payload"
    case parseFailed = "Parse failed"
}

/// Parsed ID3 marker facts from one captured asset.
struct TimedMetadataMarker: Identifiable, Sendable, Equatable {
    let id: UUID
    let segmentID: UUID?
    let segmentSequence: Int?
    let relativePlaybackTime: TimeInterval?
    let segmentRelativeTime: TimeInterval?
    let byteOffset: Int?
    let transportPID: Int?
    let presentationTimestamp90k: UInt64?
    let id3MajorVersion: Int?
    let tagSize: Int?
    let frameIdentifiers: [String]
    let privateOwnerIdentifiers: [String]
    let payloadSummary: String?
    let payloadRedacted: Bool
    let payloadDecodeStatus: TimedMetadataDecodeStatus

    init(
        id: UUID = UUID(),
        segmentID: UUID?,
        segmentSequence: Int?,
        relativePlaybackTime: TimeInterval?,
        segmentRelativeTime: TimeInterval?,
        byteOffset: Int?,
        transportPID: Int? = nil,
        presentationTimestamp90k: UInt64? = nil,
        id3MajorVersion: Int? = nil,
        tagSize: Int? = nil,
        frameIdentifiers: [String],
        privateOwnerIdentifiers: [String] = [],
        payloadSummary: String?,
        payloadRedacted: Bool,
        payloadDecodeStatus: TimedMetadataDecodeStatus
    ) {
        self.id = id
        self.segmentID = segmentID
        self.segmentSequence = segmentSequence
        self.relativePlaybackTime = relativePlaybackTime
        self.segmentRelativeTime = segmentRelativeTime
        self.byteOffset = byteOffset
        self.transportPID = transportPID
        self.presentationTimestamp90k = presentationTimestamp90k
        self.id3MajorVersion = id3MajorVersion
        self.tagSize = tagSize
        self.frameIdentifiers = frameIdentifiers
        self.privateOwnerIdentifiers = privateOwnerIdentifiers
        self.payloadSummary = payloadSummary
        self.payloadRedacted = payloadRedacted
        self.payloadDecodeStatus = payloadDecodeStatus
    }
}

/// Analysis result for one captured media asset.
struct TimedMetadataDetectionResult: Sendable, Equatable, Identifiable {
    let id: UUID
    let assetID: UUID
    let assetURL: URL?
    let containerType: TimedMetadataContainerType
    let markers: [TimedMetadataMarker]
    let analysisWarnings: [String]
    let analysisSource: TimedMetadataAnalysisSource
    let diagnostics: MediaParserDiagnostics

    init(
        id: UUID = UUID(),
        assetID: UUID,
        assetURL: URL?,
        containerType: TimedMetadataContainerType,
        markers: [TimedMetadataMarker],
        analysisWarnings: [String],
        analysisSource: TimedMetadataAnalysisSource,
        diagnostics: MediaParserDiagnostics
    ) {
        self.id = id
        self.assetID = assetID
        self.assetURL = assetURL
        self.containerType = containerType
        self.markers = markers
        self.analysisWarnings = analysisWarnings
        self.analysisSource = analysisSource
        self.diagnostics = diagnostics
    }
}

/// TS-first ID3 parser for captured media assets.
///
/// Concurrency: this type is immutable and `Sendable`; callers should run batch inspection off the main actor
/// because long HLS flows can include many segment bodies.
struct TimedMetadataID3Parser: Sendable {
    private struct MarkerContext {
        let transportPID: Int
        let presentationTimestamp90k: UInt64?
    }

    private struct TransportLayout {
        let packetSize: Int
        let firstSyncOffset: Int
    }

    private let maximumBytesToInspect: Int

    init(maximumBytesToInspect: Int = 512 * 1024) {
        self.maximumBytesToInspect = maximumBytesToInspect
    }

    func analyze(
        data: Data,
        assetID: UUID,
        assetURL: URL?,
        segmentSequence: Int? = nil,
        relativePlaybackTime: TimeInterval? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> TimedMetadataDetectionResult {
        let limitedData = data.prefix(maximumBytesToInspect)
        var warnings: [String] = []
        if data.count > maximumBytesToInspect {
            warnings.append("Analysis stopped at the first \(maximumBytesToInspect) bytes.")
        }

        let extracted = extractID3SearchBytes(from: limitedData, shouldCancel: shouldCancel)
        warnings.append(contentsOf: extracted.warnings)

        let markers = parseMarkers(
            bytes: extracted.bytes,
            originalOffsets: extracted.originalOffsets,
            markerContexts: extracted.markerContexts,
            assetID: assetID,
            segmentSequence: segmentSequence,
            relativePlaybackTime: relativePlaybackTime,
            shouldCancel: shouldCancel
        )

        if markers.isEmpty {
            warnings.append("No ID3 tag headers were detected in the inspected bytes.")
        }

        let failedMarkerCount = markers.count { $0.payloadDecodeStatus == .parseFailed }
        let outcome: MediaParserDiagnosticOutcome
        if markers.isEmpty {
            outcome = .noMetadata
        } else if failedMarkerCount > 0 {
            outcome = .partial
        } else {
            outcome = .success
        }
        var completedStages = ["input_bounded"]
        completedStages.append(extracted.containerType == .mpegTS ? "transport_payload_extracted" : "raw_payload_scan")
        completedStages.append("id3_header_scan")
        if !markers.isEmpty {
            completedStages.append("id3_frame_parse")
        }
        let diagnostics = MediaParserDiagnostics(
            parser: "id3",
            outcome: outcome,
            bytesAvailable: data.count,
            bytesInspected: limitedData.count,
            completedStages: completedStages,
            counters: [
                "frameHeaders": markers.reduce(0) { $0 + $1.frameIdentifiers.count },
                "markers": markers.count,
                "parseFailures": failedMarkerCount
            ],
            warnings: warnings
        )

        return TimedMetadataDetectionResult(
            assetID: assetID,
            assetURL: assetURL,
            containerType: extracted.containerType,
            markers: markers,
            analysisWarnings: warnings,
            analysisSource: .proxySegmentParser,
            diagnostics: diagnostics
        )
    }

    private func extractID3SearchBytes(
        from data: Data.SubSequence,
        shouldCancel: () -> Bool
    ) -> (
        bytes: [UInt8],
        originalOffsets: [Int],
        markerContexts: [Int: MarkerContext],
        containerType: TimedMetadataContainerType,
        warnings: [String]
    ) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return ([], [], [:], .unknown, [])
        }

        if let payload = transportStreamPayload(bytes, shouldCancel: shouldCancel) {
            return (
                payload.bytes,
                payload.originalOffsets,
                payload.markerContexts,
                .mpegTS,
                payload.warnings
            )
        }

        return (
            bytes,
            Array(bytes.indices),
            [:],
            bytes.starts(with: Array("ID3".utf8)) ? .elementaryStream : .unknown,
            ["No MPEG-TS packet structure was detected; ID3 scan used raw captured bytes."]
        )
    }

    private func transportStreamPayload(
        _ bytes: [UInt8],
        shouldCancel: () -> Bool
    ) -> (bytes: [UInt8], originalOffsets: [Int], markerContexts: [Int: MarkerContext], warnings: [String])? {
        guard let layout = transportLayout(in: bytes) else { return nil }

        var pmtPIDs = Set<Int>()
        var metadataPIDs = Set<Int>()
        forEachPacket(in: bytes, layout: layout) { packetOffset, syncOffset, payloadStart, payloadUnitStart in
            if shouldCancel() { return false }
            let pid = ((Int(bytes[syncOffset + 1] & 0x1F)) << 8) | Int(bytes[syncOffset + 2])
            if pid == 0, let payloadStart, payloadUnitStart {
                pmtPIDs.formUnion(parsePAT(bytes, payloadStart: payloadStart, packetEnd: packetOffset + layout.packetSize))
            } else if pmtPIDs.contains(pid), let payloadStart, payloadUnitStart {
                metadataPIDs.formUnion(parseMetadataPIDs(bytes, payloadStart: payloadStart, packetEnd: packetOffset + layout.packetSize))
            }
            return true
        }

        var payloadBytes: [UInt8] = []
        var originalOffsets: [Int] = []
        var markerContexts: [Int: MarkerContext] = [:]
        let targeted = !metadataPIDs.isEmpty
        forEachPacket(in: bytes, layout: layout) { packetOffset, syncOffset, rawPayloadStart, payloadUnitStart in
            if shouldCancel() { return false }
            guard var payloadStart = rawPayloadStart else { return true }
            let pid = ((Int(bytes[syncOffset + 1] & 0x1F)) << 8) | Int(bytes[syncOffset + 2])
            guard !targeted || metadataPIDs.contains(pid) else { return true }

            var pts: UInt64?
            if targeted, payloadUnitStart,
               payloadStart + 9 <= packetOffset + layout.packetSize,
               bytes[payloadStart] == 0, bytes[payloadStart + 1] == 0, bytes[payloadStart + 2] == 1 {
                if bytes[payloadStart + 7] & 0x80 != 0 {
                    pts = decodePTS(bytes, at: payloadStart + 9)
                }
                payloadStart += 9 + Int(bytes[payloadStart + 8])
                if payloadStart < packetOffset + layout.packetSize {
                    markerContexts[payloadBytes.count] = MarkerContext(
                        transportPID: pid,
                        presentationTimestamp90k: pts
                    )
                }
            }

            guard payloadStart < packetOffset + layout.packetSize else { return true }
            for offset in payloadStart..<(packetOffset + layout.packetSize) {
                payloadBytes.append(bytes[offset])
                originalOffsets.append(offset)
            }
            return true
        }

        guard !payloadBytes.isEmpty else { return nil }
        var warnings = ["Detected sync-aligned \(layout.packetSize)-byte MPEG-TS packets."]
        if targeted {
            warnings.append("PAT/PMT identified timed-metadata PID(s): \(metadataPIDs.sorted().map(String.init).joined(separator: ", ")).")
        } else {
            warnings.append("No PMT metadata PID was resolved; validated raw ID3 magic scanning was used across transport payloads.")
        }
        return (payloadBytes, originalOffsets, markerContexts, warnings)
    }

    private func transportLayout(in bytes: [UInt8]) -> TransportLayout? {
        for packetSize in [188, 192, 204] {
            for syncOffset in 0..<min(packetSize, 16) where syncOffset + packetSize < bytes.count {
                let packetCount = min(4, (bytes.count - syncOffset) / packetSize)
                guard packetCount >= 2 else { continue }
                if (0..<packetCount).allSatisfy({ bytes[syncOffset + $0 * packetSize] == 0x47 }) {
                    return TransportLayout(packetSize: packetSize, firstSyncOffset: syncOffset)
                }
            }
        }
        return nil
    }

    private func forEachPacket(
        in bytes: [UInt8],
        layout: TransportLayout,
        body: (_ packetOffset: Int, _ syncOffset: Int, _ payloadStart: Int?, _ payloadUnitStart: Bool) -> Bool
    ) {
        var syncOffset = layout.firstSyncOffset
        while syncOffset + 4 <= bytes.count {
            guard bytes[syncOffset] == 0x47 else { break }
            let packetOffset = syncOffset - layout.firstSyncOffset
            let packetEnd = min(bytes.count, packetOffset + layout.packetSize)
            let payloadUnitStart = bytes[syncOffset + 1] & 0x40 != 0
            let adaptationFieldControl = (bytes[syncOffset + 3] >> 4) & 0x03
            var payloadStart: Int?
            if adaptationFieldControl == 0x01 || adaptationFieldControl == 0x03 {
                var candidate = syncOffset + 4
                if adaptationFieldControl == 0x03, candidate < packetEnd {
                    candidate += 1 + Int(bytes[candidate])
                }
                if candidate < packetEnd { payloadStart = candidate }
            }
            guard body(packetOffset, syncOffset, payloadStart, payloadUnitStart) else { break }
            syncOffset += layout.packetSize
        }
    }

    private func parsePAT(_ bytes: [UInt8], payloadStart: Int, packetEnd: Int) -> Set<Int> {
        guard payloadStart < packetEnd else { return [] }
        let sectionStart = payloadStart + 1 + Int(bytes[payloadStart])
        guard sectionStart + 8 <= packetEnd, bytes[sectionStart] == 0x00 else { return [] }
        let sectionLength = (Int(bytes[sectionStart + 1] & 0x0F) << 8) | Int(bytes[sectionStart + 2])
        let entriesEnd = min(packetEnd, sectionStart + 3 + sectionLength - 4)
        guard entriesEnd >= sectionStart + 8 else { return [] }
        var pids = Set<Int>()
        var cursor = sectionStart + 8
        while cursor + 4 <= entriesEnd {
            let program = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            if program != 0 {
                pids.insert((Int(bytes[cursor + 2] & 0x1F) << 8) | Int(bytes[cursor + 3]))
            }
            cursor += 4
        }
        return pids
    }

    private func parseMetadataPIDs(_ bytes: [UInt8], payloadStart: Int, packetEnd: Int) -> Set<Int> {
        guard payloadStart < packetEnd else { return [] }
        let sectionStart = payloadStart + 1 + Int(bytes[payloadStart])
        guard sectionStart + 12 <= packetEnd, bytes[sectionStart] == 0x02 else { return [] }
        let sectionLength = (Int(bytes[sectionStart + 1] & 0x0F) << 8) | Int(bytes[sectionStart + 2])
        let sectionEnd = min(packetEnd, sectionStart + 3 + sectionLength - 4)
        let programInfoLength = (Int(bytes[sectionStart + 10] & 0x0F) << 8) | Int(bytes[sectionStart + 11])
        var cursor = sectionStart + 12 + programInfoLength
        var pids = Set<Int>()
        while cursor + 5 <= sectionEnd {
            let streamType = bytes[cursor]
            let pid = (Int(bytes[cursor + 1] & 0x1F) << 8) | Int(bytes[cursor + 2])
            let infoLength = (Int(bytes[cursor + 3] & 0x0F) << 8) | Int(bytes[cursor + 4])
            if streamType == 0x15 { pids.insert(pid) }
            cursor += 5 + infoLength
        }
        return pids
    }

    private func decodePTS(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset + 5 <= bytes.count else { return nil }
        return (UInt64((bytes[offset] >> 1) & 0x07) << 30)
            | (UInt64(bytes[offset + 1]) << 22)
            | (UInt64(bytes[offset + 2] >> 1) << 15)
            | (UInt64(bytes[offset + 3]) << 7)
            | UInt64(bytes[offset + 4] >> 1)
    }

    private func parseMarkers(
        bytes: [UInt8],
        originalOffsets: [Int],
        markerContexts: [Int: MarkerContext],
        assetID: UUID,
        segmentSequence: Int?,
        relativePlaybackTime: TimeInterval?,
        shouldCancel: () -> Bool
    ) -> [TimedMetadataMarker] {
        var markers: [TimedMetadataMarker] = []
        var offset = 0

        while offset + 10 <= bytes.count {
            if shouldCancel() { break }
            guard bytes[offset] == 0x49, bytes[offset + 1] == 0x44, bytes[offset + 2] == 0x33 else {
                offset += 1
                continue
            }

            guard let tagSize = synchsafeInteger(bytes, at: offset + 6, length: 4),
                  tagSize > 0,
                  offset + 10 + tagSize <= bytes.count else {
                markers.append(parseFailedMarker(
                    originalOffset: originalOffsets[safe: offset],
                    assetID: assetID,
                    segmentSequence: segmentSequence,
                    relativePlaybackTime: relativePlaybackTime
                ))
                offset += 3
                continue
            }

            let version = bytes[offset + 3]
            let frames = parseFrames(
                bytes: bytes,
                start: offset + 10,
                end: offset + 10 + tagSize,
                majorVersion: version
            )
            let summary = payloadSummary(for: frames)
            let context = markerContexts[offset]
            markers.append(TimedMetadataMarker(
                segmentID: assetID,
                segmentSequence: segmentSequence,
                relativePlaybackTime: relativePlaybackTime,
                segmentRelativeTime: nil,
                byteOffset: originalOffsets[safe: offset],
                transportPID: context?.transportPID,
                presentationTimestamp90k: context?.presentationTimestamp90k,
                id3MajorVersion: Int(version),
                tagSize: tagSize + 10,
                frameIdentifiers: frames.map(\.identifier),
                privateOwnerIdentifiers: privateOwnerIdentifiers(in: frames),
                payloadSummary: summary.text,
                payloadRedacted: summary.redacted,
                payloadDecodeStatus: summary.status
            ))
            offset += 10 + tagSize
        }

        return markers
    }

    private func parseFailedMarker(
        originalOffset: Int?,
        assetID: UUID,
        segmentSequence: Int?,
        relativePlaybackTime: TimeInterval?
    ) -> TimedMetadataMarker {
        TimedMetadataMarker(
            segmentID: assetID,
            segmentSequence: segmentSequence,
            relativePlaybackTime: relativePlaybackTime,
            segmentRelativeTime: nil,
            byteOffset: originalOffset,
            frameIdentifiers: [],
            payloadSummary: nil,
            payloadRedacted: false,
            payloadDecodeStatus: .parseFailed
        )
    }

    private struct ID3Frame {
        let identifier: String
        let payload: [UInt8]
    }

    private func parseFrames(bytes: [UInt8], start: Int, end: Int, majorVersion: UInt8) -> [ID3Frame] {
        var frames: [ID3Frame] = []
        var cursor = start

        while cursor + 10 <= end {
            let identifierBytes = Array(bytes[cursor..<(cursor + 4)])
            guard identifierBytes.contains(where: { $0 != 0 }),
                  let identifier = String(bytes: identifierBytes, encoding: .ascii),
                  identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                break
            }

            let size: Int?
            if majorVersion == 4 {
                size = synchsafeInteger(bytes, at: cursor + 4, length: 4)
            } else {
                size = bigEndianInteger(bytes, at: cursor + 4, length: 4)
            }

            guard let frameSize = size,
                  frameSize >= 0,
                  cursor + 10 + frameSize <= end else {
                break
            }

            let payload = Array(bytes[(cursor + 10)..<(cursor + 10 + frameSize)])
            frames.append(ID3Frame(identifier: identifier, payload: payload))
            cursor += 10 + frameSize
        }

        return frames
    }

    private func payloadSummary(for frames: [ID3Frame]) -> (
        text: String?,
        redacted: Bool,
        status: TimedMetadataDecodeStatus
    ) {
        guard !frames.isEmpty else {
            return (nil, false, .detectedOnly)
        }

        if let textFrame = frames.first(where: { $0.identifier.hasPrefix("T") }),
           let text = decodeTextFrame(textFrame.payload),
           !text.isEmpty {
            return ("\(textFrame.identifier): \(text)", false, .payloadDecoded)
        }

        if let privateFrame = frames.first(where: { $0.identifier == "PRIV" }) {
            let owner = decodeNullTerminatedUTF8(privateFrame.payload) ?? "unknown owner"
            return ("PRIV owner: \(owner)", true, .unknownPrivatePayload)
        }

        return (frames.map(\.identifier).joined(separator: ", "), false, .frameHeadersParsed)
    }

    private func privateOwnerIdentifiers(in frames: [ID3Frame]) -> [String] {
        frames
            .filter { $0.identifier == "PRIV" }
            .compactMap { decodeNullTerminatedUTF8($0.payload) }
            .map { String($0.prefix(256)) }
    }

    private func decodeTextFrame(_ payload: [UInt8]) -> String? {
        guard let encoding = payload.first else { return nil }
        let textBytes = Array(payload.dropFirst()).trimmedNulls()
        switch encoding {
        case 0, 3:
            return String(bytes: textBytes, encoding: .utf8)
        default:
            return nil
        }
    }

    private func decodeNullTerminatedUTF8(_ payload: [UInt8]) -> String? {
        let end = payload.firstIndex(of: 0) ?? payload.endIndex
        guard end > payload.startIndex else { return nil }
        return String(bytes: payload[payload.startIndex..<end], encoding: .utf8)
    }

    private func synchsafeInteger(_ bytes: [UInt8], at offset: Int, length: Int) -> Int? {
        guard offset + length <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[offset..<(offset + length)] {
            guard byte & 0x80 == 0 else { return nil }
            value = (value << 7) | Int(byte)
        }
        return value
    }

    private func bigEndianInteger(_ bytes: [UInt8], at offset: Int, length: Int) -> Int? {
        guard offset + length <= bytes.count else { return nil }
        return bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

private extension Array where Element == UInt8 {
    func trimmedNulls() -> [UInt8] {
        var copy = self
        while copy.last == 0 {
            copy.removeLast()
        }
        return copy
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
