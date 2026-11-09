import Foundation

/// A pure value type that encapsulates no-caching policy rules and applies them
/// to HTTP request and response headers in-flight.
///
/// No-caching is only applied to intercepted (decrypted) sessions. Pass-through
/// CONNECT tunnels are opaque byte streams and are never affected.
struct NoCachingPolicy: Sendable {

    // MARK: - State

    let isGloballyEnabled: Bool
    let perDomainList: [String]

    // MARK: - Policy Decision

    /// Returns `true` if no-caching should be applied to traffic directed at `host`.
    ///
    /// Applies when:
    /// - `isGloballyEnabled` is `true`, OR
    /// - `host` matches an entry in `perDomainList`
    ///
    /// Domain matching follows the `.domain`-prefix subdomain convention:
    /// - `.example.com` matches `api.example.com`, `www.example.com`, and `example.com`
    /// - `example.com` matches `example.com` and any subdomain of `example.com`
    /// - All comparisons are case-insensitive
    func applies(to host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if isGloballyEnabled { return true }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return perDomainList.contains(where: { matches(host: normalizedHost, pattern: normalizePattern($0)) })
    }

    // MARK: - Header Mutation

    /// Mutates outgoing request headers to prevent conditional/cached responses.
    ///
    /// - Adds/overrides `Cache-Control: no-cache`
    /// - Adds `Pragma: no-cache`
    /// - Removes `If-None-Match` (prevents 304 conditional responses)
    /// - Removes `If-Modified-Since` (prevents 304 conditional responses)
    static func applyToRequestHeaders(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        let blockedNames: Set<String> = ["if-none-match", "if-modified-since"]
        let overriddenNames: Set<String> = ["cache-control", "pragma"]

        var result = headers.filter { field in
            let lower = field.name.lowercased()
            return !blockedNames.contains(lower) && !overriddenNames.contains(lower)
        }
        result.append(HTTPHeaderField(name: "Cache-Control", value: "no-cache"))
        result.append(HTTPHeaderField(name: "Pragma", value: "no-cache"))
        return result
    }

    /// Mutates incoming response headers to prevent client-side caching.
    ///
    /// - Overrides `Cache-Control` → `no-store, no-cache, must-revalidate`
    /// - Adds/overrides `Pragma: no-cache`
    /// - Overrides `Expires: 0`
    /// - Removes `ETag` (prevents future conditional requests)
    /// - Removes `Last-Modified` (prevents future conditional requests)
    static func applyToResponseHeaders(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        let blockedNames: Set<String> = ["etag", "last-modified"]
        let overriddenNames: Set<String> = ["cache-control", "pragma", "expires"]

        var result = headers.filter { field in
            let lower = field.name.lowercased()
            return !blockedNames.contains(lower) && !overriddenNames.contains(lower)
        }
        result.append(HTTPHeaderField(name: "Cache-Control", value: "no-store, no-cache, must-revalidate"))
        result.append(HTTPHeaderField(name: "Pragma", value: "no-cache"))
        result.append(HTTPHeaderField(name: "Expires", value: "0"))
        return result
    }

    // MARK: - Private Helpers

    private func normalizePattern(_ pattern: String) -> String {
        let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Treat `*.example.com` the same as `.example.com` (wildcard prefix → dot prefix)
        if normalized.hasPrefix("*.") {
            return String(normalized.dropFirst(1))
        }
        return normalized
    }

    private func matches(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix(".") {
            // `.example.com` matches `example.com` and any subdomain
            return host == String(pattern.dropFirst()) || host.hasSuffix(pattern)
        }
        // `example.com` matches `example.com` and `*.example.com`
        return host == pattern || host.hasSuffix(".\(pattern)")
    }
}
