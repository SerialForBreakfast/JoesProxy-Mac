import Foundation

/// Derives main-window and management-panel status from MCP server, effect, and operation state.
enum MCPStatusProjection {
    /// Compound UI states documented in the parent ADR State Model section.
    enum CompoundUIState: Equatable, Sendable {
        case offClean
        case runningClean
        case runningActive
        case offActive
        case offConflict
        case runningConflict
    }

    /// Persistent main-window indicator reflects active or conflicted **effects** only.
    static func persistentEffectIndicatorVisible(effect: MCPEffectState) -> Bool {
        switch effect {
        case .clean:
            return false
        case .active(let summary):
            return summary.hasEffects
        case .conflict(let conflicts):
            return !conflicts.isEmpty
        }
    }

    /// Operations (including armed scenarios) must not activate the persistent effect indicator.
    static func persistentEffectIndicatorVisible(
        effect: MCPEffectState,
        operation: MCPOperationState
    ) -> Bool {
        _ = operation
        return persistentEffectIndicatorVisible(effect: effect)
    }

    static func compoundUIState(server: MCPServerState, effect: MCPEffectState) -> CompoundUIState {
        switch (server, normalizedEffectState(effect)) {
        case (.off, .clean), (.starting, .clean), (.stopping, .clean), (.failed, .clean), (.degraded, .clean):
            return .offClean
        case (.running, .clean):
            return .runningClean
        case (.running, .active):
            return .runningActive
        case (.off, .active), (.starting, .active), (.stopping, .active), (.failed, .active), (.degraded, .active):
            return .offActive
        case (.off, .conflict), (.starting, .conflict), (.stopping, .conflict), (.failed, .conflict), (.degraded, .conflict):
            return .offConflict
        case (.running, .conflict):
            return .runningConflict
        }
    }

    /// Armed scenarios are operations; they must not flip effect state to active.
    static func effectState(for operation: MCPOperationState) -> MCPEffectState {
        switch operation {
        case .idle:
            return .clean
        case .active(let summary) where summary.hasArmedScenario:
            return .clean
        case .active, .cancelling:
            return .clean
        }
    }

    /// Maps the runtime controller enum to the contract ``MCPServerState``.
    static func projectServerState(
        _ controllerState: MCPServerController.ServerState,
        connectedClientCount: Int
    ) -> MCPServerState {
        switch controllerState {
        case .stopped:
            return .off
        case .starting:
            return .starting
        case .running(_, let endpointURL):
            return .running(endpoint: endpointURL, connectedClientCount: connectedClientCount)
        case .failed(let message):
            return .failed(MCPStructuredError(code: .internalFailure, message: message))
        case .degraded(let message):
            return .degraded(MCPStructuredError(code: .internalFailure, message: message))
        }
    }

    /// The title-bar MCP pill stays visible so operators can always open MCP Management and see
    /// off/on state (product surface ADR entry points).
    static func shouldShowCompactIndicator(
        server: MCPServerState,
        effect: MCPEffectState,
        operation: MCPOperationState
    ) -> Bool {
        _ = server
        _ = effect
        _ = operation
        return true
    }

    /// Full title-bar derivation for server, effect, and operation inputs.
    ///
    /// Finite display priority (first match wins):
    /// 1. Effect conflict — always shown (including when server is off).
    /// 2. Effect active — always shown (including when server is off).
    /// 3. Operation transients — approvals, analysis, probes, armed scenarios (running server only).
    /// 4. Server lifecycle — off, starting, stopping, running, failed, degraded.
    static func pipelineStatus(
        server: MCPServerState,
        effect: MCPEffectState,
        operation: MCPOperationState,
        mcpPort: UInt16 = NetworkConstants.mcpDefaultPort
    ) -> MCPPipelineStatus {
        let visible = shouldShowCompactIndicator(server: server, effect: effect, operation: operation)
        let shouldPulse = persistentEffectIndicatorVisible(effect: effect)
        let operationSummary = activeOperationSummary(from: operation)

        if case .conflict(let conflicts) = effect, !conflicts.isEmpty {
            let conflictLabel = conflicts.count == 1 ? "conflict" : "conflicts"
            return MCPPipelineStatus(
                isVisible: visible,
                label: "MCP recovery needed",
                detail: "\(conflicts.count) unresolved MCP effect \(conflictLabel). Opens Effects & Recovery.",
                systemImage: "exclamationmark.triangle.fill",
                tone: .problem,
                badgeCount: conflicts.count,
                shouldPulse: shouldPulse,
                managementDestination: .effects
            )
        }

        if case .active(let summary) = effect, summary.hasEffects {
            let serverIsOff = isServerOff(server)
            return MCPPipelineStatus(
                isVisible: visible,
                label: serverIsOff ? "MCP effects active — server off" : "MCP effects active",
                detail: serverIsOff
                    ? "MCP-created proxy effects are active while the MCP server is off. Opens Effects & Recovery."
                    : "MCP-created proxy effects are active. Opens Effects & Recovery.",
                systemImage: "antenna.radiowaves.left.and.right",
                tone: serverIsOff ? .problem : .attention,
                badgeCount: 0,
                shouldPulse: shouldPulse,
                managementDestination: .effects
            )
        }

        if let operationSummary, isServerAcceptingOperations(server) {
            if operationSummary.pendingApprovalCount > 0 {
                return MCPPipelineStatus(
                    isVisible: visible,
                    label: "MCP approvals",
                    detail: "\(operationSummary.pendingApprovalCount) sensitive operation(s) waiting for review.",
                    systemImage: "hand.raised.fill",
                    tone: .attention,
                    badgeCount: operationSummary.pendingApprovalCount,
                    shouldPulse: false,
                    managementDestination: .approvals
                )
            }
            if operationSummary.analysisCount > 0 {
                return MCPPipelineStatus(
                    isVisible: visible,
                    label: "MCP analysis",
                    detail: "\(operationSummary.analysisCount) media inspection(s) in progress.",
                    systemImage: "waveform.badge.magnifyingglass",
                    tone: .attention,
                    badgeCount: operationSummary.analysisCount,
                    shouldPulse: false,
                    managementDestination: .activity
                )
            }
            if operationSummary.hasArmedScenario {
                let count = operationSummary.armedScenarioIDs.count
                return MCPPipelineStatus(
                    isVisible: visible,
                    label: "MCP scenario armed",
                    detail: "\(count) test scenario(s) armed and awaiting activation.",
                    systemImage: "scope",
                    tone: .attention,
                    badgeCount: count,
                    shouldPulse: false,
                    managementDestination: .scenarios
                )
            }
            if operationSummary.liveProbeCount > 0 {
                return MCPPipelineStatus(
                    isVisible: visible,
                    label: "MCP live probe",
                    detail: "\(operationSummary.liveProbeCount) live media probe stream(s) active.",
                    systemImage: "dot.radiowaves.left.and.right",
                    tone: .attention,
                    badgeCount: operationSummary.liveProbeCount,
                    shouldPulse: false,
                    managementDestination: .activity
                )
            }
        }

        return serverOnlyStatus(server: server, isVisible: visible, mcpPort: mcpPort)
    }

