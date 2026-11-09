import CryptoKit
import Foundation

/// Identifies one ordinary `EXT-X-STREAM-INF` variant without exposing its URI to an MCP client.
///
/// The byte ranges and digests are generated from one complete captured master. They are
/// intentionally stale when the source body changes, so callers must rediscover locators rather
/// than attempting to reconstruct them from an agent-supplied offset or URL.
struct HLSCODECSVariantLocator: Codable, Equatable, Hashable, Sendable {
    let ordinal: Int
    let streamInfoRange: Range<Int>
    let streamInfoLineDigest: String
    let followingURIlineDigest: String
}

/// One user-supplied CODECS value bound to an opaque server-generated variant locator.
struct HLSCODECSVariantEdit: Codable, Equatable, Sendable {
    let locator: HLSCODECSVariantLocator
    let codecs: String
}

struct HLSCODECSEditResult: Equatable, Sendable {
    let data: Data
    let editedVariantCount: Int
    let unsupportedVariantCount: Int
    let codecValueProvenance: String
    let mediaVerified: Bool
}

enum HLSCODECSEditError: Error, Equatable, Sendable {
    case invalidUTF8
    case emptyManifest
    case notMasterPlaylist
    case incompleteVariant(ordinal: Int)
    case unsupportedVariant(ordinal: Int, tag: String)
    case invalidCodecValue
    case duplicateCodecAttribute(ordinal: Int)
    case duplicateLocator
    case staleLocator(ordinal: Int)
    case invalidLocatorTarget
    case conflictingEdits(ordinal: Int)
}

/// Resolves CODECS edits into neutral byte patches for complete HLS master playlists.
///
/// This type owns HLS grammar and locator validation only. Byte application is delegated to
/// ``BoundedBytePatchEngine`` so CODECS editing shares the same content-neutral patch path as
/// exact-text response edits. The transformer does not reserialize `HLSManifest`; that model
/// intentionally omits formatting, comments, vendor tags, and attribute ordering. No media bytes
/// are inspected, therefore results are always `mediaVerified == false`.
enum HLSCODECSEditTransformer {
    private static let streamInfoPrefix = "#EXT-X-STREAM-INF:"
    private static let maxCodecValueBytes = 512
    private static let adapterName = "hls-codecs"
    private static let adapterVersion = 1

    /// Bumped when ``apply`` semantics change so preview digests cannot be reused across incompatible transformers.
    static var transformerVersion: Int { adapterVersion }

    /// Finds ordinary variant locators in a complete UTF-8 master playlist.
    static func variantLocators(in originalBytes: Data) throws -> [HLSCODECSVariantLocator] {
        let source = try sourceLines(originalBytes)
        guard source.lines.contains(where: {
            let header = $0.text.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            return header == "#EXTM3U"
        }) else {
            throw HLSCODECSEditError.emptyManifest
        }

        var locators: [HLSCODECSVariantLocator] = []
        var ordinal = 0
        for index in source.lines.indices {
            let line = source.lines[index]
            guard line.text.hasPrefix(streamInfoPrefix) else { continue }
            guard index + 1 < source.lines.count else {
                throw HLSCODECSEditError.incompleteVariant(ordinal: ordinal)
            }
            let uriLine = source.lines[index + 1]
            let uriText = uriLine.text.trimmingCharacters(in: .whitespaces)
            guard !uriText.isEmpty, !uriText.hasPrefix("#") else {
                throw HLSCODECSEditError.incompleteVariant(ordinal: ordinal)
            }
            locators.append(
                HLSCODECSVariantLocator(
                    ordinal: ordinal,
                    streamInfoRange: line.contentRange,
                    streamInfoLineDigest: digest(line.content),
                    followingURIlineDigest: digest(uriLine.content)
                )
            )
            ordinal += 1
        }
        guard !locators.isEmpty else {
            throw HLSCODECSEditError.notMasterPlaylist
        }
        return locators
    }

