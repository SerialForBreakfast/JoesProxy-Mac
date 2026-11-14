import Darwin
import Foundation

/// Policy governing whether Map Remote rules may forward selected traffic to servers
/// running on the local Mac (`127.0.0.0/8`, `::1`, `localhost`).
///
/// Global permission starts OFF (`isEnabled == false`, `authorizedPorts == []`) and is only
/// honored when both global permission + explicit port authorization + per-rule
/// `allowLoopbackDestination == true` agree at proposal, activation, and request time.
struct LoopbackDestinationPolicy: Equatable, Sendable, Codable {
    var isEnabled: Bool
    var authorizedPorts: Set<Int>

    static let disabled = LoopbackDestinationPolicy(isEnabled: false, authorizedPorts: [])

    init(isEnabled: Bool = false, authorizedPorts: Set<Int> = []) {
        self.isEnabled = isEnabled
        self.authorizedPorts = authorizedPorts
    }

    static func parsePortsList(_ text: String) -> (ports: [Int], invalidTokens: [String]) {
        let tokens = text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var ports: [Int] = []
        var seen = Set<Int>()
        var invalid: [String] = []
        for token in tokens {
            guard token.allSatisfy(\.isNumber),
                  let port = Int(token),
                  (1...65_535).contains(port) else {
                invalid.append(token)
                continue
            }
            if seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return (ports.sorted(), invalid)
    }

    static func formatPortsList(_ ports: [Int]) -> String {
        Array(Set(ports)).sorted().map(String.init).joined(separator: ", ")
    }
}

/// Distinct reasons a Map Remote rule or destination is denied. Permission denials, reserved
/// JoesProxy ports, forbidden addresses, connection failures, and detected loops are kept strictly
/// separate so fail-closed denials never masquerade as loops or upstream errors.
enum MapRemoteDenialReason: String, Sendable, Equatable, Codable {
    case permissionDisabled = "loopback_permission_disabled"
    case explicitRuleIntentRequired = "loopback_rule_intent_required"
    case portNotAuthorized = "loopback_port_not_authorized"
    case reservedDestination = "reserved_joesproxy_listener"
    case addressForbidden = "forbidden_destination_address"
    case malformedDestination = "malformed_destination"
    case invalidOriginalHost = "invalid_original_host_authority"
    case resolutionFailed = "destination_resolution_failed"
    case mixedResolutionRejected = "mixed_or_ambiguous_resolution"
}

enum MapRemoteValidationError: Error, Equatable, Sendable, LocalizedError {
    case policyDenied(MapRemoteDenialReason, String)
    case malformedRequest(String)

    var errorDescription: String? {
        switch self {
        case .policyDenied(_, let message), .malformedRequest(let message):
            return message
        }
    }
}

/// Concrete validated IP literal derived once during resolution and passed directly to socket
/// connection without re-resolving hostnames.
enum ResolvedIPAddress: Equatable, Sendable {
    case ipv4(in_addr)
    case ipv6(in6_addr)

    static func == (lhs: ResolvedIPAddress, rhs: ResolvedIPAddress) -> Bool {
        switch (lhs, rhs) {
        case (.ipv4(let a), .ipv4(let b)):
            return a.s_addr == b.s_addr
        case (.ipv6(let a), .ipv6(let b)):
            var copyA = a
            var copyB = b
            return memcmp(&copyA, &copyB, MemoryLayout<in6_addr>.size) == 0
        default:
            return false
        }
    }

    var canonicalIPString: String {
        switch self {
        case .ipv4(var addr):
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        case .ipv6(var addr):
            if let mapped = unwrappedIPv4 {
                return "::ffff:\(ResolvedIPAddress.ipv4(mapped).canonicalIPString)"
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buffer)
        }
    }

