import AppKit

/// App-owned notification bridge; its lifetime is independent of either workspace view.
@MainActor
final class EffectBundleSleepObserver: NSObject {
    private let coordinator: EffectBundleActivationCoordinator

    init(coordinator: EffectBundleActivationCoordinator) {
        self.coordinator = coordinator
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(suspendTimedRuns), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspendTimedRuns), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func suspendTimedRuns(_ notification: Notification) {
        let isSleeping = notification.name == NSWorkspace.willSleepNotification
        Task { await coordinator.handleSleepState(isSleeping: isSleeping) }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}
