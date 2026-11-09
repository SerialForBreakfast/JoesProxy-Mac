import Foundation

/// A client device discovered through incoming proxy connections.
public struct DiscoveredDevice: Identifiable, Equatable, Codable, Sendable {
    public let ipAddress: String
    public var customAlias: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var sessionCount: Int
    public var isLoopback: Bool

    public var id: String { ipAddress }

    public var displayName: String {
        if let customAlias = customAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !customAlias.isEmpty {
            return customAlias
        }
        if isLoopback {
            return "This Mac (127.0.0.1)"
        }
        return ipAddress
    }

    public var systemImageName: String {
        if isLoopback {
            return "desktopcomputer"
        }
        return "network"
    }

    public init(
        ipAddress: String,
        customAlias: String? = nil,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        sessionCount: Int = 1,
        isLoopback: Bool? = nil
    ) {
        self.ipAddress = ipAddress
        self.customAlias = customAlias
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.sessionCount = sessionCount
        if let isLoopback {
            self.isLoopback = isLoopback
        } else {
            self.isLoopback = Self.checkIsLoopback(ipAddress)
        }
    }

    public static func checkIsLoopback(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "127.0.0.1" || trimmed == "::1" || trimmed == "0:0:0:0:0:0:0:1" || trimmed == "localhost"
    }
}

/// Thread-safe persistence store for device IP aliases stored in local UserDefaults.
public actor DeviceAliasStore {
    public static let shared = DeviceAliasStore()

    private let userDefaultsKey = "JoesProxy.DeviceAliases"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getAlias(for ipAddress: String) -> String? {
        let aliases = defaults.dictionary(forKey: userDefaultsKey) as? [String: String] ?? [:]
        return aliases[ipAddress]
    }

    public func setAlias(_ alias: String?, for ipAddress: String) {
        var aliases = defaults.dictionary(forKey: userDefaultsKey) as? [String: String] ?? [:]
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            aliases[ipAddress] = trimmed
        } else {
            aliases.removeValue(forKey: ipAddress)
        }
        defaults.set(aliases, forKey: userDefaultsKey)
    }

    public func allAliases() -> [String: String] {
        return defaults.dictionary(forKey: userDefaultsKey) as? [String: String] ?? [:]
    }

    public func clearAll() {
        defaults.removeObject(forKey: userDefaultsKey)
    }
}
