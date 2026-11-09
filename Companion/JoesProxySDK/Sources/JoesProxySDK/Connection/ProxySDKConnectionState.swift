import Foundation

public enum ProxySDKConnectionState: Equatable, Sendable {
    case disconnected
    case discovering
    case connecting(host: String, port: Int)
    case connected(host: String, port: Int, clockOffsetMs: Int)
    case rejected(reason: SDKHandshakeRejectReason, compatibility: SDKCompatibilityInfo?)
    case failed(message: String)
}

public enum ProxySDKError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidWebSocketURL
    case connectionRejected(SDKHandshakeRejectReason)
    case protocolError(String)
    case discoveryTimedOut
    case serviceResolutionFailed
}

public struct SDKCompatibilityInfo: Equatable, Sendable {
    public let serverAppVersion: String?
    public let minimumSupportedSchemaVersion: Int?
    public let latestSupportedSchemaVersion: Int?
    public let compatibilityResolution: SDKCompatibilityResolution?
    public let message: String?

    public init(
        serverAppVersion: String?,
        minimumSupportedSchemaVersion: Int?,
        latestSupportedSchemaVersion: Int?,
        compatibilityResolution: SDKCompatibilityResolution?,
        message: String?
    ) {
        self.serverAppVersion = serverAppVersion
        self.minimumSupportedSchemaVersion = minimumSupportedSchemaVersion
        self.latestSupportedSchemaVersion = latestSupportedSchemaVersion
        self.compatibilityResolution = compatibilityResolution
        self.message = message
    }

    init(handshakeAck: HandshakeAck) {
        self.init(
            serverAppVersion: handshakeAck.serverAppVersion,
            minimumSupportedSchemaVersion: handshakeAck.minimumSupportedSchemaVersion,
            latestSupportedSchemaVersion: handshakeAck.latestSupportedSchemaVersion,
            compatibilityResolution: handshakeAck.compatibilityResolution,
            message: handshakeAck.compatibilityMessage
        )
    }

    var hasDetails: Bool {
        serverAppVersion != nil
            || minimumSupportedSchemaVersion != nil
            || latestSupportedSchemaVersion != nil
            || compatibilityResolution != nil
            || message != nil
    }

    public var userFacingMessage: String {
        if let message, !message.isEmpty {
            return message
        }

        switch compatibilityResolution {
        case .updateJoesProxy:
            return "Update JoesProxy to a version compatible with this SDK."
        case .updateSDK:
            return "Update the JoesProxySDK package to a version compatible with this JoesProxy app."
        case .unknown, nil:
            return "Update JoesProxy and the JoesProxySDK package to compatible versions."
        }
    }
}

public struct DiscoveredJoesProxyService: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let sdkPort: Int?
    public let profilePath: String?
    public let version: Int?

    public init(name: String, host: String, port: Int, sdkPort: Int?, profilePath: String?, version: Int?) {
        self.name = name
        self.host = host
        self.port = port
        self.sdkPort = sdkPort
        self.profilePath = profilePath
        self.version = version
    }

    public var eventServerPort: Int {
        sdkPort ?? port
    }
}
