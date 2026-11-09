//
//  BinaryMediaStructureProbe.swift
//  JoesProxy
//
//  Performs bounded structural inspection of captured video segment/container bytes.
//

import Foundation

struct BinaryMediaStructure: Sendable {
    enum Kind: String, Sendable {
        case mpegTransportStream = "MPEG-TS"
        case isoBMFF = "ISO BMFF / fMP4"
        case unknown = "Unknown Binary Media"
    }

    enum Role: String, Sendable {
        case transportSegment = "Transport Segment"
        case initializationAsset = "Initialization Asset"
        case mediaFragment = "Media Fragment"
        case completeAsset = "Complete Asset"
        case unknown = "Unknown"
    }

    struct BoxSummary: Sendable, Equatable {
        let type: String
        let size: UInt64
    }

    struct EventMessageSummary: Sendable, Equatable {
        let version: UInt8
        let schemeIDURI: String?
        let value: String?
        let timescale: UInt32?
        let presentationTime: UInt64?
        let eventDuration: UInt32?
        let eventID: UInt32?
        let messageDataSize: Int
        let embeddedID3FrameIdentifiers: [String]
    }

    let kind: Kind
    let role: Role
    let bytesInspected: Int
    let notes: [String]
    let tsPacketSize: Int?
    let tsSyncPacketCount: Int?
    let tsProgramNumbers: [Int]
    let tsStreamTypeCodes: [UInt8]
    let scte35PIDPresent: Bool
    let topLevelBoxes: [BoxSummary]
    let likelyFragmented: Bool
    let likelyEncrypted: Bool
    let segmentIndexPresent: Bool
    let eventMessagePresent: Bool
    let eventMessages: [EventMessageSummary]
    let psshCount: Int
}

protocol BinaryMediaStructureProbing: Sendable {
    func inspect(data: Data) -> BinaryMediaStructure?
}

private struct ParsedPAT {
    let programNumbers: [Int]
    let pmtPIDs: [Int]
}

private struct ParsedPMT {
    let streamTypeCodes: [UInt8]
    let scte35PIDPresent: Bool
}

struct BinaryMediaStructureProbe: BinaryMediaStructureProbing, Sendable {
    private let maximumBytesToInspect: Int
    private let maximumTopLevelBoxes: Int

    init(maximumBytesToInspect: Int = 64 * 1024, maximumTopLevelBoxes: Int = 16) {
        self.maximumBytesToInspect = maximumBytesToInspect
        self.maximumTopLevelBoxes = maximumTopLevelBoxes
    }

    func inspect(data: Data) -> BinaryMediaStructure? {
        let prefix = data.prefix(maximumBytesToInspect)
        guard !prefix.isEmpty else { return nil }

        if let ts = inspectTransportStream(prefix) {
            return ts
        }

        if let bmff = inspectISOBaseMediaFile(prefix) {
            return bmff
        }

        return nil
    }

