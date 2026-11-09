import Foundation

/// In-memory registry tracking client devices connecting through JoesProxy.
public actor DeviceRegistry {
    public static let shared = DeviceRegistry()

    private var devicesByIP: [String: DiscoveredDevice] = [:]
    private let aliasStore: DeviceAliasStore

    public init(aliasStore: DeviceAliasStore = .shared) {
        self.aliasStore = aliasStore
    }

    /// Records an observed incoming client IP connection from a captured request.
    public func recordClientConnection(ipAddress: String, timestamp: Date = Date()) async -> DiscoveredDevice? {
        let trimmedIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else {
            return nil
        }

        let existingAlias = await aliasStore.getAlias(for: trimmedIP)

        if var existing = devicesByIP[trimmedIP] {
            existing.sessionCount += 1
            existing.lastSeen = timestamp
            if existing.customAlias != existingAlias {
                existing.customAlias = existingAlias
            }
            devicesByIP[trimmedIP] = existing
            return existing
        } else {
            let newDevice = DiscoveredDevice(
                ipAddress: trimmedIP,
                customAlias: existingAlias,
                firstSeen: timestamp,
                lastSeen: timestamp,
                sessionCount: 1
            )
            devicesByIP[trimmedIP] = newDevice
            return newDevice
        }
    }

    /// Returns all discovered devices, sorted with loopback first, then by most recently seen.
    public func discoveredDevices() async -> [DiscoveredDevice] {
        let currentAliases = await aliasStore.allAliases()
        var list: [DiscoveredDevice] = []

        for (ip, var device) in devicesByIP {
            device.customAlias = currentAliases[ip]
            list.append(device)
        }

        return list.sorted { lhs, rhs in
            if lhs.isLoopback != rhs.isLoopback {
                return lhs.isLoopback && !rhs.isLoopback
            }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    /// Sets or removes a custom friendly alias for a device IP address.
    public func setDeviceAlias(ipAddress: String, alias: String?) async -> DiscoveredDevice? {
        let trimmedIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty, var device = devicesByIP[trimmedIP] else { return nil }
        await aliasStore.setAlias(alias, for: trimmedIP)
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        device.customAlias = trimmedAlias?.isEmpty == false ? trimmedAlias : nil
        devicesByIP[trimmedIP] = device
        return device
    }

    /// Retrieves details for a specific device IP.
    public func getDevice(ipAddress: String) async -> DiscoveredDevice? {
        let trimmedIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if var device = devicesByIP[trimmedIP] {
            device.customAlias = await aliasStore.getAlias(for: trimmedIP)
            return device
        }
        return nil
    }

    /// Clears the in-memory device registry (does not delete saved aliases).
    public func clear() {
        devicesByIP.removeAll()
    }
}
