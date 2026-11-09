import CryptoKit
import Combine
import Foundation

/// Serial parsing outside the main actor. Cache identity includes actual bytes, not their length.
actor MediaManifestCache {
    struct Result: Sendable {
        var hls: [ParsedHLSManifestSession] = []
        var dash: [ParsedDASHManifestSession] = []
        var omittedCount = 0
    }
    private struct Entry {
        let digest: String
        let result: Result
        let decodedCost: Int
    }
    private var entries: [UUID: Entry] = [:]
    private(set) var parseCount = 0

    func parse(_ sessions: [SessionRecord]) -> Result {
        guard !Task.isCancelled else { return Result() }
        let retained = Set(sessions.map(\.id))
        entries = entries.filter { retained.contains($0.key) }
        var result = Result()
        var remainingBytes = 16 * 1_024 * 1_024
        for session in sessions {
            guard !Task.isCancelled else { return result }
            guard let response = session.response, let raw = response.bodyData else {
                entries[session.id] = nil
                continue
            }
            let kind = MediaDetector.mediaType(for: session)
            guard kind == .hls || kind == .dash else {
                entries[session.id] = nil
                continue
            }
            let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
                + String(describing: response.headers) + session.request.host + session.request.path
            if let cached = entries[session.id], cached.digest == digest {
                guard cached.decodedCost <= remainingBytes else {
                    entries[session.id] = nil
                    result.omittedCount += 1
                    continue
                }
                remainingBytes -= cached.decodedCost
                result.hls += cached.result.hls; result.dash += cached.result.dash
                continue
            }
            var parsed = Result()
            guard remainingBytes > 0,
                  let decoded = CapturedBodyDecoder.decode(response: response,
                    maxDecodedBytes: min(2 * 1_024 * 1_024, remainingBytes)),
                  decoded.canUseAnalysisDataForInspection,
                  let text = String(data: decoded.analysisData, encoding: .utf8) else {
                entries[session.id] = nil
                result.omittedCount += 1
                continue
            }
            let cost = decoded.analysisData.count
            remainingBytes -= cost
            do {
                parseCount += 1
                if kind == .hls {
                    parsed.hls = [.init(sessionID: session.id, host: session.request.host, path: session.request.path,
                        manifest: HLSParser.parse(text, baseURL: MediaDetector.absoluteURL(for: session.request)))]
                } else if let manifest = DASHParser.parse(text) {
                    parsed.dash = [.init(sessionID: session.id, host: session.request.host, path: session.request.path,
                        manifestURL: MediaDetector.absoluteURL(for: session.request), manifest: manifest)]
                }
            }
            entries[session.id] = Entry(digest: digest, result: parsed, decodedCost: cost)
            result.hls += parsed.hls; result.dash += parsed.dash
        }
        return result
    }
}

/// One running parse and one replaceable pending snapshot; rapid view updates cannot queue jobs.
@MainActor
final class MediaManifestModel: ObservableObject {
    @Published private(set) var result = MediaManifestCache.Result()
    private var cache = MediaManifestCache()
    private var pending: (UInt64, [SessionRecord])?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func request(_ sessions: [SessionRecord]) {
        generation &+= 1
        pending = (generation, sessions)
        guard worker == nil else { return }
        worker = Task {
            while let (version, records) = pending {
                pending = nil
                let parsed = await cache.parse(records)
                if version == generation { result = parsed }
            }
            worker = nil
        }
    }

    func cancelPending() {
        generation &+= 1
        pending = nil
    }

    /// Retires capture-owned parsed data even when the inspection window is closed.
    /// An already-running parse may finish, but its generation cannot publish stale data.
    func reset() {
        cancelPending()
        result = MediaManifestCache.Result()
        cache = MediaManifestCache()
    }

    func waitForPendingWork() async {
        await worker?.value
    }
}