    private func inspectTransportStream(_ data: Data.SubSequence) -> BinaryMediaStructure? {
        let sourceBytes = [UInt8](data)
        guard let framing = transportFraming(in: sourceBytes) else { return nil }
        let packetSize = framing.packetSize
        var bytes: [UInt8] = []
        var syncOffset = framing.firstSyncOffset
        while syncOffset + 188 <= sourceBytes.count {
            bytes.append(contentsOf: sourceBytes[syncOffset..<(syncOffset + 188)])
            syncOffset += packetSize
        }
        let normalizedPacketSize = 188
        let packetCount = min(bytes.count / normalizedPacketSize, 24)
        guard packetCount >= 2 else { return nil }

        var syncCount = 0
        var patDetected = false
        var parsedPAT = ParsedPAT(programNumbers: [], pmtPIDs: [])
        var parsedPMTs: [ParsedPMT] = []
        var seenPMTPIDs = Set<Int>()

        for packetIndex in 0..<packetCount {
            let offset = packetIndex * normalizedPacketSize
            guard bytes[offset] == 0x47 else { break }
            syncCount += 1

            guard offset + 3 < bytes.count else { continue }
            let pid = ((Int(bytes[offset + 1] & 0x1F)) << 8) | Int(bytes[offset + 2])
            if pid == 0 {
                patDetected = true
                if let parsed = parsePATPacket(bytes, at: offset) {
                    parsedPAT = parsed
                }
            } else if parsedPAT.pmtPIDs.contains(pid),
                      !seenPMTPIDs.contains(pid),
                      let parsedPMT = parsePMTPacket(bytes, at: offset) {
                seenPMTPIDs.insert(pid)
                parsedPMTs.append(parsedPMT)
            }

            if patDetected,
               !parsedPAT.pmtPIDs.isEmpty,
               seenPMTPIDs.count == parsedPAT.pmtPIDs.count {
                break
            }
        }

        let hasCompletePATPMT = patDetected
            && !parsedPAT.pmtPIDs.isEmpty
            && seenPMTPIDs.count == parsedPAT.pmtPIDs.count
        guard syncCount >= 2 || hasCompletePATPMT else { return nil }

        var notes = ["Detected \(syncCount) sync-aligned \(packetSize)-byte transport packets in the captured prefix."]
        if patDetected {
            notes.append("PAT PID 0 was present in the inspected packets.")
        }
        if !parsedPAT.programNumbers.isEmpty {
            notes.append("PAT advertised program numbers: \(parsedPAT.programNumbers.map(String.init).joined(separator: ", ")).")
        }
        let streamTypeCodes = Array(Set(parsedPMTs.flatMap(\.streamTypeCodes))).sorted()
        if !streamTypeCodes.isEmpty {
            notes.append("PMT stream types: \(streamTypeCodes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")).")
        }
        let scte35PIDPresent = parsedPMTs.contains(where: \.scte35PIDPresent)
        if scte35PIDPresent {
            notes.append("PMT indicates an SCTE-35 stream type (0x86) in the inspected prefix.")
        }

