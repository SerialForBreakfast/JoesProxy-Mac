import Foundation

/// Fixed-size metadata; no payloads, hosts, chunks or per-event logs. Durations use uptime.
struct RequestTransportEvidence: Codable, Equatable, Sendable {
    var upstreamProtocol = "http1"
    var connectionReused = false
    var captureEnabled: Bool?
    var captureBodyLimit: Int?
    var intentionalThrottleObserved = false
    var responseMutationConfigured = false
    var tlsNegotiatedProtocol: String?
    var connectSeconds: Double?
    var tlsReadySeconds: Double?
    var firstUpstreamByteSeconds: Double?
    var lastUpstreamByteSeconds: Double?
    var maximumUpstreamReadGapSeconds: Double = 0
    var firstDownstreamSubmissionSeconds: Double?
    var lastDownstreamCompletionSeconds: Double?
    var pendingWrites = 0
    var peakPendingBytes = 0
    var bytesSubmitted = 0
    var bytesWriteCompleted = 0
    var failedWrites = 0
    var relayOutstandingSeconds: Double = 0
    var maximumRelayDispatchSeconds: Double = 0
    var observedReadPausedSeconds: Double = 0
    var readsCurrentlyPaused = false
    var aggregatePressureObserved = false
    var socketBackpressureObserved = false
    var deliveryState = "not_observed"
    var failureReason: String?
    var coverage = "intercepted_http1; read_gaps_include_local_backpressure; pause_reasons_are_observations_not_exclusive_causal_durations; DNS_and_connect_combined; socket_write_is_not_player_delivery"
}

/// Cross-loop callbacks only touch this locked, constant-space accumulator. It never schedules work.
final class RequestTransportDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let started: UInt64
    private var evidence = RequestTransportEvidence()
    private var pendingBytes = 0
    private var busySince: Double?
    private var pausedSince: Double?

    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) { started = now }

    private func offset(_ now: UInt64) -> Double {
        Double(now >= started ? now - started : 0) / 1_000_000_000
    }

    func configureCapture(enabled: Bool, bodyLimit: Int, mutationConfigured: Bool = false) {
        lock.withLock {
            evidence.captureEnabled = enabled
            evidence.captureBodyLimit = enabled ? bodyLimit : 0
            evidence.responseMutationConfigured = mutationConfigured
        }
    }

    func readPaused(aggregatePressure: Bool, socketBackpressure: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            if pausedSince == nil { pausedSince = offset(now) }
            evidence.readsCurrentlyPaused = true
            evidence.aggregatePressureObserved = evidence.aggregatePressureObserved || aggregatePressure
            evidence.socketBackpressureObserved = evidence.socketBackpressureObserved || socketBackpressure
        }
    }

    func readsResumedOrClosed(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            if let pausedSince { evidence.observedReadPausedSeconds += max(0, offset(now) - pausedSince) }
            pausedSince = nil
            evidence.readsCurrentlyPaused = false
        }
    }

    func dispatched(submittedAt: UInt64, throttled: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            evidence.maximumRelayDispatchSeconds = max(evidence.maximumRelayDispatchSeconds,
                Double(now >= submittedAt ? now - submittedAt : 0) / 1_000_000_000)
            evidence.intentionalThrottleObserved = evidence.intentionalThrottleObserved || throttled
        }
    }

    func connected(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock { evidence.connectSeconds = offset(now) }
    }

    func tlsReady(protocolName: String?, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            evidence.tlsReadySeconds = offset(now)
            evidence.tlsNegotiatedProtocol = protocolName.map { String($0.prefix(32)) }
        }
    }

    func upstreamRead(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            let time = offset(now)
            if let previous = evidence.lastUpstreamByteSeconds {
                evidence.maximumUpstreamReadGapSeconds = max(evidence.maximumUpstreamReadGapSeconds, time - previous)
            }
            if evidence.firstUpstreamByteSeconds == nil { evidence.firstUpstreamByteSeconds = time }
            evidence.lastUpstreamByteSeconds = time
        }
    }

    func submitted(bytes: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            let time = offset(now)
            if evidence.firstDownstreamSubmissionSeconds == nil { evidence.firstDownstreamSubmissionSeconds = time }
            if evidence.pendingWrites == 0 { busySince = time }
            evidence.pendingWrites += 1
            pendingBytes += bytes
            evidence.peakPendingBytes = max(evidence.peakPendingBytes, pendingBytes)
            evidence.bytesSubmitted += bytes
            evidence.deliveryState = "pending"
        }
    }

    func completed(bytes: Int, succeeded: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            guard evidence.pendingWrites > 0 else { return }
            let time = offset(now)
            evidence.pendingWrites -= 1
            pendingBytes -= bytes
            if succeeded { evidence.bytesWriteCompleted += bytes } else { evidence.failedWrites += 1 }
            evidence.lastDownstreamCompletionSeconds = time
            if evidence.pendingWrites == 0 {
                evidence.relayOutstandingSeconds += max(0, time - (busySince ?? time))
                busySince = nil
                evidence.deliveryState = evidence.failedWrites == 0 ? "writes_completed" : "write_failed"
            }
        }
    }

    func snapshot(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> RequestTransportEvidence {
        lock.withLock {
            var result = evidence
            if let busySince { result.relayOutstandingSeconds += max(0, offset(now) - busySince) }
            if let pausedSince { result.observedReadPausedSeconds += max(0, offset(now) - pausedSince) }
            return result
        }
    }

    func failed(error: Error) {
        lock.withLock {
            guard evidence.failureReason == nil else { return }
            switch error {
            case HTTPResponseParserError.incompleteResponse: evidence.failureReason = "upstream_response_incomplete"
            case HTTPResponseParserError.invalidChunkFraming: evidence.failureReason = "upstream_chunk_framing_invalid"
            case HTTPResponseParserError.invalidStatusLine: evidence.failureReason = "upstream_headers_invalid"
            default:
                evidence.failureReason = evidence.connectSeconds == nil ? "upstream_connect_failed" : "transport_failed"
            }
        }
    }
}
