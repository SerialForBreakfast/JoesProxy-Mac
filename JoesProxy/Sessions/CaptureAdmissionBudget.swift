import Foundation

/// Synchronous pre-task admission shared by transport threads. Every field is protected by lock.
/// Reservations cover capture bodies plus metadata; these are not whole-process memory metrics.
final class CaptureAdmissionBudget: @unchecked Sendable {
    enum Stage: String, Sendable { case admitted, collecting, storeDelivery }
    enum RejectionReason: String, Sendable { case requestTooLarge, capacityExhausted }
    private struct Reservation {
        var bytes: Int
        let started: Date
        let startedUptime: TimeInterval
        var stage: Stage = .admitted
    }
    struct Gap: Codable, Equatable, Sendable {
        let id: UInt64
        let start: CaptureObservationInstant
        var end: CaptureObservationInstant?
        var rejectedCaptures: Int
        var metadataOnlyCaptures: Int?
    }

    struct Snapshot: Equatable, Sendable {
        let reservedBytes: Int
        let peakReservedBytes: Int
        let pendingCaptures: Int
        let rejectedCaptures: Int
        let paused: Bool
        let gapStartedAt: Date?
        let lastGapEndedAt: Date?
        let historyStarted: CaptureObservationInstant
        let observed: CaptureObservationInstant
        let gaps: [Gap]
        let evictedThrough: CaptureObservationInstant?
        var byteLimit: Int = 0
        var countLimit: Int = 0
        var admittedCount: Int = 0
        var collectingCount: Int = 0
        var storeDeliveryCount: Int = 0
        var oldestReservationAt: Date?
        var lastStoreDeliveryAt: Date?
        var lastRejectionReason: RejectionReason?
        var oldestReservationUptime: TimeInterval?
        var metadataOnlyCaptures: Int = 0

        var oldestReservationAge: TimeInterval? {
            oldestReservationUptime.map { max(0, observed.uptime - $0) }
        }

        var statusText: String {
            guard paused else {
                return rejectedCaptures > 0 || metadataOnlyCaptures > 0 ? "Capture resumed with an evidence gap" : "Capture admission available"
            }
            if storeDeliveryCount > 0 { return "Capture admission paused: waiting for store delivery" }
            if collectingCount > 0 { return "Capture admission paused: waiting for capture completion" }
            return "Capture admission paused: capacity exhausted"
        }

        /// Sampling time is evidence provenance, not a metric change. Idle polling must not
        /// invalidate telemetry consumers just because a fresh observation was requested.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.reservedBytes == rhs.reservedBytes && lhs.peakReservedBytes == rhs.peakReservedBytes
                && lhs.pendingCaptures == rhs.pendingCaptures && lhs.rejectedCaptures == rhs.rejectedCaptures
                && lhs.paused == rhs.paused && lhs.gapStartedAt == rhs.gapStartedAt
                && lhs.lastGapEndedAt == rhs.lastGapEndedAt && lhs.historyStarted == rhs.historyStarted
                && lhs.gaps == rhs.gaps && lhs.evictedThrough == rhs.evictedThrough
                && lhs.byteLimit == rhs.byteLimit && lhs.countLimit == rhs.countLimit
                && lhs.admittedCount == rhs.admittedCount && lhs.collectingCount == rhs.collectingCount
                && lhs.storeDeliveryCount == rhs.storeDeliveryCount
                && lhs.oldestReservationAt == rhs.oldestReservationAt
                && lhs.lastStoreDeliveryAt == rhs.lastStoreDeliveryAt
                && lhs.lastRejectionReason == rhs.lastRejectionReason
                && lhs.oldestReservationUptime == rhs.oldestReservationUptime
                && lhs.metadataOnlyCaptures == rhs.metadataOnlyCaptures
        }
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var reservations: [UUID: Reservation] = [:]
    private var lastStoreDeliveryAt: Date?
    private var lastRejectionReason: RejectionReason?
    private var bytes = 0
    private var peak = 0
    private var rejected = 0
    private var metadataOnly = 0
    private var paused = false
    private var accepting = true
    private let now: @Sendable () -> CaptureObservationInstant
    private let historyStarted: CaptureObservationInstant
    private var gaps: [Gap] = []
    private var gapSequence: UInt64 = 0
    private var evictedThrough: CaptureObservationInstant?

    func setAccepting(_ value: Bool) { lock.withLock { accepting = value } }

    /// Shutdown has drained the store; queued admissions are invalidated by the run epoch.
    /// Their eventual releases are harmless, and a new run starts with no old reservations.
    func releaseStoppedReservations() {
        lock.withLock {
            guard !accepting else { return }
            reservations.removeAll()
            bytes = 0
            endGap()
        }
    }
    private var gapStartedAt: Date?
    private var gapEndedAt: Date?

    init(byteLimit: Int = 128 * 1_024 * 1_024, countLimit: Int = 512,
         now: @escaping @Sendable () -> CaptureObservationInstant = { .now() }) {
        precondition(byteLimit > 0 && countLimit > 0)
        self.byteLimit = byteLimit
        self.countLimit = countLimit
        self.now = now
        self.historyStarted = now()
    }

    struct CaptureReservation: Sendable {
        let id: UUID
        let metadataOnly: Bool
    }

