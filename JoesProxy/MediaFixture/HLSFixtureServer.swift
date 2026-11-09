import Foundation
import NIO
import NIOHTTP1
import NIOPosix

/// Mode-aware rendition inspection generated from the same immutable source and publication model
/// used by HTTP responses.
enum HLSFixturePlaylistPreview: Equatable, Sendable {
    case vod(parsed: HLSStaticPlaylistParser.Parsed, playlistText: String)
    case live(HLSSlidingPlaylistComputer.Window)
}

/// Loopback NIOHTTP1 server for one active HLS fixture run — serves a single, fixed profile
/// directory (see `Fixtures/HLS/`) as a deterministic, clock-driven "live" HLS source. Modeled
/// directly on `MCPNIOHTTPTransport`'s `ServerBootstrap`/`configureHTTPServerPipeline`/
/// `ChannelInboundHandler` idiom.
///
/// Concurrency: `start()`/`stop()` are awaited from the main actor (matches
/// `MCPNIOHTTPTransport`); request handling runs entirely on the channel event loop — unlike the
/// MCP transport, nothing here needs to hop to the main actor, since serving fixture content reads
/// immutable, already-loaded-at-init state plus a lock-protected completion instant.
final class HLSFixtureServer: @unchecked Sendable {
    enum FixtureServerError: LocalizedError, Equatable {
        case alreadyRunning
        case notRunning
        case bindFailed(String)
        case profileDirectoryUnreadable
        case completionRequiresLiveLoop
        case invalidTextFixture(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "The fixture or prepared transition is already active. Inspect its state before retrying."
            case .notRunning: return "The fixture is not running."
            case .bindFailed(let reason): return "The fixture server could not start: \(reason)"
            case .profileDirectoryUnreadable: return "The reviewed fixture directory is unavailable."
            case .invalidTextFixture(let reason): return reason
            case .completionRequiresLiveLoop:
                return "Unsupported live media lifecycle. Use conformant liveLoop without JIT faults, init maps, byte ranges or partial segments. Prepared switches additionally require identical master bytes, uniform matching durations, local segment filenames and unencrypted segments. Review the profile; no fallback profile is selected."
            }
        }
    }

    /// One playlist file's parsed, cacheable content — parsed once at construction, not per request,
    /// since fixture content is immutable for the lifetime of a run.
    private struct ParsedStream: Sendable {
        let parsed: HLSStaticPlaylistParser.Parsed
        /// Exact authored bytes used by `vodStatic`; parsing must never become serialization.
        let authoredData: Data
        let supportsLifecycle: Bool
    }

    private let group: MultiThreadedEventLoopGroup
    private let ownsGroup: Bool
    let profileDirectory: URL
    let startedAt: Date
    let playbackConfiguration: HLSPlaybackConfiguration
    private let clock: () -> Date
    private var serverChannel: Channel?
    private let state = HLSFixtureConnectionState()
    /// Relative path (from `profileDirectory`, e.g. `"video-lo/stream.m3u8"`) -> parsed static
    /// playlist, populated once at construction (sync `init` or async `make`).
    private let parsedStreams: [String: ParsedStream]
    private let preparedText: HLSWebVTTFixture.Prepared?
    private let textPreparationFailure: String?
    private let completionLock = NSLock()
    private var completedAt: Date?
    private var stopped = false
    private var preparingSwitch = false
    private struct PreparedSwitch: Sendable {
        let id: UUID
        let directory: URL
        let streams: [String: ParsedStream]
        let text: HLSWebVTTFixture.Prepared?
    }
    private var preparedSwitch: PreparedSwitch?
    private var switchSequences: [String: Int] = [:]

    /// The first supported switch preserves one exact master topology and a uniform segment
    /// grid. Parsing and file checks finish before activation; publication only flips metadata.
    func prepareSwitch(id: UUID, directory: URL) async throws {
        try validateLiveLifecycle()
        try completionLock.withLock {
            guard !stopped, !preparingSwitch, preparedSwitch == nil, completedAt == nil else {
                throw FixtureServerError.alreadyRunning
            }
            preparingSwitch = true
        }
        defer { completionLock.withLock { preparingSwitch = false } }
        let originalStreams = parsedStreams
        let originalDirectory = profileDirectory
        let originalText = preparedText
        let configuration = playbackConfiguration
        let preparation = Task.detached {
            let text = try HLSWebVTTFixture.prepare(directory: directory, configuration: configuration)
            let streams = Self.addingText(text, to: Self.parsedStreams(forProfileDirectory: directory))
            let originalMaster = try originalText?.resources["master.m3u8"] ?? Data(contentsOf: originalDirectory.appendingPathComponent("master.m3u8"))
            let nextMaster = try text?.resources["master.m3u8"] ?? Data(contentsOf: directory.appendingPathComponent("master.m3u8"))
            guard originalMaster == nextMaster, (originalText == nil) == (text == nil),
                  !FileManager.default.fileExists(atPath: originalDirectory.appendingPathComponent("__jp_media").path),
                  Set(streams.keys) == Set(originalStreams.keys), !streams.isEmpty else {
                throw FixtureServerError.completionRequiresLiveLoop
            }
            var commonDuration: Double?
            for (path, source) in originalStreams {
                try Task.checkCancellation()
                guard let next = streams[path], source.supportsLifecycle, next.supportsLifecycle,
                      !(path as NSString).deletingLastPathComponent.isEmpty,
                      source.parsed.targetDuration == next.parsed.targetDuration,
                      source.parsed.segments.count == next.parsed.segments.count,
                      let duration = source.parsed.segments.first?.duration,
                      originalText != nil || commonDuration == nil || commonDuration == duration,
                      (source.parsed.segments + next.parsed.segments).allSatisfy({
                          (originalText != nil || $0.duration == duration) && $0.keyLine == nil && !$0.hasDiscontinuityBefore
                              && !$0.uri.contains("/") && !$0.uri.contains("?") && !$0.uri.contains("..")
                      }) else { throw FixtureServerError.completionRequiresLiveLoop }
                commonDuration = duration
                if originalText != nil, source.parsed.segments.map(\.duration) != next.parsed.segments.map(\.duration) {
                    throw FixtureServerError.completionRequiresLiveLoop
                }
            }
            return PreparedSwitch(id: id, directory: directory, streams: streams, text: text)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        try validateLiveLifecycle()
        try completionLock.withLock {
            guard !stopped, preparedSwitch == nil, completedAt == nil else { throw FixtureServerError.alreadyRunning }
            preparedSwitch = prepared
        }
    }

    func switchPrepared(id: UUID) throws {
        try completionLock.withLock {
            guard !stopped, preparedSwitch?.id == id, completedAt == nil, switchSequences.isEmpty else {
                throw FixtureServerError.completionRequiresLiveLoop
            }
            let instant = clock()
            switchSequences = parsedStreams.mapValues { stream in
                let initial = playbackConfiguration.effectiveTimeShiftMode == .coldDVR ? 0 : playbackConfiguration.windowSegmentCount
                let next = initial + HLSSlidingPlaylistComputer.completedSegmentCount(
                    elapsed: max(0, instant.timeIntervalSince(publicationStart(stream))), startingAtVirtualIndex: initial,
                    segments: stream.parsed.segments)
                // Caption packs switch at a shared cycle boundary: AAC packet grids retain
                // their authored durations and are never falsely relabeled as video durations.
                if let preparedText {
                    let count = stream.parsed.segments.count
                    let logicalNext = initial + Int(max(0, instant.timeIntervalSince(startedAt)) / preparedText.segmentDuration)
                    return ((logicalNext + count - 1) / count) * count
                }
                return next
            }
        }
    }

    /// Freezes publication, not the fixture server. Already advertised media remains available
    /// until the owning run stops. The shared instant keeps alternate rendition clocks aligned.
    func completeLive() throws {
        try validateLiveLifecycle()
        try completionLock.withLock {
            guard !stopped else { throw FixtureServerError.notRunning }
            if completedAt == nil { completedAt = max(startedAt, clock()) }
        }
    }

    func validateLiveLifecycle() throws {
        guard playbackConfiguration.presentationMode == .liveLoop,
              playbackConfiguration.intent == .conformant,
              playbackConfiguration.jitPublicationState == nil,
              (1...64).contains(parsedStreams.count),
              parsedStreams.values.allSatisfy(\.supportsLifecycle) else {
            throw FixtureServerError.completionRequiresLiveLoop
        }
    }

    var completionTime: Date? { completionLock.withLock { completedAt } }
    var activePreparedMediaID: UUID? { completionLock.withLock { switchSequences.isEmpty ? nil : preparedSwitch?.id } }

    private func publicationWindow(_ stream: ParsedStream, path: String, now: Date) -> HLSSlidingPlaylistComputer.Window {
        let (end, prepared, cutoff) = completionLock.withLock { (completedAt, preparedSwitch, switchSequences[path]) }
        var window = HLSSlidingPlaylistComputer.window(segments: stream.parsed.segments,
            targetDuration: stream.parsed.targetDuration, startedAt: publicationStart(stream),
            now: end ?? now, configuration: playbackConfiguration)
        window.isComplete = end != nil
        if let prepared, let cutoff, let replacement = prepared.streams[path] {
            let directory = (path as NSString).deletingLastPathComponent
            let rootPrefix = String(repeating: "../", count: directory.split(separator: "/").count)
            let count = replacement.parsed.segments.count
            let entries = window.entries.map { entry -> HLSSlidingPlaylistComputer.WindowEntry in
                guard entry.virtualIndex >= cutoff else { return entry }
                let index = entry.virtualIndex - cutoff
                let segment = replacement.parsed.segments[index % count]
                return .init(segment: .init(uri: "\(rootPrefix)__jp_media/\(prepared.id.uuidString)/\(directory)/\(segment.uri)",
                    duration: segment.duration, hasDiscontinuityBefore: index == 0, keyLine: nil),
                    virtualIndex: entry.virtualIndex, isLoopBoundaryBefore: index > 0 && index % count == 0)
            }
            var discontinuities = window.discontinuitySequence
            if window.mediaSequence >= cutoff {
                let originalCount = stream.parsed.segments.count
                let previousLoops = max(0, cutoff - 1) / originalCount
                let newIndex = window.mediaSequence - cutoff
                discontinuities = previousLoops + (newIndex > 0 ? 1 : 0) + max(0, newIndex - 1) / count
            }
            window = .init(mediaSequence: window.mediaSequence, newestPublishedSequence: window.newestPublishedSequence,
                discontinuitySequence: discontinuities, targetDuration: window.targetDuration, entries: entries,
                firstSegmentProgramDateTime: window.firstSegmentProgramDateTime, configuration: window.configuration,
                isComplete: window.isComplete)
        }
        return window
    }

    private func publicationStart(_ stream: ParsedStream) -> Date {
        guard let preparedText, playbackConfiguration.effectiveTimeShiftMode != .coldDVR else { return startedAt }
        let count = playbackConfiguration.windowSegmentCount
        let actual = (0..<count).reduce(0.0) { $0 + stream.parsed.segments[$1 % stream.parsed.segments.count].duration }
        return startedAt.addingTimeInterval(actual - Double(count) * preparedText.segmentDuration)
    }

    var isRunning: Bool { serverChannel != nil }
    /// Current evaluation instant from the injected clock (tests freeze this; production uses `Date`).
    var currentTime: Date { clock() }
    var port: UInt16? {
        guard let port = serverChannel?.localAddress?.port else { return nil }
        return UInt16(exactly: port)
    }
    var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Synchronous constructor. Walks the profile directory on the calling actor — fine for tests.
    /// Production `startRun` uses ``make`` so the walk runs off the main actor.
    convenience init(
        profileDirectory: URL,
        startedAt: Date = Date(),
        playbackConfiguration: HLSPlaybackConfiguration = .legacyCompatible,
        clock: @escaping () -> Date = Date.init,
        group: MultiThreadedEventLoopGroup? = nil
    ) {
        self.init(
            profileDirectory: profileDirectory,
            startedAt: startedAt,
            playbackConfiguration: playbackConfiguration,
            clock: clock,
            group: group,
            preparsedStreams: nil
        )
    }

    /// Builds a server after parsing stream playlists off the calling actor via `Task.detached`.
    ///
    /// Concurrency: intended to be awaited from `@MainActor` `HLSFixtureRunStore.startRun` so
    /// directory I/O and playlist parsing do not block the main actor. Cancellation of the
    /// awaiting task cancels the bounded preparation, checked between files/tracks and before
    /// constructing network resources. Text compilation and source verification run here.
    static func make(
        profileDirectory: URL,
        startedAt: Date = Date(),
        playbackConfiguration: HLSPlaybackConfiguration = .legacyCompatible,
        clock: @escaping () -> Date = Date.init,
        group: MultiThreadedEventLoopGroup? = nil
    ) async throws -> HLSFixtureServer {
        let preparation = Task.detached(priority: .utility) {
            let text = try HLSWebVTTFixture.prepare(directory: profileDirectory, configuration: playbackConfiguration)
            return (Self.addingText(text, to: Self.parsedStreams(forProfileDirectory: profileDirectory)), text)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        return HLSFixtureServer(
            profileDirectory: profileDirectory,
            startedAt: startedAt,
            playbackConfiguration: playbackConfiguration,
            clock: clock,
            group: group,
            preparsedStreams: prepared.0,
            textPreparation: .success(prepared.1)
        )
    }

    private init(
        profileDirectory: URL,
        startedAt: Date,
        playbackConfiguration: HLSPlaybackConfiguration,
        clock: @escaping () -> Date,
        group: MultiThreadedEventLoopGroup?,
        preparsedStreams: [String: ParsedStream]?,
        textPreparation: Result<HLSWebVTTFixture.Prepared?, Error>? = nil
    ) {
        self.profileDirectory = profileDirectory
        self.startedAt = startedAt
        self.playbackConfiguration = playbackConfiguration
        self.clock = clock
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
        let preparation = textPreparation ?? Result { try HLSWebVTTFixture.prepare(directory: profileDirectory, configuration: playbackConfiguration) }
        var streams = preparsedStreams ?? Self.parsedStreams(forProfileDirectory: profileDirectory)
        switch preparation {
        case .success(let text):
            self.preparedText = text
            self.textPreparationFailure = nil
            if preparsedStreams == nil { streams = Self.addingText(text, to: streams) }
        case .failure(let error):
            self.preparedText = nil
            self.textPreparationFailure = error.localizedDescription
        }
        self.parsedStreams = streams
    }

    func start() async throws {
        guard !completionLock.withLock({ stopped }) else { throw FixtureServerError.notRunning }
        guard serverChannel == nil else { throw FixtureServerError.alreadyRunning }
        if let textPreparationFailure { throw FixtureServerError.invalidTextFixture(textPreparationFailure) }
        guard FileManager.default.fileExists(atPath: profileDirectory.path) else {
            throw FixtureServerError.profileDirectoryUnreadable
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(FixtureServerError.notRunning)
                }
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandlers([
                        IdleStateHandler(allTimeout: .seconds(30)),
                        HLSFixtureChannelHandler(server: self, connectionState: self.state)
                    ])
                }
            }

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            serverChannel = channel
        } catch {
            if ownsGroup { try? await group.shutdownGracefully() }
            throw FixtureServerError.bindFailed(String(describing: error))
        }
    }

    func stop() async {
        completionLock.withLock { stopped = true }
        try? await serverChannel?.close()
        serverChannel = nil
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    private static func addingText(_ text: HLSWebVTTFixture.Prepared?, to original: [String: ParsedStream]) -> [String: ParsedStream] {
        var streams = original
        for (path, bytes) in text?.resources ?? [:] where path != "master.m3u8" && path.hasSuffix(".m3u8") {
            streams[path] = .init(parsed: HLSStaticPlaylistParser.parse(String(decoding: bytes, as: UTF8.self)),
                authoredData: bytes, supportsLifecycle: true)
        }
        return streams
    }

    /// Walks `profileDirectory` for every `stream.m3u8` and parses playlists once.
    /// Safe to call from any isolation context (including `Task.detached`).
    private static func parsedStreams(forProfileDirectory profileDirectory: URL) -> [String: ParsedStream] {
        var streams: [String: ParsedStream] = [:]
        let enumerator = FileManager.default.enumerator(at: profileDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "stream.m3u8",
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let relativePath = url.path.hasPrefix(profileDirectory.path)
                ? String(url.path.dropFirst(profileDirectory.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : url.lastPathComponent
            let parsed = HLSStaticPlaylistParser.parse(text)
            streams[relativePath] = ParsedStream(parsed: parsed, authoredData: data,
                supportsLifecycle: data.count <= HLSFixtureLimits.maxRenderedPlaylistBytes
                    && !text.contains("#EXT-X-MAP:") && !text.contains("#EXT-X-BYTERANGE:")
                    && !text.contains("#EXT-X-PART:") && !parsed.segments.isEmpty
                    && parsed.segments.allSatisfy { $0.duration.isFinite && $0.duration > 0 })
        }
        return streams
    }

    /// Computes the response for one request path, entirely from immutable in-memory/on-disk
    /// fixture state — no network I/O, safe to call from the channel event loop.
    func response(forPath rawPath: String, method: String, rangeHeader: String?) -> HLSFixtureResponse {
        var response = resourceResponse(forPath: rawPath, method: method, rangeHeader: rangeHeader)
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasPrefix("__jp_media/") {
            response.textTrack = completionLock.withLock {
                guard let preparedSwitch, path.hasPrefix("__jp_media/\(preparedSwitch.id.uuidString)/") else { return nil }
                return preparedSwitch.text?.tracks[String(path.dropFirst("__jp_media/\(preparedSwitch.id.uuidString)/".count))]
            }
        } else { response.textTrack = preparedText?.tracks[path] }
        return response
    }

    private func resourceResponse(forPath rawPath: String, method: String, rangeHeader: String?) -> HLSFixtureResponse {
        guard !completionLock.withLock({ stopped }) else { return .init(status: 410, headers: [:], body: Data()) }
        guard textPreparationFailure == nil else { return .init(status: 503, headers: [:], body: Data()) }
        guard method == "GET" || method == "HEAD" else {
            return HLSFixtureResponse(status: 405, headers: ["Allow": "GET, HEAD"], body: Data())
        }
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty, isSafeRelativePath(relative) else {
            return HLSFixtureResponse(status: 404, headers: [:], body: Data())
        }

        // Validate publication before serving precompiled bytes. Text and video share the same
        // sequence clock; loop boundaries reset both timestamp domains without rewriting assets.
        let switched = relative.hasPrefix("__jp_media/")
            ? switchedAsset(rawPath: rawPath, relative: relative) : nil
        if relative.hasPrefix("__jp_media/"), switched == nil { return .init(status: 404, headers: [:], body: Data()) }
        if !relative.hasPrefix("__jp_media/"), rawPath.contains("jp_hls_sequence="),
           !isAvailableVirtualSegment(rawPath: rawPath, relativePath: relative, now: completionTime ?? clock()) {
            return .init(status: 404, headers: [:], body: Data())
        }
        if preparedText != nil, playbackConfiguration.presentationMode == .liveLoop,
           (relative.hasSuffix(".vtt") || relative.hasSuffix(".ts")), !rawPath.contains("jp_hls_sequence=") {
            return .init(status: 404, headers: [:], body: Data())
        }
        let pack = switched != nil ? completionLock.withLock { preparedSwitch?.text } : preparedText
        let resourcePath = switched?.1 ?? relative
        if let data = pack?.resources[resourcePath],
           relative == "master.m3u8" || !relative.hasSuffix(".m3u8") || playbackConfiguration.presentationMode == .vodStatic {
            var headers = ["Content-Type": Self.contentType(forPathExtension: (relative as NSString).pathExtension),
                           "Cache-Control": playbackConfiguration.cacheControlHeader,
                           "Accept-Ranges": "bytes"]
            if let hash = pack?.hashes[resourcePath] { headers["ETag"] = "\"\(hash)\"" }
            if let rangeHeader, let range = Self.parseSingleByteRange(rangeHeader, fileSize: data.count) {
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
                headers["Content-Length"] = "\(range.count)"
                return .init(status: 206, headers: headers, body: method == "HEAD" ? Data() : Data(data[range]))
            }
            headers["Content-Length"] = "\(data.count)"
            return .init(status: 200, headers: headers, body: method == "HEAD" ? Data() : data)
        }

        if let parsedStream = parsedStreams[relative] {
            if playbackConfiguration.presentationMode == .vodStatic {
                let body = method == "HEAD" ? Data() : parsedStream.authoredData
                return HLSFixtureResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/vnd.apple.mpegurl",
                        "Content-Length": "\(parsedStream.authoredData.count)",
                        "Cache-Control": playbackConfiguration.cacheControlHeader
                    ],
                    body: body
                )
            }
            let window = publicationWindow(parsedStream, path: relative, now: clock())
            let text = renderPlaylist(window)
            guard text.utf8.count <= HLSFixtureLimits.maxRenderedPlaylistBytes,
                  window.advertisedDuration <= HLSFixtureLimits.maxAdvertisedDurationSeconds else {
                return HLSFixtureResponse(status: 500, headers: [:], body: Data())
            }
            let body = method == "HEAD" ? Data() : Data(text.utf8)
            return HLSFixtureResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Content-Length": "\(text.utf8.count)",
                    "Cache-Control": playbackConfiguration.cacheControlHeader
                ],
                body: body
            )
        }

        var fileRoot = profileDirectory
        var fileRelative = relative
        if let pack {
            guard let mediaURL = pack.mediaFiles[resourcePath] else { return .init(status: 404, headers: [:], body: Data()) }
            fileRoot = mediaURL.deletingLastPathComponent()
            fileRelative = mediaURL.lastPathComponent
        }
        if let resolved = switched, pack == nil {
            fileRoot = resolved.0
            fileRelative = resolved.1
        }

        let fileURL = fileRoot.appendingPathComponent(fileRelative)
        guard let resolved = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              resolved.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize <= HLSFixtureLimits.maxServedFileBytes else {
            return HLSFixtureResponse(status: 404, headers: [:], body: Data())
        }

        let contentType = Self.contentType(forPathExtension: fileURL.pathExtension)
        if let rangeHeader, let range = Self.parseSingleByteRange(rangeHeader, fileSize: fileSize) {
            guard let full = try? Data(contentsOf: fileURL), range.upperBound <= full.count else {
                return HLSFixtureResponse(status: 500, headers: [:], body: Data())
            }
            let slice = full[range]
            let body = method == "HEAD" ? Data() : Data(slice)
            return HLSFixtureResponse(
                status: 206,
                headers: [
                    "Content-Type": contentType,
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileSize)",
                    "Content-Length": "\(range.count)",
                    "Accept-Ranges": "bytes"
                ],
                body: body
            )
        }

        let body: Data
        if method == "HEAD" {
            body = Data()
        } else {
            guard let loaded = try? Data(contentsOf: fileURL) else {
                return HLSFixtureResponse(status: 500, headers: [:], body: Data())
            }
            body = loaded
        }
        return HLSFixtureResponse(
            status: 200,
            headers: [
                "Content-Type": contentType,
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes"
            ],
            body: body
        )
    }

    /// Returns the sliding window ``response(forPath:method:rangeHeader:)`` would serve for a
    /// stream playlist, using the same path normalization and ``HLSSlidingPlaylistComputer/window``.
    ///
    /// - Parameters:
    ///   - rawPath: Relative or absolute-within-fixture path (e.g. `audio-en/stream.m3u8`).
    ///   - now: Instant to evaluate; defaults to the server's injected clock. Pass
    ///     `startedAt.addingTimeInterval(elapsed)` for deterministic previews.
    /// - Returns: `nil` when the path is unsafe, missing, or not a parsed stream playlist (masters
    ///   and segment files are not windows).
    func slidingWindow(forPath rawPath: String, now: Date? = nil) -> HLSSlidingPlaylistComputer.Window? {
        guard case .live(let window) = playlistPreview(forPath: rawPath, now: now) else { return nil }
        return window
    }

    func renderPlaylist(_ window: HLSSlidingPlaylistComputer.Window) -> String {
        HLSSlidingPlaylistComputer.render(window)
            .replacingOccurrences(of: "#EXT-X-VERSION:3", with: preparedText == nil ? "#EXT-X-VERSION:3" : "#EXT-X-VERSION:6")
    }

    /// Returns exact authored VOD text or the computed live window for a rendition playlist.
    /// Masters, segment files, missing paths, and unsafe paths return `nil`.
    func playlistPreview(forPath rawPath: String, now: Date? = nil) -> HLSFixturePlaylistPreview? {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty, isSafeRelativePath(relative),
              !completionLock.withLock({ stopped }),
              let parsedStream = parsedStreams[relative] else {
            return nil
        }
        if playbackConfiguration.presentationMode == .vodStatic {
            return .vod(
                parsed: parsedStream.parsed,
                playlistText: String(decoding: parsedStream.authoredData, as: UTF8.self)
            )
        }
        return .live(publicationWindow(parsedStream, path: relative, now: now ?? clock()))
    }

    func oldestRetainedButEvictedSequence(forPath rawPath: String, now: Date? = nil) -> Int? {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let parsedStream = parsedStreams[relative] else { return nil }
        let evaluationNow = completionTime ?? now ?? clock()
        let window = HLSSlidingPlaylistComputer.window(
            segments: parsedStream.parsed.segments,
            targetDuration: parsedStream.parsed.targetDuration,
            startedAt: publicationStart(parsedStream),
            now: evaluationNow,
            configuration: playbackConfiguration
        )
        if completionTime != nil || activePreparedMediaID != nil {
            return window.mediaSequence > 0 ? 0 : nil
        }
        return HLSSlidingPlaylistComputer.oldestRetainedButEvictedSequence(
            in: window,
            segments: parsedStream.parsed.segments,
            targetDuration: parsedStream.parsed.targetDuration,
            startedAt: publicationStart(parsedStream),
            now: evaluationNow
        )
    }

    private func isAvailableVirtualSegment(rawPath: String, relativePath: String, now: Date) -> Bool {
        guard let query = rawPath.split(separator: "?", maxSplits: 1).dropFirst().first,
              let sequenceItem = query.split(separator: "&").first(where: {
                  $0.hasPrefix("jp_hls_sequence=")
              }),
              let virtualIndex = Int(sequenceItem.dropFirst("jp_hls_sequence=".count)),
              virtualIndex >= 0 else {
            return false
        }

        for (streamPath, parsedStream) in parsedStreams {
            guard !parsedStream.parsed.segments.isEmpty else { continue }
            let streamDirectory = (streamPath as NSString).deletingLastPathComponent
            let sourceIndex = virtualIndex % parsedStream.parsed.segments.count
            guard parsedStream.parsed.segments.indices.contains(sourceIndex) else { continue }
            let sourceURI = parsedStream.parsed.segments[sourceIndex].uri
                .split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            let sourceRelativePath = URL(fileURLWithPath: "/\(streamDirectory)")
                .appendingPathComponent(sourceURI)
                .standardizedFileURL.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard sourceRelativePath == relativePath else { continue }
            let published = publicationWindow(parsedStream, path: streamPath, now: now)
            guard virtualIndex <= (published.newestPublishedSequence ?? Int.max) else { return false }
            if let cutoff = completionLock.withLock({ switchSequences[streamPath] }) {
                return virtualIndex < cutoff
            }
            if completionTime != nil {
                let finalWindow = publicationWindow(parsedStream, path: streamPath, now: now)
                return virtualIndex <= (finalWindow.newestPublishedSequence ?? -1)
            }
            switch HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: virtualIndex,
                segments: parsedStream.parsed.segments,
                targetDuration: parsedStream.parsed.targetDuration,
                startedAt: publicationStart(parsedStream),
                now: now,
                configuration: playbackConfiguration
            ) {
            case .advertised, .retainedAfterEviction:
                return true
            case .unavailable:
                return false
            }
        }
        return false
    }

    private func switchedAsset(rawPath: String, relative: String) -> (URL, String)? {
        let (prepared, cutoffs, end) = completionLock.withLock { (preparedSwitch, switchSequences, completedAt) }
        guard let prepared, relative.hasPrefix("__jp_media/\(prepared.id.uuidString)/"),
              let query = rawPath.split(separator: "?", maxSplits: 1).last,
              let item = query.split(separator: "&").first(where: { $0.hasPrefix("jp_hls_sequence=") }),
              let sequence = Int(item.dropFirst("jp_hls_sequence=".count)) else { return nil }
        let assetPath = String(relative.dropFirst("__jp_media/\(prepared.id.uuidString)/".count))
        for (path, cutoff) in cutoffs where sequence >= cutoff {
            guard let stream = prepared.streams[path], let original = parsedStreams[path] else { continue }
            let segment = stream.parsed.segments[(sequence - cutoff) % stream.parsed.segments.count]
            let directory = (path as NSString).deletingLastPathComponent
            guard assetPath == "\(directory)/\(segment.uri)" else { continue }
            let window = publicationWindow(original, path: path, now: end ?? clock())
            guard sequence <= (window.newestPublishedSequence ?? -1) else { return nil }
            return (prepared.directory, assetPath)
        }
        return nil
    }

    /// Rejects any path that would escape `profileDirectory` — `..` segments, absolute overrides
    /// via a leading `/` after normalization, or a symlink resolving outside the directory.
    private func isSafeRelativePath(_ relative: String) -> Bool {
        guard !relative.contains("..") else { return false }
        let candidate = profileDirectory.appendingPathComponent(relative).standardizedFileURL
        let base = profileDirectory.standardizedFileURL
        guard candidate.path.hasPrefix(base.path) else { return false }
        if let resolvedCandidate = try? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
           let resolvedBase = try? URL(fileURLWithPath: base.path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return resolvedCandidate.hasPrefix(resolvedBase)
        }
        return true
    }

    private static func contentType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "vtt": return "text/vtt; charset=utf-8"
        case "ts": return "video/mp2t"
        case "m4s", "mp4": return "video/mp4"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    /// Parses a single-range `Range: bytes=start-end` header (the only form HLS clients typically
    /// send). Multi-range and suffix-only (`bytes=-500`) forms fall through to a full 200 response
    /// rather than attempting partial support — a full response is always a correct answer to a
    /// Range request a server chooses not to honor.
    private static func parseSingleByteRange(_ header: String, fileSize: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < fileSize else { return nil }
        let end: Int
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = Int(parts[1]) {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}

/// A computed fixture HTTP response, decoupled from NIO types so `HLSFixtureServer.response(...)`
/// stays pure/testable without a running channel.
struct HLSFixtureResponse: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    var textTrack: HLSWebVTTFixture.TrackIdentity? = nil
}

