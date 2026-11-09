import Foundation

/// Evaluates declarative scenario assertions against collected evidence (AI-3).
///
/// Network assertions with `captured` evidence are evaluated now. SDK/external/inferred kinds
/// return explicit `inconclusive` outcomes rather than being silently treated as pass/fail.
///
/// Concurrency: `@MainActor` — delegates session matching to ``MCPScenarioObservationCollector``.
@MainActor
enum MCPScenarioAssertionEvaluator {
    static func evaluate(
        definition: MCPScenarioDefinition,
        evidence: [MCPScenarioEvidenceRecord],
        sessions: [SessionRecord],
        activatedAt: Date?,
        now: Date = Date()
    ) -> [MCPScenarioAssertionResult] {
        // Bound to the same observation window evidence collection uses — an assertion must never
        // count traffic from before the scenario activated (or after the window closed) toward
        // pass/fail, or "deterministic time windows" is violated in practice even though evidence
        // collection itself is correctly windowed.
        let windowedSessions = MCPScenarioObservationCollector.windowedSessions(
            definition: definition,
            activatedAt: activatedAt,
            sessions: sessions,
            now: now
        )
        return definition.assertions.enumerated().map { index, assertion in
            evaluateOne(
                assertionIndex: index,
                assertion: assertion,
                evidence: evidence,
                sessions: windowedSessions
            )
        }
    }

    static func resolvedOutcome(
        results: [MCPScenarioAssertionResult],
        severity: MCPScenarioAssertionSeverity
    ) -> MCPScenarioPhase {
        if results.contains(where: { $0.outcome == .failed }) {
            switch severity {
            case .blocking:
                return .failed
            case .warning, .informational:
                return .inconclusive
            }
        }
        if results.contains(where: { $0.outcome == .inconclusive }) {
            return .inconclusive
        }
        return .completed
    }

    private static func evaluateOne(
        assertionIndex: Int,
        assertion: MCPScenarioAssertion,
        evidence: [MCPScenarioEvidenceRecord],
        sessions: [SessionRecord]
    ) -> MCPScenarioAssertionResult {
        if isNonCapturedKind(assertion.kind) || assertion.evidenceSource != .captured {
            return MCPScenarioAssertionResult(
                assertionIndex: assertionIndex,
                kind: assertion.kind,
                outcome: .inconclusive,
                evidenceSource: assertion.evidenceSource,
                detail: inconclusiveDetail(for: assertion),
                supportingEvidenceIDs: []
            )
        }

        let matchingSessions = sessions.filter { MCPScenarioObservationCollector.matches(session: $0, assertion: assertion) }
        let supportingIDs = evidence.filter { record in
            matchingSessions.contains { $0.id.uuidString == record.sessionID }
        }.map(\.id)

        switch assertion.kind {
        case .requestOccurred:
            let passed = !matchingSessions.isEmpty
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: passed ? "Matching request observed." : "No matching request in observation window.",
                supportingIDs: supportingIDs
            )

        case .requestNotOccurred:
            let passed = matchingSessions.isEmpty
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: passed ? "No matching request observed." : "Unexpected matching request observed.",
                supportingIDs: supportingIDs
            )

        case .retryCount:
            let expected = assertion.expectedCount ?? 0
            let actual = matchingSessions.count
            let passed = actual == expected
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: "Expected \(expected) matching requests, observed \(actual).",
                supportingIDs: supportingIDs
            )

        case .errorResponseReachedClient:
            let passed = matchingSessions.contains { ($0.response?.statusCode ?? 0) >= 400 }
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: passed ? "Error response reached client." : "No error response observed for matcher.",
                supportingIDs: supportingIDs
            )

        case .latencyThreshold:
            let threshold = assertion.thresholdSeconds ?? 0
            let passed = matchingSessions.contains { ($0.timing.duration ?? 0) >= threshold }
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: "Latency threshold \(threshold)s \(passed ? "met" : "not met").",
                supportingIDs: supportingIDs
            )

        case .overrideMatched:
            let passed = matchingSessions.contains { $0.response?.mcpAttribution != nil }
            return result(
                assertionIndex: assertionIndex,
                assertion: assertion,
                outcome: passed ? .passed : .failed,
                detail: passed ? "MCP override attribution observed." : "No MCP override attribution on matching traffic.",
                supportingIDs: supportingIDs
            )

        default:
            return MCPScenarioAssertionResult(
                assertionIndex: assertionIndex,
                kind: assertion.kind,
                outcome: .inconclusive,
                evidenceSource: assertion.evidenceSource,
                detail: "Assertion kind \(assertion.kind.rawValue) is not yet evaluated in AI-3.",
                supportingEvidenceIDs: supportingIDs
            )
        }
    }

    private static func result(
        assertionIndex: Int,
        assertion: MCPScenarioAssertion,
        outcome: MCPScenarioAssertionOutcome,
        detail: String,
        supportingIDs: [String]
    ) -> MCPScenarioAssertionResult {
        MCPScenarioAssertionResult(
            assertionIndex: assertionIndex,
            kind: assertion.kind,
            outcome: outcome,
            evidenceSource: assertion.evidenceSource,
            detail: detail,
            supportingEvidenceIDs: supportingIDs
        )
    }

    private static func isNonCapturedKind(_ kind: MCPScenarioAssertionKind) -> Bool {
        switch kind {
        case .sdkStateTransition, .sdkErrorCategory, .sdkRetryState, .sdkPlaybackState,
             .sdkBufferingOrStall, .sdkFallbackActivated, .sdkUserVisibleRecovery, .sdkTestStepMarker,
             .externalTestStepBegin, .externalTestStepEnd:
            return true
        default:
            return false
        }
    }

    private static func inconclusiveDetail(for assertion: MCPScenarioAssertion) -> String {
        switch assertion.evidenceSource {
        case .inferredCorrelation:
            return "Inferred assertions require AI-3 correlation evaluation; not presented as directly observed."
        case .sdkReported:
            return "SDK-reported assertions require SDK observation plumbing (not yet connected)."
        case .externalRunner:
            return "External runner markers require external observation ingestion (not yet connected)."
        case .captured:
            return "Assertion is not evaluable with captured proxy evidence alone."
        }
    }
}
