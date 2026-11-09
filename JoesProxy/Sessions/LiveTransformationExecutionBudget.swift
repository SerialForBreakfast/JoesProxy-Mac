import Foundation

/// Dedicated execution-budget constants for the semantic live-response transformation subsystem
/// (selectors, body size, matched values, output growth, activation lifetime/hit-count).
///
/// Deliberately its own named type, not a reuse of `RecordingConstants.bodySizeLimit` (a
/// `.jproxy`-file-storage truncation constant already reused — and confirmed as an existing
/// anti-pattern — for several unrelated concerns) and not `MCPResourceBudget` (MCP disclosure
/// payload sizing, a different concern from real-traffic transformation execution limits). These
/// numbers are initial conservative defaults per the semantic live-response transformation ADR and
/// may be revised during grooming without touching either of those unrelated budget types.
enum LiveTransformationExecutionBudget {
    static let maxSelectorsPerRule = 16
    /// Maximum wire (encoded) body bytes before decode or after re-encode.
    static let maxEncodedBodyBytes = 1_048_576
    /// Maximum decoded JSON bytes passed to the mutation engine.
    static let maxDecodedBodyBytes = 4_194_304
    static let maxMatchedValuesPerResponse = 1_000
    /// Maximum growth in body size (transformed − original), not an absolute cap — a rule that
    /// slightly shrinks or holds body size steady is unaffected regardless of absolute size.
    static let maxOutputGrowthBytes = 65_536
    static let maxTransformedResponsesPerActivation = 100
    static let activationLifetimeSeconds: TimeInterval = 900
}
