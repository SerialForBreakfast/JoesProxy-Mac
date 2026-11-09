import Foundation
import OSLog

private let tvOSSetupStateLogger = Logger(subsystem: "com.ShowBlender.JoesProxyTV", category: "SetupState")

/// Main-actor state container for the tvOS companion setup flow.
///
/// The state owns only tvOS-local setup progress. Mac proxy/certificate state will later arrive
/// through `TVOSProxySDKFacading` when the SDK event channel is available.
@MainActor
final class TVOSSetupPresentationState: ObservableObject {
    @Published var currentStep: TVOSSetupStep
    @Published var manualMacHost: String {
        didSet {
            userDefaults.set(manualMacHost, forKey: Self.lastManualMacHostKey)
        }
    }
    @Published var pairingToken: String {
        didSet {
            userDefaults.set(pairingToken, forKey: Self.lastPairingTokenKey)
        }
    }
    @Published private(set) var discoveredProxies: [TVOSDiscoveredProxy] = []
    @Published private(set) var selectedProxy: TVOSDiscoveredProxy?
    @Published private(set) var reachabilityResult: TVOSReachabilityResult = .notChecked
    @Published private(set) var confirmedSteps: Set<TVOSSetupStep> = []
    @Published private(set) var connectionState: TVOSProxyConnectionState = .disconnected
    @Published private(set) var receivedEventCount: Int = 0
    @Published private(set) var discoveryStatusMessage: String?
    @Published private(set) var trafficVerificationResult: TVOSTrafficVerificationResult = .ready

    let sdkFacade: any TVOSProxySDKFacading

    private let userDefaults: UserDefaults
    private let urlSession: URLSession
    /// Poll interval while waiting for Mac SDK network events after a verification ping.
    var trafficObservationPollNanoseconds: UInt64 = 500_000_000
    /// Maximum wait for a matching Mac SDK network event after a verification ping.
    var trafficObservationTimeoutNanoseconds: UInt64 = 15_000_000_000
    private static let lastManualMacHostKey = "tvOSCompanion.lastManualMacHost"
    private static let lastPairingTokenKey = "tvOSCompanion.lastPairingToken"
    private static let confirmedStepsKey = "tvOSCompanion.confirmedSteps"
    private static let firstLaunchCompletedKey = "tvOSCompanion.firstLaunchCompleted"

    var profileURLText: String {
        switch reachabilityResult {
        case .reachable(_, let profileURL):
            return profileURL.absoluteString
        case .notChecked, .checking, .blocked:
            if let profileURL = selectedProxy?.profileURL {
                return profileURL.absoluteString
            }
            let host = TVOSDiscoveredProxy.normalizedHost(manualMacHost)
            return host.isEmpty ? "http://<mac-ip>:8765/profile" : "http://\(host):8765/profile"
        }
    }

    var setupProgressText: String {
        "\(confirmedSteps.intersection(Set(TVOSSetupStep.progressSteps)).count) of \(TVOSSetupStep.progressSteps.count) setup steps confirmed"
    }

    init(
        sdkFacade: any TVOSProxySDKFacading,
        userDefaults: UserDefaults = .standard,
        urlSession: URLSession = .shared
    ) {
        self.sdkFacade = sdkFacade
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        self.manualMacHost = userDefaults.string(forKey: Self.lastManualMacHostKey) ?? ""
        self.pairingToken = userDefaults.string(forKey: Self.lastPairingTokenKey) ?? ""
        self.currentStep = userDefaults.bool(forKey: Self.firstLaunchCompletedKey) ? .findMac : .welcome

        if let rawValues = userDefaults.array(forKey: Self.confirmedStepsKey) as? [Int] {
            self.confirmedSteps = Set(rawValues.compactMap(TVOSSetupStep.init(rawValue:)))
        }

        tvOSSetupStateLogger.info(
            "Setup state initialized currentStep=\(self.currentStep.title, privacy: .public) manualHostPresent=\(!self.manualMacHost.isEmpty, privacy: .public) confirmedStepCount=\(self.confirmedSteps.count, privacy: .public)"
        )
    }

    func status(for step: TVOSSetupStep) -> TVOSSetupStepStatus {
        if step == .verifyTraffic {
            if trafficVerificationResult.isSuccess {
                return .passed
            }
            if confirmedSteps.contains(step) {
                return .manualConfirmed
            }
        }

        if currentStep == step {
            return .inProgress
        }

        switch step {
        case .checkReachability:
            switch reachabilityResult {
            case .reachable:
                return .passed
            case .blocked(let issue):
                return .blocked(issue)
            case .checking:
                return .inProgress
            case .notChecked:
                break
            }
        case .troubleshooting:
            return .notStarted
        default:
            break
        }

        if confirmedSteps.contains(step) {
            return .manualConfirmed
        }

        return .notStarted
    }

