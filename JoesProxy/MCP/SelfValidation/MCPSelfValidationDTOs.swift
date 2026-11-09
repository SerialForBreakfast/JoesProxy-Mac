import Foundation

/// Stable identifier for one isolated self-validation run (AI-5).
struct MCPValidationRunID: Equatable, Sendable, Codable, Hashable {
    var rawValue: String

    static func generate() -> MCPValidationRunID {
        MCPValidationRunID(rawValue: "sv-\(UUID().uuidString)")
    }
}

/// Lifecycle phase for the self-validation coordinator (AI-5).
enum MCPSelfValidationRunPhase: String, Equatable, Sendable, Codable {
    case idle
    case running
    case cleaningUp
    case failed
}

/// Outcome of a completed self-validation run.
enum MCPSelfValidationRunOutcome: String, Equatable, Sendable, Codable {
    case succeeded
    case failed
    case timedOut
    case cleanupFailed
}

/// Named deterministic fixture routes consumed by AI-6 feature-matrix scenarios.
enum MCPSelfValidationFixtureRoute: String, Equatable, Sendable, CaseIterable {
    case ok = "/ok"
    case blockTarget = "/block-target"
    case rewriteTarget = "/rewrite-target"
    case mapRemoteTarget = "/map-remote-target"
    case liveRewriteTarget = "/live-rewrite-target"
    case epgTarget = "/epg-target"
    case throttleTarget = "/throttle-target"

    var defaultStatusCode: Int {
        switch self {
        case .ok, .blockTarget, .rewriteTarget, .mapRemoteTarget, .liveRewriteTarget, .epgTarget, .throttleTarget:
            return 200
        }
    }

    var defaultBody: String {
        switch self {
        case .ok:
            return "self-validation-ok"
        case .blockTarget:
            return "self-validation-block-upstream"
        case .rewriteTarget:
            return "self-validation-rewrite-upstream"
        case .mapRemoteTarget:
            return "self-validation-map-remote-upstream"
        case .liveRewriteTarget:
            return #"{"flag":false}"#
        case .epgTarget:
            return #"{"channels":[{"id":"news","programs":[{"title":"Morning News","rating":"TV-G"},{"title":"World Report","rating":"TV-PG"}]},{"id":"sports","programs":[{"title":"Live Match","rating":"TV-G"}]}],"generatedAt":"fixture"}"#
        case .throttleTarget:
            return "self-validation-throttle-upstream"
        }
    }

    var defaultContentType: String {
        switch self {
        case .liveRewriteTarget, .epgTarget:
            return "application/json; charset=utf-8"
        default:
            return "text/plain; charset=utf-8"
        }
    }
}

/// Summary published while a validation run is active or after it completes.
struct MCPSelfValidationRunSummary: Equatable, Sendable, Codable {
    var runID: MCPValidationRunID
    var phase: MCPSelfValidationRunPhase
    var outcome: MCPSelfValidationRunOutcome?
    var startedAt: Date
    var finishedAt: Date?
    var validationProxyPort: UInt16?
    var fixturePort: UInt16?
    var failureMessage: String?
}

enum MCPSelfValidationError: Error, Equatable, Sendable {
    case validationRunAlreadyActive
    case validationRunNotActive
    case timedOut
    case cleanupFailed(String)
    case fixtureUnavailable
    case proxyUnavailable
}
