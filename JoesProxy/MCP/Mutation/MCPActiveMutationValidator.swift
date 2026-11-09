import Foundation

/// Validates active MCP mutations (enable/disable/throttle) at propose time.
enum MCPActiveMutationValidator {
    /// Ensures an override rule is eligible for enable.
    static func validateEnableRule(_ rule: ResponseOverrideRule) throws {
        guard rule.sourceKind != .mapRemote && rule.sourceKind != .liveResponseRewrite
            && rule.sourceKind != .collectionMock else {
            let toolName: String
            switch rule.sourceKind {
            case .mapRemote: toolName = "activate_map_remote"
            case .collectionMock: toolName = "activate_collection_mock"
            default: toolName = "activate_live_rewrite"
            }
            throw MCPMutationValidationError.policyDenied(
                "\(rule.sourceKind.title) rules must be enabled with \(toolName) (open-world), not enable_rule."
            )
        }
        guard rule.mcpOrigin == .mcp else {
            throw MCPMutationValidationError.policyDenied("Only MCP-created overrides can be enabled through MCP.")
        }
        guard !rule.isEnabled else {
            throw MCPMutationValidationError.malformedRequest("Override is already enabled.")
        }
    }

    /// Ensures an override rule is eligible for disable.
    static func validateDisableRule(_ rule: ResponseOverrideRule) throws {
        guard rule.mcpOrigin == .mcp else {
            throw MCPMutationValidationError.policyDenied("Only MCP-created overrides can be disabled through MCP.")
        }
        guard rule.isEnabled else {
            throw MCPMutationValidationError.malformedRequest("Override is already disabled.")
        }
    }

    /// Ensures an override rule is eligible for permanent MCP delete.
    static func validateDeleteRule(_ rule: ResponseOverrideRule) throws {
        guard rule.mcpOrigin == .mcp else {
            throw MCPMutationValidationError.policyDenied("Only MCP-created overrides can be deleted through MCP.")
        }
    }

    /// Ensures a bookmark rewrite is eligible for enable.
    static func validateEnableRewrite(bookmark: Bookmark, rewrite: BookmarkResponseFieldRewrite) throws {
        guard bookmark.mcpOrigin == .mcp else {
            throw MCPMutationValidationError.policyDenied("Only MCP-created bookmark rewrites can be enabled through MCP.")
        }
        guard !rewrite.isRuleEnabled else {
            throw MCPMutationValidationError.malformedRequest("Rewrite rule is already enabled.")
        }
    }

    /// Ensures a bookmark rewrite is eligible for disable.
    static func validateDisableRewrite(bookmark: Bookmark, rewrite: BookmarkResponseFieldRewrite) throws {
        guard bookmark.mcpOrigin == .mcp else {
            throw MCPMutationValidationError.policyDenied("Only MCP-created bookmark rewrites can be disabled through MCP.")
        }
        guard rewrite.isRuleEnabled else {
            throw MCPMutationValidationError.malformedRequest("Rewrite rule is already disabled.")
        }
    }

    /// Builds a throttle configuration from propose arguments merged with the current config.
    static func mergedThrottleConfiguration(
        arguments: [String: Any],
        current: NetworkThrottleConfiguration
    ) throws -> NetworkThrottleConfiguration {
        var updated = current
        if let isEnabled = arguments["isEnabled"] as? Bool {
            updated.isEnabled = isEnabled
        }
        if let presetID = arguments["selectedPresetID"] as? String, !presetID.isEmpty {
            guard updated.presets.contains(where: { $0.id == presetID }) else {
                throw MCPMutationValidationError.malformedRequest("Unknown throttle preset ID.")
            }
            updated.selectedPresetID = presetID
        }
        if let presetIndex = updated.presets.firstIndex(where: { $0.id == updated.selectedPresetID }) {
            var preset = updated.presets[presetIndex]
            if let downstream = arguments["customDownstreamKbps"] as? Int {
                preset.downstreamKbps = downstream
            }
            if let upstream = arguments["customUpstreamKbps"] as? Int {
                preset.upstreamKbps = upstream
            }
            if let latencyMs = arguments["latencyMs"] as? Int {
                preset.latencyMs = latencyMs
            }
            guard preset.isValid else {
                throw MCPMutationValidationError.malformedRequest("Throttle preset values are invalid.")
            }
            updated.presets[presetIndex] = preset
        }
        return updated
    }

    static func parseOverrideID(from arguments: [String: Any]) throws -> UUID {
        guard let raw = arguments["overrideID"] as? String,
              let id = UUID(uuidString: raw) else {
            throw MCPMutationValidationError.malformedRequest("overrideID is required.")
        }
        return id
    }

    static func parseBookmarkRewriteIDs(from arguments: [String: Any]) throws -> (bookmarkID: UUID, rewriteID: UUID) {
        guard let bookmarkRaw = arguments["bookmarkID"] as? String,
              let bookmarkID = UUID(uuidString: bookmarkRaw) else {
            throw MCPMutationValidationError.malformedRequest("bookmarkID is required.")
        }
        guard let rewriteRaw = arguments["rewriteID"] as? String,
              let rewriteID = UUID(uuidString: rewriteRaw) else {
            throw MCPMutationValidationError.malformedRequest("rewriteID is required.")
        }
        return (bookmarkID, rewriteID)
    }
}
