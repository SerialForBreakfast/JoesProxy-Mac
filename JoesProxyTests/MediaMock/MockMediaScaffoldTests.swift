import XCTest
@testable import JoesProxy

final class MockMediaScaffoldTests: XCTestCase {
    func testDefaultPackageStructure() {
        let pkg = MockMediaScaffoldProvider.makeDefaultPackage()

        // Channel & Category
        XCTAssertEqual(pkg.channel.name, "JoesChannel")
        XCTAssertEqual(pkg.channel.category, "JoeTest")
        XCTAssertEqual(pkg.channel.callSign, "JOETEST")
        XCTAssertEqual(pkg.channel.channelNumber, "101")
        XCTAssertFalse(pkg.channel.streamURL.isEmpty)

        // Cast & Crew with Joe McCraw
        let castNames = pkg.vodDetail.cast.map(\.name)
        XCTAssertTrue(castNames.contains("Joe McCraw"))
        let leadActor = pkg.vodDetail.cast.first { $0.role == .leadActor }
        XCTAssertEqual(leadActor?.name, "Joe McCraw")
        XCTAssertEqual(leadActor?.characterName, "Joe / Tech Lead")

        let director = pkg.vodDetail.crew.first { $0.role == .director }
        XCTAssertEqual(director?.name, "Joe McCraw")

        // Artwork
        XCTAssertEqual(pkg.allArtwork.count, 5)
        XCTAssertTrue(pkg.allArtwork.contains { $0.kind == .logo1x1 })
        XCTAssertTrue(pkg.allArtwork.contains { $0.kind == .poster2x3 })
        XCTAssertTrue(pkg.allArtwork.contains { $0.kind == .banner16x9 })

        // Audio & Subtitles
        let audioLangs = pkg.audioTracks.map(\.language)
        XCTAssertTrue(audioLangs.contains("en"))
        XCTAssertTrue(audioLangs.contains("es"))
        XCTAssertTrue(audioLangs.contains("de"))
        XCTAssertTrue(pkg.audioTracks.contains { $0.isAudioDescription })

        let subLangs = pkg.subtitleTracks.map(\.language)
        XCTAssertTrue(subLangs.contains("en"))
        XCTAssertTrue(subLangs.contains("es"))

        // S#E# Metadata
        XCTAssertEqual(pkg.channel.currentProgram.seasonNumber, 1)
        XCTAssertEqual(pkg.channel.currentProgram.episodeNumber, 1)
        XCTAssertEqual(pkg.vodDetail.seasonNumber, 1)
        XCTAssertEqual(pkg.vodDetail.episodeNumber, 1)
        XCTAssertEqual(pkg.vodDetail.releaseYear, 2026)
    }

    func testGenericEPGJSONSerialization() throws {
        let pkg = MockMediaScaffoldProvider.makeDefaultPackage()
        let data = MockMediaScaffoldProvider.toGenericEPGJSON(package: pkg)
        XCTAssertFalse(data.isEmpty)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        let categories = json?["categories"] as? [[String: Any]]
        XCTAssertEqual(categories?.first?["title"] as? String, "JoeTest")

        let channels = json?["channels"] as? [[String: Any]]
        XCTAssertEqual(channels?.first?["name"] as? String, "JoesChannel")
        XCTAssertEqual(channels?.first?["category"] as? String, "JoeTest")

        let currentProgram = channels?.first?["currentProgram"] as? [String: Any]
        XCTAssertEqual(currentProgram?["seasonNumber"] as? Int, 1)
        XCTAssertEqual(currentProgram?["episodeNumber"] as? Int, 1)
    }

    func testGenericVODDetailJSONSerialization() throws {
        let pkg = MockMediaScaffoldProvider.makeDefaultPackage()
        let data = MockMediaScaffoldProvider.toGenericVODDetailJSON(package: pkg)
        XCTAssertFalse(data.isEmpty)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        XCTAssertEqual(json?["title"] as? String, "Joe's Streaming Lab Live")
        XCTAssertEqual(json?["seasonNumber"] as? Int, 1)
        XCTAssertEqual(json?["episodeNumber"] as? Int, 1)
        XCTAssertEqual(json?["releaseYear"] as? Int, 2026)

        let cast = json?["cast"] as? [[String: Any]]
        XCTAssertEqual(cast?.first?["name"] as? String, "Joe McCraw")
        XCTAssertEqual(cast?.first?["role"] as? String, "Lead Actor")

        let audioTracks = json?["audioTracks"] as? [[String: Any]]
        XCTAssertEqual(audioTracks?.count, 4)
    }

    func testAssetServerLoadsAvatarData() throws {
        let avatarData = MockMediaAssetServer.shared.loadPrimaryAvatarData()
        XCTAssertNotNil(avatarData)
        XCTAssertTrue((avatarData?.count ?? 0) > 100)

        let testURL = URL(string: "https://images.joesproxy.invalid/assets/joe_avatar.jpg")!
        let response = MockMediaAssetServer.shared.response(for: testURL)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.contentType, "image/jpeg")
        XCTAssertEqual(response?.data.count, avatarData?.count)
    }

    func testMCPMediaMockService() {
        let service = MCPMediaMockService.shared
        let scaffold = service.getMockMediaScaffold()
        XCTAssertEqual(scaffold.package.channel.name, "JoesChannel")
        XCTAssertFalse(scaffold.genericEPGJSON.isEmpty)
        XCTAssertFalse(scaffold.genericVODDetailJSON.isEmpty)

        let customEPG = service.exportMockEPG(
            request: MCPExportMockEPGRequestDTO(
                channelName: "CustomJoeLive",
                categoryName: "CustomCategory"
            )
        )
        XCTAssertEqual(customEPG.channel.name, "CustomJoeLive")
        XCTAssertEqual(customEPG.channel.category, "CustomCategory")
        XCTAssertTrue(customEPG.epgJSON.contains("CustomJoeLive"))
    }

    func testLargeEPGJSONGenerationAndServerResponse() throws {
        let largeData = MockMediaScaffoldProvider.toLargeEPGJSON(categoryCount: 40, channelsPerCategory: 60)
        XCTAssertFalse(largeData.isEmpty)
        XCTAssertTrue(largeData.count > 500_000, "40x60 EPG JSON should be ~680KB")

        let json = try JSONSerialization.jsonObject(with: largeData) as? [String: Any]
        XCTAssertNotNil(json)
        let categories = json?["categories"] as? [[String: Any]]
        let channels = json?["channels"] as? [[String: Any]]
        XCTAssertEqual(categories?.count, 40)
        XCTAssertEqual(channels?.count, 2400)

        // Verify MockMediaAssetServer routes epg.joesproxy.invalid/epg in-process
        let epgURL = URL(string: "https://epg.joesproxy.invalid/epg")!
        let response = MockMediaAssetServer.shared.response(for: epgURL)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.contentType, "application/json; charset=utf-8")
        XCTAssertTrue((response?.data.count ?? 0) > 500_000)
    }
}
