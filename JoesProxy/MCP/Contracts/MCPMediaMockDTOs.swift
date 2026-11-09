import Foundation

public struct MCPGetMockMediaScaffoldRequestDTO: Codable, Sendable, Equatable {
    public let customStreamURL: String?
    public let customCDNBaseURL: String?

    public init(customStreamURL: String? = nil, customCDNBaseURL: String? = nil) {
        self.customStreamURL = customStreamURL
        self.customCDNBaseURL = customCDNBaseURL
    }
}

public struct MCPMockMediaScaffoldResponseDTO: Codable, Sendable, Equatable {
    public let package: MockMediaPackage
    public let genericEPGJSON: String
    public let genericVODDetailJSON: String

    public init(package: MockMediaPackage, genericEPGJSON: String, genericVODDetailJSON: String) {
        self.package = package
        self.genericEPGJSON = genericEPGJSON
        self.genericVODDetailJSON = genericVODDetailJSON
    }
}

public struct MCPExportMockEPGRequestDTO: Codable, Sendable, Equatable {
    public let channelName: String?
    public let categoryName: String?
    public let hlsStreamURL: String?

    public init(channelName: String? = nil, categoryName: String? = nil, hlsStreamURL: String? = nil) {
        self.channelName = channelName
        self.categoryName = categoryName
        self.hlsStreamURL = hlsStreamURL
    }
}

public struct MCPExportMockEPGResponseDTO: Codable, Sendable, Equatable {
    public let epgJSON: String
    public let channel: MockChannel

    public init(epgJSON: String, channel: MockChannel) {
        self.epgJSON = epgJSON
        self.channel = channel
    }
}
