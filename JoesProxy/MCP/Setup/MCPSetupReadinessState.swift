import Foundation

/// Typed app-owned inputs for setup readiness. This value deliberately contains no presentation
/// model reference, captured content, or remote-device claim.
struct MCPSetupReadinessState: Equatable, Sendable {
    enum LocalTrustState: String, Equatable, Sendable {
        case notSetUp
        case installedTrustRequired
        case ready
        case needsCleanup
    }

    enum VerificationState: Equatable, Sendable {
        case inspected
        case tunneled
        case noTrafficObserved
        case proxyStopped
    }

    let localTrustState: LocalTrustState
    let profileHealth: ProfileSnapshotHealth
    let verificationState: VerificationState?
    let profileDownloadObserved: Bool

    init(
        localTrustState: LocalTrustState,
        profileHealth: ProfileSnapshotHealth,
        verificationState: VerificationState?,
        profileDownloadObserved: Bool
    ) {
        self.localTrustState = localTrustState
        self.profileHealth = profileHealth
        self.verificationState = verificationState
        self.profileDownloadObserved = profileDownloadObserved
    }
}
