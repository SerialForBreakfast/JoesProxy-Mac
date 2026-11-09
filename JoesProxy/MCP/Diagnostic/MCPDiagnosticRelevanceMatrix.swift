import Foundation

/// Maps diagnostic views to MCP effect kinds that can skew their readings (ADR § Diagnostic Interlock).
enum MCPDiagnosticRelevanceMatrix {
    /// Returns whether `kind` can affect measurements for `diagnostic`.
    static func isRelevant(effectKind: MCPEffectKind, to diagnostic: MCPDiagnosticKind) -> Bool {
        relevantEffectKinds(for: diagnostic).contains(effectKind)
    }

    /// Effect kinds that can skew the given diagnostic. Unknown kinds are not listed — callers fail closed.
    static func relevantEffectKinds(for diagnostic: MCPDiagnosticKind) -> Set<MCPEffectKind> {
        switch diagnostic {
        case .waterfallLatencyTimeline:
            return [.throttle, .responseOverride]
        case .hostHealthErrorSummary:
            return [.throttle, .block, .responseOverride, .mapRemote, .liveResponseRewrite]
        case .responseComparison:
            return [.mapLocal, .mapRemote, .bookmarkRewrite, .responseOverride, .liveResponseRewrite, .openAPIMockPack]
        }
    }

    /// Maps a diagnostic export type to the closest interlock diagnostic kind.
    static func diagnosticKind(for exportType: VisualizationExportType) -> MCPDiagnosticKind? {
        switch exportType {
        case .requestWaterfall, .sessionTimeline:
            return .waterfallLatencyTimeline
        case .hostHealthSummary:
            return .hostHealthErrorSummary
        case .latencyDistribution, .errorHeatmap, .hlsPlaybackFlow, .mediaAssetDeliveryTimeline,
             .adAndCompanionAssetTimeline, .variantSwitchTimeline, .timedMetadataTimeline,
             .contractViolationSummary:
            return nil
        }
    }

    /// Filters inventory rows to those relevant and currently enabled for the diagnostic.
    static func relevantEnabledItems(
        _ inventory: [MCPEffectInventoryItem],
        diagnostic: MCPDiagnosticKind
    ) -> [MCPEffectInventoryItem] {
        let relevant = relevantEffectKinds(for: diagnostic)
        return inventory.filter { $0.isEnabled && relevant.contains($0.kind) }
    }
}
