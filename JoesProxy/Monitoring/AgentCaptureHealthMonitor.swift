import Combine
import Foundation

/// Shared, aggregate capture health for Agent supervision.
///
/// The monitor observes the runtime and session store directly. It intentionally does not create
/// filtered rows, summaries, selections, or any Inspector analysis cache.
@MainActor
final class AgentCaptureHealthMonitor: ObservableObject {
    @Published private(set) var health: CaptureHealthMetrics = .empty

    private let sessionStore: any SessionStore
    private let processMetricsSampler: any ProcessMetricsSampling
    private var captureStartedAt: Date?
    private var lastUpdateAt: Date = .distantPast
    private var latestProcessMetrics: AppProcessMetrics = .empty
    private var cancellables: Set<AnyCancellable> = []

    init(
        sessionStore: any SessionStore,
        proxyRuntime: any ProxyRuntime,
        processMetricsSampler: any ProcessMetricsSampling = CurrentProcessMetricsSampler()
    ) {
        self.sessionStore = sessionStore
        self.processMetricsSampler = processMetricsSampler
        updateRuntimeState(proxyRuntime.currentState)
        proxyRuntime.statePublisher
            .sink { [weak self] in self?.updateRuntimeState($0) }
            .store(in: &cancellables)
        sessionStore.sessionChangesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIfDue() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        latestProcessMetrics = processMetricsSampler.sample()
        health = CaptureHealthMetrics(
            sessionCount: sessionStore.sessions.count,
            retainedBodyBytes: sessionStore.retainedBodyBytes,
            droppedSessionCount: sessionStore.droppedSessionCount,
            evictedBodyCount: sessionStore.evictedBodyCount,
            captureStartedAt: captureStartedAt,
            processMetrics: latestProcessMetrics
        )
        lastUpdateAt = Date()
    }

    private func updateRuntimeState(_ state: ProxyRuntimeState) {
        if case .running = state {
            if captureStartedAt == nil { captureStartedAt = Date() }
        } else if case .stopped = state {
            captureStartedAt = nil
        }
        refresh()
    }

    private func updateIfDue() {
        guard Date().timeIntervalSince(lastUpdateAt) >= 2 else { return }
        refresh()
    }
}
