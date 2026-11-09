import Foundation
import CryptoKit

/// Persistent preferences, not bundle effects. Validate and write on MainActor without suspension.
enum MCPHTTPSRules {
    enum Mode: String, CaseIterable { case tunnel, inspect, remove }

    static func host(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw invalid() }
        let host = value.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), !labels.allSatisfy({ Int($0) != nil }) else { throw invalid() }
        return host
    }

    static func revision(_ rules: TLSInterceptionRules) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(rules)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func changed(_ rules: TLSInterceptionRules, host: String, mode: Mode) throws -> TLSInterceptionRules {
        var updated = rules
        updated.bypassDomains.removeAll { $0.lowercased() == host }
        updated.interceptDomains.removeAll { $0.lowercased() == host }
        switch mode {
        case .tunnel: updated.bypassDomains.append(host)
        case .inspect:
            if case .bypass = TLSInterceptionPolicy.decision(for: host, rules: updated) {
                throw MCPStructuredError(code: .policyDenied,
                    message: "A built-in or broader tunnel rule still applies. Review HTTPS Rules locally; this operation cannot remove a broader rule.")
            }
            updated.interceptDomains.append(host)
        case .remove: break
        }
        guard updated.bypassDomains.count + updated.interceptDomains.count <= 256 else {
            throw MCPStructuredError(code: .malformedRequest, message: "Remote changes support at most 256 custom HTTPS rules; review existing rules locally.")
        }
        return updated
    }

    static func inspection(_ rules: TLSInterceptionRules, host: String, globalMode: HTTPSProxyMode? = nil) -> [String: Any] {
        let mode: String
        let reason: String
        switch TLSInterceptionPolicy.decision(for: host, rules: rules) {
        case .bypass(let value): mode = "tunnel"; reason = value
        case .intercept(let value): mode = "inspect"; reason = value
        }
        return ["host": host, "revision": revision(rules), "effectiveRuleMode": mode,
                "reason": String(reason.prefix(1024)), "scope": "host_and_subdomains_all_clients",
                "appliesTo": "new_connections_only", "persistent": true,
                "globalHTTPSModeMayOverride": true,
                "globalHTTPSMode": globalMode?.rawValue ?? "unknown",
                "newConnectionMode": globalMode == .passThrough ? "tunnel" : (globalMode == .intercepting ? mode : "unknown"),
                "customTunnelRulePresent": rules.bypassDomains.contains(host),
                "customInspectRulePresent": rules.interceptDomains.contains(host),
                "transport": "opaque_tcp_when_tunneled_not_quic",
                "warning": "Tunnel hides HTTPS bodies and bypasses HTTP modifications. Existing connections are unchanged. This persistent setting is not removed by bundle Stop or expiry."]
    }

    static func invalid() -> MCPStructuredError {
        MCPStructuredError(code: .malformedRequest,
            message: "Use an ASCII DNS host without URL, port, wildcard or path. Modes: tunnel, inspect, remove. Example: https_rules_get {\"host\":\"media.example.test\"}; then https_rules_set with host, mode, expectedRevision and scope=host_and_subdomains_all_clients. Optional recoveryID is a UUID chosen before set. Inspect it with get; https_rules_restore requires host, recoveryID, expectedRevision and the same scope, with separate approval.")
    }
}