    func go(to step: TVOSSetupStep) {
        tvOSSetupStateLogger.info(
            "Navigating setup step from=\(self.currentStep.title, privacy: .public) to=\(step.title, privacy: .public)"
        )
        currentStep = step
        if step != .welcome {
            userDefaults.set(true, forKey: Self.firstLaunchCompletedKey)
        }
    }

    func goToNextStep() {
        let steps = TVOSSetupStep.progressSteps
        guard let index = steps.firstIndex(of: currentStep), index + 1 < steps.count else {
            return
        }
        go(to: steps[index + 1])
    }

    func markCurrentStepComplete(advance: Bool = true) {
        tvOSSetupStateLogger.info("Marking setup step complete step=\(self.currentStep.title, privacy: .public)")
        confirmedSteps.insert(currentStep)
        persistConfirmedSteps()
        recordAnnotation(for: currentStep)
        if advance, currentStep != .verifyTraffic {
            if currentStep == .welcome {
                go(to: .findMac)
            } else {
                goToNextStep()
            }
        }
    }

    /// Sends a small HTTP request through the Apple TV's configured global proxy so JoesProxy on the Mac can observe device traffic.
    ///
    /// Concurrency: call from the main actor (views use `Task { await ... }`). Network work uses `URLSession` and does not block the UI thread.
    func sendTrafficVerificationPing() async {
        trafficVerificationResult = .pinging
        tvOSSetupStateLogger.info("Traffic verification ping started")

        let verificationURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
        var request = URLRequest(url: verificationURL)
        request.timeoutInterval = 20
        request.setValue("JoesProxyTV-SetupVerify/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 399).contains(http.statusCode) else {
                trafficVerificationResult = .failed("Verification ping returned an unexpected HTTP status.")
                return
            }
        } catch {
            trafficVerificationResult = .failed(error.localizedDescription)
            tvOSSetupStateLogger.error("Traffic verification ping failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        trafficVerificationResult = .watchingForCapture
        confirmedSteps.insert(.verifyTraffic)
        persistConfirmedSteps()
        await recordVerificationAnnotation()
        await observeTrafficFromMacSDK()
        tvOSSetupStateLogger.info(
            "Traffic verification finished result=\(self.trafficVerificationResult.logDescription, privacy: .public)"
        )
    }

    /// Polls SDK `networkEvent` messages from the Mac and classifies capture depth for the verification ping.
    func observeTrafficFromMacSDK() async {
        var elapsed: UInt64 = 0
        while elapsed < trafficObservationTimeoutNanoseconds {
            receivedEventCount = await sdkFacade.transport.collectedEvents().count
            let events = await sdkFacade.transport.collectedNetworkEvents()
            if let result = TVOSNetworkEventObservation.verificationResult(from: events) {
                trafficVerificationResult = result
                return
            }

            try? await Task.sleep(nanoseconds: trafficObservationPollNanoseconds)
            elapsed += trafficObservationPollNanoseconds
        }

        trafficVerificationResult = .noTrafficObserved
    }

    func discoverAndConnect(source: String = "manual") async {
        tvOSSetupStateLogger.info("Discovery started source=\(source, privacy: .public)")
        discoveryStatusMessage = "Searching for JoesProxy on the local network."
        connectionState = .discovering
        let proxies = await sdkFacade.discoveryService.discover()
        tvOSSetupStateLogger.info("Discovery completed source=\(source, privacy: .public) proxyCount=\(proxies.count, privacy: .public)")
        discoveredProxies = proxies
        selectedProxy = proxies.first
        if let selectedProxy {
            tvOSSetupStateLogger.info(
                "Discovery selected proxy name=\(selectedProxy.name, privacy: .public) host=\(selectedProxy.host, privacy: .public) profilePort=\(selectedProxy.profilePort, privacy: .public) sdkPort=\(selectedProxy.sdkPort ?? 0, privacy: .public)"
            )
            manualMacHost = selectedProxy.host
            discoveryStatusMessage = "Found \(selectedProxy.name) at \(selectedProxy.host). Connecting to SDK event channel."
            connectionState = .connecting(selectedProxy)
            let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
            connectionState = await sdkFacade.transport.connect(
                to: selectedProxy,
                pairingToken: token.isEmpty ? nil : token
            )
            tvOSSetupStateLogger.info("Discovery connection result state=\(self.connectionState.logDescription, privacy: .public)")
        } else {
            connectionState = .rejected(TVOSSetupIssue.macNotFound.title)
            discoveryStatusMessage = "No Mac was found with Bonjour. Confirm JoesProxy is running on the Mac, SDK connections are enabled, and both devices are on the same network. You can also enter the Mac IP address manually."
            tvOSSetupStateLogger.warning("Discovery found no proxies source=\(source, privacy: .public)")
        }
        receivedEventCount = await sdkFacade.transport.collectedEvents().count
        tvOSSetupStateLogger.info("SDK event count refreshed after discovery count=\(self.receivedEventCount, privacy: .public)")
    }

    func refreshEventCount() async {
        receivedEventCount = await sdkFacade.transport.collectedEvents().count
        tvOSSetupStateLogger.info("SDK event count refreshed count=\(self.receivedEventCount, privacy: .public)")
    }

    func checkReachability() async {
        let host = TVOSDiscoveredProxy.normalizedHost(manualMacHost)
        tvOSSetupStateLogger.info(
            "Reachability check started hostPresent=\(!host.isEmpty, privacy: .public) selectedProxyPresent=\((self.selectedProxy != nil), privacy: .public)"
        )
        if manualMacHost != host {
            manualMacHost = host
        }
        reachabilityResult = .checking
        reachabilityResult = await sdkFacade.setupProbe.probeProfileServer(
            host: host,
            port: selectedProxy?.profilePort ?? 8765,
            path: selectedProxy?.profilePath ?? "profile"
        )
        tvOSSetupStateLogger.info("Reachability check completed result=\(self.reachabilityResult.logDescription, privacy: .public)")
        if case .reachable = reachabilityResult {
            confirmedSteps.insert(.checkReachability)
            persistConfirmedSteps()
        }
    }

    private func persistConfirmedSteps() {
        userDefaults.set(confirmedSteps.map(\.rawValue).sorted(), forKey: Self.confirmedStepsKey)
    }

    private func recordAnnotation(for step: TVOSSetupStep) {
        let draft: TVOSAnnotationDraft?
        switch step {
        case .welcome:
            draft = TVOSAnnotationDraft(kind: .setupStarted, label: "Apple TV setup started")
        case .openHiddenProfilesMenu:
            draft = TVOSAnnotationDraft(kind: .hiddenMenuReached, label: "Hidden Profiles menu reached")
        case .installProfile:
            draft = TVOSAnnotationDraft(kind: .profileInstalled, label: "Apple TV profile installed")
        case .trustCertificate:
            draft = TVOSAnnotationDraft(kind: .certificateTrusted, label: "Apple TV certificate trusted")
        case .verifyTraffic, .findMac, .checkReachability, .troubleshooting:
            draft = nil
        }

        guard let draft else { return }
        tvOSSetupStateLogger.info("Recording setup annotation step=\(step.title, privacy: .public) kind=\(draft.kind.rawValue, privacy: .public)")
        Task {
            await sdkFacade.annotationSender.record(draft)
        }
    }

    private func recordVerificationAnnotation() async {
        let draft = TVOSAnnotationDraft(
            kind: .setupVerificationPing,
            label: "Apple TV setup verification ping",
            metadata: ["source": "tvOSCompanion"]
        )
        tvOSSetupStateLogger.info("Recording setup verification annotation")
        await sdkFacade.annotationSender.record(draft)
    }
}

private extension TVOSTrafficVerificationResult {
    var logDescription: String {
        switch self {
        case .ready:
            return "ready"
        case .pinging:
            return "pinging"
        case .watchingForCapture:
            return "watchingForCapture"
        case .trafficInspected(let host):
            return "trafficInspected(\(host))"
        case .trafficTunneled(let host):
            return "trafficTunneled(\(host))"
        case .trafficObserved(let host):
            return "trafficObserved(\(host))"
        case .noTrafficObserved:
            return "noTrafficObserved"
        case .failed(let message):
            return "failed(\(message))"
        }
    }
}

private extension TVOSProxyConnectionState {
    var logDescription: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .discovering:
            return "discovering"
        case .connecting(let proxy):
            return "connecting(\(proxy.host))"
        case .connected(let proxy):
            return "connected(\(proxy.host))"
        case .rejected(let reason):
            return "rejected(\(reason))"
        }
    }
}

private extension TVOSReachabilityResult {
    var logDescription: String {
        switch self {
        case .notChecked:
            return "notChecked"
        case .checking:
            return "checking"
        case .reachable(let baseURL, let profileURL):
            return "reachable(base=\(baseURL.absoluteString), profile=\(profileURL.absoluteString))"
        case .blocked(let issue):
            return "blocked(\(issue.title))"
        }
    }
}
