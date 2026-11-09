import Foundation

public struct MCPDiscoveredDeviceDTO: Codable, Sendable, Equatable {
    public let ipAddress: String
    public let customAlias: String?
    public let displayName: String
    public let sessionCount: Int
    public let isLoopback: Bool
    public let firstSeen: String
    public let lastSeen: String

    public init(from device: DiscoveredDevice) {
        self.ipAddress = device.ipAddress
        self.customAlias = device.customAlias
        self.displayName = device.displayName
        self.sessionCount = device.sessionCount
        self.isLoopback = device.isLoopback
        self.firstSeen = ISO8601DateFormatter().string(from: device.firstSeen)
        self.lastSeen = ISO8601DateFormatter().string(from: device.lastSeen)
    }
}

public struct MCPListDevicesResponseDTO: Codable, Sendable, Equatable {
    public let devices: [MCPDiscoveredDeviceDTO]

    public init(devices: [DiscoveredDevice]) {
        self.devices = devices.map(MCPDiscoveredDeviceDTO.init)
    }
}

public struct MCPSetDeviceAliasRequestDTO: Codable, Sendable, Equatable {
    public let ipAddress: String
    public let alias: String?

    public init(ipAddress: String, alias: String?) {
        self.ipAddress = ipAddress
        self.alias = alias
    }
}

public struct MCPSetDeviceAliasResponseDTO: Codable, Sendable, Equatable {
    public let device: MCPDiscoveredDeviceDTO

    public init(device: DiscoveredDevice) {
        self.device = MCPDiscoveredDeviceDTO(from: device)
    }
}