    /// Unwraps IPv4-mapped IPv6 (`::ffff:a.b.c.d` and `::ffff:7f00:1`) before classification so
    /// IPv4 and IPv4-mapped IPv6 share one single address policy without contradictions.
    var unwrappedIPv4: in_addr? {
        switch self {
        case .ipv4(let addr):
            return addr
        case .ipv6(var addr):
            return withUnsafeBytes(of: &addr) { bytes in
                guard bytes.count == 16 else { return nil }
                let prefixZero = (0..<10).allSatisfy { bytes[$0] == 0 }
                let mappedFF = bytes[10] == 0xff && bytes[11] == 0xff
                guard prefixZero && mappedFF else { return nil }
                var v4 = in_addr()
                withUnsafeMutableBytes(of: &v4.s_addr) { out in
                    out[0] = bytes[12]
                    out[1] = bytes[13]
                    out[2] = bytes[14]
                    out[3] = bytes[15]
                }
                return v4
            }
        }
    }
}

enum AddressClassification: Equatable, Sendable {
    case loopback
    case unspecifiedOrLinkLocal
    case external
}

/// Validated outbound connection target produced by single-shot resolution + policy checks.
struct ValidatedUpstreamEndpoint: Equatable, Sendable {
    let destinationHost: String
    let port: Int
    let scheme: SessionScheme
    let candidateAddresses: [ResolvedIPAddress]
    let httpHostHeaderValue: String
    let tlsServerName: String?
    let isLoopback: Bool
}

/// Tracks every listener socket owned by JoesProxy itself (`ProxyServer`, `MCPNIOHTTPTransport`,
/// `PACHostingServer`, `HLSFixtureServer`, `SDKEventServer`) from bind preflight until close.
final class ReservedListenerRegistry: @unchecked Sendable {
    static let shared = ReservedListenerRegistry()

    struct ReservationToken: Hashable, Sendable {
        let id: UUID
        let owner: String
        let port: UInt16
    }

    private struct Entry {
        let token: ReservationToken
        let boundAddresses: [ResolvedIPAddress]?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    init() {}

    @discardableResult
    func reserve(owner: String, port: UInt16, boundHost: String? = nil) -> ReservationToken {
        let token = ReservationToken(id: UUID(), owner: owner, port: port)
        let parsedAddresses: [ResolvedIPAddress]?
        if let boundHost, !boundHost.isEmpty {
            if let literal = LoopbackAddressInspector.parseLiteralIP(boundHost) {
                parsedAddresses = [literal]
            } else {
                parsedAddresses = nil
            }
        } else {
            parsedAddresses = nil
        }
        lock.withLock {
            entries[token.id] = Entry(token: token, boundAddresses: parsedAddresses)
        }
        return token
    }

    func release(_ token: ReservationToken?) {
        guard let token else { return }
        lock.withLock {
            _ = entries.removeValue(forKey: token.id)
        }
    }

    func conflictsWithPort(_ port: Int) -> String? {
        guard (1...65_535).contains(port) else { return nil }
        let targetPort = UInt16(port)
        return lock.withLock {
            entries.values.first(where: { $0.token.port == targetPort })?.token.owner
        }
    }

    func conflicts(address: ResolvedIPAddress, port: Int) -> String? {
        guard (1...65_535).contains(port) else { return nil }
        let targetPort = UInt16(port)
        let matchingEntries = lock.withLock {
            Array(entries.values.filter { $0.token.port == targetPort })
        }
        guard !matchingEntries.isEmpty else { return nil }

        let targetClassification = LoopbackAddressInspector.classify(address)
        let targetCanonical = unwrappedComparableKey(for: address)
        let localInterfaceKeys = Set(Self.localInterfaceAddresses().map(unwrappedComparableKey(for:)))

        for entry in matchingEntries {
            guard let boundAddresses = entry.boundAddresses else {
                // Listener bound on wildcard / all interfaces: any loopback or own-interface IP on that port conflicts.
                if targetClassification == .loopback || targetClassification == .unspecifiedOrLinkLocal ||
                    localInterfaceKeys.contains(targetCanonical) {
                    return entry.token.owner
                }
                continue
            }
            for bound in boundAddresses {
                if unwrappedComparableKey(for: bound) == targetCanonical {
                    return entry.token.owner
                }
                // Wildcard `0.0.0.0` or `::` matches any local or loopback address.
                if LoopbackAddressInspector.isUnspecified(bound),
                   (targetClassification == .loopback || localInterfaceKeys.contains(targetCanonical)) {
                    return entry.token.owner
                }
            }
        }
        return nil
    }

    private func unwrappedComparableKey(for addr: ResolvedIPAddress) -> String {
        if let v4 = addr.unwrappedIPv4 {
            return ResolvedIPAddress.ipv4(v4).canonicalIPString
        }
        return addr.canonicalIPString.lowercased()
    }

