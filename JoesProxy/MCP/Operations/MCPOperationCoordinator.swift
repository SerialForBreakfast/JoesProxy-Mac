import Combine
import Foundation

@MainActor
final class MCPOperationCoordinator: ObservableObject {
    static let maximumActivePerClient = 1
    static let maximumActiveGlobally = 2
    static let completedRetention: TimeInterval = 10 * 60
    static let expiredTombstoneRetention: TimeInterval = 60
    static let maximumCompletedPerClient = 32
    static let operationTimeout: TimeInterval = 60

    @Published private(set) var activeAnalysisCount = 0
    @Published private(set) var activeOperations: [MCPOperationDescriptorDTO] = []

    private struct Record {
        var ownerClientID: String
        var ownerSessionID: String
        var captureEpoch: MCPCaptureEpoch
        var policyRevision: MCPPolicyRevision
        var capability: MCPCapabilityID
        var argumentDigest: String
        var sourceSessionID: SessionRecord.ID
        var descriptor: MCPOperationDescriptorDTO
        var stageStartedAt: Date?
        var task: Task<Void, Never>?
    }

    private var records: [String: Record] = [:]
    private var sessionChangesCancellable: AnyCancellable?
    private let mediaService: any MCPMediaOperationServicing
    private let liveProbeService: any MCPLiveProbeServicing
    private let snapshotService: MCPSessionSnapshotService
    private let policyStore: MCPPolicyStore
    private let auditStore: MCPAuditStore
    private let notificationHub: MCPNotificationHub?
    private let now: () -> Date
    /// Instance override for `Self.operationTimeout`, defaulting to the real 60s constant. Exists
    /// so tests can exercise the timeout path itself without an actual 60-second wait.
    private let operationTimeout: TimeInterval

