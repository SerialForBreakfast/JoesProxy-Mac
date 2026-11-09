import Combine
import Foundation
import OSLog

enum ProxyRuntimeState: Equatable {
    case stopped
    case starting(port: UInt16)
    case running(port: UInt16)
    case stopping
    case failed(message: String)

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }

    /// Stable accessibility value for the proxy toggle. UI tests wait on `"running"` rather than button copy.
    var accessibilityRuntimeValue: String {
        switch self {
        case .stopped:
            return "stopped"
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .stopping:
            return "stopping"
        case .failed:
            return "failed"
        }
    }
}

@MainActor
protocol ProxyRuntime: AnyObject {
    var currentState: ProxyRuntimeState { get }
    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> { get }

    func start() async
    func stop() async
    func sdkEventServerStatus() async -> SDKEventServerStatus
}

@MainActor
final class DefaultProxyRuntime: ProxyRuntime {
    var currentState: ProxyRuntimeState {
        stateSubject.value
    }

    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    private let configuration: AppConfiguration
    private let server: ProxyServer
    private let sdkEventServer: (any SDKEventServing)?
    private let stateSubject: CurrentValueSubject<ProxyRuntimeState, Never>
    private let logger = Logger(subsystem: "com.JoesProxyApp", category: "ProxyRuntime")
    private var cancellables: Set<AnyCancellable> = []
    /// Tracks whether `sdkEventServer` is believed to be running, so overlapping
    /// `syncSDKEventServerWithCurrentState()` calls (e.g. from the `start()` path and
    /// a `configuration.didChangePublisher` tick firing in close succession) settle on
    /// the desired state once instead of issuing redundant start/stop calls.
    private var isSDKEventServerRunning = false

    init(
        configuration: AppConfiguration,
        server: ProxyServer,
        sdkEventServer: (any SDKEventServing)? = nil
    ) {
        // Proxy runtime state is consumed only by UI-facing view models. Keep the
        // subject main-actor isolated so start/stop transitions are serialized and
        // never published from arbitrary executors.
        self.configuration = configuration
        self.server = server
        self.sdkEventServer = sdkEventServer
        self.stateSubject = CurrentValueSubject(.stopped)
        self.server.port = configuration.proxyPort

        configuration.didChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncSDKEventServerWithCurrentState()
                }
            }
            .store(in: &cancellables)
    }

    func start() async {
        if case .starting = currentState {
            return
        }
        if case .running = currentState {
            return
        }

        server.port = configuration.proxyPort
        stateSubject.send(.starting(port: server.port))

        do {
            try await server.start()
            configuration.proxyPort = server.port
            await syncSDKEventServerWithCurrentState(forceStart: true)
            stateSubject.send(.running(port: server.port))
        } catch {
            let presentation = NetworkFailureClassifier.presentation(for: error)
            stateSubject.send(.failed(message: presentation.userFacingMessage))
        }
    }

    func stop() async {
        if case .stopped = currentState {
            return
        }

        stateSubject.send(.stopping)
        await sdkEventServer?.stop()
        isSDKEventServerRunning = false
        await server.stop()
        stateSubject.send(.stopped)
    }

    func sdkEventServerStatus() async -> SDKEventServerStatus {
        guard let sdkEventServer else { return .stopped }
        return await sdkEventServer.status()
    }

    private func syncSDKEventServerWithCurrentState(forceStart: Bool = false) async {
        guard let sdkEventServer else {
            return
        }

        let shouldRun: Bool
        switch currentState {
        case .running:
            shouldRun = configuration.sdkEventServerEnabled
        case .starting:
            guard forceStart else {
                return
            }
            shouldRun = forceStart && configuration.sdkEventServerEnabled
        case .stopped, .stopping, .failed:
            shouldRun = false
        }

        guard shouldRun != isSDKEventServerRunning else {
            return
        }

        // Claim the target state before the first suspension point so an overlapping
        // sync call (interleaved while this one awaits start/stop) sees the update
        // immediately and bails out via the guard above instead of issuing a duplicate
        // start/stop call.
        isSDKEventServerRunning = shouldRun

        if shouldRun {
            do {
                try await sdkEventServer.start(port: configuration.sdkEventServerPort)
            } catch {
                logger.error("SDK event server failed to start: \(String(describing: error), privacy: .public)")
                isSDKEventServerRunning = false
            }
        } else {
            await sdkEventServer.stop()
        }
    }
}