    /// Enumerates all IPv4/IPv6 addresses assigned to local interfaces on this Mac so attempts to
    /// reach JoesProxy via its LAN IP (not just `127.0.0.1`) are detected and rejected.
    static func localInterfaceAddresses() -> [ResolvedIPAddress] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var result: [ResolvedIPAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddr = current.pointee.ifa_addr else { continue }
            let family = Int32(sockaddr.pointee.sa_family)
            if family == AF_INET {
                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    result.append(.ipv4(sin.pointee.sin_addr))
                }
            } else if family == AF_INET6 {
                sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    result.append(.ipv6(sin6.pointee.sin6_addr))
                }
            }
        }
        return result
    }
}

/// Tracks active in-flight Map Remote connections so revoking global permission or removing an
/// authorized port immediately closes affected streams.
final class ActiveMapRemoteSessionRegistry: @unchecked Sendable {
    static let shared = ActiveMapRemoteSessionRegistry()

    private struct Registration {
        let port: Int
        let isLoopback: Bool
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]

    init() {}

    @discardableResult
    func register(port: Int, isLoopback: Bool, cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            registrations[id] = Registration(port: port, isLoopback: isLoopback, cancel: cancel)
        }
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        lock.withLock {
            _ = registrations.removeValue(forKey: id)
        }
    }

    func cancelLoopbackSessions(forPorts removedPorts: Set<Int>? = nil) {
        let toCancel: [@Sendable () -> Void] = lock.withLock {
            registrations.values.compactMap { entry in
                guard entry.isLoopback else { return nil }
                if let removedPorts, !removedPorts.contains(entry.port) { return nil }
                return entry.cancel
            }
        }
        for cancel in toCancel { cancel() }
    }
}

/// Unified address & host validator plus single-shot resolver for Map Remote and proxy forwarding.
enum LoopbackAddressInspector {
    typealias Resolver = @Sendable (_ host: String, _ port: Int) throws -> [ResolvedIPAddress]

