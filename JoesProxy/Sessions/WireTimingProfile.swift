import Foundation

/// A bounded observation of one upstream channel read. Samples describe transport delivery, not
/// decoded media frames or application-level events.
struct WireChunkSample: Codable, Equatable, Sendable, Identifiable {
    let offset: TimeInterval
    let byteCount: Int

    var id: TimeInterval { offset }
}

struct WireTransferMetrics: Codable, Equatable, Sendable {
    let headerByteCount: Int
    let transferBodyByteCount: Int
    let decodedBodyByteCount: Int?
    let contentEncoding: String?

    var compressionRatio: Double? {
        guard let decodedBodyByteCount, decodedBodyByteCount > 0 else { return nil }
        return Double(transferBodyByteCount) / Double(decodedBodyByteCount)
    }

    var compressionSavingsFraction: Double? {
        guard let compressionRatio else { return nil }
        return max(0, 1 - compressionRatio)
    }
}

/// Persisted request-level timing evidence. Optional milestones mean “not observed”; the profiler
/// never invents DNS, TLS, or cache evidence that the active transport path did not expose.
struct WireTimingProfile: Codable, Equatable, Sendable {
    var connectionStartedAt: Date?
    var connectionEstablishedAt: Date?
    var tlsHandshakeCompletedAt: Date?
    var requestSendStartedAt: Date?
    var requestSentAt: Date?
    var firstResponseByteAt: Date?
    var responseCompletedAt: Date?
    var chunks: [WireChunkSample]
    var omittedChunkCount: Int
    var transfer: WireTransferMetrics?
    var transport: RequestTransportEvidence?

    init(
        connectionStartedAt: Date? = nil,
        connectionEstablishedAt: Date? = nil,
        tlsHandshakeCompletedAt: Date? = nil,
        requestSendStartedAt: Date? = nil,
        requestSentAt: Date? = nil,
        firstResponseByteAt: Date? = nil,
        responseCompletedAt: Date? = nil,
        chunks: [WireChunkSample] = [],
        omittedChunkCount: Int = 0,
        transfer: WireTransferMetrics? = nil
    ) {
        self.connectionStartedAt = connectionStartedAt
        self.connectionEstablishedAt = connectionEstablishedAt
        self.tlsHandshakeCompletedAt = tlsHandshakeCompletedAt
        self.requestSendStartedAt = requestSendStartedAt
        self.requestSentAt = requestSentAt
        self.firstResponseByteAt = firstResponseByteAt
        self.responseCompletedAt = responseCompletedAt
        self.chunks = chunks
        self.omittedChunkCount = omittedChunkCount
        self.transfer = transfer
    }
}

enum WireTimingPhase: String, CaseIterable, Identifiable, Sendable {
    case connect
    case tls
    case requestSend
    case wait
    case contentDownload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "DNS + Connect"
        case .tls: return "TLS"
        case .requestSend: return "Request Send"
        case .wait: return "Wait (TTFB)"
        case .contentDownload: return "Content Download"
        }
    }
}

struct WireTimingPhaseMeasurement: Identifiable, Equatable, Sendable {
    let phase: WireTimingPhase
    let startOffset: TimeInterval
    let duration: TimeInterval

    var id: WireTimingPhase { phase }
}

enum WireCacheDisposition: String, Equatable, Sendable {
    case hit
    case miss
    case unknown
}

enum WireWaterfallAnalyzer {
    static func phases(for timing: SessionTiming) -> [WireTimingPhaseMeasurement] {
        guard let profile = timing.wireProfile else { return [] }
        let origin = timing.startedAt
        var result: [WireTimingPhaseMeasurement] = []

        appendPhase(.connect, from: profile.connectionStartedAt, to: profile.connectionEstablishedAt, origin: origin, into: &result)
        appendPhase(.tls, from: profile.connectionEstablishedAt, to: profile.tlsHandshakeCompletedAt, origin: origin, into: &result)
        appendPhase(.requestSend, from: profile.requestSendStartedAt, to: profile.requestSentAt, origin: origin, into: &result)
        appendPhase(.wait, from: profile.requestSentAt, to: profile.firstResponseByteAt, origin: origin, into: &result)
        appendPhase(.contentDownload, from: profile.firstResponseByteAt, to: profile.responseCompletedAt, origin: origin, into: &result)
        return result
    }

    static func cacheDisposition(headers: [HTTPHeaderField]) -> WireCacheDisposition {
        let values = headers.compactMap { header -> String? in
            let name = header.name.lowercased()
            guard name == "cache-status" || name == "x-cache" || name == "age" else { return nil }
            return header.value.lowercased()
        }
        if values.contains(where: { $0.contains("hit") || (Int($0) ?? 0) > 0 }) { return .hit }
        if values.contains(where: { $0.contains("miss") }) { return .miss }
        return .unknown
    }

    static func stalledChunkIndices(profile: WireTimingProfile, threshold: TimeInterval) -> Set<Int> {
        guard threshold > 0 else { return [] }
        return Set(profile.chunks.indices.filter { index in
            guard index > profile.chunks.startIndex else { return false }
            return profile.chunks[index].offset - profile.chunks[index - 1].offset > threshold
        })
    }

    private static func appendPhase(
        _ phase: WireTimingPhase,
        from start: Date?,
        to end: Date?,
        origin: Date,
        into result: inout [WireTimingPhaseMeasurement]
    ) {
        guard let start, let end, end >= start else { return }
        result.append(
            WireTimingPhaseMeasurement(
                phase: phase,
                startOffset: max(0, start.timeIntervalSince(origin)),
                duration: end.timeIntervalSince(start)
            )
        )
    }
}