    /// Resolves CODECS edits into ``ResolvedPatch`` values without mutating the source bytes.
    ///
    /// Callers that need patched output should use ``apply(originalBytes:edits:)``, which feeds
    /// these patches into ``BoundedBytePatchEngine``.
    static func resolvePatches(
        originalBytes: Data,
        edits: [HLSCODECSVariantEdit]
    ) throws -> [ResolvedPatch] {
        let source = try sourceLines(originalBytes)
        let locators = try variantLocators(in: originalBytes)
        let locatorByOrdinal = Dictionary(uniqueKeysWithValues: locators.map { ($0.ordinal, $0) })
        var seenOrdinals = Set<Int>()
        var patches: [ResolvedPatch] = []

        for edit in edits {
            guard let expected = locatorByOrdinal[edit.locator.ordinal],
                  expected == edit.locator,
                  source.lines.contains(where: { $0.contentRange == expected.streamInfoRange }) else {
                throw HLSCODECSEditError.staleLocator(ordinal: edit.locator.ordinal)
            }
            guard seenOrdinals.insert(edit.locator.ordinal).inserted else {
                throw HLSCODECSEditError.conflictingEdits(ordinal: edit.locator.ordinal)
            }
            guard let streamLine = source.lines.first(where: { $0.contentRange == expected.streamInfoRange }),
                  let streamIndex = source.lines.firstIndex(where: { $0.contentRange == expected.streamInfoRange }),
                  streamIndex + 1 < source.lines.count,
                  source.lines[streamIndex + 1].text.trimmingCharacters(in: .whitespaces).hasPrefix("#") == false,
                  digest(streamLine.content) == expected.streamInfoLineDigest,
                  digest(source.lines[streamIndex + 1].content) == expected.followingURIlineDigest else {
                throw HLSCODECSEditError.staleLocator(ordinal: edit.locator.ordinal)
            }

            let parsed = try parseStreamInfo(
                line: streamLine.text,
                ordinal: edit.locator.ordinal,
                lineStart: streamLine.contentRange.lowerBound
            )
            guard parsed.duplicateCodecCount <= 1 else {
                throw HLSCODECSEditError.duplicateCodecAttribute(ordinal: edit.locator.ordinal)
            }
            try validateCodecValue(edit.codecs)
            let byteRange: Range<Int>
            let replacementBytes: Data
            if let codecRange = parsed.codecValueRange {
                byteRange = codecRange
                replacementBytes = Data(edit.codecs.utf8)
            } else {
                let insertion = streamLine.contentRange.upperBound
                byteRange = insertion..<insertion
                replacementBytes = Data(",CODECS=\"\(edit.codecs)\"".utf8)
            }
            patches.append(
                ResolvedPatch(
                    patchID: UUID(),
                    byteRange: byteRange,
                    expectedOriginalSHA256: digest(Data(originalBytes[byteRange])),
                    replacementBytes: replacementBytes,
                    provenance: .selectorAdapter(name: adapterName, version: adapterVersion)
                )
            )
        }
        return patches
    }

    /// Applies all CODECS edits atomically through the shared bounded byte-patch engine.
    static func apply(
        originalBytes: Data,
        edits: [HLSCODECSVariantEdit]
    ) throws -> HLSCODECSEditResult {
        // Empty edit sets historically returned the original bytes unchanged; keep that behavior
        // rather than surfacing the engine's empty-patch rejection to existing callers.
        guard !edits.isEmpty else {
            return HLSCODECSEditResult(
                data: originalBytes,
                editedVariantCount: 0,
                unsupportedVariantCount: 0,
                codecValueProvenance: "user_supplied",
                mediaVerified: false
            )
        }
        let patches = try resolvePatches(originalBytes: originalBytes, edits: edits)
        let patched = try BoundedBytePatchEngine.apply(
            originalBytes: originalBytes,
            patches: patches
        )
        return HLSCODECSEditResult(
            data: patched.data,
            editedVariantCount: patches.count,
            unsupportedVariantCount: 0,
            codecValueProvenance: "user_supplied",
            mediaVerified: false
        )
    }

    private struct SourceLines {
        let lines: [SourceLine]
    }

    private struct SourceLine {
        let contentRange: Range<Int>
        let content: Data
        let text: String
    }

    private struct ParsedStreamInfo {
        let codecValueRange: Range<Int>?
        let duplicateCodecCount: Int
    }

    private static func sourceLines(_ data: Data) throws -> SourceLines {
        guard !data.isEmpty else { throw HLSCODECSEditError.emptyManifest }
        guard String(data: data, encoding: .utf8) != nil else {
            throw HLSCODECSEditError.invalidUTF8
        }
        var lines: [SourceLine] = []
        var start = 0
        for index in data.indices where data[index] == 0x0A {
            let contentEnd = index > start && data[index - 1] == 0x0D ? index - 1 : index
            let content = Data(data[start..<contentEnd])
            lines.append(
                SourceLine(
                    contentRange: start..<contentEnd,
                    content: content,
                    text: String(decoding: content, as: UTF8.self)
                )
            )
            start = index + 1
        }
        if start < data.count {
            let content = Data(data[start..<data.count])
            lines.append(
                SourceLine(
                    contentRange: start..<data.count,
                    content: content,
                    text: String(decoding: content, as: UTF8.self)
                )
            )
        }
        return SourceLines(lines: lines)
    }

