import Foundation

/// Resolves immutable capture-time MCP attribution for live proxy effects.
enum MCPActiveEffectAttributionResolver {
    /// Returns attribution when an enabled override rule has MCP provenance.
    static func attribution(for rule: ResponseOverrideRule) -> MCPCaptureAttribution? {
        guard rule.isEnabled, let provenance = rule.mcpProvenance else {
            return nil
        }
        let effectKind = effectKind(for: rule.sourceKind)
        return MCPSessionAttributionService.attributionForActiveEffects(
            effectKinds: [effectKind],
            provenance: provenance
        )
    }

    /// Returns attribution when network throttling is active and MCP-owned.
    static func attribution(for throttleConfiguration: NetworkThrottleConfiguration) -> MCPCaptureAttribution? {
        guard throttleConfiguration.effectivePreset() != nil,
              let provenance = throttleConfiguration.mcpProvenance else {
            return nil
        }
        return MCPSessionAttributionService.attributionForActiveEffects(
            effectKinds: [.throttle],
            provenance: provenance
        )
    }

    /// Returns attribution when a bookmark intercept rewrite is MCP-owned.
    static func attribution(for bookmark: Bookmark) -> MCPCaptureAttribution? {
        guard bookmark.mcpOrigin == .mcp,
              bookmark.responseRewrites.contains(where: \.isRuleEnabled),
              let provenance = bookmark.mcpProvenance else {
            return nil
        }
        return MCPSessionAttributionService.attributionForActiveEffects(
            effectKinds: [.bookmarkRewrite],
            provenance: provenance
        )
    }

    /// Stamps a response once with override attribution, optionally layering throttle attribution.
    static func stampedResponse(
        _ response: CapturedResponse,
        overrideAttribution: MCPCaptureAttribution?,
        throttleAttribution: MCPCaptureAttribution?
    ) -> CapturedResponse {
        if let overrideAttribution {
            return MCPSessionAttributionService.stampedResponse(response, attribution: overrideAttribution)
        }
        if let throttleAttribution {
            return MCPSessionAttributionService.stampedResponse(response, attribution: throttleAttribution)
        }
        return response
    }

    private static func effectKind(for sourceKind: ResponseOverrideSourceKind) -> MCPEffectKind {
        switch sourceKind {
        case .block:
            return .block
        case .mapRemote:
            return .mapRemote
        case .bookmarkRewrite:
            return .bookmarkRewrite
        case .liveResponseRewrite:
            return .liveResponseRewrite
        case .collectionMock:
            return .collectionMock
        case .capturedResponse, .inlineText, .localFile, .fixtureRun, .localDirectory:
            return .mapLocal
        }
    }
}
