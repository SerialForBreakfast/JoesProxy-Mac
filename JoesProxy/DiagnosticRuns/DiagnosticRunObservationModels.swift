import Foundation

/// Kind of one bounded observation published to a diagnostic run (AN-3).
enum DiagnosticObservationKind: String, Codable, Sendable {
    case hit
    case matcherMiss
    case absence
    case captureUnavailable
    case marker
}

/// Compact, privacy-bounded observation. Never contains bodies, headers, query values, or credentials.
struct DiagnosticRunObservationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var runID: DiagnosticRunID
    var sequence: UInt64
    var kind: DiagnosticObservationKind
    var observedAt: Date
    var captureEpoch: MCPCaptureEpoch
    var captureSequence: UInt64?
    var sessionID: UUID?
    var method: String?
    var scheme: SessionScheme?
    var host: String?
    var port: Int?
    /// Root-relative path with query and fragment stripped.
    var path: String?
    var statusFamily: String?
    var latencyMilliseconds: Int?
    var attributionIDs: [String]
    var markerID: UUID?
    var unavailableReason: DiagnosticEvidenceUnavailableReason?
}

/// Owner-scoped cursor bound to one run and one capture epoch.
struct DiagnosticObservationCursor: Codable, Equatable, Sendable {
    var runID: DiagnosticRunID
    var ownerID: String
    var captureEpoch: MCPCaptureEpoch
    var lastSequence: UInt64
}

/// One page of observations plus an optional resume cursor.
struct DiagnosticRunObservationPage: Equatable, Sendable {
    var records: [DiagnosticRunObservationRecord]
    var nextCursor: DiagnosticObservationCursor?
    var droppedObservationCount: Int
    var evidenceUnavailableReason: DiagnosticEvidenceUnavailableReason?
}

/// Coalesced notification that a run has new observations. Does not carry payloads.
struct DiagnosticRunObservationNotification: Equatable, Sendable {
    var runID: DiagnosticRunID
    var latestSequence: UInt64
    var captureEpoch: MCPCaptureEpoch
    var droppedEventCount: Int
}

/// Sendable capture fact extracted on the main actor before hopping to the observation index.
struct DiagnosticRunCaptureEvent: Equatable, Sendable {
    var sessionID: UUID
    var captureSequence: UInt64
    var captureEpoch: MCPCaptureEpoch
    var method: String
    var scheme: SessionScheme
    var host: String
    var port: Int
    var path: String
    var statusCode: Int?
    var latencyMilliseconds: Int?
    var observedAt: Date
    var isMarker: Bool
    var attributionIDs: [String]

    /// Builds an event the same way for both the live capture bridge and the regression re-check's
    /// synchronous history scan. Returns nil for in-flight sessions that are neither a marker nor
    /// have a response yet — nothing to observe.
    static func make(
        from session: SessionRecord,
        captureSequence: UInt64,
        captureEpoch: MCPCaptureEpoch
    ) -> DiagnosticRunCaptureEvent? {
        let isMarker = CaptureMarkerConstants.isMarkerRecord(session)
        let hasResponse = session.response != nil || session.state == .completed
        guard isMarker || hasResponse else { return nil }
        let path = DiagnosticRunScopeMatcher.pathExcludingQuery(session.request.path)
        let latency: Int?
        if let duration = session.timing.duration {
            latency = Int((duration * 1_000).rounded())
        } else {
            latency = nil
        }
        return DiagnosticRunCaptureEvent(
            sessionID: session.id,
            captureSequence: captureSequence,
            captureEpoch: captureEpoch,
            method: session.request.method,
            scheme: session.request.scheme,
            host: session.request.host.lowercased(),
            port: BookmarkRequestMatcher.canonicalPort(session.request.port, scheme: session.request.scheme),
            path: path,
            statusCode: session.response?.statusCode,
            latencyMilliseconds: latency,
            observedAt: session.timing.completedAt ?? session.timing.startedAt,
            isMarker: isMarker,
            attributionIDs: DiagnosticRunScopeMatcher.attributionIDs(from: session.response?.mcpAttribution)
        )
    }
}

/// Watch descriptor resolved on the main actor before install (frozen matcher snapshot).
struct DiagnosticInstalledWatch: Equatable, Sendable {
    var id: UUID
    var runID: DiagnosticRunID
    var ownerID: String
    var scope: DiagnosticRunScope
    var resolvedHTTP: DiagnosticHTTPScope?
    var fingerprint: String?
}

/// Result of ingesting one capture event into zero or more watching runs.
struct DiagnosticRunIngestResult: Equatable, Sendable {
    var updatedSummaries: [DiagnosticRunID: DiagnosticRunObservationSummary]

    static let empty = DiagnosticRunIngestResult(updatedSummaries: [:])
}

/// Resolves an effect ID to the disclosed HTTP matcher used for observation (AN-3).
protocol DiagnosticRunEffectScopeResolving: AnyObject {
    func disclosedHTTPScope(
        kind: DiagnosticReferenceKind,
        effectID: String
    ) async -> DiagnosticHTTPScope?
}

/// Override-rule resolver. Other effect kinds are unsupported for v1 observation.
@MainActor
final class OverrideRuleEffectScopeResolver: DiagnosticRunEffectScopeResolving {
    private let store: ResponseOverrideStore

    init(store: ResponseOverrideStore) {
        self.store = store
    }

    func disclosedHTTPScope(
        kind: DiagnosticReferenceKind,
        effectID: String
    ) async -> DiagnosticHTTPScope? {
        guard kind == .overrideRule, let uuid = UUID(uuidString: effectID) else { return nil }
        guard let rule = await store.rule(id: uuid) else { return nil }
        let path = String(rule.path.split(separator: "?", maxSplits: 1).first ?? Substring(rule.path))
        let pathMatch: DiagnosticPathMatch
        switch rule.matchMode {
        case .exactPath, .ignoreQuery:
            pathMatch = .exact
        case .pathPrefix:
            pathMatch = .prefix
        case .pathSuffix:
            pathMatch = .suffix
        case .filename:
            pathMatch = .filename
        }
        return DiagnosticHTTPScope(
            method: rule.requestMethod,
            scheme: rule.requestScheme,
            host: rule.host,
            port: BookmarkRequestMatcher.canonicalPort(rule.port, scheme: rule.requestScheme),
            path: path,
            pathMatch: pathMatch
        )
    }
}