    private static func parseStreamInfo(
        line: String,
        ordinal: Int,
        lineStart: Int
    ) throws -> ParsedStreamInfo {
        guard line.hasPrefix(streamInfoPrefix) else {
            throw HLSCODECSEditError.invalidLocatorTarget
        }
        let attributesStart = line.index(line.startIndex, offsetBy: streamInfoPrefix.count)
        let attributes = String(line[attributesStart...])
        let offset = lineStart + streamInfoPrefix.utf8.count
        var codecRange: Range<Int>?
        var codecCount = 0
        var index = attributes.startIndex
        while index < attributes.endIndex {
            let nameStart = index
            while index < attributes.endIndex, attributes[index] != "=", attributes[index] != "," {
                index = attributes.index(after: index)
            }
            guard index < attributes.endIndex, attributes[index] == "=" else {
                break
            }
            let name = String(attributes[nameStart..<index])
            index = attributes.index(after: index)
            let valueStart = index
            if index < attributes.endIndex, attributes[index] == "\"" {
                index = attributes.index(after: index)
                while index < attributes.endIndex, attributes[index] != "\"" {
                    index = attributes.index(after: index)
                }
                guard index < attributes.endIndex else {
                    throw HLSCODECSEditError.invalidLocatorTarget
                }
                let valueEnd = index
                if name == "CODECS" {
                    codecCount += 1
                    let lower = offset + attributes.distance(from: attributes.startIndex, to: valueStart) + 1
                    let upper = offset + attributes.distance(from: attributes.startIndex, to: valueEnd)
                    codecRange = lower..<upper
                }
                index = attributes.index(after: index)
            } else {
                while index < attributes.endIndex, attributes[index] != "," {
                    index = attributes.index(after: index)
                }
            }
            if index < attributes.endIndex, attributes[index] == "," {
                index = attributes.index(after: index)
            }
            _ = valueStart
        }
        _ = ordinal
        return ParsedStreamInfo(codecValueRange: codecRange, duplicateCodecCount: codecCount)
    }

    private static func validateCodecValue(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maxCodecValueBytes else {
            throw HLSCODECSEditError.invalidCodecValue
        }
        guard !value.contains("\""), !value.contains("\r"), !value.contains("\n"),
              !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw HLSCODECSEditError.invalidCodecValue
        }
        guard value.split(separator: ",", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw HLSCODECSEditError.invalidCodecValue
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Secondary semantic check for CODECS-only preview: non-CODECS variant fields must be unchanged.
enum HLSCODECSPreviewSemanticCheck {
    enum Failure: Error, Equatable, Sendable {
        case variantCountMismatch
        case nonCodecsFieldChanged(ordinal: Int, field: String)
        case unexpectedCodecsChange(ordinal: Int)
    }

    /// Ensures `patched` differs from `original` only in `codecs` on `editedOrdinals`.
    static func assertCodecsOnlyChange(
        original: HLSManifest,
        patched: HLSManifest,
        editedOrdinals: Set<Int>
    ) throws {
        guard original.variants.count == patched.variants.count else {
            throw Failure.variantCountMismatch
        }
        for index in original.variants.indices {
            let before = original.variants[index]
            let after = patched.variants[index]
            if before.uri != after.uri {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "uri")
            }
            if before.bandwidth != after.bandwidth {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "bandwidth")
            }
            if before.averageBandwidth != after.averageBandwidth {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "averageBandwidth")
            }
            if before.resolution != after.resolution {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "resolution")
            }
            if before.frameRate != after.frameRate {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "frameRate")
            }
            if before.videoRange != after.videoRange {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "videoRange")
            }
            if before.hdcpLevel != after.hdcpLevel {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "hdcpLevel")
            }
            if before.name != after.name {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "name")
            }
            if before.audioGroupID != after.audioGroupID {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "audioGroupID")
            }
            if before.subtitlesGroupID != after.subtitlesGroupID {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "subtitlesGroupID")
            }
            if before.videoGroupID != after.videoGroupID {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "videoGroupID")
            }
            if before.closedCaptionsGroupID != after.closedCaptionsGroupID {
                throw Failure.nonCodecsFieldChanged(ordinal: index, field: "closedCaptionsGroupID")
            }
            if editedOrdinals.contains(index) {
                continue
            }
            if before.codecs != after.codecs {
                throw Failure.unexpectedCodecsChange(ordinal: index)
            }
        }
    }
}
