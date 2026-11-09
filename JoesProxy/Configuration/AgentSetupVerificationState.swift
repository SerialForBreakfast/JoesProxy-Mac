enum AgentSetupVerificationState: String, Equatable, Sendable {
    case inspected
    case tunneled
    case noTrafficObserved
    case proxyStopped

    var title: String {
        switch self {
        case .inspected: return "HTTPS traffic was inspected successfully"
        case .tunneled: return "Traffic is routing through JoesProxy, but HTTPS is still tunneled"
        case .noTrafficObserved: return "No test traffic was observed yet"
        case .proxyStopped: return "Start the proxy before running the test"
        }
    }

    var message: String {
        switch self {
        case .inspected: return "JoesProxy has observed at least one inspected HTTPS session, so certificate trust and routing are working together."
        case .tunneled: return "Traffic is reaching JoesProxy, but HTTPS decryption is still unavailable or intentionally bypassed for the observed host."
        case .noTrafficObserved: return "No routed session observed yet. Verify proxy host, port, browser or device proxy settings, and network reachability."
        case .proxyStopped: return "The proxy listener is not running. Start it, then retry the verification flow."
        }
    }
}
