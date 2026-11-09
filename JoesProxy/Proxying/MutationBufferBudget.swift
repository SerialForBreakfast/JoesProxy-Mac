import Foundation

/// Reserves the complete per-response wire-buffer allowance before collecting any body bytes.
/// No waiting queue: callers without a reservation must forward the original response.
final class MutationBufferBudget: @unchecked Sendable {
    static let shared = MutationBufferBudget()
    final class Reservation: Sendable {
        private let budget: MutationBufferBudget
        init(budget: MutationBufferBudget) { self.budget = budget }
        deinit { budget.lock.withLock { budget.active -= 1 } }
    }
    private let lock = NSLock()
    private let limit: Int
    private var active = 0
    private var rejected = 0
    init(limit: Int = 2) { precondition(limit > 0); self.limit = limit }
    var activeCount: Int { lock.withLock { active } }
    var rejectedCount: Int { lock.withLock { rejected } }
    func reserve() -> Reservation? {
        lock.withLock {
            guard active < limit else { rejected += 1; return nil }
            active += 1
            return Reservation(budget: self)
        }
    }
}
