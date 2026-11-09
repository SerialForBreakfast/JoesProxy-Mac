import Foundation

/// Bounded worker result, not proof of downstream delivery or client acceptance.
struct LiveCollectionTransformationResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case applied(beforeCount: Int, afterCount: Int)
        case alreadyPresent
        case ineligibleResponse
        case unsupportedEncoding
        case sizeLimit
        case decodeFailed
        case contractMismatch(CollectionMockError)
        case encodingFailed
        case capacityLimited
        case inactiveRevision
        case cancelled

        var evidenceCode: String {
            switch self {
            case .applied: return "applied"
            case .alreadyPresent: return "alreadyPresent"
            case .ineligibleResponse: return "ineligibleResponse"
            case .unsupportedEncoding: return "unsupportedEncoding"
            case .sizeLimit: return "sizeLimit"
            case .decodeFailed: return "decodeFailed"
            case .contractMismatch: return "contractMismatch"
            case .encodingFailed: return "encodingFailed"
            case .capacityLimited: return "capacityLimited"
            case .inactiveRevision: return "inactiveRevision"
            case .cancelled: return "cancelled"
            }
        }
    }

    let body: Data
    let headers: [HTTPHeaderField]
    let outcome: Outcome
}

extension LiveResponseTransformation {
    /// CPU work only. Invoke off the main actor and network event loops. Never mutates the input.
    static func transformCollection(method: String, statusCode: Int, headers: [HTTPHeaderField],
                                    body: Data, plan: CompiledCollectionMock) -> LiveCollectionTransformationResult {
        func skipped(_ outcome: LiveCollectionTransformationResult.Outcome) -> LiveCollectionTransformationResult {
            .init(body: body, headers: headers, outcome: outcome)
        }
        guard method.uppercased() == "GET", (200..<300).contains(statusCode),
              statusCode != 204, statusCode != 205, statusCode != 206,
              !headers.contains(where: { $0.name.lowercased() == "content-range" }) else {
            return skipped(.ineligibleResponse)
        }
        let encodings = headers.filter { $0.name.lowercased() == "content-encoding" }
            .flatMap { $0.value.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard encodings.isEmpty || encodings == ["identity"] || encodings == ["gzip"] || encodings == ["x-gzip"] else {
            return skipped(.unsupportedEncoding)
        }
        let limit = CollectionMockCompiler.maximumBodyBytes
        guard body.count <= limit else { return skipped(.sizeLimit) }
        guard let decoded = CapturedBodyDecoder.decode(bodyData: body, headers: headers, maxDecodedBytes: limit) else {
            return skipped(.decodeFailed)
        }
        if case .limitExceeded = decoded.status { return skipped(.sizeLimit) }
        guard decoded.canUseAnalysisDataForInspection else { return skipped(.decodeFailed) }
        guard !Task.isCancelled else { return skipped(.cancelled) }
        do {
            switch try CollectionMockCompiler.apply(source: decoded.analysisData, plan: plan) {
            case .alreadyPresent:
                return skipped(.alreadyPresent)
            case .applied(let changed, let before, let after):
                let isGzip = encodings == ["gzip"] || encodings == ["x-gzip"]
                guard let wire = isGzip ? gzipCompress(changed) : changed else { return skipped(.encodingFailed) }
                guard wire.count <= limit else { return skipped(.sizeLimit) }
                guard !Task.isCancelled else { return skipped(.cancelled) }
                return .init(body: wire,
                    headers: reconcileHeadersAfterMutation(headers, newBodyData: wire, reencodedAsGzip: isGzip),
                    outcome: .applied(beforeCount: before, afterCount: after))
            }
        } catch let error as CollectionMockError {
            return skipped(error == .sizeLimit ? .sizeLimit : .contractMismatch(error))
        } catch {
            return skipped(.contractMismatch(.invalidJSON))
        }
    }
}

/// Revision isolation for live collection transforms. Admission is deliberately owned by
/// `MutationBufferBudget` at the streaming boundary: this type never queues or limits workers.
/// Workers run outside the caller's actor and event-loop context. A result must still be checked
/// at the downstream handoff; this type does not own socket writes.
final class LiveCollectionTransformationExecutor: @unchecked Sendable {
    struct Revision: Equatable, Sendable {
        let effectID: UUID
        let generation: UUID
        var phase: EffectBundleActivationGate.PhaseIdentity? = nil
        var observation: EffectBundleObservation.Identity? = nil
    }

