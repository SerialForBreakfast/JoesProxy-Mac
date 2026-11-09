import Foundation

/// Role of a person in cast or crew metadata.
public enum MockPersonRole: String, Codable, CaseIterable, Sendable {
    case leadActor = "Lead Actor"
    case supportingActor = "Supporting Actor"
    case director = "Director"
    case creator = "Creator"
    case writer = "Writer"
    case producer = "Producer"
    case host = "Host"
}

/// A cast or crew member in streaming mock metadata.
public struct MockPerson: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var role: MockPersonRole
    public var characterName: String?
    public var headshotURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: MockPersonRole,
        characterName: String? = nil,
        headshotURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.characterName = characterName
        self.headshotURL = headshotURL
    }
}

/// The visual aspect ratio and presentation kind of an artwork asset.
public enum MockArtworkKind: String, Codable, CaseIterable, Sendable {
    case logo1x1 = "logo_1x1"
    case poster2x3 = "poster_2x3"
    case banner16x9 = "banner_16x9"
    case heroBackdrop = "hero_backdrop"
    case thumbnail = "thumbnail"
}

/// An image asset for a channel, program, poster carousel, or detail view.
public struct MockArtworkAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: MockArtworkKind
    public var url: String
    public var width: Int
    public var height: Int
    public var altText: String

    public init(
        id: String = UUID().uuidString,
        kind: MockArtworkKind,
        url: String,
        width: Int,
        height: Int,
        altText: String
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.width = width
        self.height = height
        self.altText = altText
    }
}

/// An audio track rendition available in playback.
public struct MockAudioTrack: Identifiable, Codable, Equatable, Sendable {
    public var id: String { language + (isAudioDescription ? "-ad" : "") }
    public var language: String
    public var displayName: String
    public var channels: String
    public var isDefault: Bool
    public var isAutoSelect: Bool
    public var isAudioDescription: Bool
    public var characteristics: [String]
    public var audibleSignature: String

    public init(
        language: String,
        displayName: String,
        channels: String = "2.0",
        isDefault: Bool = false,
        isAutoSelect: Bool = true,
        isAudioDescription: Bool = false,
        characteristics: [String] = [],
        audibleSignature: String = ""
    ) {
        self.language = language
        self.displayName = displayName
        self.channels = channels
        self.isDefault = isDefault
        self.isAutoSelect = isAutoSelect
        self.isAudioDescription = isAudioDescription
        self.characteristics = characteristics
        self.audibleSignature = audibleSignature
    }
}

/// A subtitle / caption track available in playback.
public struct MockSubtitleTrack: Identifiable, Codable, Equatable, Sendable {
    public var id: String { language + (isClosedCaption ? "-cc" : "") }
    public var language: String
    public var displayName: String
    public var format: String
    public var isClosedCaption: Bool
    public var isDefault: Bool

    public init(
        language: String,
        displayName: String,
        format: String = "webvtt",
        isClosedCaption: Bool = false,
        isDefault: Bool = false
    ) {
        self.language = language
        self.displayName = displayName
        self.format = format
        self.isClosedCaption = isClosedCaption
        self.isDefault = isDefault
    }
}

/// A scheduled program in a live Electronic Program Guide (EPG).
public struct MockEPGProgram: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var episodeTitle: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var synopsis: String
    public var rating: String
    public var genres: [String]
    public var startTime: Date
    public var endTime: Date
    public var durationSeconds: Int
    public var isLive: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        episodeTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        synopsis: String,
        rating: String = "TV-MA",
        genres: [String] = ["Tech Thriller", "Comedy"],
        startTime: Date = Date(),
        endTime: Date = Date().addingTimeInterval(3600),
        durationSeconds: Int = 3600,
        isLive: Bool = true
    ) {
        self.id = id
        self.title = title
        self.episodeTitle = episodeTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.synopsis = synopsis
        self.rating = rating
        self.genres = genres
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.isLive = isLive
    }
}

/// A live linear channel in an EPG lineup.
public struct MockChannel: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var callSign: String
    public var name: String
    public var category: String
    public var channelNumber: String
    public var logoArtwork: MockArtworkAsset
    public var currentProgram: MockEPGProgram
    public var upcomingSchedule: [MockEPGProgram]
    public var streamURL: String

    public init(
        id: String = "ch-joes-channel",
        callSign: String = "JOETEST",
        name: String = "JoesChannel",
        category: String = "JoeTest",
        channelNumber: String = "101",
        logoArtwork: MockArtworkAsset,
        currentProgram: MockEPGProgram,
        upcomingSchedule: [MockEPGProgram] = [],
        streamURL: String
    ) {
        self.id = id
        self.callSign = callSign
        self.name = name
        self.category = category
        self.channelNumber = channelNumber
        self.logoArtwork = logoArtwork
        self.currentProgram = currentProgram
        self.upcomingSchedule = upcomingSchedule
        self.streamURL = streamURL
    }
}

/// Rich metadata for a VOD title / content detail screen.
public struct MockVODDetail: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var seriesTitle: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var synopsis: String
    public var rating: String
    public var genres: [String]
    public var contentAdvisories: [String]
    public var releaseYear: Int
    public var durationSeconds: Int
    public var cast: [MockPerson]
    public var crew: [MockPerson]
    public var artwork: [MockArtworkAsset]
    public var audioTracks: [MockAudioTrack]
    public var subtitleTracks: [MockSubtitleTrack]
    public var shareURL: String
    public var deepLinkURL: String
    public var streamURL: String

    public init(
        id: String = "vod-joes-streaming-lab",
        title: String,
        seriesTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        synopsis: String,
        rating: String = "TV-MA",
        genres: [String] = ["Tech Thriller", "Comedy", "Engineering"],
        contentAdvisories: [String] = ["High Frame Rate", "Audible Frequency Shifts", "Live Interception"],
        releaseYear: Int = 2026,
        durationSeconds: Int = 3600,
        cast: [MockPerson],
        crew: [MockPerson],
        artwork: [MockArtworkAsset],
        audioTracks: [MockAudioTrack],
        subtitleTracks: [MockSubtitleTrack],
        shareURL: String,
        deepLinkURL: String,
        streamURL: String
    ) {
        self.id = id
        self.title = title
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.synopsis = synopsis
        self.rating = rating
        self.genres = genres
        self.contentAdvisories = contentAdvisories
        self.releaseYear = releaseYear
        self.durationSeconds = durationSeconds
        self.cast = cast
        self.crew = crew
        self.artwork = artwork
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.shareURL = shareURL
        self.deepLinkURL = deepLinkURL
        self.streamURL = streamURL
    }
}

/// Complete cohesive package tying together channel, EPG schedule, VOD details, artwork, and HLS stream.
public struct MockMediaPackage: Identifiable, Codable, Equatable, Sendable {
    public var id: String { channel.id }
    public var channel: MockChannel
    public var vodDetail: MockVODDetail
    public var allArtwork: [MockArtworkAsset]
    public var audioTracks: [MockAudioTrack]
    public var subtitleTracks: [MockSubtitleTrack]
    public var generatedAt: Date

    public init(
        channel: MockChannel,
        vodDetail: MockVODDetail,
        allArtwork: [MockArtworkAsset],
        audioTracks: [MockAudioTrack],
        subtitleTracks: [MockSubtitleTrack],
        generatedAt: Date = Date()
    ) {
        self.channel = channel
        self.vodDetail = vodDetail
        self.allArtwork = allArtwork
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.generatedAt = generatedAt
    }
}
