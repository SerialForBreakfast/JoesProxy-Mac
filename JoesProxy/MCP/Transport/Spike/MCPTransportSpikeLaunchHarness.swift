import Foundation

#if DEBUG
/// Keeps the AG-0 server alive for manual Claude/Codex interoperability testing.
///
/// This is intentionally launch-argument gated and is not the production MCP lifecycle.
@MainActor
enum MCPTransportSpikeLaunchHarness {
    private static let launchArgument = "--mcp-transport-spike"
    private static let portArgumentPrefix = "--mcp-spike-port="
    private static let credentialEnvironmentKey = "JOESPROXY_MCP_SPIKE_CREDENTIAL"
    private static var retainedServer: MCPTransportSpikeServer?

    static func startIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard arguments.contains(launchArgument), retainedServer == nil else {
            return
        }

        let port = arguments
            .first(where: { $0.hasPrefix(portArgumentPrefix) })
            .flatMap { UInt16($0.dropFirst(portArgumentPrefix.count)) }
            ?? NetworkConstants.mcpDefaultPort
        let suppliedCredential = environment[credentialEnvironmentKey]
        let server = MCPTransportSpikeServer { event in
            print("JOESPROXY_MCP_SPIKE_EVENT \(event.consoleDescription)")
        }
        retainedServer = server

        Task {
            do {
                let credential = try await server.start(
                    port: port,
                    bearerCredential: suppliedCredential
                )
                print("JOESPROXY_MCP_SPIKE_READY http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")
                if suppliedCredential == nil {
                    print("JOESPROXY_MCP_SPIKE_CREDENTIAL \(credential)")
                } else {
                    print("JOESPROXY_MCP_SPIKE_CREDENTIAL_SOURCE supplied_environment")
                }
            } catch {
                print("JOESPROXY_MCP_SPIKE_FAILED \(error.localizedDescription)")
                retainedServer = nil
            }
        }
    }
}
#endif
