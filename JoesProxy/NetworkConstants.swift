// NetworkConstants.swift
// JoesProxyApp
//
// Created by [Your Name] on [Date].
//
// MIT License
//
// [Include MIT License Text]

import Foundation

/// `NetworkConstants` contains network-related constants used in the proxy server.
enum NetworkConstants {
    static let defaultPort: UInt16 = 9090
    /// Default loopback port for the MCP Streamable HTTP listener (independent of the proxy port).
    static let mcpDefaultPort: UInt16 = 9091
    static let defaultBindHost = "0.0.0.0"
    static let queueLabel = "com.joesproxyapp.proxy"
}

/// Shared MCP transport constants for spike and production listeners.
enum MCPNetworkConstants {
    static let endpointPath = "/mcp"
    static let preferredProtocolVersion = "2025-11-25"
    static let supportedProtocolVersions = [
        preferredProtocolVersion,
        "2025-06-18",
        "2025-03-26"
    ]
    static let sessionIDHeader = "Mcp-Session-Id"
    static let protocolVersionHeader = "MCP-Protocol-Version"
    static let maxRequestBodyBytes = 1_048_576
    static let maxHeaderBytes = 32_768
    static let maxSlowToolDelayMilliseconds = 30_000
}
