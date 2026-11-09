import Foundation

/// Projects live MCP-owned proxy effects into ``MCPEffectSummary`` for recovery UI.
enum MCPEffectStateScanner {
    static func summarize(
        rules: [ResponseOverrideRule],
        bookmarks: [Bookmark],
        throttleConfiguration: NetworkThrottleConfiguration,
        activeScenarioIDs: [String] = []
    ) -> MCPEffectSummary {
        let createdOverrides = rules.filter { $0.mcpOrigin == .mcp }.count
        let createdBookmarks = bookmarks.filter { $0.mcpOrigin == .mcp }.count
        let enabledOverrides = rules.filter { $0.mcpOrigin == .mcp && $0.isEnabled }.count
        let enabledBookmarkRewrites = bookmarks.filter { bookmark in
            bookmark.mcpOrigin == .mcp && bookmark.responseRewrites.contains(where: \.isRuleEnabled)
        }.count
        let throttleChanged = throttleConfiguration.isEnabled
            && throttleConfiguration.mcpOrigin == .mcp
            && throttleConfiguration.effectivePreset() != nil
        return MCPEffectSummary(
            createdRuleCount: createdOverrides + createdBookmarks,
            changedRuleCount: enabledOverrides + enabledBookmarkRewrites,
            throttleChanged: throttleChanged,
            activeScenarioIDs: activeScenarioIDs
        )
    }

    static func effectState(from summary: MCPEffectSummary) -> MCPEffectState {
        if summary.changedRuleCount > 0 || summary.throttleChanged {
            return .active(summary)
        }
        return .clean
    }
}
