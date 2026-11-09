#if os(iOS) && canImport(SafariServices) && canImport(UIKit)
import SafariServices
import UIKit

@MainActor
public final class IOSSetupAssistantPresenter {
    public let assistant: SetupAssistant

    public init(assistant: SetupAssistant) {
        self.assistant = assistant
    }

    @discardableResult
    public func start(in viewController: UIViewController, opensProfileImmediately: Bool = true) -> Bool {
        assistant.start()

        guard opensProfileImmediately,
              let profileURL = assistant.configuration.profileURL else {
            return false
        }

        let safari = SFSafariViewController(url: profileURL)
        viewController.present(safari, animated: true)
        return true
    }

    public func applicationDidBecomeActive() {
        Task {
            _ = await assistant.probeOnce()
        }
    }
}

@MainActor
public extension ProxySDK {
    func startSetupAssistant(
        in viewController: UIViewController,
        configuration: SetupAssistantConfiguration,
        probe: any CertTrustProbing = CertTrustProbe()
    ) -> SetupAssistant {
        let assistant = SetupAssistant(configuration: configuration, probe: probe)
        IOSSetupAssistantPresenter(assistant: assistant).start(in: viewController)
        return assistant
    }
}
#endif