    /// Convenience for the main window using controller runtime state.
    static func pipelineStatus(
        controllerState: MCPServerController.ServerState,
        connectedClientCount: Int,
        effect: MCPEffectState,
        operation: MCPOperationState,
        mcpPort: UInt16 = NetworkConstants.mcpDefaultPort
    ) -> MCPPipelineStatus {
        pipelineStatus(
            server: projectServerState(controllerState, connectedClientCount: connectedClientCount),
            effect: effect,
            operation: operation,
            mcpPort: mcpPort
        )
    }

    // MARK: - Private

    private static func hasTransientOperationActivity(_ operation: MCPOperationState, server: MCPServerState) -> Bool {
        guard isServerAcceptingOperations(server) else { return false }
        guard let summary = activeOperationSummary(from: operation) else { return false }
        return summary.pendingApprovalCount > 0
            || summary.analysisCount > 0
            || summary.liveProbeCount > 0
            || summary.hasArmedScenario
    }

    private static func activeOperationSummary(from operation: MCPOperationState) -> MCPOperationSummary? {
        switch operation {
        case .idle, .cancelling:
            return nil
        case .active(let summary):
            return summary
        }
    }

    private static func normalizedEffectState(_ effect: MCPEffectState) -> MCPEffectState {
        switch effect {
        case .active(let summary) where !summary.hasEffects:
            return .clean
        case .conflict(let conflicts) where conflicts.isEmpty:
            return .clean
        case .clean, .active, .conflict:
            return effect
        }
    }

    private static func isServerOff(_ server: MCPServerState) -> Bool {
        switch server {
        case .off, .starting, .stopping, .failed, .degraded:
            return true
        case .running:
            return false
        }
    }

    /// Transient operation attention (approvals, probes, armed scenarios) applies only while the
    /// MCP listener is running — pending work cannot complete when the server is off.
    private static func isServerAcceptingOperations(_ server: MCPServerState) -> Bool {
        if case .running = server { return true }
        return false
    }

    private static func serverOnlyStatus(
        server: MCPServerState,
        isVisible: Bool,
        mcpPort: UInt16
    ) -> MCPPipelineStatus {
        let portSuffix = " · \(mcpPort)"
        switch server {
        case .off:
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: "MCP off\(portSuffix)",
                detail: "The local MCP server is not running. Click to open MCP Management.",
                systemImage: "antenna.radiowaves.left.and.right",
                tone: .idle,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: .overview
            )
        case .starting:
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: "MCP starting\(portSuffix)",
                detail: "The local MCP server is starting.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .attention,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: .overview
            )
        case .stopping:
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: "MCP stopping\(portSuffix)",
                detail: "The local MCP server is shutting down.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .attention,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: .overview
            )
        case .running(_, let connectedClientCount):
            let connected = connectedClientCount > 0
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: (connected ? "MCP connected" : "MCP running") + portSuffix,
                detail: connected
                    ? "\(connectedClientCount) MCP client(s) connected."
                    : "The local MCP server is running.",
                systemImage: "antenna.radiowaves.left.and.right",
                tone: connected ? .healthy : .healthy,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: connected ? .clients : .overview
            )
        case .failed(let error):
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: "MCP failed\(portSuffix)",
                detail: error.message,
                systemImage: "exclamationmark.triangle.fill",
                tone: .problem,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: .overview
            )
        case .degraded(let error):
            return MCPPipelineStatus(
                isVisible: isVisible,
                label: "MCP degraded\(portSuffix)",
                detail: error.message,
                systemImage: "exclamationmark.triangle.fill",
                tone: .problem,
                badgeCount: 0,
                shouldPulse: false,
                managementDestination: .overview
            )
        }
    }
}