    typealias Worker = @Sendable (String, Int, [HTTPHeaderField], Data, CompiledCollectionMock) async -> LiveCollectionTransformationResult

    private struct Registration {
        let revision: Revision
        let plan: CompiledCollectionMock
        let byteCount: Int
        let bundleGate: EffectBundleActivationGate?
        let bundleID: UUID?

        // Matching owns phase admission. Admitted work may finish in its original phase, but
        // closing/removing the owning bundle invalidates it even before rule teardown completes.
        var permitsCompletion: Bool {
            guard let bundleID else { return true }
            return bundleGate?.allows(bundleID: bundleID) == true
        }
    }

    private let lock = NSLock()
    private var revisions: [UUID: Registration] = [:]
    private let worker: Worker

    init(worker: @escaping Worker = { method, status, headers, body, plan in
        LiveResponseTransformation.transformCollection(method: method, statusCode: status,
            headers: headers, body: body, plan: plan)
    }) {
        self.worker = worker
    }

    /// Activates a fresh revision. Replacing a plan invalidates any outstanding worker result for
    /// the prior revision; callers must continue delivering those original bytes fail-open.
    func begin(effectID: UUID, plan: CompiledCollectionMock, bundleGate: EffectBundleActivationGate? = nil) -> Revision? {
        lock.lock()
        defer { lock.unlock() }
        guard revisions[effectID] != nil || revisions.count < EffectBundleBudget.maxResponseEffectCount else { return nil }
        guard let bytes = try? JSONEncoder().encode(plan),
              bytes.count <= CollectionMockCompiler.maximumBodyBytes else { return nil }
        let otherBytes = revisions.values.reduce(0) { $0 + $1.byteCount } - (revisions[effectID]?.byteCount ?? 0)
        guard bytes.count <= 20 * 1_024 * 1_024 - otherBytes else { return nil }
        let revision = Revision(effectID: effectID, generation: UUID(), phase: bundleGate?.phaseIdentity(ruleID: effectID),
            observation: bundleGate?.observationIdentity(resourceID: effectID, requireOpen: false))
        revisions[effectID] = Registration(revision: revision, plan: plan, byteCount: bytes.count,
            bundleGate: bundleGate, bundleID: bundleGate?.bundleID(responseRuleID: effectID))
        return revision
    }

    func stop(effectID: UUID) {
        lock.lock()
        revisions.removeValue(forKey: effectID)
        lock.unlock()
    }

    func currentRevision(effectID: UUID) -> Revision? {
        lock.lock()
        defer { lock.unlock() }
        return revisions[effectID]?.revision
    }

    func isCurrent(_ revision: Revision) -> Bool {
        let registration = lock.withLock { revisions[revision.effectID] }
        return registration?.revision == revision
            && registration?.permitsCompletion == true
    }

    func transform(revision: Revision, method: String, statusCode: Int, headers: [HTTPHeaderField],
                   body: Data) async -> LiveCollectionTransformationResult {
        func skipped(_ outcome: LiveCollectionTransformationResult.Outcome) -> LiveCollectionTransformationResult {
            .init(body: body, headers: headers, outcome: outcome)
        }
        guard !Task.isCancelled else { return skipped(.cancelled) }
        let registration = lock.withLock { revisions[revision.effectID] }
        guard let registration, registration.revision == revision,
              registration.permitsCompletion else {
            return skipped(.inactiveRevision)
        }
        guard body.count <= CollectionMockCompiler.maximumBodyBytes else { return skipped(.sizeLimit) }
        // A caller may be an NIO event loop or the main actor. Always detach the actual worker
        // from that caller so custom workers receive the same off-loop guarantee as the default
        // JSON/gzip implementation. The inputs are immutable value types captured above.
        let worker = self.worker
        let workerTask = Task.detached {
            await worker(method, statusCode, headers, body, registration.plan)
        }
        let result = await withTaskCancellationHandler(
            operation: { await workerTask.value },
            onCancel: { workerTask.cancel() }
        )
        guard !Task.isCancelled else { return skipped(.cancelled) }
        guard isCurrent(revision) else { return skipped(.inactiveRevision) }
        return result
    }
}
