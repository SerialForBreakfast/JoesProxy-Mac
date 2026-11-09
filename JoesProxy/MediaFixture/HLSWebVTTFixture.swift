import CryptoKit
import Foundation

/// Prepared once off the calling actor in the production fixture factory. Never translates or
/// generates cues on a network/UI execution path; existing media files are referenced, not copied.
enum HLSWebVTTFixture {
    struct TrackIdentity: Codable, Equatable, Hashable, Sendable {
        let id: String
        let language: String
        let role: String
        let sourceRevision: String
    }
    struct Cue: Codable, Equatable, Sendable {
        var id: String
        var startMilliseconds: Int
        var endMilliseconds: Int
        var text: String
    }

    struct Track: Codable, Equatable, Sendable, Identifiable {
        enum Role: String, Codable, Sendable { case subtitles, sdh, forced }
        var id: String
        var name: String
        var language: String
        var role: Role
        var isDefault: Bool
        var isAutoSelect: Bool
        var reviewStatus: String
        var cues: [Cue]

        var playlistPath: String { "text/\(id)/stream.m3u8" }
        var characteristics: [String] {
            role == .sdh ? ["public.accessibility.transcribes-spoken-dialog", "public.accessibility.describes-music-and-sound"] : []
        }
    }

    struct Specification: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var baseProfileID: String
        var baseInventorySHA256: String
        var durationMilliseconds: Int
        var segmentMilliseconds: Int
        var mediaTimestamp: Int64
        var sourceRevision: String
        var provenance: String
        var tracks: [Track]
    }

    struct Prepared: Sendable {
        var resources: [String: Data]
        var mediaFiles: [String: URL]
        var hashes: [String: String]
        var segmentDuration: Double
        var tracks: [String: TrackIdentity] = [:]
    }

    static func validateConfiguration(_ configuration: HLSPlaybackConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.jitPublicationState == nil,
              configuration.presentationMode == .vodStatic && configuration.effectiveTimeShiftMode == .off
                || configuration.presentationMode == .liveLoop && configuration.intent == .conformant
                    && configuration.recommendationViolations.isEmpty && configuration.jitPublicationState == nil else {
            throw ValidationError.invalid("select vodStatic or conformant liveLoop without JIT; live text requires unique segment URLs and declared discontinuities")
        }
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid caption fixture: \(reason). Use a validated VOD profile; no fallback was selected."
            }
        }
    }

    static func validate(_ spec: Specification) throws {
        guard spec.schemaVersion == 1, safeComponent(spec.baseProfileID),
              spec.baseInventorySHA256.count == 64,
              spec.durationMilliseconds > 0, spec.durationMilliseconds <= 300_000,
              spec.segmentMilliseconds >= 1000, spec.segmentMilliseconds <= 10_000,
              spec.durationMilliseconds % spec.segmentMilliseconds == 0,
              (0..<(Int64(1) << 33)).contains(spec.mediaTimestamp),
              !spec.sourceRevision.isEmpty, spec.sourceRevision.utf8.count <= 128, !spec.provenance.isEmpty,
              (1...8).contains(spec.tracks.count), Set(spec.tracks.map(\.id)).count == spec.tracks.count,
              Set(spec.tracks.map(\.name)).count == spec.tracks.count,
              spec.tracks.filter(\.isDefault).count <= 1 else { throw ValidationError.invalid("invalid contract or limits") }
        for track in spec.tracks {
            guard safeComponent(track.id), safeAttribute(track.name),
                  track.language.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil,
                  track.language.count <= 35, track.name.count <= 80,
                  ["diagnosticUnreviewed", "reviewed"].contains(track.reviewStatus),
                  !track.isDefault || track.isAutoSelect,
                  track.role != .sdh || track.isAutoSelect,
                  track.cues.count <= 64, Set(track.cues.map(\.id)).count == track.cues.count else {
                throw ValidationError.invalid("invalid track identity, language, role or selection flags")
            }
            var previousStart = -1
            for cue in track.cues {
                guard safeComponent(cue.id), cue.startMilliseconds >= previousStart,
                      cue.startMilliseconds >= 0, cue.endMilliseconds > cue.startMilliseconds,
                      cue.endMilliseconds <= spec.durationMilliseconds, !cue.text.isEmpty,
                      cue.text.utf8.count <= 2048, !cue.text.contains("\n"), !cue.text.contains("\r"),
                      !cue.text.contains("-->"), !cue.text.contains("\0") else {
                    throw ValidationError.invalid("invalid cue timing, order or text")
                }
                previousStart = cue.startMilliseconds
            }
        }
    }

    static func prepare(directory: URL, configuration: HLSPlaybackConfiguration) throws -> Prepared? {
        let profileURL = directory.appendingPathComponent("profile.json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
        let data = try boundedFile(profileURL, root: directory, maximum: 128 * 1024)
        // Existing profiles without textFixture retain their historical loader semantics.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if String(decoding: data, as: UTF8.self).contains("\"textFixture\"") { throw ValidationError.invalid("malformed text metadata") }
            return nil
        }
        guard object["textFixture"] != nil else { return nil }
        let descriptor = try JSONDecoder().decode(HLSFixtureProfileDescriptor.self, from: data)
        guard let spec = descriptor.textFixture else { throw ValidationError.invalid("missing text contract") }
        try validate(spec)
        try validateConfiguration(configuration)
        let base = directory.deletingLastPathComponent().appendingPathComponent(spec.baseProfileID)
        let inventoryData = try boundedFile(base.appendingPathComponent("expected-hashes.json"), root: base, maximum: 128 * 1024)
        guard sha256(inventoryData) == spec.baseInventorySHA256 else { throw ValidationError.invalid("base inventory changed") }
        struct Inventory: Decodable {
            struct File: Decodable { var sha256: String; var bytes: Int }
            var files: [String: File]
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: inventoryData)
        guard inventory.files.count <= 128,
              inventory.files.values.allSatisfy({ $0.bytes >= 0 && $0.bytes <= HLSFixtureLimits.maxServedFileBytes }),
              inventory.files.values.reduce(0, { $0 + $1.bytes }) <= 32 * 1024 * 1024 else {
            throw ValidationError.invalid("base inventory limit")
        }
        var prepared = Prepared(resources: [:], mediaFiles: [:], hashes: [:], segmentDuration: Double(spec.segmentMilliseconds) / 1000)
        for path in inventory.files.keys.sorted() where path.hasSuffix(".ts") || path.hasSuffix(".m3u8") {
            try Task.checkCancellation()
            guard safePath(path), let expected = inventory.files[path] else { throw ValidationError.invalid("unsafe base path") }
            let url = base.appendingPathComponent(path)
            let bytes = try boundedFile(url, root: base, maximum: HLSFixtureLimits.maxServedFileBytes)
            guard bytes.count == expected.bytes, sha256(bytes) == expected.sha256 else { throw ValidationError.invalid("base asset changed") }
            prepared.hashes[path] = expected.sha256
            if path.hasSuffix(".m3u8") { prepared.resources[path] = bytes }
            else { prepared.mediaFiles[path] = url }
        }
        guard let masterData = prepared.resources["master.m3u8"],
              let master = String(data: masterData, encoding: .utf8), !master.contains("TYPE=SUBTITLES"),
              !master.contains("TYPE=CLOSED-CAPTIONS") else { throw ValidationError.invalid("unsupported base master") }
        for (path, bytes) in prepared.resources where path != "master.m3u8" {
            let text = String(decoding: bytes, as: UTF8.self)
            let parsed = HLSStaticPlaylistParser.parse(text)
            guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-DISCONTINUITY"),
                  !parsed.segments.isEmpty,
                  abs(parsed.segments.reduce(0) { $0 + $1.duration } - Double(spec.durationMilliseconds) / 1000) < 0.05 else {
                throw ValidationError.invalid("base timeline does not match text")
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard parsed.segments.allSatisfy({ safeComponent($0.uri) && prepared.mediaFiles["\(parent)/\($0.uri)"] != nil }) else {
                throw ValidationError.invalid("unresolved media segment")
            }
            if configuration.presentationMode == .liveLoop {
                let isAudio = master.components(separatedBy: "\n").contains {
                    $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO,") && $0.contains("URI=\"\(path)\"")
                }
                var boundary = 0.0
                let aligned = parsed.segments.enumerated().allSatisfy { index, segment in
                    boundary += segment.duration
                    return abs(boundary - Double(index + 1) * prepared.segmentDuration) < (isAudio ? 0.020 : 0.000001)
                }
                guard parsed.segments.count == spec.durationMilliseconds / spec.segmentMilliseconds, aligned,
                      abs(boundary - Double(spec.durationMilliseconds) / 1000) < 0.000001 else {
                    throw ValidationError.invalid("live media and text require identical uniform segment grids")
                }
            }
        }
        let declarations = spec.tracks.map { track in
            var line = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"text\",NAME=\"\(track.name)\",LANGUAGE=\"\(track.language)\",DEFAULT=\(track.isDefault ? "YES" : "NO"),AUTOSELECT=\(track.isAutoSelect ? "YES" : "NO"),FORCED=\(track.role == .forced ? "YES" : "NO"),URI=\"\(track.playlistPath)\""
            if !track.characteristics.isEmpty { line += ",CHARACTERISTICS=\"\(track.characteristics.joined(separator: ","))\"" }
            return line
        }.joined(separator: "\n")
        let lines = master.components(separatedBy: "\n").map { line -> String in
            if line == "#EXTM3U" { return line + "\n" + declarations }
            if line.hasPrefix("#EXT-X-VERSION:") { return "#EXT-X-VERSION:6" }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { return line + ",SUBTITLES=\"text\"" }
            return line
        }
        prepared.resources["master.m3u8"] = Data(lines.joined(separator: "\n").utf8)
        for track in spec.tracks {
            try Task.checkCancellation()
            let identity = TrackIdentity(id: track.id, language: track.language, role: track.role.rawValue, sourceRevision: spec.sourceRevision)
            prepared.tracks[track.playlistPath] = identity
            var playlist = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:\((spec.segmentMilliseconds + 999) / 1000)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for index in 0..<(spec.durationMilliseconds / spec.segmentMilliseconds) {
                let start = index * spec.segmentMilliseconds, end = start + spec.segmentMilliseconds
                var vtt = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(spec.mediaTimestamp)\n\n"
                for cue in track.cues where cue.startMilliseconds < end && cue.endMilliseconds > start {
                    let escaped = cue.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    vtt += "\(cue.id)\n\(timestamp(cue.startMilliseconds)) --> \(timestamp(cue.endMilliseconds))\n[\(track.language) · \(track.role.rawValue) · \(cue.id)] \(escaped)\n\n"
                }
                let filename = "segment-\(index).vtt"
                prepared.resources["text/\(track.id)/\(filename)"] = Data(vtt.utf8)
                prepared.tracks["text/\(track.id)/\(filename)"] = identity
                playlist += "#EXTINF:\(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(spec.segmentMilliseconds) / 1000)),\n\(filename)\n"
            }
            prepared.resources[track.playlistPath] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        }
        guard prepared.resources.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 else { throw ValidationError.invalid("prepared text budget") }
        let peakTextBytes = prepared.resources.filter { $0.key.hasSuffix(".vtt") }.values.map(\.count).max() ?? 0
        let textBandwidth = (peakTextBytes * 8000 + spec.segmentMilliseconds - 1) / spec.segmentMilliseconds
        let adjustedMaster = lines.map { line -> String in
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { return line }
            let prefix = "#EXT-X-STREAM-INF:"
            let attributes = line.dropFirst(prefix.count).components(separatedBy: ",").map { attribute -> String in
                for name in ["BANDWIDTH", "AVERAGE-BANDWIDTH"] where attribute.hasPrefix(name + "=") {
                    if let value = Int(attribute.dropFirst(name.count + 1)) { return "\(name)=\(value + textBandwidth)" }
                }
                return attribute
            }
            return prefix + attributes.joined(separator: ",")
        }.joined(separator: "\n")
        prepared.resources["master.m3u8"] = Data(adjustedMaster.utf8)
        for (path, bytes) in prepared.resources { prepared.hashes[path] = sha256(bytes) }
        return prepared
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
    private static func safeAttribute(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\"") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value != "." && value != ".." &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }
    private static func safePath(_ value: String) -> Bool { value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) } }
    private static func boundedFile(_ url: URL, root: URL, maximum: Int) throws -> Data {
        let rootPath = root.standardizedFileURL.path
        guard root.resolvingSymlinksInPath().path == rootPath,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { throw ValidationError.invalid("unsafe fixture path") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else { throw ValidationError.invalid("fixture file limit") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw ValidationError.invalid("fixture changed during preparation") }
        return data
    }
}
