import Foundation

/// Collects observations, evaluates assertions, and builds disclosure-gated reports (AI-3).
///
/// Concurrency: `@MainActor` — reads session and policy stores on the main actor.
@MainActor
final class MCPScenarioObservationService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService
    private let policyStore: MCPPolicyStore
    private let scenarioStore: MCPScenarioStore
    private let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let disclosureSerializer = MCPDisclosureSerializer()

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService,
        policyStore: MCPPolicyStore,
        scenarioStore: MCPScenarioStore,
        lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
        self.policyStore = policyStore
        self.scenarioStore = scenarioStore
        self.lifecycleCoordinator = lifecycleCoordinator
    }

    @discardableResult
    func evaluateScenario(_ scenarioID: MCPScenarioID, now: Date = Date()) throws -> MCPScenarioEvaluationResultDTO {
        guard var record = scenarioStore.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        guard record.phase == .observing else {
            throw MCPScenarioLifecycleError.invalidTransition(from: record.phase, to: .evaluating)
        }

        let evidence = MCPScenarioObservationCollector.collect(
            definition: record.definition,
            activatedAt: record.activatedAt,
            sessions: sessionStore.sessions,
            disclosureSerializer: disclosureSerializer,
            snapshotService: snapshotService,
            now: now
        )
        let assertionResults = MCPScenarioAssertionEvaluator.evaluate(
            definition: record.definition,
            evidence: evidence,
            sessions: sessionStore.sessions,
            activatedAt: record.activatedAt,
            now: now
        )
        var warnings: [String] = []
        let effectiveCap = min(record.definition.evidenceRetentionSpec.maxRecords, MCPScenarioResourceBudget.maxEvidenceRecords)
        if evidence.count >= effectiveCap {
            warnings.append("Observation evidence capped at \(effectiveCap) records.")
        }
        if assertionResults.contains(where: { $0.outcome == .inconclusive && $0.detail?.contains("SDK") == true }) {
            warnings.append("One or more SDK assertions remain inconclusive until SDK observation plumbing lands.")
        }

        let resolvedOutcome = MCPScenarioAssertionEvaluator.resolvedOutcome(
            results: assertionResults,
            severity: record.definition.assertionSeverity
        )

        _ = try lifecycleCoordinator.transition(scenarioID, to: .evaluating)
        record = scenarioStore.scenario(id: scenarioID) ?? record

        let profile = try policyStore.resolvedProfile(for: record.definition.disclosureProfileID)
        let report = try MCPScenarioReportBuilder.build(
            record: record,
            assertionResults: assertionResults,
            evidence: evidence,
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            profile: profile,
            disclosureSerializer: disclosureSerializer,
            warnings: warnings,
            evaluatedAt: now
        )

        record.observationEvidence = evidence
        record.assertionResults = assertionResults
        record.evaluationReport = report
        record.cleanupResolvedOutcome = resolvedOutcome
        try scenarioStore.updateScenario(record)

        return MCPScenarioEvaluationResultDTO(
            scenarioID: scenarioID,
            evidence: evidence,
            assertionResults: assertionResults,
            resolvedOutcome: resolvedOutcome,
            report: report,
            warnings: warnings
        )
    }
}
