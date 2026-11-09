import Foundation

/// Collects bounded proxy observations for an active scenario observation window (AI-3).
///
/// Concurrency: `@MainActor` — reads from the main-actor session store at evaluation time.
@MainActor
enum MCPScenarioObservationCollector {
    /// Bounds `sessions` to the scenario's observation window (`[activatedAt, min(now, activatedAt
    /// + duration)]`) and declared capture-scope hosts. Shared by both evidence collection and
    /// assertion evaluation so the two can never disagree about what "in window" means — an
    /// assertion evaluated against sessions outside this bound would count traffic that happened
    /// before the scenario was even activated, violating the ADR's "deterministic time windows"
    /// requirement.
    static func windowedSessions(
        definition: MCPScenarioDefinition,
        activatedAt: Date?,
        sessions: [SessionRecord],
        now: Date = Date()
    ) -> [SessionRecord] {
        guard let activatedAt else { return [] }
        let windowEnd = activatedAt.addingTimeInterval(definition.observationWindow.duration)
        let effectiveEnd = min(now, windowEnd)
        let allowedHosts = Set(definition.captureScope.hosts.map { $0.lowercased() })

        return sessions.filter { session in
            guard session.timing.startedAt >= activatedAt, session.timing.startedAt <= effectiveEnd else {
                return false
            }
            let host = session.request.host.lowercased()
            guard allowedHosts.isEmpty || allowedHosts.contains(host) else {
                return false
            }
            return true
        }
    }

    static func collect(
        definition: MCPScenarioDefinition,
        activatedAt: Date?,
        sessions: [SessionRecord],
        disclosureSerializer: MCPDisclosureSerializer,
        snapshotService: MCPSessionSnapshotService,
        now: Date = Date()
    ) -> [MCPScenarioEvidenceRecord] {
        let matched = windowedSessions(definition: definition, activatedAt: activatedAt, sessions: sessions, now: now)
        // Honor the scenario's own declared cap, not just the global ceiling — a scenario that
        // requested a tighter retention spec must actually get a tighter cap, not silently receive
        // up to the global maximum regardless of what it asked for.
        let effectiveCap = min(definition.evidenceRetentionSpec.maxRecords, MCPScenarioResourceBudget.maxEvidenceRecords)
        let capped = matched.prefix(effectiveCap)
        return capped.enumerated().map { index, session in
            MCPScenarioEvidenceRecord(
                id: "evidence-\(index)",
                sessionID: session.id.uuidString,
                captureSequence: snapshotService.indexedSession(id: session.id)?.captureSequence,
                method: session.request.method,
                sanitizedHost: disclosureSerializer.sanitizedHost(session.request.host),
                sanitizedPath: disclosureSerializer.sanitizedPath(session.request.path),
                statusCode: session.response?.statusCode,
                durationSeconds: session.timing.duration,
                evidenceSource: .captured,
                observedAt: session.timing.startedAt,
                inferenceNotes: nil
            )
        }
    }

    static func matches(
        session: SessionRecord,
        assertion: MCPScenarioAssertion
    ) -> Bool {
        if let matcher = assertion.matcher {
            return matches(session: session, matcher: matcher)
        }
        if let host = assertion.host?.lowercased() {
            guard session.request.host.lowercased() == host else { return false }
            if let path = assertion.path, !path.isEmpty {
                return session.request.path.hasPrefix(path)
            }
            return true
        }
        return false
    }

    static func matches(session: SessionRecord, matcher: MCPMutationMatcher) -> Bool {
        guard session.request.method.caseInsensitiveCompare(matcher.method) == .orderedSame else {
            return false
        }
        guard session.request.scheme == matcher.scheme else { return false }
        guard session.request.host.caseInsensitiveCompare(matcher.host) == .orderedSame else {
            return false
        }
        if let port = matcher.port, session.request.port != port {
            return false
        }
        switch matcher.matchMode {
        case .exactPath:
            return session.request.path == matcher.path
        case .pathPrefix:
            return session.request.path.hasPrefix(matcher.path)
        case .ignoreQuery:
            return BookmarkRequestMatcher.pathMatches(
                rulePath: BookmarkRequestMatcher.normalizedPathForMatch(matcher.path, mode: .ignoreQuery),
                requestPath: BookmarkRequestMatcher.normalizedPathForMatch(session.request.path, mode: .ignoreQuery),
                mode: .ignoreQuery
            )
        case .pathSuffix:
            return BookmarkRequestMatcher.pathMatches(
                rulePath: BookmarkRequestMatcher.normalizedPathForMatch(matcher.path, mode: .pathSuffix),
                requestPath: BookmarkRequestMatcher.normalizedPathForMatch(session.request.path, mode: .pathSuffix),
                mode: .pathSuffix
            )
        case .filename:
            return BookmarkRequestMatcher.pathMatches(
                rulePath: BookmarkRequestMatcher.normalizedPathForMatch(matcher.path, mode: .filename),
                requestPath: BookmarkRequestMatcher.normalizedPathForMatch(session.request.path, mode: .filename),
                mode: .filename
            )
        }
    }
}
