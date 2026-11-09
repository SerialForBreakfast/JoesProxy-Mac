//
//  LocalNetworkInfo.swift
//  JoesProxy
//
//  Provides the Mac's LAN IP and Bonjour hostname for device setup instructions.
//  Used by iOS and tvOS setup walkthrough views.
//

import Foundation
import SystemConfiguration
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host information for the Mac running JoesProxy, used when configuring remote devices.
struct LocalNetworkInfo: Equatable, Sendable {
    /// Primary IPv4 LAN address (e.g., "192.168.1.5"), or nil if unavailable.
    let lanIP: String?
    /// Bonjour hostname (e.g., "MacBook-Pro.local"), or nil if unavailable.
    let bonjourName: String?

    /// Resolves the Mac's primary LAN IP and Bonjour hostname.
    /// - Returns: A struct with `lanIP` and `bonjourName`; either may be nil.
    static func current() -> LocalNetworkInfo {
        let ip = primaryLANIPv4()
        let bonjour = bonjourHostname()
        return LocalNetworkInfo(lanIP: ip, bonjourName: bonjour)
    }

    /// Primary IPv4 address on a non-loopback, up interface (e.g., en0).
    private static func primaryLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [LocalNetworkIPv4Candidate] = []
        var ptr = first
        while true {
            guard let addr = ptr.pointee.ifa_addr else {
                guard let next = ptr.pointee.ifa_next else { break }
                ptr = next
                continue
            }
            let flags = ptr.pointee.ifa_flags
            let name = String(cString: ptr.pointee.ifa_name)

            if (flags & UInt32(IFF_UP)) != 0,
               (flags & UInt32(IFF_LOOPBACK)) == 0,
               addr.pointee.sa_family == UInt8(AF_INET),
               name.hasPrefix("en") || name.hasPrefix("bridge") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(addr, addrLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    candidates.append(
                        LocalNetworkIPv4Candidate(
                            interfaceName: name,
                            address: String(cString: hostname),
                            isRunning: (flags & UInt32(IFF_RUNNING)) != 0
                        )
                    )
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return preferredIPv4Address(
            from: candidates,
            primaryInterfaceName: primaryIPv4InterfaceName()
        )
    }

    static func preferredIPv4Address(
        from candidates: [LocalNetworkIPv4Candidate],
        primaryInterfaceName: String? = nil
    ) -> String? {
        candidates
            .filter { !$0.address.isEmpty }
            .sorted { lhs, rhs in
                lhs.preferenceScore(primaryInterfaceName: primaryInterfaceName) <
                    rhs.preferenceScore(primaryInterfaceName: primaryInterfaceName)
            }
            .first?
            .address
    }

    /// Bonjour-style hostname (hostname.local).
    private static func bonjourHostname() -> String? {
        let host = Host.current()
        let name = host.localizedName ?? host.name ?? ""
        guard !name.isEmpty else { return nil }
        if name.hasSuffix(".local") {
            return name
        }
        return "\(name).local"
    }

    private static func primaryIPv4InterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "JoesProxy.LocalNetworkInfo" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dictionary = value as? [String: Any] else {
            return nil
        }

        return dictionary["PrimaryInterface"] as? String
    }
}

struct LocalNetworkIPv4Candidate: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let isRunning: Bool

    func preferenceScore(primaryInterfaceName: String?) -> Int {
        var score = 0

        if !isRunning {
            score += 1_000
        }

        if let primaryInterfaceName, interfaceName == primaryInterfaceName {
            score -= 500
        }

        if isLinkLocalIPv4 {
            score += 10_000
        } else if isPrivateLANIPv4 {
            score += 0
        } else {
            score += 2_000
        }

        if interfaceName == "en0" {
            score += 0
        } else if interfaceName.hasPrefix("en") {
            score += 100
        } else if interfaceName.hasPrefix("bridge") {
            score += 500
        } else {
            score += 800
        }

        return score
    }

    private var isLinkLocalIPv4: Bool {
        address.hasPrefix("169.254.")
    }

    private var isPrivateLANIPv4: Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        if octets[0] == 10 {
            return true
        }
        if octets[0] == 172, (16...31).contains(octets[1]) {
            return true
        }
        if octets[0] == 192, octets[1] == 168 {
            return true
        }
        return false
    }
}

protocol LocalNetworkInfoProviding: Sendable {
    func current() -> LocalNetworkInfo
}

struct SystemLocalNetworkInfoProvider: LocalNetworkInfoProviding {
    func current() -> LocalNetworkInfo {
        LocalNetworkInfo.current()
    }
}

struct SyntheticLocalNetworkInfoProvider: LocalNetworkInfoProviding {
    var lanIP: String? = "192.0.2.10"
    var bonjourName: String? = "macbook.local"

    func current() -> LocalNetworkInfo {
        LocalNetworkInfo(lanIP: lanIP, bonjourName: bonjourName)
    }
}
