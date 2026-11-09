import Foundation

/// Maps the app's existing proxy/routing state to a HUD-tile-sized description and health level.
/// Deliberately a small pure function, not a dependency the view model holds — this is app-specific
/// glue (`AppCoordinator` calls it when building the `proxyStatusProvider` closure), kept separate
/// from `MinimalMonitoringViewModel` so that type stays free of any reference to
/// `SystemProxyController`/`SystemProxyRoutingModel`.
enum MinimalMonitoringProxyStatus {
    static func describe(
        controllerStatus: SystemProxyController.Status,
        hasPendingRecovery: Bool,
        isRoutingEnabled: Bool,
        isProxyRunning: Bool
    ) -> (description: String, level: HealthLevel) {
        if hasPendingRecovery {
            return ("Needs restore", .caution)
        }
        switch controllerStatus {
        case .active:
            return ("Routing active", .safe)
        case .failed:
            return ("Routing failed", .critical)
        case .inactive:
            if isRoutingEnabled {
                return (isProxyRunning ? "Activating…" : "Armed", .safe)
            }
            return (isProxyRunning ? "Running" : "Stopped", .safe)
        }
    }
}