    init(
        sessionStore: any SessionStore,
        mediaService: any MCPMediaOperationServicing,
        snapshotService: MCPSessionSnapshotService,
        policyStore: MCPPolicyStore,
        auditStore: MCPAuditStore,
        notificationHub: MCPNotificationHub? = nil,
        liveProbeService: (any MCPLiveProbeServicing)? = nil,
        now: @escaping () -> Date = Date.init,
        // Default argument expressions run in a nonisolated context, so this can't reference the
        // @MainActor-isolated `Self.operationTimeout` directly — keep this literal in sync with it.
        operationTimeout: TimeInterval = 60
    ) {
        self.mediaService = mediaService
        self.liveProbeService = liveProbeService ?? MCPLiveProbeService()
        self.snapshotService = snapshotService
        self.policyStore = policyStore
        self.auditStore = auditStore
        self.notificationHub = notificationHub
        self.now = now
        self.operationTimeout = operationTimeout
        sessionChangesCancellable = sessionStore.sessionChangesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.handleSessionStoreChange(change)
            }
    }

    func startMediaInspection(
        clientID: String,
        mcpSessionID: String,
        sourceSessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        argumentDigest: String,
        authorize: () throws -> Void
    ) throws -> MCPOperationDescriptorDTO {
        pruneExpired()
        guard !analyses.isEmpty else {
            throw MCPStructuredError.malformedRequest(message: "At least one media analysis is required.")
        }
        guard analyses.count <= MCPMediaAnalysisKind.allCases.count,
              Set(analyses).count == analyses.count else {
            throw MCPStructuredError.malformedRequest(message: "Duplicate or excessive media analyses were requested.")
        }
        guard sampleTime.isFinite, sampleTime >= 0 else {
            throw MCPStructuredError.malformedRequest(message: "sampleTimeSeconds must be a non-negative finite number.")
        }

        let active = records.values.filter { isActive($0.descriptor.status) }
        guard active.count < Self.maximumActiveGlobally else {
            audit(clientID: clientID, reason: "media_inspection_busy_global")
            throw MCPStructuredError(
                code: .busy,
                message: "The global media-inspection limit is active.",
                details: ["retryAfterSeconds": "1"]
            )
        }
        guard active.count(where: { $0.ownerClientID == clientID }) < Self.maximumActivePerClient else {
            audit(clientID: clientID, reason: "media_inspection_busy_client")
            throw MCPStructuredError(
                code: .busy,
                message: "This client already has an active media inspection.",
                details: ["retryAfterSeconds": "1"]
            )
        }

        let source = try mediaService.inspectionSource(
            sessionID: sourceSessionID,
            analyses: analyses
        )
        try authorize()
        let operationID = UUID().uuidString
        let createdAt = now()
        let descriptor = MCPOperationDescriptorDTO(
            operationID: operationID,
            status: .running,
            progress: 0,
            currentStage: "preparing",
            operationKind: .mediaInspection,
            requestedAnalyses: analyses,
            stages: [],
            warnings: [],
            failureCode: nil,
            result: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(Self.completedRetention)
        )
        records[operationID] = Record(
            ownerClientID: clientID,
            ownerSessionID: mcpSessionID,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            capability: .mediaInspection,
            argumentDigest: argumentDigest,
            sourceSessionID: source.sessionID,
            descriptor: descriptor,
            stageStartedAt: createdAt,
            task: nil
        )
        refreshActiveCount()
        audit(clientID: clientID, reason: "media_inspection_started")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runWithTimeout(
                    source: source,
                    analyses: analyses,
                    sampleTime: sampleTime,
                    policyRevision: self.policyStore.policyRevision,
                    operationID: operationID
                )
                try Task.checkCancellation()
                self.complete(operationID: operationID, result: result)
            } catch is CancellationError {
                self.finishCancelled(operationID: operationID)
            } catch let error as MCPStructuredError {
                self.fail(operationID: operationID, code: error.code, warning: error.message)
            } catch {
                self.fail(operationID: operationID, code: .internalFailure, warning: "Media inspection failed.")
            }
        }
        records[operationID]?.task = task
        return descriptor
    }

    /// Starts an open-world live media URL probe. Only this entry point may touch the network.
    func startLiveMediaProbe(
        clientID: String,
        mcpSessionID: String,
        sourceSessionID: SessionRecord.ID,
        liveURL: URL,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        argumentDigest: String
    ) throws -> MCPOperationDescriptorDTO {
        pruneExpired()
        let resolvedAnalyses = analyses.isEmpty ? [MCPMediaAnalysisKind.liveMediaEngine] : analyses
        guard resolvedAnalyses.allSatisfy({ $0 == .liveMediaEngine }) else {
            throw MCPStructuredError.malformedRequest(
                message: "live_media_probe_start only accepts live_media_engine analyses."
            )
        }
        guard sampleTime.isFinite, sampleTime >= 0 else {
            throw MCPStructuredError.malformedRequest(message: "sampleTimeSeconds must be a non-negative finite number.")
        }

        let active = records.values.filter { isActive($0.descriptor.status) }
        guard active.count < Self.maximumActiveGlobally else {
            audit(clientID: clientID, reason: "live_probe_busy_global")
            throw MCPStructuredError(
                code: .busy,
                message: "The global media-operation limit is active.",
                details: ["retryAfterSeconds": "1"]
            )
        }
        guard active.count(where: { $0.ownerClientID == clientID }) < Self.maximumActivePerClient else {
            audit(clientID: clientID, reason: "live_probe_busy_client")
            throw MCPStructuredError(
                code: .busy,
                message: "This client already has an active media operation.",
                details: ["retryAfterSeconds": "1"]
            )
        }

        let operationID = UUID().uuidString
        let createdAt = now()
        let descriptor = MCPOperationDescriptorDTO(
            operationID: operationID,
            status: .running,
            progress: 0,
            currentStage: "preparing",
            operationKind: .liveProbe,
            requestedAnalyses: resolvedAnalyses,
            stages: [],
            warnings: [],
            failureCode: nil,
            result: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(Self.completedRetention)
        )
        records[operationID] = Record(
            ownerClientID: clientID,
            ownerSessionID: mcpSessionID,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            capability: .liveMediaProbe,
            argumentDigest: argumentDigest,
            sourceSessionID: sourceSessionID,
            descriptor: descriptor,
            stageStartedAt: createdAt,
            task: nil
        )
        refreshActiveCount()
        audit(clientID: clientID, reason: "live_probe_started")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runLiveProbeWithTimeout(
                    sessionID: sourceSessionID,
                    liveURL: liveURL,
                    sampleTime: sampleTime,
                    policyRevision: self.policyStore.policyRevision,
                    captureEpoch: self.snapshotService.captureEpoch,
                    operationID: operationID
                )
                try Task.checkCancellation()
                self.complete(operationID: operationID, result: result)
            } catch is CancellationError {
                self.finishCancelled(operationID: operationID)
            } catch let error as MCPStructuredError {
                self.fail(operationID: operationID, code: error.code, warning: error.message)
            } catch {
                self.fail(operationID: operationID, code: .internalFailure, warning: "Live media probe failed.")
            }
        }
        records[operationID]?.task = task
        return descriptor
    }

    func descriptor(
        operationID: String,
        clientID: String,
        mcpSessionID: String
    ) throws -> MCPOperationDescriptorDTO {
        pruneExpired()
        guard let record = records[operationID],
              record.ownerClientID == clientID,
              record.ownerSessionID == mcpSessionID else {
            throw MCPStructuredError(code: .malformedRequest, message: "Operation was not found.")
        }
        guard record.policyRevision == policyStore.policyRevision else {
            throw MCPStructuredError(code: .policyDenied, message: "Policy changed; the operation result is unavailable.")
        }
        guard record.captureEpoch == snapshotService.captureEpoch else {
            throw MCPStructuredError(code: .staleCursor, message: "Capture changed; the operation result is unavailable.")
        }
        return record.descriptor
    }

    @discardableResult
    func cancel(
        operationID: String,
        clientID: String,
        mcpSessionID: String
    ) throws -> MCPOperationDescriptorDTO {
        pruneExpired()
        guard var record = records[operationID],
              record.ownerClientID == clientID,
              record.ownerSessionID == mcpSessionID else {
            throw MCPStructuredError(code: .malformedRequest, message: "Operation was not found.")
        }
        if isActive(record.descriptor.status) {
            finishCurrentStage(&record, outcome: "cancelled")
            record.descriptor.status = .cancelling
            record.descriptor.currentStage = "cancelling"
            record.stageStartedAt = now()
            records[operationID] = record
            record.task?.cancel()
            audit(clientID: clientID, reason: "media_inspection_cancelling")
        }
        return records[operationID]?.descriptor ?? record.descriptor
    }

    func cancelOperations(forClientID clientID: String) {
        invalidateRecords { $0.ownerClientID == clientID }
    }

    func activeOperationCount(forClientID clientID: String) -> Int {
        pruneExpired()
        return records.values.count {
            $0.ownerClientID == clientID && isActive($0.descriptor.status)
        }
    }

    func cancelOperations(forMCPSessionID sessionID: String) {
        invalidateRecords { $0.ownerSessionID == sessionID }
    }

    func cancelAll() {
        invalidateRecords { _ in true }
    }

    private func runWithTimeout(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        operationID: String
    ) async throws -> MCPMediaInspectionResultDTO {
        let timeout = operationTimeout
        return try await withThrowingTaskGroup(of: MCPMediaInspectionResultDTO.self) { group in
            group.addTask { @MainActor [mediaService] in
                try await mediaService.inspect(
                    source: source,
                    analyses: analyses,
                    sampleTime: sampleTime,
                    policyRevision: policyRevision
                ) { [weak self] progress, stage in
                    self?.update(operationID: operationID, progress: progress, stage: stage)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPStructuredError(code: .timeout, message: "Media inspection timed out.")
            }
            guard let result = try await group.next() else {
                throw MCPStructuredError(code: .internalFailure, message: "Media inspection produced no result.")
            }
            group.cancelAll()
            return result
        }
    }

    private func runLiveProbeWithTimeout(
        sessionID: SessionRecord.ID,
        liveURL: URL,
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        captureEpoch: MCPCaptureEpoch,
        operationID: String
    ) async throws -> MCPMediaInspectionResultDTO {
        let timeout = operationTimeout
        return try await withThrowingTaskGroup(of: MCPMediaInspectionResultDTO.self) { group in
            group.addTask { @MainActor [liveProbeService] in
                try await liveProbeService.probe(
                    sessionID: sessionID,
                    liveURL: liveURL,
                    sampleTime: sampleTime,
                    policyRevision: policyRevision,
                    captureEpoch: captureEpoch
                ) { [weak self] progress, stage in
                    self?.update(operationID: operationID, progress: progress, stage: stage)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPStructuredError(code: .timeout, message: "Live media probe timed out.")
            }
            guard let result = try await group.next() else {
                throw MCPStructuredError(code: .internalFailure, message: "Live media probe produced no result.")
            }
            group.cancelAll()
            return result
        }
    }

    private func update(operationID: String, progress: Double, stage: String) {
        guard var record = records[operationID], record.descriptor.status == .running else { return }
        if record.descriptor.currentStage != stage {
            finishCurrentStage(&record, outcome: "completed")
            record.descriptor.currentStage = stage
            record.stageStartedAt = now()
        }
        record.descriptor.progress = min(max(progress, 0), 1)
        records[operationID] = record
        publishOperationNotification(for: record, isTerminal: false)
    }

    private func complete(operationID: String, result: MCPMediaInspectionResultDTO) {
        guard var record = records[operationID] else { return }
        guard record.captureEpoch == snapshotService.captureEpoch,
              record.policyRevision == policyStore.policyRevision else {
            fail(operationID: operationID, code: .policyDenied, warning: "Capture or policy changed during inspection.")
            return
        }
        finishCurrentStage(&record, outcome: "completed")
        record.descriptor.status = result.disclosure.partialResultReason == nil ? .completed : .partial
        record.descriptor.progress = 1
        record.descriptor.currentStage = nil
        record.descriptor.result = result
        record.descriptor.warnings = result.warnings
        record.descriptor.expiresAt = now().addingTimeInterval(Self.completedRetention)
        record.task = nil
        records[operationID] = record
        trimCompleted(for: record.ownerClientID)
        refreshActiveCount()
        audit(clientID: record.ownerClientID, reason: record.descriptor.status == .partial
            ? "media_inspection_partial"
            : "media_inspection_completed")
        publishOperationNotification(for: record, isTerminal: true)
    }

    private func fail(operationID: String, code: MCPErrorCode, warning: String) {
        guard var record = records[operationID] else { return }
        finishCurrentStage(&record, outcome: code.rawValue)
        record.descriptor.status = .failed
        record.descriptor.currentStage = nil
        record.descriptor.failureCode = code
        record.descriptor.warnings = [warning]
        record.descriptor.result = nil
        record.descriptor.expiresAt = now().addingTimeInterval(Self.completedRetention)
        record.task = nil
        records[operationID] = record
        trimCompleted(for: record.ownerClientID)
        refreshActiveCount()
        audit(clientID: record.ownerClientID, reason: "media_inspection_\(code.rawValue)")
        publishOperationNotification(for: record, isTerminal: true)
    }

    private func finishCancelled(operationID: String) {
        guard var record = records[operationID] else { return }
        finishCurrentStage(&record, outcome: "cancelled")
        record.descriptor.status = .cancelled
        record.descriptor.currentStage = nil
        record.descriptor.failureCode = .cancelled
        record.descriptor.result = nil
        record.descriptor.expiresAt = now().addingTimeInterval(Self.completedRetention)
        record.task = nil
        records[operationID] = record
        trimCompleted(for: record.ownerClientID)
        refreshActiveCount()
        audit(clientID: record.ownerClientID, reason: "media_inspection_cancelled")
        publishOperationNotification(for: record, isTerminal: true)
    }

    private func handleSessionStoreChange(_ change: SessionStoreChange) {
        switch change {
        case .cleared, .loaded:
            cancelAll()
        case .removed(let ids):
            invalidateRecords { ids.contains($0.sourceSessionID) }
        case .bodiesStripped(let sessions):
            let ids = Set(sessions.map(\.id))
            invalidateRecords { ids.contains($0.sourceSessionID) }
        case .appended, .updated, .updatedBatch:
            break
        }
    }

    private func invalidateRecords(where predicate: (Record) -> Bool) {
        let matchingIDs = records.compactMap { key, record in
            predicate(record) ? key : nil
        }
        for id in matchingIDs {
            guard var record = records[id] else { continue }
            record.descriptor.result = nil
            if isActive(record.descriptor.status) {
                finishCurrentStage(&record, outcome: "cancelled")
                record.descriptor.status = .cancelling
                record.descriptor.currentStage = "cancelling"
                record.stageStartedAt = now()
                records[id] = record
                record.task?.cancel()
            } else {
                records.removeValue(forKey: id)
            }
        }
        refreshActiveCount()
    }

    private func pruneExpired() {
        let now = now()
        let tombstoneIDs = records.compactMap { id, record in
            record.descriptor.status != .expired
                && !isActive(record.descriptor.status)
                && record.descriptor.expiresAt <= now ? id : nil
        }
        for id in tombstoneIDs {
            records[id]?.descriptor.status = .expired
            records[id]?.descriptor.result = nil
            records[id]?.descriptor.currentStage = nil
            records[id]?.descriptor.warnings = ["Operation result expired."]
            records[id]?.descriptor.expiresAt = now.addingTimeInterval(Self.expiredTombstoneRetention)
        }
        let removalIDs = records.compactMap { id, record in
            record.descriptor.status == .expired && record.descriptor.expiresAt <= now ? id : nil
        }
        for id in removalIDs {
            records.removeValue(forKey: id)
        }
        refreshActiveCount()
    }

    private func trimCompleted(for clientID: String) {
        let completed = records
            .filter { $0.value.ownerClientID == clientID && !isActive($0.value.descriptor.status) }
            .sorted { $0.value.descriptor.createdAt < $1.value.descriptor.createdAt }
        let excess = max(0, completed.count - Self.maximumCompletedPerClient)
        for (id, _) in completed.prefix(excess) {
            records.removeValue(forKey: id)
        }
    }

    private func refreshActiveCount() {
        activeAnalysisCount = records.values.count { isActive($0.descriptor.status) }
        activeOperations = records.values
            .filter { isActive($0.descriptor.status) }
            .map(\.descriptor)
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func isActive(_ status: MCPOperationStatus) -> Bool {
        status == .running || status == .cancelling || status == .pendingApproval
    }

    private func finishCurrentStage(_ record: inout Record, outcome: String) {
        guard let stage = record.descriptor.currentStage,
              let startedAt = record.stageStartedAt else { return }
        record.descriptor.stages.append(
            MCPOperationStageDTO(
                id: stage,
                title: stage.replacingOccurrences(of: "_", with: " ").capitalized,
                durationSeconds: max(0, now().timeIntervalSince(startedAt)),
                outcome: outcome,
                message: nil
            )
        )
        record.stageStartedAt = nil
    }

    private func audit(clientID: String?, reason: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: Date(),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: reason,
                detail: nil
            )
        )
    }

    private func publishOperationNotification(for record: Record, isTerminal: Bool) {
        guard let notificationHub else { return }
        notificationHub.publishOperationUpdate(
            key: MCPLogicalSessionKey(clientID: record.ownerClientID, mcpSessionID: record.ownerSessionID),
            descriptor: record.descriptor,
            isTerminal: isTerminal
        )
    }
}
