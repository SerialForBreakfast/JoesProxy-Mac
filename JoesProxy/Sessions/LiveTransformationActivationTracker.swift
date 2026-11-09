import Foundation

/// Thread-safe tracker for per-rule activation lifetime and transformed-response hit-count limits
/// (see `LiveTransformationExecutionBudget`). Deliberately a plain lock-protected class, not an
/// actor: the real-traffic budget check happens on a synchronous NIO completion callback in
/// `ConnectionHandler`, and actor-hopping there would mean restructuring an already-shipped hot
/// path into a fully async flow — a low-contention counter/timestamp lookup is exactly what a
/// lock is for. `ResponseOverrideStore.setEnabled` is the single choke point for every enable and
/// disable trigger (explicit disable, scenario stop, hit-limit, expiration, client revocation,
/// server stop, Return To Normal, startup reconciliation), so hooking activation-start/clear there
/// covers all of them without hunting down each call site individually.
final class LiveTransformationActivationTracker: @unchecked Sendable {
    static let shared = LiveTransformationActivationTracker()

    private let lock = NSLock()
    private var activationStartTimes: [UUID: Date] = [:]
    private var transformedCounts: [UUID: Int] = [:]

    func recordActivationStart(ruleID: UUID, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        activationStartTimes[ruleID] = now
        transformedCounts[ruleID] = 0
    }

    func clear(ruleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activationStartTimes.removeValue(forKey: ruleID)
        transformedCounts.removeValue(forKey: ruleID)
    }

    /// Whether a transform attempt is still within budget for `ruleID` — false once the
    /// activation lifetime has elapsed or the hit-count cap has been reached. A rule with no
    /// recorded activation start (e.g. a bug, or a rule enabled through a path that doesn't call
    /// `recordActivationStart`) fails open, consistent with this subsystem's v1 fail-open
    /// philosophy, rather than silently blocking traffic.
    func isWithinBudget(
        ruleID: UUID,
        now: Date = Date(),
        lifetimeSeconds: TimeInterval = LiveTransformationExecutionBudget.activationLifetimeSeconds,
        maxTransformedResponses: Int = LiveTransformationExecutionBudget.maxTransformedResponsesPerActivation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt = activationStartTimes[ruleID] else {
            return true
        }
        if now.timeIntervalSince(startedAt) > lifetimeSeconds {
            return false
        }
        let count = transformedCounts[ruleID] ?? 0
        return count < maxTransformedResponses
    }

    /// Call only after a transform actually applied (not merely attempted) — only successful
    /// transformations count against the hit-count budget.
    func recordTransformed(ruleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        transformedCounts[ruleID, default: 0] += 1
    }

    /// Atomically rechecks and consumes one transformed-response allowance. This is used at the
    /// event-loop delivery boundary so concurrently completed workers cannot both commit beyond
    /// the activation hit budget.
    func recordTransformedIfWithinBudget(
        ruleID: UUID,
        now: Date = Date(),
        lifetimeSeconds: TimeInterval = LiveTransformationExecutionBudget.activationLifetimeSeconds,
        maxTransformedResponses: Int = LiveTransformationExecutionBudget.maxTransformedResponsesPerActivation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let startedAt = activationStartTimes[ruleID] {
            guard now.timeIntervalSince(startedAt) <= lifetimeSeconds,
                  transformedCounts[ruleID, default: 0] < maxTransformedResponses else {
                return false
            }
        }
        transformedCounts[ruleID, default: 0] += 1
        return true
    }

    /// Whether `ruleID`'s activation lifetime has elapsed. Callers should auto-disable the rule
    /// via `ResponseOverrideStore.setEnabled(false, for:)` when this is true, reusing the existing
    /// recovery/audit wiring rather than inventing a new cleanup mechanism.
    func isExpired(
        ruleID: UUID,
        now: Date = Date(),
        lifetimeSeconds: TimeInterval = LiveTransformationExecutionBudget.activationLifetimeSeconds
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt = activationStartTimes[ruleID] else {
            return false
        }
        return now.timeIntervalSince(startedAt) > lifetimeSeconds
    }
}
