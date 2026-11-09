import Foundation

public final class MCPDeviceService: Sendable {
    public static let shared = MCPDeviceService()

    private let registry: DeviceRegistry

    public init(registry: DeviceRegistry = .shared) {
        self.registry = registry
    }

    public func listDevices() async -> MCPListDevicesResponseDTO {
        let devices = await registry.discoveredDevices()
        return MCPListDevicesResponseDTO(devices: devices)
    }

    public func setDeviceAlias(request: MCPSetDeviceAliasRequestDTO) async -> MCPSetDeviceAliasResponseDTO? {
        if let device = await registry.setDeviceAlias(ipAddress: request.ipAddress, alias: request.alias) {
            return MCPSetDeviceAliasResponseDTO(device: device)
        }
        return nil
    }
}
