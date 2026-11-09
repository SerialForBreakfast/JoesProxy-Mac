#if DEBUG
import Combine
import Foundation

/// Live event ring-buffer for the developer overlay.
///
/// Subscribes to `ProxySDK.onNetworkEvent` from first activation and retains the
/// 50 most recent events (newest-first). Auth-cascade groups and third-party
/// summaries are computed on demand from the current buffer.
@MainActor
final class OverlayEventStore: ObservableObject {
    static let shared = OverlayEventStore()

    @Published private(set) var events: [NetworkEvent] = []

    private var handlerID: UUID?
    private let capacity = 50

    struct AuthCascadeGroup: Identifiable, Sendable {
        let id: UUID
        let trigger: NetworkEvent
        let cascade: [NetworkEvent]
        let holdDurationMs: Int
    }

    var authCascadeGroups: [AuthCascadeGroup] {
        events
            .filter { $0.statusCode == 401 }
            .compactMap { trigger in
                let window = trigger.timestamp.addingTimeInterval(0.2)
                let cascade = events.filter {
                    $0.url.host == trigger.url.host &&
                    $0.timestamp > trigger.timestamp &&
                    $0.timestamp <= window &&
                    $0.id != trigger.id
                }
                guard cascade.count >= 2 else { return nil }
                // Use the earliest cascade event (events array is newest-first)
                let earliest = cascade.min(by: { $0.timestamp < $1.timestamp })!
                let holdMs = Int((earliest.timestamp.timeIntervalSince(trigger.timestamp)) * 1000)
                return AuthCascadeGroup(id: trigger.id, trigger: trigger, cascade: cascade, holdDurationMs: holdMs)
            }
    }

    var thirdPartySummary: [String: Int] {
        Dictionary(
            grouping: events.compactMap(\.sourceSDK),
            by: { $0 }
        ).mapValues(\.count)
    }

    func startCollecting(sdk: ProxySDK = .shared) {
        guard handlerID == nil else { return }
        handlerID = sdk.onNetworkEvent { [weak self] event in
            Task { @MainActor [weak self] in
                self?.append(event)
            }
        }
    }

    func clear() {
        events = []
    }

    /// Internal entry point used by tests to inject events directly.
    func appendEvent(_ event: NetworkEvent) {
        append(event)
    }

    private func append(_ event: NetworkEvent) {
        events.insert(event, at: 0)
        if events.count > capacity {
            events = Array(events.prefix(capacity))
        }
    }
}
#endif