private final class HLSFixtureConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeConnections = 0

    func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < HLSFixtureLimits.concurrentConnections else { return false }
        activeConnections += 1
        return true
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        activeConnections = max(0, activeConnections - 1)
    }
}

private final class HLSFixtureChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: HLSFixtureServer?
    private let connectionState: HLSFixtureConnectionState
    private var requestHead: HTTPRequestHead?
    private var isResponding = false
    private var trackedConnection = false

    init(server: HLSFixtureServer, connectionState: HLSFixtureConnectionState) {
        self.server = server
        self.connectionState = connectionState
    }

    func channelActive(context: ChannelHandlerContext) {
        trackedConnection = connectionState.tryBegin()
        if !trackedConnection {
            let response = HLSFixtureResponse(status: 503, headers: [:], body: Data("Too many connections".utf8))
            write(response, context: context, closeAfterWrite: true)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if trackedConnection {
            connectionState.end()
            trackedConnection = false
        }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard trackedConnection, !isResponding else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard NIOHTTPRequestHeaderSize.estimatedBytes(head) <= HLSFixtureLimits.maxRequestHeaderBytes else {
                isResponding = true
                write(HLSFixtureResponse(status: 431, headers: [:], body: Data()), context: context, closeAfterWrite: true)
                return
            }
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead, let server else {
                write(HLSFixtureResponse(status: 400, headers: [:], body: Data()), context: context, closeAfterWrite: true)
                return
            }
            isResponding = true
            let rangeHeader = head.headers["range"].first
            let response = server.response(forPath: head.uri, method: head.method.rawValue, rangeHeader: rangeHeader)
            write(response, context: context, closeAfterWrite: true)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        isResponding = true
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func write(_ response: HLSFixtureResponse, context: ChannelHandlerContext, closeAfterWrite: Bool) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers { headers.add(name: name, value: value) }
        if headers["Content-Length"].isEmpty {
            headers.add(name: "Content-Length", value: "\(response.body.count)")
        }
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            if closeAfterWrite { context.close(promise: nil) }
        }
    }

}
