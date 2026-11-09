import Foundation

public final class MCPMediaMockService: Sendable {
    public static let shared = MCPMediaMockService()

    public init() {}

    public func getMockMediaScaffold(
        request: MCPGetMockMediaScaffoldRequestDTO = MCPGetMockMediaScaffoldRequestDTO()
    ) -> MCPMockMediaScaffoldResponseDTO {
        let cdnBase = request.customCDNBaseURL ?? MockMediaAssetServer.defaultBaseURL
        let pkg = MockMediaScaffoldProvider.makeDefaultPackage(
            hlsStreamURL: request.customStreamURL,
            cdnBaseURL: cdnBase
        )

        let epgData = MockMediaScaffoldProvider.toGenericEPGJSON(package: pkg)
        let vodData = MockMediaScaffoldProvider.toGenericVODDetailJSON(package: pkg)

        let epgString = String(data: epgData, encoding: .utf8) ?? "{}"
        let vodString = String(data: vodData, encoding: .utf8) ?? "{}"

        return MCPMockMediaScaffoldResponseDTO(
            package: pkg,
            genericEPGJSON: epgString,
            genericVODDetailJSON: vodString
        )
    }

    public func exportMockEPG(
        request: MCPExportMockEPGRequestDTO = MCPExportMockEPGRequestDTO()
    ) -> MCPExportMockEPGResponseDTO {
        var pkg = MockMediaScaffoldProvider.makeDefaultPackage(
            hlsStreamURL: request.hlsStreamURL
        )

        if let chName = request.channelName?.trimmingCharacters(in: .whitespacesAndNewlines), !chName.isEmpty {
            pkg.channel.name = chName
        }
        if let catName = request.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines), !catName.isEmpty {
            pkg.channel.category = catName
        }

        let epgData = MockMediaScaffoldProvider.toGenericEPGJSON(package: pkg)
        let epgString = String(data: epgData, encoding: .utf8) ?? "{}"

        return MCPExportMockEPGResponseDTO(
            epgJSON: epgString,
            channel: pkg.channel
        )
    }
}