    func reserve(bytes requested: Int) -> UUID? {
        reserveCapture(bytes: requested, metadataBytes: nil)?.id
    }

    /// Metadata fallback shares the same byte/count limits. It never waits for capacity and
    /// cannot bypass shutdown. Body admission retains its low-water recovery hysteresis.
    func reserveCapture(bytes requested: Int, metadataBytes: Int?) -> CaptureReservation? {
        lock.withLock {
            guard accepting else { return nil }
            if paused, bytes <= byteLimit / 2, reservations.count <= countLimit / 2 {
                endGap()
            }
            let oversized = requested < 0 || requested > byteLimit
            guard !paused, !oversized, requested <= byteLimit - bytes,
                  reservations.count < countLimit else {
                lastRejectionReason = oversized ? .requestTooLarge : .capacityExhausted
                let wasPaused = paused
                if !paused {
                    let instant = now()
                    gapStartedAt = instant.date
                    gapSequence += 1
                    gaps.append(.init(id: gapSequence, start: instant, rejectedCaptures: 0))
                    if gaps.count > 64 { evictedThrough = gaps.removeFirst().end }
                }
                paused = true
                // A request that can never fit is a point-in-time evidence gap, not backlog.
                if oversized, !wasPaused { endGap() }
                if let metadataBytes, metadataBytes >= 0, metadataBytes <= byteLimit - bytes,
                   reservations.count < countLimit {
                    metadataOnly += 1
                    gaps[gaps.count - 1].metadataOnlyCaptures = (gaps[gaps.count - 1].metadataOnlyCaptures ?? 0) + 1
                    return CaptureReservation(id: insertReservation(bytes: metadataBytes), metadataOnly: true)
                }
                rejected += 1
                gaps[gaps.count - 1].rejectedCaptures += 1
                return nil
            }
            return CaptureReservation(id: insertReservation(bytes: requested), metadataOnly: false)
        }
    }

    /// Caller holds lock.
    private func insertReservation(bytes requested: Int) -> UUID {
        let id = UUID()
        let instant = now()
        reservations[id] = Reservation(bytes: requested, started: instant.date, startedUptime: instant.uptime)
        bytes += requested
        peak = max(peak, bytes)
        return id
    }

    func release(_ id: UUID) {
        lock.withLock {
            guard let cost = reservations.removeValue(forKey: id) else { return }
            bytes -= cost.bytes
            if cost.stage == .storeDelivery { lastStoreDeliveryAt = now().date }
            if paused, bytes <= byteLimit / 2, reservations.count <= countLimit / 2 {
                endGap()
            }
        }
    }

    /// Stage changes never release ownership. Only a proven smaller retained cost may shrink it.
    func transition(_ id: UUID, to stage: Stage, retainedBytes: Int? = nil) {
        lock.withLock {
            guard var reservation = reservations[id] else { return }
            reservation.stage = stage
            if let retainedBytes, retainedBytes >= 0, retainedBytes < reservation.bytes {
                bytes -= reservation.bytes - retainedBytes
                reservation.bytes = retainedBytes
            }
            reservations[id] = reservation
            if paused, bytes <= byteLimit / 2, reservations.count <= countLimit / 2 { endGap() }
        }
    }

    func recordStoreDelivery() {
        lock.withLock { lastStoreDeliveryAt = now().date }
    }

    static func reservationCost(requestBytes: Int, responseLimit: Int, headerBytes: Int) -> Int? {
        guard requestBytes >= 0, responseLimit >= 0, headerBytes >= 0 else { return nil }
        let doubled = responseLimit.multipliedReportingOverflow(by: 2)
        let body = requestBytes.addingReportingOverflow(doubled.partialValue)
        let headers = body.partialValue.addingReportingOverflow(headerBytes)
        let total = headers.partialValue.addingReportingOverflow(65_536)
        guard !doubled.overflow, !body.overflow, !headers.overflow, !total.overflow else { return nil }
        return total.partialValue
    }

    /// Caller holds the lock. The active interval is always the final retained entry.
    private func endGap() {
        guard paused else { return }
        let instant = now()
        gapEndedAt = instant.date
        gaps[gaps.count - 1].end = instant
        paused = false
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(reservedBytes: bytes, peakReservedBytes: peak, pendingCaptures: reservations.count,
                rejectedCaptures: rejected, paused: paused, gapStartedAt: gapStartedAt,
                lastGapEndedAt: gapEndedAt, historyStarted: historyStarted, observed: now(),
                gaps: gaps, evictedThrough: evictedThrough,
                byteLimit: byteLimit, countLimit: countLimit,
                admittedCount: reservations.values.filter { $0.stage == .admitted }.count,
                collectingCount: reservations.values.filter { $0.stage == .collecting }.count,
                storeDeliveryCount: reservations.values.filter { $0.stage == .storeDelivery }.count,
                oldestReservationAt: reservations.values.map(\.started).min(),
                lastStoreDeliveryAt: lastStoreDeliveryAt, lastRejectionReason: lastRejectionReason,
                oldestReservationUptime: reservations.values.map(\.startedUptime).min(),
                metadataOnlyCaptures: metadataOnly)
        }
    }
}
