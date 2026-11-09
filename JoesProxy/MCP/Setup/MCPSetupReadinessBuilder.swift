import Foundation

/// Builds bounded, orthogonal onboarding evidence from app-owned state.
///
/// This deliberately omits LAN addresses, certificate fingerprints, profile bytes, and captured
/// content. Those values remain behind the existing explicit disclosure profiles and are not needed
/// to tell a user what action to take next.
@MainActor
enum MCPSetupReadinessBuilder {
    static func make(
        target: MCPSetupReadinessTarget,
        host: MCPManagedRuntimeHostStatusDTO,
        credentialState: MCPClientCredentialState,
        readinessState: MCPSetupReadinessState
    ) -> MCPSetupReadinessDTO {
        let hostReady = host.appState == "running"
        let proxyReady = host.proxyState == "running"
        let trustState = readinessState.localTrustState

        var checks: [MCPSetupReadinessCheckDTO] = [
            MCPSetupReadinessCheckDTO(
                id: "host.app",
                state: hostReady ? .confirmed : .needsUserConfirmation,
                detail: hostReady ? "JoesProxy is running." : "JoesProxy is not confirmed to be running.",
                evidence: hostReady ? "app_runtime_running" : nil,
                actor: .app,
                nextHumanAction: hostReady ? nil : "Open JoesProxy and complete the core setup flow.",
                confidenceBoundary: "App-local runtime state only."
            ),
            MCPSetupReadinessCheckDTO(
                id: "host.proxy",
                state: proxyReady ? .confirmed : .needsUserConfirmation,
                detail: proxyReady ? "The local proxy listener is running." : "The local proxy listener is not running.",
                evidence: proxyReady ? "proxy_running" : nil,
                actor: .app,
                nextHumanAction: proxyReady ? nil : "Start the proxy in JoesProxy.",
                confidenceBoundary: "Does not prove a target device is using this proxy."
            ),
            MCPSetupReadinessCheckDTO(
                id: "agent.credential",
                state: credentialState == .active ? .confirmed : .needsUserConfirmation,
                detail: credentialState == .active ? "The connected client credential is active." : "The connected client credential requires attention.",
                evidence: credentialState == .active ? "credential_active" : nil,
                actor: .agent,
                nextHumanAction: credentialState == .active ? nil : "Re-enroll or rotate the client credential in MCP Management.",
                confidenceBoundary: "Credential validity does not imply runtime or device readiness."
            ),
            MCPSetupReadinessCheckDTO(
                id: "local_trust",
                state: trustState == .ready ? .confirmed : .needsUserConfirmation,
                detail: trustState == .ready ? "The local CA is trusted for HTTPS inspection." : "Local CA trust is (trustState.rawValue.lowercased()).",
                evidence: trustState == .ready ? "local_trust_ready" : nil,
                actor: .app,
                nextHumanAction: trustState == .ready ? nil : "Complete the local CA trust step shown in Guided Setup.",
                confidenceBoundary: "Local trust state does not prove trust on a remote device."
            )
        ]

        checks.append(profileHostEvidence(health: readinessState.profileHealth))

        let deviceCheck = deviceEvidence(target: target, profileDownloadObserved: readinessState.profileDownloadObserved)
        checks.append(deviceCheck)

        let trafficCheck: MCPSetupReadinessCheckDTO
        switch readinessState.verificationState {
        case .inspected:
            trafficCheck = MCPSetupReadinessCheckDTO(
                id: "traffic",
                state: .observed,
                detail: "Inspected traffic has been observed.",
                evidence: "inspected",
                actor: .app,
                nextHumanAction: nil,
                confidenceBoundary: "Captured evidence is bounded to the observed run."
            )
        case .tunneled:
            trafficCheck = MCPSetupReadinessCheckDTO(
                id: "traffic",
                state: .observed,
                detail: "Tunneled traffic has been observed, but HTTPS inspection is not confirmed.",
                evidence: "tunneled",
                actor: .app,
                nextHumanAction: "Confirm the target trusts the JoesProxy CA if inspection is required.",
                confidenceBoundary: "Tunneled evidence proves routing, not decryption."
            )
        case .noTrafficObserved:
            trafficCheck = MCPSetupReadinessCheckDTO(
                id: "traffic",
                state: .needsUserConfirmation,
                detail: "No verification traffic was observed yet.",
                evidence: "no_traffic_observed",
                actor: .app,
                nextHumanAction: "Generate a real request from the target and run Verify Capture.",
                confidenceBoundary: "No traffic observed cannot distinguish routing, filtering, or an idle target."
            )
        case .proxyStopped, nil:
            trafficCheck = MCPSetupReadinessCheckDTO(
                id: "traffic",
                state: .needsUserConfirmation,
                detail: "Traffic readiness has not been established.",
                evidence: nil,
                actor: .user,
                nextHumanAction: "Start the proxy, generate a real request, and verify capture.",
                confidenceBoundary: "Capture state is not inferred from profile generation."
            )
        }
        checks.append(trafficCheck)

        checks.append(MCPSetupReadinessCheckDTO(
            id: "remote_profile_installation",
            state: .notObservable,
            detail: "Remote profile installation cannot be observed by JoesProxy.",
            evidence: readinessState.profileDownloadObserved ? "profile_download_served" : nil,
            actor: .user,
            nextHumanAction: "Open the downloaded profile on the target and confirm installation there.",
            confidenceBoundary: "A generated or downloaded profile is not proof of installation or trust."
        ))
        checks.append(MCPSetupReadinessCheckDTO(
            id: "remote_wifi_proxy",
            state: .notObservable,
            detail: "Remote Wi-Fi proxy settings cannot be observed by JoesProxy.",
            evidence: nil,
            actor: .user,
            nextHumanAction: "Confirm the target uses the current host and proxy port.",
            confidenceBoundary: "Only a subsequent captured request can provide routing evidence."
        ))

        let actions = checks.compactMap(\.nextHumanAction)
        let hasObservedTraffic = readinessState.verificationState == .inspected || readinessState.verificationState == .tunneled
        let state = hostReady && proxyReady && trustState == .ready && hasObservedTraffic ? "ready" : "action_required"
        return MCPSetupReadinessDTO(
            schemaVersion: MCPSetupReadinessDTO.schemaVersion,
            target: target,
            state: state,
            checks: checks,
            recommendedNextActions: Array(actions.prefix(5)),
            remoteTrustNotObservable: true
        )
    }

