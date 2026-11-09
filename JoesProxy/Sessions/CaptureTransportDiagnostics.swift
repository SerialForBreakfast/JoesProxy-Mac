//
//  CaptureTransportDiagnostics.swift
//  JoesProxy
//
//  Thread-safe transport counters aggregated into shareable long-capture summaries (AD-2/AD-3).
//

import Foundation

enum CaptureRequestProgressStage: String, CaseIterable, Sendable {
    case routingStarted, upstreamStarted, responseHead, responseComplete, responseFailed
}

struct CaptureRequestProgress: Equatable, Sendable {
    var count: UInt64 = 0
    var lastObservedAt: Date?
}

/// Point-in-time transport diagnostics for `capture_summary` emission.
struct CaptureTransportDiagnosticsSnapshot: Equatable, Sendable {
    let activeProxyChannels: Int
    let upstreamResponseBytesForwarded: Int
    let expectedClientDisconnectCount: Int
    let unexpectedChannelErrorCount: Int
    let expectedClientWriteFailureCount: Int
    let unexpectedClientWriteFailureCount: Int
    let leafCertCacheHits: Int
    let leafCertCacheMisses: Int
    var captureAdmission: CaptureAdmissionBudget.Snapshot? = nil
    var uploadActiveSpools = 0
    var uploadPeakSpools = 0
    var uploadStorageNeedsRecovery = false
    var requestProgress: [CaptureRequestProgressStage: CaptureRequestProgress] = [:]

    static let empty = CaptureTransportDiagnosticsSnapshot(
        activeProxyChannels: 0,
        upstreamResponseBytesForwarded: 0,
        expectedClientDisconnectCount: 0,
        unexpectedChannelErrorCount: 0,
        expectedClientWriteFailureCount: 0,
        unexpectedClientWriteFailureCount: 0,
        leafCertCacheHits: 0,
        leafCertCacheMisses: 0
    )
}

/// Lock-protected counters updated from NIO handlers and certificate issuance.
///
/// Concurrency: safe to call from any thread; `snapshot()` and `reset()` are serialized.
final class CaptureTransportDiagnostics: @unchecked Sendable {
    // Metadata only; accepted capture IDs are attached asynchronously, never awaited by forwarding.
    private var requestEvidence: [UUID: RequestTransportDiagnostics] = [:]
    private var requestEvidenceOrder: [UUID] = []
    private var evidenceEpoch = UUID()
    var requestEvidenceEpoch: UUID { lock.withLock { evidenceEpoch } }

    func observeRequest(id: UUID, diagnostics: RequestTransportDiagnostics, epoch: UUID? = nil) {
        lock.withLock {
            guard epoch == nil || epoch == evidenceEpoch else { return }
            if requestEvidence[id] == nil { requestEvidenceOrder.append(id) }
            requestEvidence[id] = diagnostics
            while requestEvidenceOrder.count > 256 {
                requestEvidence.removeValue(forKey: requestEvidenceOrder.removeFirst())
            }
        }
    }

    func evidence(for id: UUID) -> RequestTransportEvidence? {
        let diagnostics = lock.withLock { requestEvidence[id] }
        return diagnostics?.snapshot()
    }

    private let lock = NSLock()
    private var activeProxyChannels = 0
    private var upstreamResponseBytesForwarded = 0
    private var expectedClientDisconnectCount = 0
    private var unexpectedChannelErrorCount = 0
    private var expectedClientWriteFailureCount = 0
    private var unexpectedClientWriteFailureCount = 0
    private var leafCertCacheHits = 0
    private var leafCertCacheMisses = 0
    private var admissionBudget: CaptureAdmissionBudget?
    private var uploadSpoolService: UploadSpoolService?
    private var requestProgress: [CaptureRequestProgressStage: CaptureRequestProgress] = [:]

    /// Fixed-cardinality aggregate evidence, including uncaptured traffic. No request content or IDs.
    /// Stages are not per-request correlation and completion is not downstream/client acceptance.
    func recordProgress(_ stage: CaptureRequestProgressStage, at date: Date = Date()) {
        lock.withLock {
            var progress = requestProgress[stage, default: CaptureRequestProgress()]
            progress.count &+= 1
            progress.lastObservedAt = max(progress.lastObservedAt ?? date, date)
            requestProgress[stage] = progress
        }
    }

    func observeUploads(_ service: UploadSpoolService) {
        lock.withLock { uploadSpoolService = service }
    }

    func observeAdmission(_ budget: CaptureAdmissionBudget) {
        lock.lock()
        admissionBudget = budget
        lock.unlock()
    }

    func recordChannelOpened() {
        lock.lock()
        activeProxyChannels += 1
        lock.unlock()
    }

    func recordChannelClosed() {
        lock.lock()
        activeProxyChannels = max(0, activeProxyChannels - 1)
        lock.unlock()
    }

    func recordUpstreamResponseBytes(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.lock()
        upstreamResponseBytesForwarded += byteCount
        lock.unlock()
    }

    func recordExpectedClientDisconnect() {
        lock.lock()
        expectedClientDisconnectCount += 1
        lock.unlock()
    }

    func recordUnexpectedChannelError() {
        lock.lock()
        unexpectedChannelErrorCount += 1
        lock.unlock()
    }

    func recordExpectedClientWriteFailure() {
        lock.lock()
        expectedClientWriteFailureCount += 1
        lock.unlock()
    }

    func recordUnexpectedClientWriteFailure() {
        lock.lock()
        unexpectedClientWriteFailureCount += 1
        lock.unlock()
    }

    /// Returns the new hit count after incrementing (used for sampled debug logging).
    @discardableResult
    func recordLeafCertCacheHit() -> Int {
        lock.lock()
        leafCertCacheHits += 1
        let total = leafCertCacheHits
        lock.unlock()
        return total
    }

    func recordLeafCertCacheMiss() {
        lock.lock()
        leafCertCacheMisses += 1
        lock.unlock()
    }

    func snapshot() -> CaptureTransportDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = CaptureTransportDiagnosticsSnapshot(
            activeProxyChannels: activeProxyChannels,
            upstreamResponseBytesForwarded: upstreamResponseBytesForwarded,
            expectedClientDisconnectCount: expectedClientDisconnectCount,
            unexpectedChannelErrorCount: unexpectedChannelErrorCount,
            expectedClientWriteFailureCount: expectedClientWriteFailureCount,
            unexpectedClientWriteFailureCount: unexpectedClientWriteFailureCount,
            leafCertCacheHits: leafCertCacheHits,
            leafCertCacheMisses: leafCertCacheMisses
        )
        result.captureAdmission = admissionBudget?.snapshot
        result.requestProgress = requestProgress
        result.uploadActiveSpools = uploadSpoolService?.budget.activeCount ?? 0
        result.uploadPeakSpools = uploadSpoolService?.budget.peakCount ?? 0
        result.uploadStorageNeedsRecovery = uploadSpoolService?.needsCleanup ?? false
        return result
    }

    func reset() {
        lock.lock()
        evidenceEpoch = UUID()
        requestEvidence = [:]
        requestEvidenceOrder = []
        activeProxyChannels = 0
        requestProgress = [:]
        upstreamResponseBytesForwarded = 0
        expectedClientDisconnectCount = 0
        unexpectedChannelErrorCount = 0
        expectedClientWriteFailureCount = 0
        unexpectedClientWriteFailureCount = 0
        leafCertCacheHits = 0
        leafCertCacheMisses = 0
        lock.unlock()
    }
}