    static let systemResolver: Resolver = { host, _ in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0, let head = list else {
            throw MapRemoteValidationError.policyDenied(
                .resolutionFailed,
                "Could not resolve destination host '\(host)'."
            )
        }
        defer { freeaddrinfo(head) }

        var results: [ResolvedIPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let sa = info.pointee.ai_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    let addr = ResolvedIPAddress.ipv4(sin.pointee.sin_addr)
                    if !results.contains(addr) { results.append(addr) }
                }
            } else if family == AF_INET6 {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    let addr = ResolvedIPAddress.ipv6(sin6.pointee.sin6_addr)
                    if !results.contains(addr) { results.append(addr) }
                }
            }
        }
        guard !results.isEmpty else {
            throw MapRemoteValidationError.policyDenied(
                .resolutionFailed,
                "Destination host '\(host)' returned no usable socket addresses."
            )
        }
        return results
    }

    static func canonicalHostAuthority(host: String, port: Int, scheme: SessionScheme) -> String {
        let stripped = stripBracketsAndTrailingDot(host).host
        let isIPv6 = isIPv6Literal(stripped)
        let formattedHost = isIPv6 ? "[\(stripped)]" : stripped
        let defaultPort = (scheme == .https) ? 443 : 80
        return port == defaultPort ? formattedHost : "\(formattedHost):\(port)"
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        var addr6 = in6_addr()
        return inet_pton(AF_INET6, host, &addr6) == 1
    }

    static func stripBracketsAndTrailingDot(_ rawHost: String) -> (host: String, hadTrailingDot: Bool, malformed: Bool) {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              !trimmed.contains("%"), !trimmed.contains("@"), !trimmed.contains("/"), !trimmed.contains("?") else {
            return ("", false, true)
        }
        var work = trimmed
        if work.hasPrefix("[") || work.hasSuffix("]") {
            guard work.hasPrefix("[") && work.hasSuffix("]"), work.count > 2 else {
                return ("", false, true)
            }
            work = String(work.dropFirst().dropLast())
            // Inside brackets must be a valid IPv6 literal.
            guard isIPv6Literal(work) else {
                return ("", false, true)
            }
            return (work.lowercased(), false, false)
        }
        // Unbracketed colons are only allowed for raw IPv6 literals, not host:port.
        if work.contains(":") {
            guard isIPv6Literal(work) else {
                return ("", false, true)
            }
            return (work.lowercased(), false, false)
        }
        let hadTrailingDot = work.hasSuffix(".")
        if hadTrailingDot {
            work = String(work.dropLast())
            guard !work.isEmpty, !work.hasSuffix(".") else {
                return ("", true, true)
            }
        }
        return (work.lowercased(), hadTrailingDot, false)
    }

    /// Parses strict IPv4 (dotted-quad without octal/hex/leading-zero/integer ambiguity) or IPv6
    /// literals. Non-canonical numeric IPv4 tricks (`0177.0.0.1`, `2130706433`, `127.1`, trailing
    /// dots on numeric literals) are explicitly rejected by `normalizeHost`.
    static func parseLiteralIP(_ rawHost: String) -> ResolvedIPAddress? {
        let parsed = stripBracketsAndTrailingDot(rawHost)
        guard !parsed.malformed, !parsed.hadTrailingDot else { return nil }
        let host = parsed.host
        if host.contains(":") {
            var addr6 = in6_addr()
            if inet_pton(AF_INET6, host, &addr6) == 1 {
                return .ipv6(addr6)
            }
            return nil
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return false }
                  // Reject leading zeros (octal ambiguity such as 0177.0.0.1).
                  if part.count > 1 && part.hasPrefix("0") { return false }
                  return UInt8(part) != nil
              }) else {
            return nil
        }
        var addr4 = in_addr()
        guard inet_pton(AF_INET, host, &addr4) == 1 else { return nil }
        return .ipv4(addr4)
    }

    static func looksLikeObfuscatedNumericHost(_ host: String) -> Bool {
        let clean = stripBracketsAndTrailingDot(host)
        if clean.malformed { return true }
        let candidate = clean.host
        if parseLiteralIP(host) != nil { return false }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return true }
        // Single numeric integer host (`2130706433`), hex integer (`0x7f000001`),
        // short dotted form (`127.1`), or leading-zero octet (`0177.0.0.1`).
        if labels.allSatisfy({ label in
            let s = String(label).lowercased()
            if s.allSatisfy(\.isNumber) { return true }
            if s.hasPrefix("0x") && s.dropFirst(2).allSatisfy({ $0.isHexDigit }) { return true }
            return false
        }) {
            return true
        }
        // Numeric literal with trailing dot (`127.0.0.1.`).
        if clean.hadTrailingDot, labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return true
        }
        return false
    }

    static func isLocalhostName(_ normalizedHost: String) -> Bool {
        normalizedHost == "localhost" || normalizedHost.hasSuffix(".localhost")
    }

    static func isUnspecified(_ address: ResolvedIPAddress) -> Bool {
        if let v4 = address.unwrappedIPv4 {
            let hostOrder = UInt32(bigEndian: v4.s_addr)
            return (hostOrder & 0xff00_0000) == 0x0000_0000 // 0.0.0.0/8
        }
        guard case .ipv6(var v6) = address else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            bytes.count == 16 && bytes.allSatisfy { $0 == 0 }
        }
    }

    static func classify(_ address: ResolvedIPAddress) -> AddressClassification {
        if let v4 = address.unwrappedIPv4 {
            let hostOrder = UInt32(bigEndian: v4.s_addr)
            let firstOctet = (hostOrder >> 24) & 0xff
            let secondOctet = (hostOrder >> 16) & 0xff
            if firstOctet == 0 { return .unspecifiedOrLinkLocal }          // 0.0.0.0/8
            if firstOctet == 169 && secondOctet == 254 { return .unspecifiedOrLinkLocal } // 169.254.0.0/16
            if firstOctet >= 224 { return .unspecifiedOrLinkLocal }        // multicast & experimental
            if firstOctet == 127 { return .loopback }                      // 127.0.0.0/8
            return .external
        }
        guard case .ipv6(var v6) = address else { return .external }
        return withUnsafeBytes(of: &v6) { bytes in
            guard bytes.count == 16 else { return .unspecifiedOrLinkLocal }
            if bytes.allSatisfy({ $0 == 0 }) { return .unspecifiedOrLinkLocal } // ::
            let isLoopbackV6 = (0..<15).allSatisfy { bytes[$0] == 0 } && bytes[15] == 1
            if isLoopbackV6 { return .loopback }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .unspecifiedOrLinkLocal } // fe80::/10 link-local
            if bytes[0] == 0xff { return .unspecifiedOrLinkLocal } // ff00::/8 multicast
            return .external
        }
    }

    /// Static validation without performing DNS lookup (used at UI/propose/scenario validation time).
    /// Also verifies `port` against reserved listener ports and authorized loopback ports if `host`
    /// is statically identifiable as loopback.
    static func validateStaticDestination(
        host rawHost: String,
        port resolvedPort: Int,
        scheme: SessionScheme,
        allowLoopbackDestination: Bool,
        policy: LoopbackDestinationPolicy,
        reservedRegistry: ReservedListenerRegistry = .shared
    ) throws -> (normalizedHost: String, isStaticLoopback: Bool) {
        let stripped = stripBracketsAndTrailingDot(rawHost)
        guard !stripped.malformed else {
            throw MapRemoteValidationError.malformedRequest("Destination host '\(rawHost)' is malformed or contains unsupported characters.")
        }
        guard !looksLikeObfuscatedNumericHost(rawHost) else {
            throw MapRemoteValidationError.policyDenied(
                .malformedDestination,
                "Destination host '\(rawHost)' uses an ambiguous or obfuscated numeric host format."
            )
        }
        guard (1...65_535).contains(resolvedPort) else {
            throw MapRemoteValidationError.malformedRequest("remotePort must be between 1 and 65535.")
        }
        let normalizedHost = stripped.host

        if let literal = parseLiteralIP(rawHost) {
            let classification = classify(literal)
            if classification == .unspecifiedOrLinkLocal {
                throw MapRemoteValidationError.policyDenied(
                    .addressForbidden,
                    "Map Remote destination '\(normalizedHost)' targets a forbidden unspecified, link-local, or multicast address."
                )
            }
            if let conflictOwner = reservedRegistry.conflicts(address: literal, port: resolvedPort) {
                throw MapRemoteValidationError.policyDenied(
                    .reservedDestination,
                    "Destination \(normalizedHost):\(resolvedPort) conflicts with JoesProxy listener '\(conflictOwner)'."
                )
            }
            if classification == .loopback {
                try enforceLoopbackPermission(
                    host: normalizedHost,
                    port: resolvedPort,
                    allowLoopbackDestination: allowLoopbackDestination,
                    policy: policy,
                    reservedRegistry: reservedRegistry
                )
                return (normalizedHost, true)
            }
            return (normalizedHost, false)
        }

        if isLocalhostName(normalizedHost) {
            try enforceLoopbackPermission(
                host: normalizedHost,
                port: resolvedPort,
                allowLoopbackDestination: allowLoopbackDestination,
                policy: policy,
                reservedRegistry: reservedRegistry
            )
            return (normalizedHost, true)
        }

        // Non-loopback hostname: reject direct conflict against a wildcard/reserved port before even DNS-resolving.
        _ = scheme
        return (normalizedHost, false)
    }

    static func enforceLoopbackPermission(
        host: String,
        port: Int,
        allowLoopbackDestination: Bool,
        policy: LoopbackDestinationPolicy,
        reservedRegistry: ReservedListenerRegistry = .shared
    ) throws {
        guard policy.isEnabled else {
            throw MapRemoteValidationError.policyDenied(
                .permissionDisabled,
                "Local-server Map Remote is disabled. Enable it in Settings > Proxy > Local-Server Routing."
            )
        }
        guard allowLoopbackDestination else {
            throw MapRemoteValidationError.policyDenied(
                .explicitRuleIntentRequired,
                "Rule targets loopback destination '\(host)' without explicit allowLoopbackDestination=true intent."
            )
        }
        if let owner = reservedRegistry.conflictsWithPort(port) {
            throw MapRemoteValidationError.policyDenied(
                .reservedDestination,
                "Port \(port) is reserved by JoesProxy ('\(owner)') and cannot be targeted."
            )
        }
        guard policy.authorizedPorts.contains(port) else {
            throw MapRemoteValidationError.policyDenied(
                .portNotAuthorized,
                "Loopback port \(port) is not in the authorized local destination ports list."
            )
        }
    }

    /// Validates incoming original `Host` authority when `preserveHostHeader == true`, rejecting
    /// duplicate `Host` headers, malformed authorities, or authorities that disagree with the
    /// matched request's host/port, and returns the canonical authority derived from the request.
    static func validateOriginalHostAuthority(
        headers: [HTTPHeaderField],
        fallbackHost: String,
        fallbackPort: Int,
        scheme: SessionScheme
    ) throws -> String {
        let hostHeaders = headers.filter { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        guard hostHeaders.count <= 1 else {
            throw MapRemoteValidationError.policyDenied(
                .invalidOriginalHost,
                "Incoming request contains duplicate Host headers and cannot preserve original Host authority."
            )
        }

        let canonicalExpected = canonicalHostAuthority(host: fallbackHost, port: fallbackPort, scheme: scheme)
        let strippedFallback = stripBracketsAndTrailingDot(fallbackHost)
        guard !strippedFallback.malformed, (1...65_535).contains(fallbackPort) else {
            throw MapRemoteValidationError.policyDenied(
                .invalidOriginalHost,
                "Matched request host '\(fallbackHost):\(fallbackPort)' cannot form a canonical Host authority."
            )
        }

        if let rawAuthority = hostHeaders.first?.value.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard let parsed = parseHostAuthority(rawAuthority) else {
                throw MapRemoteValidationError.policyDenied(
                    .invalidOriginalHost,
                    "Incoming Host header '\(rawAuthority)' is malformed."
                )
            }

            let hostsAgree: Bool
            if let fallbackIP = parseLiteralIP(strippedFallback.host),
               let headerIP = parseLiteralIP(parsed.host) {
                hostsAgree = (fallbackIP == headerIP)
            } else {
                hostsAgree = (parsed.host == strippedFallback.host)
            }

            let defaultPort = (scheme == .https) ? 443 : 80
            let effectiveHeaderPort = parsed.port ?? defaultPort
            guard hostsAgree && effectiveHeaderPort == fallbackPort else {
                throw MapRemoteValidationError.policyDenied(
                    .invalidOriginalHost,
                    "Incoming Host header '\(rawAuthority)' does not match request authority '\(canonicalExpected)'."
                )
            }
        }

        return canonicalExpected
    }

    private static func parseHostAuthority(_ rawAuthority: String) -> (host: String, port: Int?)? {
        guard !rawAuthority.isEmpty,
              rawAuthority.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              !rawAuthority.contains("%"), !rawAuthority.contains("@"),
              !rawAuthority.contains("/"), !rawAuthority.contains("?") else {
            return nil
        }

        if rawAuthority.hasPrefix("[") {
            guard let closingIndex = rawAuthority.firstIndex(of: "]") else {
                return nil
            }
            let literalInside = String(rawAuthority[rawAuthority.index(after: rawAuthority.startIndex)..<closingIndex])
            guard isIPv6Literal(literalInside) else {
                return nil
            }
            let remainder = rawAuthority[rawAuthority.index(after: closingIndex)...]
            if remainder.isEmpty {
                return (literalInside.lowercased(), nil)
            }
            guard remainder.hasPrefix(":"),
                  let port = parseStrictPort(String(remainder.dropFirst())) else {
                return nil
            }
            return (literalInside.lowercased(), port)
        }

        if let colonIndex = rawAuthority.firstIndex(of: ":") {
            let hostPart = String(rawAuthority[..<colonIndex])
            let portPart = String(rawAuthority[rawAuthority.index(after: colonIndex)...])
            // Reject multiple colons (e.g. unbracketed IPv6) or non-numeric port suffixes.
            guard !portPart.contains(":"),
                  let port = parseStrictPort(portPart) else {
                return nil
            }
            let normalized = stripBracketsAndTrailingDot(hostPart)
            guard !normalized.malformed, !normalized.host.isEmpty else {
                return nil
            }
            return (normalized.host, port)
        }

        let normalized = stripBracketsAndTrailingDot(rawAuthority)
        guard !normalized.malformed, !normalized.host.isEmpty else {
            return nil
        }
        return (normalized.host, nil)
    }

    private static func parseStrictPort(_ text: String) -> Int? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let port = Int(text),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    /// Single-shot resolution & candidate-socket validation executed right before TCP/TLS connect.
    /// Every candidate `sockaddr` returned by DNS must pass policy (mixed allowed/forbidden fails closed).
    static func resolveAndValidate(
        destinationHost rawHost: String,
        port: Int,
        scheme: SessionScheme,
        incomingHeaders: [HTTPHeaderField] = [],
        originalRequestHost: String? = nil,
        originalRequestPort: Int? = nil,
        originalRequestScheme: SessionScheme? = nil,
        isMapRemote: Bool,
        allowLoopbackDestination: Bool,
        preserveHostHeader: Bool,
        policy: LoopbackDestinationPolicy,
        reservedRegistry: ReservedListenerRegistry = .shared,
        resolver: Resolver = systemResolver
    ) throws -> ValidatedUpstreamEndpoint {
        let stripped = stripBracketsAndTrailingDot(rawHost)
        guard !stripped.malformed else {
            throw MapRemoteValidationError.policyDenied(
                .malformedDestination,
                "Destination host '\(rawHost)' is malformed."
            )
        }
        guard !looksLikeObfuscatedNumericHost(rawHost) else {
            throw MapRemoteValidationError.policyDenied(
                .malformedDestination,
                "Destination host '\(rawHost)' uses a disallowed numeric format."
            )
        }
        guard (1...65_535).contains(port) else {
            throw MapRemoteValidationError.policyDenied(.malformedDestination, "Invalid port \(port).")
        }

        let normalizedHost = stripped.host
        let candidates: [ResolvedIPAddress]
        let isLiteral: Bool
        if let literal = parseLiteralIP(rawHost) {
            candidates = [literal]
            isLiteral = true
        } else {
            candidates = try resolver(normalizedHost, port)
            isLiteral = false
        }
        guard !candidates.isEmpty else {
            throw MapRemoteValidationError.policyDenied(
                .resolutionFailed,
                "No candidate socket addresses resolved for '\(normalizedHost)'."
            )
        }

        var sawLoopback = false
        var sawExternal = false
        for addr in candidates {
            let classification = classify(addr)
            if classification == .unspecifiedOrLinkLocal {
                throw MapRemoteValidationError.policyDenied(
                    .addressForbidden,
                    "Resolved address \(addr.canonicalIPString) for '\(normalizedHost)' is forbidden."
                )
            }
            if let conflictOwner = reservedRegistry.conflicts(address: addr, port: port) {
                throw MapRemoteValidationError.policyDenied(
                    .reservedDestination,
                    "Resolved endpoint \(addr.canonicalIPString):\(port) conflicts with JoesProxy listener '\(conflictOwner)'."
                )
            }
            switch classification {
            case .loopback:
                sawLoopback = true
                guard isMapRemote else {
                    throw MapRemoteValidationError.policyDenied(
                        .permissionDisabled,
                        "Direct proxy request resolved to loopback without an explicit Map Remote rule."
                    )
                }
                try enforceLoopbackPermission(
                    host: normalizedHost,
                    port: port,
                    allowLoopbackDestination: allowLoopbackDestination,
                    policy: policy,
                    reservedRegistry: reservedRegistry
                )
            case .external:
                sawExternal = true
            case .unspecifiedOrLinkLocal:
                break
            }
        }

        if sawLoopback && sawExternal {
            throw MapRemoteValidationError.policyDenied(
                .mixedResolutionRejected,
                "Destination '\(normalizedHost)' resolved to mixed loopback and non-loopback addresses."
            )
        }

        let hostAuthority: String
        if preserveHostHeader {
            hostAuthority = try validateOriginalHostAuthority(
                headers: incomingHeaders,
                fallbackHost: originalRequestHost ?? normalizedHost,
                fallbackPort: originalRequestPort ?? port,
                scheme: originalRequestScheme ?? scheme
            )
        } else {
            hostAuthority = canonicalHostAuthority(host: normalizedHost, port: port, scheme: scheme)
        }

        // Preserve TLS SNI identity independently of HTTP `Host`: only use destination hostname
        // when it is a DNS name (TLS RFC 6066 forbids IP literals in SNI).
        let tlsServerName: String? = (scheme == .https && !isLiteral) ? normalizedHost : nil

        return ValidatedUpstreamEndpoint(
            destinationHost: normalizedHost,
            port: port,
            scheme: scheme,
            candidateAddresses: candidates,
            httpHostHeaderValue: hostAuthority,
            tlsServerName: tlsServerName,
            isLoopback: sawLoopback
        )
    }
}
