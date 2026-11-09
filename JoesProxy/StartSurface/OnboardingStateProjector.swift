//
//  OnboardingStateProjector.swift
//  JoesProxy
//
//  Projects live domain states and persisted safe presentation hints into a unified
//  WorkingSurfaceState model (BA-2.3). Preserves presentation truth and guarantees
//  deterministic row ordering.
//

import Foundation

enum OnboardingStateProjector {

    struct DomainInputs: Sendable {
        var hints: SessionStartPresentationRecord
        var preferredView: WorkingViewPreference
        var proxyRunning: Bool?
        var proxyPort: UInt16
        var certificateStatus: String?
        var isCertificateTrusted: Bool?
        var isSystemProxyActive: Bool?
        var pendingApprovals: [WorkingSurfaceApprovalItem]
        var launchFacts: LaunchInterruptionArbitrator.LaunchFacts

        init(
            hints: SessionStartPresentationRecord = .default,
            preferredView: WorkingViewPreference = .inspector,
            proxyRunning: Bool? = nil,
            proxyPort: UInt16 = NetworkConstants.defaultPort,
            certificateStatus: String? = nil,
            isCertificateTrusted: Bool? = nil,
            isSystemProxyActive: Bool? = nil,
            pendingApprovals: [WorkingSurfaceApprovalItem] = [],
            launchFacts: LaunchInterruptionArbitrator.LaunchFacts = LaunchInterruptionArbitrator.LaunchFacts()
        ) {
            self.hints = hints
            self.preferredView = preferredView
            self.proxyRunning = proxyRunning
            self.proxyPort = proxyPort
            self.certificateStatus = certificateStatus
            self.isCertificateTrusted = isCertificateTrusted
            self.isSystemProxyActive = isSystemProxyActive
            self.pendingApprovals = pendingApprovals
            self.launchFacts = launchFacts
        }
    }

    /// Pure projection mapping domain inputs into an immutable WorkingSurfaceState.
    static func project(from inputs: DomainInputs) -> WorkingSurfaceState {
        var statusRows: [WorkingSurfaceStatusRow] = []

        // 1. Proxy status row
        let proxyTruth: PresentationTruth
        if let running = inputs.proxyRunning {
            proxyTruth = running ? .current("Running on port \(inputs.proxyPort)") : .current("Stopped")
        } else if let summary = inputs.hints.lastVerificationSummary, let timestamp = inputs.hints.lastVerifiedAt {
            proxyTruth = .lastKnown(summary: summary, timestamp: timestamp)
        } else {
            proxyTruth = .checking
        }
        statusRows.append(
            WorkingSurfaceStatusRow(
                id: "status.proxy",
                category: .proxy,
                label: "Proxy Engine",
                truth: proxyTruth
            )
        )

        // 2. Certificate status row
        let certTruth: PresentationTruth
        if let certStatus = inputs.certificateStatus {
            let trustedText = (inputs.isCertificateTrusted == true) ? "Trusted" : "Trust Required"
            certTruth = .current("\(certStatus) (\(trustedText))")
        } else if let timestamp = inputs.hints.lastVerifiedAt {
            certTruth = .lastKnown(summary: "CA Installed", timestamp: timestamp)
        } else {
            certTruth = .checking
        }
        statusRows.append(
            WorkingSurfaceStatusRow(
                id: "status.certificate",
                category: .certificate,
                label: "HTTPS & Root CA",
                truth: certTruth
            )
        )

        // 3. Routing status row
        let routingTruth: PresentationTruth
        if let isSystem = inputs.isSystemProxyActive {
            routingTruth = isSystem ? .current("System Proxy Active") : .current("Direct / App Targeted")
        } else {
            routingTruth = .checking
        }
        statusRows.append(
            WorkingSurfaceStatusRow(
                id: "status.routing",
                category: .routing,
                label: "Network Routing",
                truth: routingTruth
            )
        )

        // 4. Target status row
        if let targetID = inputs.hints.selectedTargetID {
            statusRows.append(
                WorkingSurfaceStatusRow(
                    id: "status.target",
                    category: .client,
                    label: "Selected Target",
                    truth: .current(targetID.capitalized)
                )
            )
        }

        // Project Issues with ActionOwnershipResolver
        var issues: [WorkingSurfaceIssueItem] = []

        if inputs.launchFacts.hasSystemProxyRoutingDisruption {
            let owner = ActionOwnershipResolver.resolveOwner(
                for: .restoreSystemProxy,
                pendingApprovals: inputs.pendingApprovals,
                localIssueAction: (actionID: "restore_system_proxy", title: "Restore System Proxy")
            )
            issues.append(
                WorkingSurfaceIssueItem(
                    id: "issue.routing_disrupted",
                    severity: .critical,
                    title: "System Proxy Disrupted",
                    message: "Previous proxy settings were not cleaned up cleanly on quit.",
                    actionOwner: owner
                )
            )
        }

        if inputs.launchFacts.isCertificateUnusable {
            let owner = ActionOwnershipResolver.resolveOwner(
                for: .repairCertificate,
                pendingApprovals: inputs.pendingApprovals,
                localIssueAction: (actionID: "repair_certificate", title: "Repair Certificate")
            )
            issues.append(
                WorkingSurfaceIssueItem(
                    id: "issue.cert_unusable",
                    severity: .critical,
                    title: "Root Certificate Unusable",
                    message: "HTTPS inspection is disabled until the root certificate is repaired.",
                    actionOwner: owner
                )
            )
        }

        if inputs.proxyRunning == false {
            let owner = ActionOwnershipResolver.resolveOwner(
                for: .startProxy,
                pendingApprovals: inputs.pendingApprovals,
                localIssueAction: (actionID: "start_proxy", title: "Start Proxy")
            )
            issues.append(
                WorkingSurfaceIssueItem(
                    id: "issue.proxy_stopped",
                    severity: .info,
                    title: "Proxy Engine Stopped",
                    message: "Start the proxy to begin capturing traffic.",
                    actionOwner: owner
                )
            )
        }

        // Sort issues deterministically by severity (critical first)
        issues.sort { $0.severity < $1.severity }

        let activeInterruption = LaunchInterruptionArbitrator.nextInterruption(from: inputs.launchFacts)

        return WorkingSurfaceState(
            selectedTargetID: inputs.hints.selectedTargetID,
            preferredView: inputs.preferredView,
            statusRows: statusRows,
            pendingApprovals: inputs.pendingApprovals,
            issues: issues,
            activeInterruption: activeInterruption
        )
    }
}