    private static func deviceEvidence(
        target: MCPSetupReadinessTarget,
        profileDownloadObserved: Bool
    ) -> MCPSetupReadinessCheckDTO {
        if profileDownloadObserved {
            return MCPSetupReadinessCheckDTO(
                id: "device.profile_delivery",
                state: .observed,
                detail: "JoesProxy observed a profile download response for the selected target flow.",
                evidence: "profile_download_served",
                actor: .app,
                nextHumanAction: "Confirm profile installation and trust on the target.",
                confidenceBoundary: "Download delivery does not prove installation or trust."
            )
        }
        return MCPSetupReadinessCheckDTO(
            id: "device.manual_setup",
            state: .needsUserConfirmation,
            detail: "(target.rawValue) device setup requires a human confirmation.",
            evidence: nil,
            actor: .user,
            nextHumanAction: "Complete the target's manual proxy and certificate steps in Guided Setup.",
            confidenceBoundary: "JoesProxy cannot observe remote configuration directly."
        )
    }

    private static func profileHostEvidence(health: ProfileSnapshotHealth) -> MCPSetupReadinessCheckDTO {
        switch health {
        case .current:
            return MCPSetupReadinessCheckDTO(
                id: "profile.host",
                state: .observed,
                detail: "The latest generated profile matches the app's current host, port, and certificate metadata.",
                evidence: "profile_metadata_current",
                actor: .app,
                nextHumanAction: nil,
                confidenceBoundary: "This is an app-local comparison; it does not prove the target installed or trusted the profile."
            )
        case .manualHostConfigured:
            return MCPSetupReadinessCheckDTO(
                id: "profile.host",
                state: .needsUserConfirmation,
                detail: "The generated profile uses a manually configured host.",
                evidence: "profile_manual_host",
                actor: .user,
                nextHumanAction: "Confirm that the manual host still reaches this Mac from the target.",
                confidenceBoundary: "JoesProxy cannot validate remote DNS, routing, or proxy settings from this check."
            )
        case .ipChanged:
            return staleProfileEvidence(
                detail: "The generated profile's LAN host no longer matches current app state.",
                evidence: "profile_lan_host_changed",
                nextHumanAction: "Regenerate the profile and complete the target installation steps again."
            )
        case .bonjourChanged:
            return staleProfileEvidence(
                detail: "The generated profile's local host name no longer matches current app state.",
                evidence: "profile_local_host_changed",
                nextHumanAction: "Regenerate the profile and complete the target installation steps again."
            )
        case .proxyPortChanged:
            return staleProfileEvidence(
                detail: "The generated profile uses a different proxy port than the app currently exposes.",
                evidence: "profile_proxy_port_changed",
                nextHumanAction: "Regenerate the profile and confirm the target uses the current proxy port."
            )
        case .certificateChanged:
            return staleProfileEvidence(
                detail: "The generated profile references a different root certificate than the app currently uses.",
                evidence: "profile_certificate_changed",
                nextHumanAction: "Regenerate the profile, install it on the target, and confirm trust there."
            )
        case .certificateExpired:
            return staleProfileEvidence(
                detail: "The root certificate used by the generated profile has expired.",
                evidence: "profile_certificate_expired",
                nextHumanAction: "Regenerate the certificate and profile, then complete target installation again."
            )
        case .certificateExpiringSoon:
            return staleProfileEvidence(
                detail: "The root certificate used by the generated profile expires soon.",
                evidence: "profile_certificate_expiring",
                nextHumanAction: "Plan to regenerate the certificate and reinstall the target profile."
            )
        case .unknown:
            return MCPSetupReadinessCheckDTO(
                id: "profile.host",
                state: .needsUserConfirmation,
                detail: "No generated profile metadata is available for comparison.",
                evidence: nil,
                actor: .user,
                nextHumanAction: "Generate a profile if the target requires one, or confirm the target's manual settings.",
                confidenceBoundary: "Profile installation and remote configuration remain outside app observability."
            )
        }
    }

    private static func staleProfileEvidence(
        detail: String,
        evidence: String,
        nextHumanAction: String
    ) -> MCPSetupReadinessCheckDTO {
        MCPSetupReadinessCheckDTO(
            id: "profile.host",
            state: .needsUserConfirmation,
            detail: detail,
            evidence: evidence,
            actor: .app,
            nextHumanAction: nextHumanAction,
            confidenceBoundary: "The comparison is app-local and intentionally omits the affected host, port, and certificate values."
        )
    }
}
