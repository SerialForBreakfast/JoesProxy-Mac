import Foundation

enum HTTPSProxyMode: String, Equatable, Sendable {
    case passThrough = "Pass-through"
    case intercepting = "Intercepting"
}

struct TLSInterceptionRules: Codable, Equatable, Sendable {
    var bypassDomains: [String]
    var interceptDomains: [String]

    init(
        bypassDomains: [String] = [],
        interceptDomains: [String] = []
    ) {
        self.bypassDomains = bypassDomains
        self.interceptDomains = interceptDomains
    }

    var isEmpty: Bool {
        bypassDomains.isEmpty && interceptDomains.isEmpty
    }
}

enum TLSInterceptionDecision: Equatable, Sendable {
    case intercept(reason: String)
    case bypass(reason: String)
}

enum TLSInterceptionPolicy {
    static let builtInBypassDomains = [
        ".apple.com",
        ".icloud.com",
        ".itunes.apple.com",
        ".ess.apple.com",
        ".ls.apple.com",
        ".mzstatic.com"
    ]

    static func decision(
        for host: String,
        rules: TLSInterceptionRules
    ) -> TLSInterceptionDecision {
        let normalizedHost = normalize(host)
        guard !normalizedHost.isEmpty else {
            return .intercept(reason: "Default HTTPS inspection")
        }

        if let builtInMatch = firstMatchingPattern(in: builtInBypassDomains, host: normalizedHost) {
            return .bypass(reason: "Built-in compatibility bypass: \(builtInMatch)")
        }

        let normalizedBypassDomains = normalizedPatterns(from: rules.bypassDomains)
        if let matchedBypass = firstMatchingPattern(in: normalizedBypassDomains, host: normalizedHost) {
            return .bypass(reason: "Matched bypass rule: \(matchedBypass)")
        }

        let normalizedInterceptDomains = normalizedPatterns(from: rules.interceptDomains)
        if let matchedIntercept = firstMatchingPattern(in: normalizedInterceptDomains, host: normalizedHost) {
            return .intercept(reason: "Matched intercept rule: \(matchedIntercept)")
        }

        return .intercept(reason: "Default HTTPS inspection")
    }

    private static func normalize(_ host: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost.hasPrefix("*.") {
            return String(normalizedHost.dropFirst(1))
        }
        return normalizedHost
    }

    private static func normalizedPatterns(from domains: [String]) -> [String] {
        domains
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    private static func firstMatchingPattern(in patterns: [String], host: String) -> String? {
        patterns.first(where: { matches(host: host, pattern: $0) })
    }

    private static func matches(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix(".") {
            return host == String(pattern.dropFirst()) || host.hasSuffix(pattern)
        }

        return host == pattern || host.hasSuffix(".\(pattern)")
    }
}
