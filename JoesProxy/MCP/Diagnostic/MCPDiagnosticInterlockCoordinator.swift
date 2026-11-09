import Foundation

/// User-invoked, single-shot suspend/restore around diagnostic measurements (AJ-4).
///
/// Concurrency: `@MainActor` — coordinates recovery inventory and UI; activates
/// ``MCPMeasurementSuspensionGate`` for the proxy capture path.
@MainActor
final class MCPDiagnosticInterlockCoordinator: ObservableObject {
    @Published private(set) var isMeasurementActive = false
    @Published private(set) var activeDiagnostic: MCPDiagnosticKind?
    @Published private(set) var lastRestoreConflictMessage: String?
    @Published var acknowledgedDiagnostics: Set<MCPDiagnosticKind> = []

    private let recoveryService: MCPRecoveryService
    private let restorer: MCPRecoveryRestorer
    private let scenarioLifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let finishScenario: (MCPScenarioID, MCPScenarioPhase?) async -> Void
    private var suspendedSnapshots: [MCPSuspendedEffectSnapshot] = []

    init(
        recoveryService: MCPRecoveryService,
        restorer: MCPRecoveryRestorer,
        scenarioLifecycleCoordinator: MCPScenarioLifecycleCoordinator,
        finishScenario: @escaping (MCPScenarioID, MCPScenarioPhase?) async -> Void
    ) {
        self.recoveryService = recoveryService
        self.restorer = restorer
        self.scenarioLifecycleCoordinator = scenarioLifecycleCoordinator
        self.finishScenario = finishScenario
    }

    /// Evaluates whether the diagnostic should show an interlock warning.
    func evaluate(diagnostic: MCPDiagnosticKind) async -> MCPDiagnosticInterlockEvaluation {
        let inventory = await recoveryService.buildInventory()
        let relevant = MCPDiagnosticRelevanceMatrix.relevantEnabledItems(inventory, diagnostic: diagnostic)
        let activeScenarios = scenarioLifecycleCoordinator.activeScenarioIDs
        let requiresScenarioStop = !activeScenarios.isEmpty && !relevant.isEmpty
        let unknownKinds = inventory.filter { item in
            item.isEnabled && !MCPEffectKind.allCases.contains(item.kind)
        }
        let failClosed = !unknownKinds.isEmpty
        let requiresWarning = !relevant.isEmpty || requiresScenarioStop || failClosed
        let summary: String?
        if failClosed {
            summary = "An unrecognized MCP effect is active. Clean measurement cannot be guaranteed."
        } else if requiresScenarioStop {
            summary = "Active test scenario(s) own relevant effects. Stop the scenario before measuring cleanly."
        } else if let first = relevant.first {
            summary = "Measurements may be affected by \(first.displayLabel)."
        } else {
            summary = nil
        }
        return MCPDiagnosticInterlockEvaluation(
            requiresWarning: requiresWarning,
            relevantItems: relevant,
            activeScenarioIDs: activeScenarios,
            requiresScenarioStop: requiresScenarioStop,
            failClosedUnknownEffect: failClosed,
            summaryMessage: summary
        )
    }

    func acknowledgeWarning(for diagnostic: MCPDiagnosticKind) {
        acknowledgedDiagnostics.insert(diagnostic)
    }

    func shouldShowWarning(for diagnostic: MCPDiagnosticKind, evaluation: MCPDiagnosticInterlockEvaluation) -> Bool {
        evaluation.requiresWarning && !acknowledgedDiagnostics.contains(diagnostic)
    }

    /// Suspends relevant standalone effects and begins a clean measurement window.
    func beginCleanMeasurement(for diagnostic: MCPDiagnosticKind) async -> MCPDiagnosticMeasurementBeginResult {
        guard !isMeasurementActive else {
            return .failed(message: "A clean measurement is already active.")
        }
        let evaluation = await evaluate(diagnostic: diagnostic)
        if evaluation.requiresScenarioStop {
            return .requiresScenarioStop(scenarioIDs: evaluation.activeScenarioIDs)
        }
        guard !evaluation.relevantItems.isEmpty else {
            return .nothingToSuspend
        }

        var snapshots: [MCPSuspendedEffectSnapshot] = []
        for item in evaluation.relevantItems {
            do {
                let throttleSnapshot: NetworkThrottleConfiguration?
                if item.kind == .throttle {
                    throttleSnapshot = restorer.currentThrottleConfiguration()
                } else {
                    throttleSnapshot = nil
                }
                try await restorer.disable(item: item)
                snapshots.append(MCPSuspendedEffectSnapshot(item: item, throttleConfiguration: throttleSnapshot))
            } catch {
                await restoreSnapshots(snapshots)
                return .failed(message: "Could not suspend \(item.displayLabel): \(error.localizedDescription)")
            }
        }

        suspendedSnapshots = snapshots
        isMeasurementActive = true
        activeDiagnostic = diagnostic
        lastRestoreConflictMessage = nil
        MCPMeasurementSuspensionGate.activate(diagnosticLabel: diagnostic.displayName)
        return .started
    }

    /// Stops an active scenario, marks it inconclusive, then begins clean measurement.
    func stopScenarioAndMeasureClean(
        scenarioID: MCPScenarioID,
        diagnostic: MCPDiagnosticKind
    ) async -> MCPDiagnosticMeasurementBeginResult {
        await finishScenario(scenarioID, .inconclusive)
        return await beginCleanMeasurement(for: diagnostic)
    }

    /// Restores suspended effects after measurement completes.
    func endCleanMeasurement() async {
        guard isMeasurementActive else { return }
        await restoreSnapshots(suspendedSnapshots)
        suspendedSnapshots = []
        isMeasurementActive = false
        activeDiagnostic = nil
        MCPMeasurementSuspensionGate.deactivate()
    }

    private func restoreSnapshots(_ snapshots: [MCPSuspendedEffectSnapshot]) async {
        var conflicts: [String] = []
        for snapshot in snapshots.reversed() {
            do {
                try await restorer.restoreSuspended(snapshot: snapshot)
            } catch {
                conflicts.append("\(snapshot.item.displayLabel): \(error.localizedDescription)")
            }
        }
        if conflicts.isEmpty {
            lastRestoreConflictMessage = nil
        } else {
            lastRestoreConflictMessage = conflicts.joined(separator: " ")
        }
    }
}
