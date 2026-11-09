import Foundation

actor ProxySessionRecorder {
    nonisolated let admission = CaptureAdmissionBudget()
    nonisolated private let captureEpoch: LiveCaptureEpoch
    nonisolated static let uncapturedSession = Task<UUID?, Never> { nil }
    private var reservations: [UUID: UUID] = [:]
    private let sessionStore: any SessionStore
    private let beforeStoreDelivery: (@Sendable () async -> Void)?
    private var records: [UUID: SessionRecord] = [:]
    private var recordEpochs: [UUID: UInt64] = [:]
    private var accepting = true

    private var pendingAppends: [SessionRecord] = []
    private var pendingUpdates: [SessionRecord] = []
    private var flushTask: Task<Void, Never>?
    private var storeFlushTask: Task<Void, Never>?

    private let maxBatchSize: Int = 50

    var inFlightSessionCount: Int {
        records.count
    }

    init(sessionStore: any SessionStore, beforeStoreDelivery: (@Sendable () async -> Void)? = nil) {
        self.sessionStore = sessionStore
        self.beforeStoreDelivery = beforeStoreDelivery
        self.captureEpoch = sessionStore.liveCaptureEpoch
    }

    /// Reserve before allocating a transport-to-recorder task; rejected requests keep forwarding.
    nonisolated func scheduleSession(request: CapturedRequest, responseBodyLimit: Int) -> Task<UUID?, Never> {
        admitSession(request: request, responseBodyLimit: responseBodyLimit) ?? Self.uncapturedSession
    }

    /// Nil admission lets forwarding omit capture collectors and completion jobs synchronously.
    nonisolated func admitSession(request: CapturedRequest, responseBodyLimit: Int) -> Task<UUID?, Never>? {
        let headers = request.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
        let cost = CaptureAdmissionBudget.reservationCost(requestBytes: request.bodyData?.count ?? 0,
            responseLimit: responseBodyLimit, headerBytes: headers) ?? Int.max
        guard let reservation = admission.reserve(bytes: cost) else { return nil }
        let epoch = captureEpoch.current
        return Task {
            await beginSession(request: request, epoch: epoch, reservation: reservation)
        }
    }

    struct CaptureAdmission: Sendable {
        let session: Task<UUID?, Never>
        let responseBodyLimit: Int
    }

    /// Freeze the effective collector limit before entering any asynchronous routing work.
    /// Under pressure retain request/response metadata, not a response prefix; forwarding is
    /// independent of whether either bounded admission succeeds.
    nonisolated func admitPlaybackFirst(request: CapturedRequest, responseBodyLimit: Int) -> CaptureAdmission? {
        let headers = request.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
        let requestBytes = request.bodyData?.count ?? 0
        let fullCost = CaptureAdmissionBudget.reservationCost(requestBytes: requestBytes,
            responseLimit: responseBodyLimit, headerBytes: headers) ?? Int.max
        let metadataCost = CaptureAdmissionBudget.reservationCost(requestBytes: requestBytes,
            responseLimit: 0, headerBytes: headers)
        guard let reservation = admission.reserveCapture(bytes: fullCost, metadataBytes: metadataCost) else { return nil }
        let epoch = captureEpoch.current
        return CaptureAdmission(session: Task {
            await beginSession(request: request, epoch: epoch, reservation: reservation.id,
                               responseCaptureLimitedByPressure: reservation.metadataOnly)
        }, responseBodyLimit: reservation.metadataOnly ? 0 : responseBodyLimit)
    }

    func beginSession(request: CapturedRequest, epoch: UInt64? = nil, reservation: UUID? = nil,
                      responseCaptureLimitedByPressure: Bool = false) async -> UUID {
        guard accepting, epoch == nil || epoch == captureEpoch.current else {
            if let reservation { admission.release(reservation) }
            return UUID()
        }
        let signpost = ProxyIOPerformanceSignposts.beginSessionIngest()
        defer { ProxyIOPerformanceSignposts.endSessionIngest(signpost) }

        var record = SessionRecord(
            request: request,
            timing: SessionTiming(startedAt: Date())
        )
        if responseCaptureLimitedByPressure { record.responseCaptureLimitedByPressure = true }
        records[record.id] = record
        recordEpochs[record.id] = epoch ?? captureEpoch.current
        if let reservation {
            reservations[record.id] = reservation
            admission.transition(reservation, to: .collecting)
        }
        pendingAppends.append(record)

        if pendingAppends.count + pendingUpdates.count >= maxBatchSize {
            flush()
        } else {
            scheduleFlushIfNeeded()
        }

        return record.id
    }

    func completeSession(
        id: UUID,
        response: CapturedResponse,
        wireProfile: WireTimingProfile? = nil
    ) async {
        let signpost = ProxyIOPerformanceSignposts.beginSessionIngest()
        defer { ProxyIOPerformanceSignposts.endSessionIngest(signpost) }

        guard var record = records.removeValue(forKey: id) else {
            return
        }

        record.response = response
        record.state = .completed
        record.timing.completedAt = Date()
        if var wireProfile {
            let contentEncoding = response.headers.first {
                $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
            }?.value
            let decodedBodyByteCount: Int?
            if response.bodyTruncated {
                decodedBodyByteCount = nil
            } else {
                decodedBodyByteCount = CapturedBodyDecoder.decode(response: response)?
                    .analysisByteCount ?? response.bodySize
            }
            wireProfile.transfer = WireTransferMetrics(
                headerByteCount: wireProfile.transfer?.headerByteCount ?? 0,
                transferBodyByteCount: wireProfile.transfer?.transferBodyByteCount ?? response.bodySize ?? 0,
                decodedBodyByteCount: decodedBodyByteCount,
                contentEncoding: contentEncoding
            )
            record.timing.wireProfile = wireProfile
        }
        let updatedRecord = record

        if let reservation = reservations[id] {
            let headers = (record.request.headers + response.headers).reduce(0) {
                $0 + $1.name.utf8.count + $1.value.utf8.count
            }
            let retainedCost = CaptureAdmissionBudget.reservationCost(
                requestBytes: record.request.bodyData?.count ?? 0,
                responseLimit: response.bodyData?.count ?? 0, headerBytes: headers)
            admission.transition(reservation, to: .storeDelivery, retainedBytes: retainedCost)
        }

        if let pendingIndex = pendingAppends.firstIndex(where: { $0.id == id }) {
            pendingAppends[pendingIndex] = updatedRecord
        } else if let updateIndex = pendingUpdates.firstIndex(where: { $0.id == id }) {
            pendingUpdates[updateIndex] = updatedRecord
        } else {
            pendingUpdates.append(updatedRecord)
        }

        flush()
    }

    /// Records a failed session using classified user-facing network copy.
    func failSession(id: UUID, error: Error) async {
        let presentation = NetworkFailureClassifier.presentation(for: error)
        await failSession(id: id, presentation: presentation)
    }

    /// Records a failed session with an explicit message (used by tests and synthetic fixtures).
    func failSession(id: UUID, message: String) async {
        await failSession(
            id: id,
            presentation: NetworkFailureClassifier.presentation(forMessage: message)
        )
    }

    private func failSession(id: UUID, presentation: NetworkFailurePresentation) async {
        let signpost = ProxyIOPerformanceSignposts.beginSessionIngest()
        defer { ProxyIOPerformanceSignposts.endSessionIngest(signpost) }

        guard var record = records.removeValue(forKey: id) else {
            return
        }

        record.state = .failed
        record.failure = SessionFailure(message: presentation.userFacingMessage, bucket: presentation.bucket)
        record.timing.completedAt = Date()
        let updatedRecord = record
        if let reservation = reservations[id] {
            admission.transition(reservation, to: .storeDelivery)
        }

        if let pendingIndex = pendingAppends.firstIndex(where: { $0.id == id }) {
            pendingAppends[pendingIndex] = updatedRecord
        } else if let updateIndex = pendingUpdates.firstIndex(where: { $0.id == id }) {
            pendingUpdates[updateIndex] = updatedRecord
        } else {
            pendingUpdates.append(updatedRecord)
        }

        flush()
    }

    /// One actor-owned runner hands bounded batches to the main actor, without predecessor tasks.
    /// Only the test barrier waits for draining; transport callbacks never wait for store delivery.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard storeFlushTask == nil, !pendingAppends.isEmpty || !pendingUpdates.isEmpty else { return }
        storeFlushTask = Task { await drainStoreQueue() }
    }

    private func drainStoreQueue() async {
        while !pendingAppends.isEmpty || !pendingUpdates.isEmpty {
            let appends = Array(pendingAppends.prefix(maxBatchSize))
            pendingAppends.removeFirst(appends.count)
            let updates = Array(pendingUpdates.prefix(maxBatchSize))
            pendingUpdates.removeFirst(updates.count)
            let epochs = recordEpochs
            let store = sessionStore
            // Injectable suspension exercises the real queue without blocking the test/UI thread.
            await beforeStoreDelivery?()
            await MainActor.run {
                for record in appends where epochs[record.id] == store.liveCaptureEpoch.current {
                    store.append(record)
                }
                // Live updates are not upserts: removed/evicted records stay removed.
                let existing = updates.filter {
                    epochs[$0.id] == store.liveCaptureEpoch.current && store.record(for: $0.id) != nil
                }
                if !existing.isEmpty { store.update(existing) }
            }
            admission.recordStoreDelivery()
            for record in appends + updates where records[record.id] == nil
                && !pendingUpdates.contains(where: { $0.id == record.id })
                && !pendingAppends.contains(where: { $0.id == record.id }) {
                recordEpochs[record.id] = nil
                if let reservation = reservations.removeValue(forKey: record.id) { admission.release(reservation) }
            }
        }
        storeFlushTask = nil
    }

    func waitForPendingStoreFlush() async {
        flush()
        while let task = storeFlushTask { await task.value }
    }

    /// Call after transport shutdown. Terminal callbacks are idempotent; queued old admissions
    /// fail their epoch check even if a later capture run has already started.
    func finishCaptureRun() async {
        accepting = false
        admission.setAccepting(false)
        for id in Array(records.keys) { await failSession(id: id, message: "Capture stopped before request completed.") }
        await waitForPendingStoreFlush()
        captureEpoch.advance()
        admission.releaseStoppedReservations()
    }

    func startCaptureRun() {
        accepting = true
        admission.setAccepting(true)
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000) }
            catch { return }
            await self?.flush()
        }
    }
}
