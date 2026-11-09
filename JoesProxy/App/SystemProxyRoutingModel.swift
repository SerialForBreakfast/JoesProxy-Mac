import Combine
import Foundation

/// Single source for the user-facing copy around macOS system-proxy routing, shared by
/// Settings, the Simulator Setup walkthrough, the menu bar item, and the main-window indicator.
enum SystemProxyRoutingCopy {
    static func consentMessage(strictCapture: Bool) -> String {
        if strictCapture {
            return "Strict capture routes all Mac and Simulator traffic through JoesProxy with no fallback. If JoesProxy crashes, internet will not work until you reopen JoesProxy or turn the proxy off in System Settings → Network → Proxies."
        }
        return "JoesProxy will route Mac and Simulator traffic through itself while capturing. If JoesProxy stops unexpectedly, traffic automatically falls back to a direct connection, so your network keeps working."
    }

    static let consentTitle = "Route system proxy through JoesProxy?"
}

/// Consent-gated toggle for "route macOS traffic through JoesProxy while capturing".
///
/// Wraps `configuration.isSystemProxyManagementEnabled`. The first enable is gated behind a
/// consent alert (`pendingConsent`); once `hasAcknowledgedSystemProxyRouting` is set the toggle
/// applies directly. Republishes configuration changes so every surface (menu bar, main window,
/// Settings, walkthrough) stays in sync regardless of where the toggle was flipped.
@MainActor
final class SystemProxyRoutingModel: ObservableObject {
    /// True while the first-enable consent alert should be shown.
    @Published var pendingConsent = false

    private let configuration: AppConfiguration
    private var lastIsRoutingEnabled: Bool
    private var lastIsStrictCapture: Bool
    private var cancellables: Set<AnyCancellable> = []

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.lastIsRoutingEnabled = configuration.isSystemProxyManagementEnabled
        self.lastIsStrictCapture = configuration.systemProxyStrictCapture
        configuration.didChangePublisher
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let isRoutingEnabled = self.configuration.isSystemProxyManagementEnabled
                let isStrictCapture = self.configuration.systemProxyStrictCapture
                guard isRoutingEnabled != self.lastIsRoutingEnabled
                        || isStrictCapture != self.lastIsStrictCapture else {
                    return
                }
                self.lastIsRoutingEnabled = isRoutingEnabled
                self.lastIsStrictCapture = isStrictCapture
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Whether routing is armed. Setting `true` before consent raises `pendingConsent`
    /// instead of applying the change.
    var isRoutingEnabled: Bool {
        get { configuration.isSystemProxyManagementEnabled }
        set {
            if newValue, !configuration.hasAcknowledgedSystemProxyRouting {
                pendingConsent = true
                return
            }
            configuration.isSystemProxyManagementEnabled = newValue
        }
    }

    var isStrictCapture: Bool {
        configuration.systemProxyStrictCapture
    }

    var consentMessage: String {
        SystemProxyRoutingCopy.consentMessage(strictCapture: isStrictCapture)
    }

    func confirmConsent() {
        configuration.hasAcknowledgedSystemProxyRouting = true
        pendingConsent = false
        isRoutingEnabled = true
    }

    func cancelConsent() {
        pendingConsent = false
    }
}
