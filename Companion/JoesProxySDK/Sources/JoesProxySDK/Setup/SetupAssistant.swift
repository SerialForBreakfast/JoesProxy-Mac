import Combine
import Foundation

public struct SetupAssistantConfiguration: Equatable, Sendable {
    public let proxyHost: String
    public let proxyPort: Int
    public let profileURL: URL?
    public let probeIntervalNanoseconds: UInt64

    public init(
        proxyHost: String,
        proxyPort: Int,
        profileURL: URL? = nil,
        probeIntervalNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.profileURL = profileURL
        self.probeIntervalNanoseconds = probeIntervalNanoseconds
    }
}

public extension SetupAssistantConfiguration {
    var profileURLString: String? {
        profileURL?.absoluteString
    }
}

public enum SetupAssistantStep: Equatable, Sendable {
    case checkingProxy
    case configureProxy
    case installCertificate
    case trustCertificate
    case ready
}

@MainActor
public final class SetupAssistant: ObservableObject {
    @Published public private(set) var status: ProxySDKSetupStatus?
    @Published public private(set) var step: SetupAssistantStep = .checkingProxy
    @Published public private(set) var isRunning = false
    @Published public private(set) var certificateWarning: SetupCertificateWarning?

    public let configuration: SetupAssistantConfiguration

    private let probe: any CertTrustProbing
    private let sleep: @Sendable (UInt64) async -> Void
    private var task: Task<Void, Never>?

    public init(
        configuration: SetupAssistantConfiguration,
        probe: any CertTrustProbing = CertTrustProbe(),
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.configuration = configuration
        self.probe = probe
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    public func start() {
        guard task == nil else {
            return
        }
        isRunning = true
        step = .checkingProxy
        task = Task { [weak self] in
            await self?.runProbeLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func probeOnce() async -> ProxySDKSetupStatus {
        let newStatus = await probe.run(
            proxyHost: configuration.proxyHost,
            port: configuration.proxyPort
        )
        apply(newStatus)
        return newStatus
    }

    private func runProbeLoop() async {
        while !Task.isCancelled {
            let newStatus = await probeOnce()
            if case .ready = newStatus {
                stop()
                return
            }
            await sleep(configuration.probeIntervalNanoseconds)
        }
    }

    private func apply(_ newStatus: ProxySDKSetupStatus) {
        status = newStatus
        step = Self.step(for: newStatus)
        certificateWarning = Self.warning(for: newStatus)
    }

    private static func step(for status: ProxySDKSetupStatus) -> SetupAssistantStep {
        switch status {
        case .proxyNotFound:
            return .configureProxy
        case .proxyFoundCertNotInstalled:
            return .installCertificate
        case .proxyFoundCertNotTrusted:
            return .trustCertificate
        case .ready:
            return .ready
        }
    }

    private static func warning(for status: ProxySDKSetupStatus) -> SetupCertificateWarning? {
        guard case .ready(let certificateExpiry?) = status else {
            return nil
        }
        let warningThreshold = Date().addingTimeInterval(14 * 24 * 60 * 60)
        return certificateExpiry < warningThreshold ? .expiresSoon(certificateExpiry) : nil
    }
}

public enum SetupCertificateWarning: Equatable, Sendable {
    case expiresSoon(Date)
}
