import Foundation
import os

/// Coordinates automatic macOS system proxy management around the proxy capture lifecycle.
/// Enabling captures the user's prior settings (persisted for crash recovery), points the active
/// network service at JoesProxy, and exposes a visible status. Disabling restores the prior settings.
@MainActor
final class SystemProxyController: ObservableObject {
    enum Status: Equatable {
        case inactive
        case active(host: String, port: UInt16, service: String)
        case failed(String)
    }

    /// How traffic is routed when system-proxy management is active.
    enum Mode: Equatable {
        /// PAC with a `; DIRECT` fallback — fails open if JoesProxy stops (recommended default).
        case pacFailOpen
        /// Static web/secure proxy — no fallback, fails closed if JoesProxy stops.
        case strictStatic
    }

    @Published private(set) var status: Status = .inactive
    @Published private(set) var pendingRecovery: SystemProxySnapshot?

    private let manager: any SystemProxyManaging
    private let stateStore: any SystemProxyStateStore
    private let pacServer: any PACHosting
    private let host: String
    private let logger = Logger(subsystem: "com.JoesProxyApp.SystemProxy", category: "Controller")
    /// Serializes enable/disable so reconcile firing from multiple sources can't double-apply
    /// (a second enable would snapshot our own proxy as the "prior" settings).
    private var isApplying = false

    init(
        manager: any SystemProxyManaging = NetworksetupSystemProxyManager(),
        stateStore: any SystemProxyStateStore = UserDefaultsSystemProxyStateStore(),
        pacServer: any PACHosting = PACHostingServer(),
        host: String = "127.0.0.1"
    ) {
        self.manager = manager
        self.stateStore = stateStore
        self.pacServer = pacServer
        self.host = host
    }

    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    /// Captures the current system proxy settings, persists them, then routes the active network
    /// service through JoesProxy at the given port using the requested mode.
    func enable(port: UInt16, mode: Mode) async {
        if case .active = status {
            return
        }
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        logger.info("System proxy: enable requested port=\(port, privacy: .public) mode=\(String(describing: mode), privacy: .public)")
        do {
            let service = try await manager.activePrimaryServiceName()
            logger.info("System proxy: active network service=\(service, privacy: .public)")
            let snapshot = try await manager.readSnapshot(serviceName: service)
            stateStore.pendingSnapshot = snapshot
            logger.info("System proxy: captured prior settings httpEnabled=\(snapshot.httpEnabled, privacy: .public) httpsEnabled=\(snapshot.httpsEnabled, privacy: .public) autoProxyEnabled=\(snapshot.autoProxyEnabled, privacy: .public)")

            switch mode {
            case .pacFailOpen:
                let pacURL = try await pacServer.start(proxyPort: port)
                try await manager.enablePAC(pacURL: pacURL, serviceName: service)
                logger.info("System proxy: enabled PAC fail-open \(pacURL, privacy: .public) on service=\(service, privacy: .public)")
            case .strictStatic:
                try await manager.enableProxy(host: host, port: port, serviceName: service)
                logger.info("System proxy: enabled strict static \(self.host, privacy: .public):\(port, privacy: .public) on service=\(service, privacy: .public)")
            }

            status = .active(host: host, port: port, service: service)
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("System proxy: enable failed: \(error.localizedDescription, privacy: .public)")
            await pacServer.stop()
        }
    }

    /// Restores the previously captured system proxy settings and clears the persisted snapshot.
    /// No-op when nothing was captured.
    func disable() async {
        guard !isApplying else { return }
        guard let snapshot = stateStore.pendingSnapshot else {
            status = .inactive
            return
        }
        isApplying = true
        defer { isApplying = false }
        logger.info("System proxy: disable requested, restoring service=\(snapshot.serviceName, privacy: .public)")
        do {
            try await manager.restore(snapshot)
            await pacServer.stop()
            stateStore.pendingSnapshot = nil
            status = .inactive
            logger.info("System proxy: restored prior settings on service=\(snapshot.serviceName, privacy: .public)")
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("System proxy: disable/restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Synchronously restores the system proxy before the app exits on a graceful quit. The async
    /// `disable()` would not finish before the process terminates, so this blocks briefly while
    /// `networksetup` runs. No-op when nothing is being managed. Force-quit/crash is handled by
    /// `recoverIfNeeded()` on the next launch instead.
    func cleanUpForQuit() {
        guard let snapshot = stateStore.pendingSnapshot else { return }
        logger.info("System proxy: restoring on quit for service=\(snapshot.serviceName, privacy: .public)")
        manager.restoreSynchronously(snapshot)
        stateStore.pendingSnapshot = nil
        status = .inactive
    }

    /// On launch, surfaces a recovery offer if a snapshot was left behind by a previous run that
    /// did not restore it (force-quit or crash while active).
    func recoverIfNeeded() {
        pendingRecovery = stateStore.pendingSnapshot
        if let pendingRecovery {
            logger.info("System proxy: stale snapshot found at launch for service=\(pendingRecovery.serviceName, privacy: .public); offering recovery")
        }
    }

    /// Restores the prior settings captured before the unclean shutdown, then clears the offer.
    func confirmRecovery() async {
        guard let snapshot = pendingRecovery else { return }
        do {
            try await manager.restore(snapshot)
            await pacServer.stop()
            stateStore.pendingSnapshot = nil
            pendingRecovery = nil
            status = .inactive
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Dismisses the recovery offer without restoring, accepting the current system proxy state.
    func dismissRecovery() {
        stateStore.pendingSnapshot = nil
        pendingRecovery = nil
    }
}
