import Foundation

/// In-process asset and synthetic API server for mock media images, EPG lineups, and VOD details.
public final class MockMediaAssetServer: Sendable {
    public static let shared = MockMediaAssetServer()

    public static let defaultHost = "images.joesproxy.invalid"
    public static let defaultBaseURL = "https://\(defaultHost)"
    public static let epgHost = "epg.joesproxy.invalid"
    public static let mockMediaHost = "media.joesproxy.invalid"

    private let cachedLargeEPGData: Data
    private let cachedDefaultPackage: MockMediaPackage
    private let cachedVODData: Data

    public init() {
        let pkg = MockMediaScaffoldProvider.makeDefaultPackage()
        self.cachedDefaultPackage = pkg
        self.cachedLargeEPGData = MockMediaScaffoldProvider.toLargeEPGJSON(categoryCount: 40, channelsPerCategory: 60, includeJoeChannel: true)
        self.cachedVODData = MockMediaScaffoldProvider.toGenericVODDetailJSON(package: pkg)
    }

    /// Checks if a host is an in-process mock media or asset domain.
    public static func isMockMediaHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == defaultHost || h == epgHost || h == mockMediaHost || h == "mock-epg.joesproxy.invalid" || h.hasSuffix(".joesproxy.invalid")
    }

    /// Returns the bundled JPEG data for the primary mock avatar/logo.
    public func loadPrimaryAvatarData() -> Data? {
        // 1. Try bundle resource lookup
        if let bundleURL = Bundle.main.url(forResource: "joe_avatar", withExtension: "jpg", subdirectory: "Fixtures/MediaMock/Assets") {
            if let data = try? Data(contentsOf: bundleURL), !data.isEmpty {
                return data
            }
        }

        // 2. Try direct bundle root or general bundle lookup
        if let bundleURL = Bundle.main.url(forResource: "joe_avatar", withExtension: "jpg") {
            if let data = try? Data(contentsOf: bundleURL), !data.isEmpty {
                return data
            }
        }

        // 3. Try filesystem relative path (for unit tests / development)
        let cwd = FileManager.default.currentDirectoryPath
        let possiblePaths = [
            "\(cwd)/Fixtures/MediaMock/Assets/joe_avatar.jpg",
            "\(cwd)/../Fixtures/MediaMock/Assets/joe_avatar.jpg"
        ]
        for path in possiblePaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    /// Checks if a requested URL targets a JoesProxy synthetic image asset or EPG endpoint and returns its bytes.
    public func response(for requestURL: URL) -> (data: Data, contentType: String)? {
        let host = requestURL.host?.lowercased() ?? ""
        let path = requestURL.path.lowercased()

        // 1. Image Assets
        if host == Self.defaultHost || path.hasSuffix("joe_avatar.jpg") || path.hasSuffix("joeschannel-logo.jpg") || path.hasSuffix("joeschannel-poster.jpg") || path.hasSuffix(".jpg") || path.hasSuffix(".png") {
            if let avatarData = loadPrimaryAvatarData() {
                return (avatarData, "image/jpeg")
            }
        }

        // 2. EPG Feeds
        if host == Self.epgHost || host == "mock-epg.joesproxy.invalid" || path == "/epg" || path == "/epg.json" || path.hasSuffix("/channels") {
            return (cachedLargeEPGData, "application/json; charset=utf-8")
        }

        // 3. VOD Details
        if path == "/vod" || path == "/vod.json" || path.hasSuffix("/detail") {
            return (cachedVODData, "application/json; charset=utf-8")
        }

        return nil
    }
}
