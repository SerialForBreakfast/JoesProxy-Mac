import XCTest
@testable import JoesProxy

final class MCPStatusProjectionTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!

    func testPersistentIndicatorTracksEffectsNotOperations() {
        XCTAssertFalse(MCPStatusProjection.persistentEffectIndicatorVisible(effect: .clean))
        XCTAssertTrue(
            MCPStatusProjection.persistentEffectIndicatorVisible(
                effect: .active(.init(createdRuleCount: 1, changedRuleCount: 0, throttleChanged: false, activeScenarioIDs: []))
            )
        )

        let armedOperation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 0,
                sensitiveReadCount: 0,
                liveProbeCount: 0,
                analysisCount: 0,
                armedScenarioIDs: ["scenario-1"]
            )
        )
        XCTAssertFalse(MCPStatusProjection.persistentEffectIndicatorVisible(effect: .clean, operation: armedOperation))
        XCTAssertEqual(MCPStatusProjection.effectState(for: armedOperation), .clean)

        let analysisOperation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 0,
                sensitiveReadCount: 0,
                liveProbeCount: 0,
                analysisCount: 2,
                armedScenarioIDs: []
            )
        )
        XCTAssertFalse(MCPStatusProjection.persistentEffectIndicatorVisible(effect: .clean, operation: analysisOperation))
        XCTAssertEqual(MCPStatusProjection.effectState(for: analysisOperation), .clean)
    }

    func testCompoundUIStateMatrix() {
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(server: .off, effect: .clean),
            .offClean
        )
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(
                server: .running(endpoint: endpoint, connectedClientCount: 1),
                effect: .clean
            ),
            .runningClean
        )
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(
                server: .running(endpoint: endpoint, connectedClientCount: 1),
                effect: .active(.empty)
            ),
            .runningClean
        )
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(
                server: .off,
                effect: .active(.empty)
            ),
            .offClean
        )
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(
                server: .off,
                effect: .conflict([MCPEffectConflictItem(id: "1", kind: .block, message: "review")])
            ),
            .offConflict
        )
        XCTAssertEqual(
            MCPStatusProjection.compoundUIState(
                server: .running(endpoint: endpoint, connectedClientCount: 0),
                effect: .conflict([MCPEffectConflictItem(id: "1", kind: .throttle, message: "review")])
            ),
            .runningConflict
        )
    }

    func testPipelineStatusOffCleanIdleIsAlwaysVisible() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .off,
            effect: .clean,
            operation: .idle,
            mcpPort: 9091
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP off · 9091")
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .overview)
    }

    func testPipelineStatusRunningClean() {
        let running = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .clean,
            operation: .idle,
            mcpPort: 9091
        )
        XCTAssertTrue(running.isVisible)
        XCTAssertEqual(running.label, "MCP running · 9091")
        XCTAssertEqual(running.tone, .healthy)
        XCTAssertFalse(running.shouldPulse)

        let connected = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 2),
            effect: .clean,
            operation: .idle,
            mcpPort: 9091
        )
        XCTAssertTrue(connected.isVisible)
        XCTAssertEqual(connected.label, "MCP connected · 9091")
        XCTAssertEqual(connected.tone, .healthy)
        XCTAssertEqual(connected.managementDestination, .clients)
    }

    func testPipelineStatusRunningActivePulses() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 1),
            effect: .active(.init(createdRuleCount: 1, changedRuleCount: 0, throttleChanged: false, activeScenarioIDs: [])),
            operation: .idle
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP effects active")
        XCTAssertEqual(status.tone, .attention)
        XCTAssertTrue(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .effects)
    }

    func testPipelineStatusOffActiveUsesProblemTone() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .off,
            effect: .active(.init(createdRuleCount: 1, changedRuleCount: 0, throttleChanged: false, activeScenarioIDs: [])),
            operation: .idle
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP effects active — server off")
        XCTAssertEqual(status.tone, .problem)
        XCTAssertTrue(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .effects)
    }

    func testPipelineStatusConflictPulses() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .conflict([MCPEffectConflictItem(id: "1", kind: .block, message: "review")]),
            operation: .idle
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP recovery needed")
        XCTAssertEqual(status.tone, .problem)
        XCTAssertEqual(status.badgeCount, 1)
        XCTAssertTrue(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .effects)
    }

    func testPipelineStatusEmptyConflictDoesNotClaimReviewIsNeeded() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .conflict([]),
            operation: .idle
        )

        XCTAssertEqual(status.label, "MCP running · 9091")
        XCTAssertEqual(status.badgeCount, 0)
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .overview)
        XCTAssertFalse(MCPStatusProjection.persistentEffectIndicatorVisible(effect: .conflict([])))
    }

    func testPipelineStatusApprovalTransientWhenRunning() {
        let operation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 2,
                sensitiveReadCount: 1,
                liveProbeCount: 0,
                analysisCount: 0,
                armedScenarioIDs: []
            )
        )
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 1),
            effect: .clean,
            operation: operation
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP approvals")
        XCTAssertEqual(status.badgeCount, 2)
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .approvals)
    }

    func testPipelineStatusIgnoresStaleOperationStateWhenServerOff() {
        let operation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 2,
                sensitiveReadCount: 1,
                liveProbeCount: 1,
                analysisCount: 3,
                armedScenarioIDs: ["scenario-a"]
            )
        )
        let status = MCPStatusProjection.pipelineStatus(
            server: .off,
            effect: .clean,
            operation: operation,
            mcpPort: 9091
        )
        XCTAssertEqual(status.label, "MCP off · 9091")
        XCTAssertEqual(status.badgeCount, 0)
    }

    func testPipelineStatusProbeTransientWhenRunning() {
        let operation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 0,
                sensitiveReadCount: 0,
                liveProbeCount: 1,
                analysisCount: 0,
                armedScenarioIDs: []
            )
        )
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .clean,
            operation: operation
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP live probe")
        XCTAssertEqual(status.badgeCount, 1)
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .activity)
    }

    func testPipelineStatusArmedScenarioTransientWhenRunning() {
        let operation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 0,
                sensitiveReadCount: 0,
                liveProbeCount: 0,
                analysisCount: 0,
                armedScenarioIDs: ["scenario-a", "scenario-b"]
            )
        )
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .clean,
            operation: operation
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP scenario armed")
        XCTAssertEqual(status.badgeCount, 2)
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(MCPStatusProjection.effectState(for: operation), .clean)
        XCTAssertEqual(status.managementDestination, .scenarios)
    }

    func testPipelineStatusAnalysisTransientWhenRunning() {
        let operation = MCPOperationState.active(
            MCPOperationSummary(
                pendingApprovalCount: 0,
                sensitiveReadCount: 0,
                liveProbeCount: 0,
                analysisCount: 3,
                armedScenarioIDs: []
            )
        )
        let status = MCPStatusProjection.pipelineStatus(
            server: .running(endpoint: endpoint, connectedClientCount: 0),
            effect: .clean,
            operation: operation
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP analysis")
        XCTAssertEqual(status.badgeCount, 3)
        XCTAssertFalse(status.shouldPulse)
        XCTAssertEqual(status.managementDestination, .activity)
    }

    func testPipelineStatusServerStarting() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .starting,
            effect: .clean,
            operation: .idle,
            mcpPort: 9091
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP starting · 9091")
        XCTAssertEqual(status.tone, .attention)
        XCTAssertEqual(status.systemImage, "arrow.triangle.2.circlepath")
    }

    func testPipelineStatusServerStopping() {
        let status = MCPStatusProjection.pipelineStatus(
            server: .stopping,
            effect: .clean,
            operation: .idle,
            mcpPort: 9091
        )
        XCTAssertTrue(status.isVisible)
        XCTAssertEqual(status.label, "MCP stopping · 9091")
        XCTAssertEqual(status.tone, .attention)
        XCTAssertEqual(status.systemImage, "arrow.triangle.2.circlepath")
    }

    func testProjectServerStateMapsControllerStates() {
        XCTAssertEqual(
            MCPStatusProjection.projectServerState(.stopped, connectedClientCount: 0),
            .off
        )
        XCTAssertEqual(
            MCPStatusProjection.projectServerState(.starting, connectedClientCount: 0),
            .starting
        )
        let runningURL = URL(string: "http://127.0.0.1:9090/mcp")!
        XCTAssertEqual(
            MCPStatusProjection.projectServerState(.running(port: 9090, endpointURL: runningURL), connectedClientCount: 3),
            .running(endpoint: runningURL, connectedClientCount: 3)
        )
    }

    @MainActor
    func testMCPManagementPresentationPreservesRequestedDestination() {
        let presentationState = AppPresentationState()

        presentationState.presentMCPManagement(destination: .effects)

        XCTAssertEqual(presentationState.mcpManagementContext?.destination, .effects)
    }

    func testManagementSectionMapsEveryPipelineDestination() {
        XCTAssertEqual(MCPManagementSection(destination: .overview), .overview)
        XCTAssertEqual(MCPManagementSection(destination: .effects), .effects)
        XCTAssertEqual(MCPManagementSection(destination: .clients), .clients)
        XCTAssertEqual(MCPManagementSection(destination: .activity), .activity)
        XCTAssertEqual(MCPManagementSection(destination: .approvals), .approvals)
        XCTAssertEqual(MCPManagementSection(destination: .scenarios), .scenarios)
    }

    /// Degraded (bootstrapped but policy/audit persistence unhealthy) must stay visually distinct
    /// from a hard failure (bind/start failure) — collapsing them into the same contract case and
    /// label would make an operator unable to tell "partially working, fix persistence" apart from
    /// "server did not start at all."
    func testDegradedServerStateStaysDistinctFromFailed() {
        let projected = MCPStatusProjection.projectServerState(
            .degraded(message: "Policy store failed to load."),
            connectedClientCount: 0
        )
        guard case .degraded(let error) = projected else {
            return XCTFail("Expected .degraded, got \(projected).")
        }
        XCTAssertEqual(error.message, "Policy store failed to load.")

        let degradedStatus = MCPStatusProjection.pipelineStatus(
            server: projected,
            effect: .clean,
            operation: .idle
        )
        let failedStatus = MCPStatusProjection.pipelineStatus(
            server: .failed(MCPStructuredError(code: .internalFailure, message: "Policy store failed to load.")),
            effect: .clean,
            operation: .idle
        )
        XCTAssertNotEqual(degradedStatus.label, failedStatus.label)
        XCTAssertEqual(degradedStatus.label, "MCP degraded · 9091")
        XCTAssertEqual(failedStatus.label, "MCP failed · 9091")
    }
}
