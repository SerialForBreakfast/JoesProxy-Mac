import Combine
import Foundation
import SwiftUI

/// Runtime-only labels used by the Agent HUD. These stay outside the full title-bar formatter so
/// the Inspector-free target does not inherit its presentation dependencies.
enum AgentRuntimeFormatter {
    static func buttonTitle(state: ProxyRuntimeState, canStart: Bool) -> String {
        switch state {
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        default: return canStart ? "Start" : "Stop"
        }
    }

    static func buttonIcon(canStart: Bool) -> String {
        canStart ? "play.fill" : "stop.fill"
    }

    static func runtimeTint(for state: ProxyRuntimeState) -> Color {
        switch state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

/// Shared runtime start/stop state for Agent supervision surfaces.
///
/// This owner intentionally depends on `ProxyRuntime`, not `ProxyViewModel`, so an Agent shell
/// can supervise listener lifecycle without constructing Inspector presentation state.
@MainActor
final class AgentRuntimeControls: ObservableObject {
    @Published private(set) var proxyState: ProxyRuntimeState

    private let proxyRuntime: any ProxyRuntime
    private var cancellables: Set<AnyCancellable> = []

    init(proxyRuntime: any ProxyRuntime) {
        self.proxyRuntime = proxyRuntime
        proxyState = proxyRuntime.currentState
        proxyRuntime.statePublisher
            .sink { [weak self] in self?.proxyState = $0 }
            .store(in: &cancellables)
    }

    var canStart: Bool {
        switch proxyState {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var canStop: Bool {
        switch proxyState {
        case .starting, .running:
            return true
        case .stopped, .stopping, .failed:
            return false
        }
    }

    var isRunning: Bool {
        if case .running = proxyState { return true }
        return false
    }

    func start() {
        guard canStart else { return }
        Task { await proxyRuntime.start() }
    }

    func stop() {
        guard canStop else { return }
        Task { await proxyRuntime.stop() }
    }
}
