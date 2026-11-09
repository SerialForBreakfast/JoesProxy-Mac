import Foundation
import Combine

final class UITestCertificateAuthority: CertificateAuthorityProviding {
    private(set) var currentIdentity: RootCertificateIdentity?

    init(currentIdentity: RootCertificateIdentity?) {
        self.currentIdentity = currentIdentity
    }

    func currentRootCertificate() -> RootCertificateIdentity? {
        currentIdentity
    }

    func loadOrCreateRootCertificate() throws -> RootCertificateIdentity {
        if let currentIdentity {
            return currentIdentity
        }

        let createdIdentity = Self.demoIdentity
        currentIdentity = createdIdentity
        return createdIdentity
    }

    func issueLeafCertificate(for host: String) throws -> IssuedLeafCertificate {
        throw CertificateAuthorityError.unsupportedOperation("UI-test certificate authority does not issue leaf certificates.")
    }

    static let demoIdentity = RootCertificateIdentity(
        label: CertificateNaming.productionRootCA,
        subjectSummary: "JoesProxy Root CA",
        certificateData: Data([0x00, 0x01, 0x02]),
        privateKeyData: Data([0x03, 0x04, 0x05])
    )
}

final class UITestCertificateStore: CertificateStore {
    var identity: RootCertificateIdentity?

    init(identity: RootCertificateIdentity?) {
        self.identity = identity
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        guard identity?.label == label else {
            return nil
        }
        return identity
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        self.identity = identity
    }

    func removeRootCertificate(label: String) throws {
        if identity?.label == label {
            identity = nil
        }
    }
}

final class UITestTrustInstaller: TrustInstalling {
    var status: TrustInstallationStatus

    init(status: TrustInstallationStatus) {
        self.status = status
    }

    func installationStatus(for label: String) -> TrustInstallationStatus {
        status
    }

    func install(_ identity: RootCertificateIdentity) throws {
        status = .trustRequired(reason: "Not trusted")
    }

    func removeCertificate(label: String) throws {
        status = .notInstalled
    }
}

@MainActor
final class UITestProxyRuntime: ProxyRuntime {
    private let stateSubject: CurrentValueSubject<ProxyRuntimeState, Never>
    private let configuredPort: UInt16

    init(initialState: ProxyRuntimeState, configuredPort: UInt16) {
        stateSubject = CurrentValueSubject(initialState)
        self.configuredPort = configuredPort
    }

    var currentState: ProxyRuntimeState {
        stateSubject.value
    }

    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func start() async {
        stateSubject.send(.running(port: portForCurrentState))
    }

    func stop() async {
        stateSubject.send(.stopped)
    }

    func sdkEventServerStatus() async -> SDKEventServerStatus {
        .stopped
    }

    private var portForCurrentState: UInt16 {
        switch currentState {
        case .starting(let port), .running(let port):
            return port
        case .stopped, .stopping, .failed:
            return configuredPort
        }
    }
}
