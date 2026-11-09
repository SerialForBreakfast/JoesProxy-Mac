import Foundation

/// Main-actor owned elapsed-time state. No timer, I/O, or traffic references are retained here.
/// Callers publish a routing generation synchronously before exposing a new snapshot.
struct EffectBundleTimeline: Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        let activationID: UUID
        let phaseID: UUID
        let phaseIndex: Int
        let phaseCount: Int
        let label: String
        let activatedAt: Date
        let phaseDeadline: Date
        let expiresAt: Date
    }

    let activationID: UUID
    let phases: [EffectBundlePhase]
    let activatedAt: Date
    let startedUptime: TimeInterval
    let expiryUptime: TimeInterval
    private(set) var phaseIndex = 0
    private(set) var phaseStartedUptime: TimeInterval

    init(phases: [EffectBundlePhase], activatedAt: Date, uptime: TimeInterval, duration: TimeInterval) {
        precondition(!phases.isEmpty)
        self.activationID = UUID()
        self.phases = phases
        self.activatedAt = activatedAt
        self.startedUptime = uptime
        self.phaseStartedUptime = uptime
        self.expiryUptime = uptime + duration
    }

    var phase: EffectBundlePhase { phases[phaseIndex] }
    var deadlineUptime: TimeInterval { min(expiryUptime, phaseStartedUptime + phase.durationSeconds) }
    var snapshot: Snapshot {
        .init(activationID: activationID, phaseID: phase.id, phaseIndex: phaseIndex,
              phaseCount: phases.count, label: phase.label, activatedAt: activatedAt,
              phaseDeadline: activatedAt.addingTimeInterval(deadlineUptime - startedUptime),
              expiresAt: activatedAt.addingTimeInterval(expiryUptime - startedUptime))
    }

    /// Returns false at the terminal phase or lifetime boundary. A delayed timer never replays
    /// missed phases: the next reviewed phase starts now, still within the original lifetime.
    mutating func advance(at uptime: TimeInterval) -> Bool {
        guard uptime < expiryUptime, phaseIndex + 1 < phases.count else { return false }
        phaseIndex += 1
        phaseStartedUptime = uptime
        return true
    }
}
