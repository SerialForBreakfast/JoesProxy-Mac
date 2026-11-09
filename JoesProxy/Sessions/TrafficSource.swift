import Foundation

/// Best-effort classification of where a captured request originated, derived from the proxy
/// client's peer address and the request's User-Agent. Not authoritative — tunneled HTTPS has no
/// visible User-Agent, and User-Agent can be absent or spoofed.
enum TrafficSource: String, Codable, CaseIterable, Sendable {
    case mac
    case simulator
    case device
    case unknown

    var title: String {
        switch self {
        case .mac: return "Mac"
        case .simulator: return "Simulator"
        case .device: return "Device"
        case .unknown: return "Unknown"
        }
    }

    /// Compact label for row badges.
    var badgeText: String {
        switch self {
        case .mac: return "Mac"
        case .simulator: return "Sim"
        case .device: return "Device"
        case .unknown: return "?"
        }
    }

    var systemImage: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .simulator: return "iphone.gen3"
        case .device: return "iphone"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Classifies a request's source.
    /// - A non-loopback client address means a physical device on the network.
    /// - Loopback + an iOS-family User-Agent means a simulator (shares the Mac's loopback stack).
    /// - Loopback + a macOS User-Agent means a Mac-native client.
    /// - Otherwise unknown (e.g. tunneled HTTPS with no User-Agent).
    static func classify(clientAddress: String?, userAgent: String?) -> TrafficSource {
        guard let clientAddress, !clientAddress.isEmpty else {
            return .unknown
        }
        if !isLoopback(clientAddress) {
            return .device
        }
        guard let userAgent, !userAgent.isEmpty else {
            return .unknown
        }
        if userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod") {
            return .simulator
        }
        if userAgent.contains("Macintosh") || userAgent.contains("Mac OS X") {
            return .mac
        }
        return .unknown
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "0:0:0:0:0:0:0:1"
    }
}
