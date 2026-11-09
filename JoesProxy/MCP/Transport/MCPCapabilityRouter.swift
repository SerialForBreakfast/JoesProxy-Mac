import Foundation

/// Maps MCP tool names and resource URIs to stable capability identifiers for policy and approval.
enum MCPCapabilityRouter {
    static func capability(forTool name: String) -> MCPCapabilityID? {
        MCPCapabilitiesManifestBuilder.productionTool(named: name)?.capability
    }

    static func capability(forResource uri: String) -> MCPCapabilityID? {
        switch uri {
        case "joesproxy://server/status": return .serverResource
        case "joesproxy://capture/summary": return .captureResource
        case "joesproxy://capture/health": return .healthResource
        case "joesproxy://agent/capabilities", "joesproxy://agent/guide", "joesproxy://docs/index": return .agentResource
        case "joesproxy://setup/guide": return .agentResource
        default: return nil
        }
    }

    /// Sensitive-read capabilities requested by optional `session_summary` / response-edit arguments.
    static func sensitiveReadCapabilities(from arguments: [String: Any]) -> Set<MCPCapabilityID> {
        var capabilities: Set<MCPCapabilityID> = []
        if arguments["includeHeaders"] as? Bool == true {
            capabilities.insert(.headerRead)
        }
        if arguments["includeQuery"] as? Bool == true {
            capabilities.insert(.queryRead)
        }
        if arguments["includeBody"] as? Bool == true || arguments["includeContext"] as? Bool == true {
            capabilities.insert(.bodyRead)
        }
        return capabilities
    }

    /// Primary capability used when minting a pending approval for `session_summary`.
    static func primarySensitiveCapability(from arguments: [String: Any]) -> MCPCapabilityID? {
        let sensitive = sensitiveReadCapabilities(from: arguments)
        if sensitive.contains(.bodyRead) { return .bodyRead }
        if sensitive.contains(.queryRead) { return .queryRead }
        if sensitive.contains(.headerRead) { return .headerRead }
        return nil
    }
}
