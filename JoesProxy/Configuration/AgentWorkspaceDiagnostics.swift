import Foundation

/// Enables aggregate-only ownership diagnostics for isolated synthetic agent-workspace runs.
///
/// Production launches cannot enable this recorder: both an isolated test launch and the explicit
/// argument/environment pair are required. The recorder stores counters only, never an owner,
/// session, query, body, or timing sample.
struct AgentWorkspaceDiagnosticsConfiguration: Equatable {
    init?(arguments: [String], environment: [String: String], isolated: Bool) {
        guard isolated,
              arguments.contains("--agent-workspace-diagnostics"),
              environment["JOESPROXY_AGENT_WORKSPACE_DIAGNOSTICS"] == "1" else {
            return nil
        }
    }
}

struct AgentWorkspaceDiagnosticSnapshot: Equatable, Sendable {
    var inspectorModelConstructionCount: UInt64
    var inspectorModelReleaseCount: UInt64
    var inspectorSubscriptionCount: UInt64
    var inspectorPresentationActivationCount: UInt64
    var inspectorPresentationDeactivationCount: UInt64
    var explicitAgentAnalysisCount: UInt64

    static let empty = AgentWorkspaceDiagnosticSnapshot(
        inspectorModelConstructionCount: 0,
        inspectorModelReleaseCount: 0,
        inspectorSubscriptionCount: 0,
        inspectorPresentationActivationCount: 0,
        inspectorPresentationDeactivationCount: 0,
        explicitAgentAnalysisCount: 0
    )
}

/// Lock-protected counter recorder shared by the disposable app process and its profiling sampler.
/// Calls are intentionally no-ops unless the isolated configuration is installed first.
final class AgentWorkspaceDiagnostics: @unchecked Sendable {
    static let shared = AgentWorkspaceDiagnostics()

    private let lock = NSLock()
    private var isEnabled = false
    private var snapshot = AgentWorkspaceDiagnosticSnapshot.empty

    init() {}

    func configure(arguments: [String], environment: [String: String], isolated: Bool) {
        lock.lock()
        isEnabled = AgentWorkspaceDiagnosticsConfiguration(
            arguments: arguments,
            environment: environment,
            isolated: isolated
        ) != nil
        snapshot = .empty
        lock.unlock()
    }

    func currentSnapshot() -> AgentWorkspaceDiagnosticSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return isEnabled ? snapshot : nil
    }

    func recordInspectorModelConstruction() {
        mutate { $0.inspectorModelConstructionCount &+= 1 }
    }

    func recordInspectorModelRelease() {
        mutate { $0.inspectorModelReleaseCount &+= 1 }
    }

    func recordInspectorSubscription() {
        mutate { $0.inspectorSubscriptionCount &+= 1 }
    }

    func recordInspectorPresentation(active: Bool) {
        mutate {
            if active {
                $0.inspectorPresentationActivationCount &+= 1
            } else {
                $0.inspectorPresentationDeactivationCount &+= 1
            }
        }
    }

    /// Reserved for the shared query owner introduced by AGW-2. It deliberately has no object
    /// argument, so recording explicit agent work cannot retain a presentation owner.
    func recordExplicitAgentAnalysis() {
        mutate { $0.explicitAgentAnalysisCount &+= 1 }
    }

    private func mutate(_ body: (inout AgentWorkspaceDiagnosticSnapshot) -> Void) {
        lock.lock()
        if isEnabled {
            body(&snapshot)
        }
        lock.unlock()
    }
}
