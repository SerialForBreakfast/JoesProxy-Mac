import Foundation

/// Diagnostic surfaces that participate in the MCP interlock (AJ-4).
enum MCPDiagnosticKind: String, Equatable, Sendable, CaseIterable {
    case waterfallLatencyTimeline
    case hostHealthErrorSummary
    case responseComparison

    var displayName: String {
        switch self {
        case .waterfallLatencyTimeline:
            return "Waterfall and latency"
        case .hostHealthErrorSummary:
            return "Host health and errors"
        case .responseComparison:
            return "Response comparison"
        }
    }
}
