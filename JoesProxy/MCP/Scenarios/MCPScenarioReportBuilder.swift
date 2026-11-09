import Foundation

/// Builds privacy-filtered scenario reports through disclosure profile gating (AI-3).
///
/// Concurrency: `@MainActor` — reads snapshot indexes and session records from main-actor stores.
@MainActor
enum MCPScenarioReportBuilder {
    static func build(
        record: MCPScenarioRecord,
        assertionResults: [MCPScenarioAssertionResult],
        evidence: [MCPScenarioEvidenceRecord],
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService,
        profile: MCPDisclosureProfileDocument,
        disclosureSerializer: MCPDisclosureSerializer,
        warnings: [String],
        evaluatedAt: Date = Date()
    ) throws -> MCPScenarioReportDTO {
        var redactionSummary: [String] = []
        var sessionSummaries: [MCPSessionSummaryDTO]?

        if profile.allowedFieldClasses.contains(.scenarioEvidence) {
            let sessions = evidence.compactMap { item -> SessionRecord? in
                guard let id = UUID(uuidString: item.sessionID) else { return nil }
                return sessionStore.record(for: id)
            }
            sessionSummaries = try sessions.prefix(20).map { session in
                let captureSequence = snapshotService.indexedSession(id: session.id)?.captureSequence ?? 0
                return try disclosureSerializer.sessionSummary(
                    record: session,
                    captureSequence: captureSequence,
                    profile: profile
                )
            }
        } else {
            redactionSummary.append("scenarioEvidence")
        }

        let filteredResults: [MCPScenarioAssertionResult]
        if profile.allowedFieldClasses.contains(.scenarioAssertionResults) {
            filteredResults = assertionResults
        } else {
            filteredResults = []
            redactionSummary.append("scenarioAssertionResults")
        }

        return MCPScenarioReportDTO(
            scenarioID: record.id.rawValue,
            scenarioName: record.definition.name,
            phase: record.phase,
            riskTier: record.validationResult?.riskTier,
            activatedAt: record.activatedAt,
            evaluatedAt: evaluatedAt,
            observationWindowSeconds: record.definition.observationWindow.duration,
            evidenceCount: evidence.count,
            assertionResults: filteredResults,
            sessionSummaries: sessionSummaries,
            cleanupResult: nil,
            redactionSummary: redactionSummary.sorted(),
            warnings: warnings
        )
    }
}
