//
//  SessionStartCoordinator.swift
//  JoesProxy
//
//  Coordinates the session-start lifecycle (BA-2.2), immediately projecting safe
//  hints without awaiting live stores, and reconciling live provider facts independently.
//

import Combine
import Foundation

@MainActor
protocol SessionStartLiveProxyProviding: Sendable {
    func isProxyRunning() async -> Bool
    func proxyPort() -> UInt16
}

@MainActor
protocol SessionStartLiveCertificateProviding: Sendable {
    func checkCertificateStatus() async -> (status: String, isTrusted: Bool)
}

@MainActor
protocol SessionStartLiveRoutingProviding: Sendable {
    func isSystemProxyActive() async -> Bool
}

@MainActor
protocol SessionStartLiveApprovalsProviding: Sendable {
    func pendingApprovals() async -> [WorkingSurfaceApprovalItem]
}

@MainActor
final class SessionStartCoordinator: ObservableObject {

    @Published private(set) var workingSurfaceState: WorkingSurfaceState

    private let configuration: AppConfiguration
    private let proxyProvider: SessionStartLiveProxyProviding?
    private let certificateProvider: SessionStartLiveCertificateProviding?
    private let routingProvider: SessionStartLiveRoutingProviding?
    private let approvalsProvider: SessionStartLiveApprovalsProviding?

    private var domainInputs: OnboardingStateProjector.DomainInputs
    private var reconciliationTask: Task<Void, Never>?

    init(
        configuration: AppConfiguration,
        proxyProvider: SessionStartLiveProxyProviding? = nil,
        certificateProvider: SessionStartLiveCertificateProviding? = nil,
        routingProvider: SessionStartLiveRoutingProviding? = nil,
        approvalsProvider: SessionStartLiveApprovalsProviding? = nil,
        initialLaunchFacts: LaunchInterruptionArbitrator.LaunchFacts? = nil
    ) {
        self.configuration = configuration
        self.proxyProvider = proxyProvider
        self.certificateProvider = certificateProvider
        self.routingProvider = routingProvider
        self.approvalsProvider = approvalsProvider

        let hints = configuration.sessionStartPresentationRecord
        let preferredView = configuration.preferredWorkingView
        let launchFacts = initialLaunchFacts ?? LaunchInterruptionArbitrator.LaunchFacts(
            onboardingLifecycle: configuration.onboardingProgressRecord.lifecycle
        )

        self.domainInputs = OnboardingStateProjector.DomainInputs(
            hints: hints,
            preferredView: preferredView,
            proxyPort: configuration.proxyPort,
            launchFacts: launchFacts
        )

        // Publish initial frame immediately from persisted hints without awaiting any live store
        self.workingSurfaceState = OnboardingStateProjector.project(from: self.domainInputs)
    }

    /// Triggers asynchronous reconciliation of live facts across providers independently.
    func startReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            guard let self else { return }

            // 1. Reconcile Proxy
            if let proxyProvider = self.proxyProvider {
                let running = await proxyProvider.isProxyRunning()
                let port = proxyProvider.proxyPort()
                guard !Task.isCancelled else { return }
                self.domainInputs.proxyRunning = running
                self.domainInputs.proxyPort = port
                self.recomputeState()
            }

            // 2. Reconcile Certificate
            if let certificateProvider = self.certificateProvider {
                let cert = await certificateProvider.checkCertificateStatus()
                guard !Task.isCancelled else { return }
                self.domainInputs.certificateStatus = cert.status
                self.domainInputs.isCertificateTrusted = cert.isTrusted
                self.recomputeState()
            }

            // 3. Reconcile Routing
            if let routingProvider = self.routingProvider {
                let isSystem = await routingProvider.isSystemProxyActive()
                guard !Task.isCancelled else { return }
                self.domainInputs.isSystemProxyActive = isSystem
                self.recomputeState()
            }

            // 4. Reconcile Approvals
            if let approvalsProvider = self.approvalsProvider {
                let approvals = await approvalsProvider.pendingApprovals()
                guard !Task.isCancelled else { return }
                self.domainInputs.pendingApprovals = approvals
                self.recomputeState()
            }
        }
    }

    /// Selects a setup target and persists the hint safely.
    func selectTarget(targetID: String) {
        var hints = configuration.sessionStartPresentationRecord
        hints.selectedTargetID = targetID
        configuration.sessionStartPresentationRecord = hints
        domainInputs.hints = hints
        recomputeState()
    }

    /// Reloads persisted lifecycle, target, and working-view hints after a first-run path choice.
    ///
    /// Call from the Inspector after BA-3 path choice so projection matches durable storage.
    func syncPersistedOnboardingState() {
        domainInputs.hints = configuration.sessionStartPresentationRecord
        domainInputs.preferredView = configuration.preferredWorkingView
        domainInputs.launchFacts.onboardingLifecycle = configuration.onboardingProgressRecord.lifecycle
        recomputeState()
    }

    /// Resolves or dismisses an active launch interruption and recomputes the next interruption dynamically.
    func resolveInterruption(_ kind: LaunchInterruptionKind) {
        switch kind {
        case .systemProxyRecovery:
            domainInputs.launchFacts.hasSystemProxyRoutingDisruption = false
        case .certificateRepair:
            domainInputs.launchFacts.isCertificateUnusable = false
        case .effectConflictRecovery:
            domainInputs.launchFacts.hasActiveEffectConflict = false
        case .savedCaptureRestoration:
            domainInputs.launchFacts.hasUnsavedCaptureRestorationOffer = false
        case .guidedSetup:
            domainInputs.launchFacts.onboardingLifecycle = .completed
            configuration.onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .completed)
        }
        recomputeState()
    }

    private func recomputeState() {
        workingSurfaceState = OnboardingStateProjector.project(from: domainInputs)
    }
}
