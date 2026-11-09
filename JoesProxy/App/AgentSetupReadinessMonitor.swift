import Foundation

/// Builds setup-readiness inputs from runtime owners rather than Inspector presentation state.
///
/// The monitor deliberately reads the canonical session store for the bounded verification
/// classification. It does not create filtered rows, selections, or Inspector analysis caches.
@MainActor
final class AgentSetupReadinessMonitor {
    private let configuration: any AppConfiguration
    private let proxyRuntime: any ProxyRuntime
    private let sessionStore: any SessionStore
    private let certificateAuthority: any CertificateAuthorityProviding
    private let trustInstaller: any TrustInstalling
    private let certificateStatusReader: (any CertificateStatusReading)?
    private let profileSnapshotStore: any ProfileSnapshotStoring
    private let localNetworkInfoProvider: any LocalNetworkInfoProviding

    init(
        configuration: any AppConfiguration,
        proxyRuntime: any ProxyRuntime,
        sessionStore: any SessionStore,
        certificateAuthority: any CertificateAuthorityProviding,
        trustInstaller: any TrustInstalling,
        certificateStatusReader: (any CertificateStatusReading)? = nil,
        profileSnapshotStore: any ProfileSnapshotStoring,
        localNetworkInfoProvider: any LocalNetworkInfoProviding
    ) {
        self.configuration = configuration
        self.proxyRuntime = proxyRuntime
        self.sessionStore = sessionStore
        self.certificateAuthority = certificateAuthority
        self.trustInstaller = trustInstaller
        self.certificateStatusReader = certificateStatusReader
        self.profileSnapshotStore = profileSnapshotStore
        self.localNetworkInfoProvider = localNetworkInfoProvider
    }

    func readinessState() async -> MCPSetupReadinessState {
        let certificateStatus: CertificateStatusSnapshot
        if let certificateStatusReader {
            certificateStatus = await certificateStatusReader.readStatus()
        } else {
            certificateStatus = CertificateStatusSnapshot(
                rootCertificate: certificateAuthority.currentRootCertificate(),
                trustStatus: trustInstaller.installationStatus(for: configuration.certificateLabel)
            )
        }

        let profileHealth = ProfileSnapshotDiagnosis.evaluate(
            snapshot: profileSnapshotStore.loadSnapshots().first,
            currentNetworkInfo: localNetworkInfoProvider.current(),
            currentProxyPort: configuration.proxyPort,
            currentCertificateFingerprint: certificateStatus.rootCertificate.map {
                ProfileSnapshotFactory.certificateFingerprint(from: $0.certificateData)
            }
        ).health

        return MCPSetupReadinessState(
            localTrustState: Self.localTrustState(for: certificateStatus.trustStatus),
            profileHealth: profileHealth,
            verificationState: verificationState(),
            // Profile delivery is a short-lived setup-surface observation. Do not turn an absent
            // Inspector surface into an invented delivery claim.
            profileDownloadObserved: false
        )
    }

    private func verificationState() -> MCPSetupReadinessState.VerificationState? {
        switch proxyRuntime.currentState {
        case .stopped, .stopping, .failed:
            return .proxyStopped
        case .starting:
            return .noTrafficObserved
        case .running:
            break
        }

        let sessions = sessionStore.sessions
        if sessions.contains(where: { session in
            session.request.scheme == .https &&
                session.response != nil &&
                session.request.inspectionKind != .tunneledTLS
        }) {
            return .inspected
        }
        if sessions.contains(where: { session in
            session.request.scheme == .https && session.request.inspectionKind == .tunneledTLS
        }) {
            return .tunneled
        }
        return .noTrafficObserved
    }

    private static func localTrustState(
        for status: TrustInstallationStatus
    ) -> MCPSetupReadinessState.LocalTrustState {
        switch status {
        case .notInstalled:
            return .notSetUp
        case .trustRequired:
            return .installedTrustRequired
        case .installed:
            return .ready
        case .invalid:
            return .needsCleanup
        }
    }
}