        return BinaryMediaStructure(
            kind: .mpegTransportStream,
            role: .transportSegment,
            bytesInspected: data.count,
            notes: notes,
            tsPacketSize: packetSize,
            tsSyncPacketCount: syncCount,
            tsProgramNumbers: parsedPAT.programNumbers.sorted(),
            tsStreamTypeCodes: streamTypeCodes,
            scte35PIDPresent: scte35PIDPresent,
            topLevelBoxes: [],
            likelyFragmented: false,
            likelyEncrypted: false,
            segmentIndexPresent: false,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )
    }

    private func transportFraming(in bytes: [UInt8]) -> (packetSize: Int, firstSyncOffset: Int)? {
        for packetSize in [188, 192, 204] {
            for offset in 0..<min(packetSize, 16) where offset + packetSize < bytes.count {
                let packetCount = min(4, (bytes.count - offset) / packetSize)
                guard packetCount >= 2 else { continue }
                if (0..<packetCount).allSatisfy({ bytes[offset + $0 * packetSize] == 0x47 }) {
                    return (packetSize, offset)
                }
            }
        }
        return nil
    }

    private func inspectISOBaseMediaFile(_ data: Data.SubSequence) -> BinaryMediaStructure? {
        let bytes = [UInt8](data)
        var offset = 0
        var boxes: [BinaryMediaStructure.BoxSummary] = []
        var eventMessages: [BinaryMediaStructure.EventMessageSummary] = []

        while offset + 8 <= bytes.count && boxes.count < maximumTopLevelBoxes {
            guard let size32 = readUInt32(bytes, at: offset) else { break }
            let typeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
            guard let type = String(bytes: typeBytes, encoding: .ascii),
                  type.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                break
            }

            var boxSize = UInt64(size32)
            var headerSize = 8
            if size32 == 1 {
                guard let largeSize = readUInt64(bytes, at: offset + 8) else { break }
                boxSize = largeSize
                headerSize = 16
            } else if size32 == 0 {
                boxSize = UInt64(bytes.count - offset)
            }

            guard boxSize >= UInt64(headerSize), boxSize > 0 else { break }

            boxes.append(.init(type: type, size: boxSize))

            if type == "emsg",
               let eventMessage = parseEventMessage(bytes, at: offset, size: Int(boxSize), headerSize: headerSize) {
                eventMessages.append(eventMessage)
            } else if type == "moof" {
                eventMessages.append(contentsOf: scanChildEventMessages(
                    bytes: bytes,
                    boxOffset: offset,
                    boxSize: Int(boxSize),
                    headerSize: headerSize
                ))
            }

            let advance = Int(boxSize)
            guard advance > 0 else { break }
            offset += advance
        }

        guard boxes.first?.type == "ftyp" || boxes.contains(where: { $0.type == "moof" || $0.type == "moov" || $0.type == "styp" }) else {
            return nil
        }

        let types = Set(boxes.map(\.type))
        let likelyFragmented = types.contains("moof") || types.contains("styp") || types.contains("sidx")
        let psshCount = boxes.filter { $0.type == "pssh" }.count
        let likelyEncrypted = psshCount > 0
        let segmentIndexPresent = types.contains("sidx")
        let eventMessagePresent = !eventMessages.isEmpty || types.contains("emsg")
        let role: BinaryMediaStructure.Role
        if likelyFragmented {
            role = .mediaFragment
        } else if types.contains("moov") && !types.contains("mdat") {
            role = .initializationAsset
        } else if types.contains("moov") && types.contains("mdat") {
            role = .completeAsset
        } else {
            role = .unknown
        }

        var notes: [String] = []
        if likelyFragmented {
            notes.append("Fragment-style boxes suggest fMP4 / CMAF segment structure.")
        } else if types.contains("moov") {
            notes.append("Top-level boxes look like an initialization or complete MP4 asset.")
        }
        if likelyEncrypted {
            notes.append("Top-level `pssh` was present, which usually indicates DRM protection metadata.")
        }
        if eventMessagePresent {
            notes.append("`emsg` event message boxes were present in the inspected prefix.")
        }
        if segmentIndexPresent {
            notes.append("`sidx` was present, which often carries segment index information.")
        }
        if bytes.count >= maximumBytesToInspect {
            notes.append("Inspection stopped at the configured \(maximumBytesToInspect)-byte prefix.")
        }

        return BinaryMediaStructure(
            kind: .isoBMFF,
            role: role,
            bytesInspected: data.count,
            notes: notes,
            tsPacketSize: nil,
            tsSyncPacketCount: nil,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: boxes,
            likelyFragmented: likelyFragmented,
            likelyEncrypted: likelyEncrypted,
            segmentIndexPresent: segmentIndexPresent,
            eventMessagePresent: eventMessagePresent,
            eventMessages: eventMessages,
            psshCount: psshCount
        )
    }

    private func scanChildEventMessages(
        bytes: [UInt8],
        boxOffset: Int,
        boxSize: Int,
        headerSize: Int
    ) -> [BinaryMediaStructure.EventMessageSummary] {
        var results: [BinaryMediaStructure.EventMessageSummary] = []
        var childOffset = boxOffset + headerSize
        let childEnd = min(boxOffset + boxSize, bytes.count)

        while childOffset + 8 <= childEnd {
            guard let size32 = readUInt32(bytes, at: childOffset) else { break }
            let typeBytes = Array(bytes[(childOffset + 4)..<(childOffset + 8)])
            guard let type = String(bytes: typeBytes, encoding: .ascii) else { break }

            var childSize = Int(size32)
            var childHeader = 8
            if size32 == 1 {
                guard let largeSize = readUInt64(bytes, at: childOffset + 8) else { break }
                childSize = Int(largeSize)
                childHeader = 16
            } else if size32 == 0 {
                childSize = childEnd - childOffset
            }

            guard childSize >= childHeader, childOffset + childSize <= childEnd else { break }
            if type == "emsg",
               let eventMessage = parseEventMessage(bytes, at: childOffset, size: childSize, headerSize: childHeader) {
                results.append(eventMessage)
            }

            guard childSize > 0 else { break }
            childOffset += childSize
        }

        return results
    }

    private func parseEventMessage(
        _ bytes: [UInt8],
        at offset: Int,
        size: Int,
        headerSize: Int
    ) -> BinaryMediaStructure.EventMessageSummary? {
        let payloadStart = offset + headerSize
        guard payloadStart + 4 <= bytes.count, size >= headerSize + 4 else {
            return nil
        }

        let version = bytes[payloadStart]
        let bodyStart = payloadStart + 4
        let bodyLength = size - headerSize - 4
        guard bodyLength > 0, bodyStart + bodyLength <= bytes.count else {
            return nil
        }

        let body = Array(bytes[bodyStart..<(bodyStart + bodyLength)])
        switch version {
        case 0:
            return parseVersion0EventMessage(body)
        case 1:
            return parseVersion1EventMessage(body)
        default:
            return nil
        }
    }

    private func parseVersion0EventMessage(_ body: [UInt8]) -> BinaryMediaStructure.EventMessageSummary? {
        var cursor = 0
        guard let schemeIDURI = readCString(body, cursor: &cursor),
              let value = readCString(body, cursor: &cursor),
              let timescale = readUInt32(body, at: cursor),
              let _ = readUInt32(body, at: cursor + 4),
              let eventDuration = readUInt32(body, at: cursor + 8),
              let eventID = readUInt32(body, at: cursor + 12) else {
            return nil
        }

        return .init(
            version: 0,
            schemeIDURI: schemeIDURI,
            value: value,
            timescale: timescale,
            presentationTime: UInt64(readUInt32(body, at: cursor + 4) ?? 0),
            eventDuration: eventDuration,
            eventID: eventID,
            messageDataSize: max(0, body.count - cursor - 16),
            embeddedID3FrameIdentifiers: embeddedID3FrameIdentifiers(in: Array(body.dropFirst(min(body.count, cursor + 16))))
        )
    }

    private func parseVersion1EventMessage(_ body: [UInt8]) -> BinaryMediaStructure.EventMessageSummary? {
        var cursor = 0
        guard let timescale = readUInt32(body, at: cursor),
              let _ = readUInt64(body, at: cursor + 4),
              let eventDuration = readUInt32(body, at: cursor + 12),
              let eventID = readUInt32(body, at: cursor + 16) else {
            return nil
        }
        cursor = 20

        guard let schemeIDURI = readCString(body, cursor: &cursor),
              let value = readCString(body, cursor: &cursor) else {
            return nil
        }

        return .init(
            version: 1,
            schemeIDURI: schemeIDURI,
            value: value,
            timescale: timescale,
            presentationTime: readUInt64(body, at: 4),
            eventDuration: eventDuration,
            eventID: eventID,
            messageDataSize: max(0, body.count - cursor),
            embeddedID3FrameIdentifiers: embeddedID3FrameIdentifiers(in: Array(body.dropFirst(cursor)))
        )
    }

    private func embeddedID3FrameIdentifiers(in payload: [UInt8]) -> [String] {
        guard let id3Offset = payload.indices.first(where: {
            $0 + 10 <= payload.count
                && payload[$0] == 0x49
                && payload[$0 + 1] == 0x44
                && payload[$0 + 2] == 0x33
                && (payload[$0 + 3] == 3 || payload[$0 + 3] == 4)
        }) else { return [] }

        let version = payload[id3Offset + 3]
        let tagBytes = payload[(id3Offset + 6)..<(id3Offset + 10)]
        guard tagBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return [] }
        let tagSize = tagBytes.reduce(0) { ($0 << 7) | Int($1) }
        let end = min(payload.count, id3Offset + 10 + tagSize)
        var cursor = id3Offset + 10
        var identifiers: [String] = []
        while cursor + 10 <= end, identifiers.count < 32 {
            let identifierBytes = Array(payload[cursor..<(cursor + 4)])
            guard identifierBytes.contains(where: { $0 != 0 }),
                  let identifier = String(bytes: identifierBytes, encoding: .ascii),
                  identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { break }
            let sizeBytes = Array(payload[(cursor + 4)..<(cursor + 8)])
            let frameSize = version == 4
                ? sizeBytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
                : sizeBytes.reduce(0) { ($0 << 8) | Int($1) }
            guard frameSize >= 0, cursor + 10 + frameSize <= end else { break }
            identifiers.append(identifier)
            cursor += 10 + frameSize
        }
        return identifiers
    }

    private func parsePATPacket(_ bytes: [UInt8], at packetOffset: Int) -> ParsedPAT? {
        guard let payloadRange = transportPayloadRange(bytes, at: packetOffset) else {
            return nil
        }
        let payload = Array(bytes[payloadRange])
        guard let table = psiSectionPayload(from: payload), table.count >= 8 else {
            return nil
        }
        guard table[0] == 0x00 else { return nil }

        let sectionLength = Int(((UInt16(table[1] & 0x0F)) << 8) | UInt16(table[2]))
        let totalLength = min(table.count, sectionLength + 3)
        guard totalLength >= 12 else { return nil }

        var programNumbers: [Int] = []
        var pmtPIDs: [Int] = []
        var cursor = 8
        let loopEnd = totalLength - 4
        while cursor + 4 <= loopEnd {
            let programNumber = Int((UInt16(table[cursor]) << 8) | UInt16(table[cursor + 1]))
            let pid = Int((UInt16(table[cursor + 2] & 0x1F) << 8) | UInt16(table[cursor + 3]))
            if programNumber != 0 {
                programNumbers.append(programNumber)
                pmtPIDs.append(pid)
            }
            cursor += 4
        }

        return ParsedPAT(programNumbers: programNumbers, pmtPIDs: pmtPIDs)
    }

    private func parsePMTPacket(_ bytes: [UInt8], at packetOffset: Int) -> ParsedPMT? {
        guard let payloadRange = transportPayloadRange(bytes, at: packetOffset) else {
            return nil
        }
        let payload = Array(bytes[payloadRange])
        guard let table = psiSectionPayload(from: payload), table.count >= 12 else {
            return nil
        }
        guard table[0] == 0x02 else { return nil }

        let sectionLength = Int(((UInt16(table[1] & 0x0F)) << 8) | UInt16(table[2]))
        let totalLength = min(table.count, sectionLength + 3)
        guard totalLength >= 16 else { return nil }

        let programInfoLength = Int((UInt16(table[10] & 0x0F) << 8) | UInt16(table[11]))
        var cursor = 12 + programInfoLength
        let loopEnd = totalLength - 4
        var streamTypeCodes: [UInt8] = []
        var scte35PIDPresent = false

        while cursor + 5 <= loopEnd {
            let streamType = table[cursor]
            streamTypeCodes.append(streamType)
            if streamType == 0x86 {
                scte35PIDPresent = true
            }
            let esInfoLength = Int((UInt16(table[cursor + 3] & 0x0F) << 8) | UInt16(table[cursor + 4]))
            cursor += 5 + esInfoLength
        }

        return ParsedPMT(
            streamTypeCodes: streamTypeCodes,
            scte35PIDPresent: scte35PIDPresent
        )
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func readCString(_ bytes: [UInt8], cursor: inout Int) -> String? {
        guard cursor < bytes.count else { return nil }
        guard let terminatorIndex = bytes[cursor...].firstIndex(of: 0) else { return nil }
        let stringBytes = Array(bytes[cursor..<terminatorIndex])
        cursor = terminatorIndex + 1
        return String(bytes: stringBytes, encoding: .utf8)
    }

    private func transportPayloadRange(_ bytes: [UInt8], at packetOffset: Int) -> Range<Int>? {
        guard packetOffset + 188 <= bytes.count else { return nil }
        let adaptationFieldControl = (bytes[packetOffset + 3] >> 4) & 0x03
        guard adaptationFieldControl == 0x01 || adaptationFieldControl == 0x03 else {
            return nil
        }

        var payloadStart = packetOffset + 4
        if adaptationFieldControl == 0x03 {
            let adaptationLength = Int(bytes[payloadStart])
            payloadStart += 1 + adaptationLength
        }

        guard payloadStart < packetOffset + 188 else { return nil }
        return payloadStart..<(packetOffset + 188)
    }

    private func psiSectionPayload(from payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty else { return nil }
        let pointerField = Int(payload[0])
        guard pointerField + 1 < payload.count else { return nil }
        return Array(payload[(pointerField + 1)...])
    }
}
