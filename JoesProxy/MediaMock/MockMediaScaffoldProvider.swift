import Foundation

/// Primary generator and exporter for synthetic mock media metadata packages.
public enum MockMediaScaffoldProvider {
    public static let defaultStreamURL = "https://fixture-player-qa.hls.joesproxy.invalid/master.m3u8"

    /// Builds a complete, coherent mock media package populated with rich metadata, cast (Joe McCraw),
    /// multi-language audio tracks, and custom artwork URLs.
    public static func makeDefaultPackage(
        hlsStreamURL: String? = nil,
        cdnBaseURL: String = MockMediaAssetServer.defaultBaseURL
    ) -> MockMediaPackage {
        let streamURL = hlsStreamURL ?? defaultStreamURL
        let avatarURL = "\(cdnBaseURL)/assets/joe_avatar.jpg"

        // Cast & Crew
        let leadJoe = MockPerson(
            id: "person-joe-mccraw",
            name: "Joe McCraw",
            role: .leadActor,
            characterName: "Joe / Tech Lead",
            headshotURL: avatarURL
        )
        let directorJoe = MockPerson(
            id: "crew-director-joe",
            name: "Joe McCraw",
            role: .director
        )
        let creatorJoe = MockPerson(
            id: "crew-creator-joe",
            name: "Joe McCraw",
            role: .creator
        )
        let writerJoe = MockPerson(
            id: "crew-writer-joe",
            name: "Joe McCraw",
            role: .writer
        )

        // Artwork Assets
        let logo1x1 = MockArtworkAsset(
            id: "art-logo-1x1",
            kind: .logo1x1,
            url: avatarURL,
            width: 512,
            height: 512,
            altText: "JoesChannel Circular Badge Logo"
        )
        let poster2x3 = MockArtworkAsset(
            id: "art-poster-2x3",
            kind: .poster2x3,
            url: avatarURL,
            width: 600,
            height: 900,
            altText: "Joe's Streaming Lab Key Art Poster"
        )
        let banner16x9 = MockArtworkAsset(
            id: "art-banner-16x9",
            kind: .banner16x9,
            url: avatarURL,
            width: 1920,
            height: 1080,
            altText: "Joe's Streaming Lab 16:9 Widescreen Banner"
        )
        let heroBackdrop = MockArtworkAsset(
            id: "art-hero-backdrop",
            kind: .heroBackdrop,
            url: avatarURL,
            width: 1920,
            height: 1080,
            altText: "Joe's Streaming Lab Hero Stage Backdrop"
        )
        let thumbnail = MockArtworkAsset(
            id: "art-thumbnail",
            kind: .thumbnail,
            url: avatarURL,
            width: 320,
            height: 180,
            altText: "S1E1 Episode Thumbnail"
        )
        let allArtwork = [logo1x1, poster2x3, banner16x9, heroBackdrop, thumbnail]

        // Audio Tracks
        let audioEN = MockAudioTrack(
            language: "en",
            displayName: "English",
            channels: "2.0",
            isDefault: true,
            isAutoSelect: true,
            isAudioDescription: false,
            characteristics: [],
            audibleSignature: "440 Hz Sine Tone"
        )
        let audioENAD = MockAudioTrack(
            language: "en",
            displayName: "English (Audio Description)",
            channels: "2.0",
            isDefault: false,
            isAutoSelect: true,
            isAudioDescription: true,
            characteristics: ["public.accessibility.describes-video"],
            audibleSignature: "440 Hz + 1 kHz Cue Tone Mix"
        )
        let audioES = MockAudioTrack(
            language: "es",
            displayName: "Spanish",
            channels: "2.0",
            isDefault: false,
            isAutoSelect: false,
            isAudioDescription: false,
            characteristics: [],
            audibleSignature: "660 Hz Sine Tone"
        )
        let audioDE = MockAudioTrack(
            language: "de",
            displayName: "German",
            channels: "2.0",
            isDefault: false,
            isAutoSelect: false,
            isAudioDescription: false,
            characteristics: [],
            audibleSignature: "330 Hz Sine Tone"
        )
        let audioTracks = [audioEN, audioENAD, audioES, audioDE]

        // Subtitle Tracks
        let subEN = MockSubtitleTrack(
            language: "en",
            displayName: "English [CC]",
            format: "webvtt",
            isClosedCaption: true,
            isDefault: true
        )
        let subES = MockSubtitleTrack(
            language: "es",
            displayName: "Spanish",
            format: "webvtt",
            isClosedCaption: false,
            isDefault: false
        )
        let subtitleTracks = [subEN, subES]

        // EPG Program
        let now = Date()
        let currentProgram = MockEPGProgram(
            id: "prog-s1e1",
            title: "Joe's Streaming Lab Live",
            episodeTitle: "The Multi-Audio Protocol Mystery",
            seasonNumber: 1,
            episodeNumber: 1,
            synopsis: "Join Joe McCraw in the streaming lab as he investigates live HLS alternate audio rendition switching, real-time EPG splicing, and wire-level protocol fidelity.",
            rating: "TV-MA",
            genres: ["Tech Thriller", "Comedy", "Engineering"],
            startTime: now.addingTimeInterval(-600),
            endTime: now.addingTimeInterval(3000),
            durationSeconds: 3600,
            isLive: true
        )
        let nextProgram = MockEPGProgram(
            id: "prog-s1e2",
            title: "Joe's Streaming Lab Live",
            episodeTitle: "Bitrate Adaptation on the Wire",
            seasonNumber: 1,
            episodeNumber: 2,
            synopsis: "Joe tackles bandwidth throttling and stepped bitrate ladder switches under heavy network contention.",
            rating: "TV-MA",
            genres: ["Tech Thriller", "Comedy", "Engineering"],
            startTime: now.addingTimeInterval(3000),
            endTime: now.addingTimeInterval(6600),
            durationSeconds: 3600,
            isLive: false
        )

        // Live Channel
        let channel = MockChannel(
            id: "ch-joes-channel",
            callSign: "JOETEST",
            name: "JoesChannel",
            category: "JoeTest",
            channelNumber: "101",
            logoArtwork: logo1x1,
            currentProgram: currentProgram,
            upcomingSchedule: [nextProgram],
            streamURL: streamURL
        )

        // VOD Detail
        let vodDetail = MockVODDetail(
            id: "vod-joes-streaming-lab-s1e1",
            title: "Joe's Streaming Lab Live",
            seriesTitle: "Joe's Streaming Lab",
            seasonNumber: 1,
            episodeNumber: 1,
            synopsis: "Join Joe McCraw in the streaming lab as he investigates live HLS alternate audio rendition switching, real-time EPG splicing, and wire-level protocol fidelity.",
            rating: "TV-MA",
            genres: ["Tech Thriller", "Comedy", "Engineering"],
            contentAdvisories: ["High Frame Rate", "Audible Frequency Shifts", "Live Interception"],
            releaseYear: 2026,
            durationSeconds: 3600,
            cast: [leadJoe],
            crew: [directorJoe, creatorJoe, writerJoe],
            artwork: allArtwork,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            shareURL: "https://joesproxy.invalid/watch/vod-joes-streaming-lab-s1e1",
            deepLinkURL: "joesproxy://watch/vod-joes-streaming-lab-s1e1",
            streamURL: streamURL
        )

        return MockMediaPackage(
            channel: channel,
            vodDetail: vodDetail,
            allArtwork: allArtwork,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            generatedAt: now
        )
    }

    /// Serializes a complete generic EPG JSON response containing categories and channels.
    public static func toGenericEPGJSON(package: MockMediaPackage) -> Data {
        let payload: [String: Any] = [
            "categories": [
                [
                    "id": "cat-joetest",
                    "title": package.channel.category,
                    "channelCount": 1
                ]
            ],
            "channels": [
                toChannelLineupDict(package: package)
            ]
        ]

        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func programToDict(_ prog: MockEPGProgram) -> [String: Any] {
        var dict: [String: Any] = [
            "id": prog.id,
            "title": prog.title,
            "synopsis": prog.synopsis,
            "rating": prog.rating,
            "genres": prog.genres,
            "startTime": ISO8601DateFormatter().string(from: prog.startTime),
            "endTime": ISO8601DateFormatter().string(from: prog.endTime),
            "isLive": prog.isLive
        ]
        if let epTitle = prog.episodeTitle { dict["episodeTitle"] = epTitle }
        if let sNum = prog.seasonNumber { dict["seasonNumber"] = sNum }
        if let eNum = prog.episodeNumber { dict["episodeNumber"] = eNum }
        return dict
    }

    /// Serializes a single channel lineup dictionary for array splicing.
    public static func toChannelLineupDict(package: MockMediaPackage) -> [String: Any] {
        let ch = package.channel
        let upcoming = ch.upcomingSchedule.map { programToDict($0) }
        return [
            "id": ch.id,
            "callSign": ch.callSign,
            "name": ch.name,
            "category": ch.category,
            "channelNumber": ch.channelNumber,
            "logoUrl": ch.logoArtwork.url,
            "streamUrl": ch.streamURL,
            "currentProgram": programToDict(ch.currentProgram),
            "upcomingSchedule": upcoming
        ]
    }

    /// Serializes a complete generic VOD detail JSON response.
    public static func toGenericVODDetailJSON(package: MockMediaPackage) -> Data {
        let vod = package.vodDetail

        let castList: [[String: Any]] = vod.cast.map { p in
            var dict: [String: Any] = [
                "id": p.id,
                "name": p.name,
                "role": p.role.rawValue
            ]
            if let character = p.characterName { dict["characterName"] = character }
            if let headshot = p.headshotURL { dict["headshotUrl"] = headshot }
            return dict
        }

        let crewList: [[String: Any]] = vod.crew.map { p in
            [
                "id": p.id,
                "name": p.name,
                "role": p.role.rawValue
            ]
        }

        let artworkList: [[String: Any]] = vod.artwork.map { a in
            [
                "id": a.id,
                "kind": a.kind.rawValue,
                "url": a.url,
                "width": a.width,
                "height": a.height,
                "altText": a.altText
            ]
        }

        let audioList: [[String: Any]] = vod.audioTracks.map { t in
            [
                "language": t.language,
                "displayName": t.displayName,
                "channels": t.channels,
                "isDefault": t.isDefault,
                "isAutoSelect": t.isAutoSelect,
                "isAudioDescription": t.isAudioDescription,
                "characteristics": t.characteristics,
                "audibleSignature": t.audibleSignature
            ]
        }

        let subList: [[String: Any]] = vod.subtitleTracks.map { s in
            [
                "language": s.language,
                "displayName": s.displayName,
                "format": s.format,
                "isClosedCaption": s.isClosedCaption,
                "isDefault": s.isDefault
            ]
        }

        var payload: [String: Any] = [
            "id": vod.id,
            "title": vod.title,
            "synopsis": vod.synopsis,
            "rating": vod.rating,
            "genres": vod.genres,
            "contentAdvisories": vod.contentAdvisories,
            "releaseYear": vod.releaseYear,
            "durationSeconds": vod.durationSeconds,
            "streamUrl": vod.streamURL,
            "shareUrl": vod.shareURL,
            "deepLinkUrl": vod.deepLinkURL,
            "cast": castList,
            "crew": crewList,
            "artwork": artworkList,
            "audioTracks": audioList,
            "subtitleTracks": subList
        ]

        if let series = vod.seriesTitle { payload["seriesTitle"] = series }
        if let sNum = vod.seasonNumber { payload["seasonNumber"] = sNum }
        if let eNum = vod.episodeNumber { payload["episodeNumber"] = eNum }

        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Serializes a large synthetic EPG JSON response (e.g. 40 categories x 60 channels, ~680KB)
    /// for high-throughput testing, live demo benchmarks, and synthetic EPG testing.
    public static func toLargeEPGJSON(
        categoryCount: Int = 40,
        channelsPerCategory: Int = 60,
        includeJoeChannel: Bool = true
    ) -> Data {
        let package = makeDefaultPackage()
        let joeChannelDict = toChannelLineupDict(package: package)

        var categories: [[String: Any]] = []
        var allChannels: [[String: Any]] = []

        categories.reserveCapacity(categoryCount)
        allChannels.reserveCapacity(categoryCount * channelsPerCategory)

        for c in 0..<categoryCount {
            let catID = "cat-\(c)"
            let catTitle = (c == 0 && includeJoeChannel) ? "JoeTest" : "Category \(c)"
            categories.append([
                "id": catID,
                "title": catTitle,
                "channelCount": channelsPerCategory
            ])

            for ch in 0..<channelsPerCategory {
                if c == 0 && ch == 0 && includeJoeChannel {
                    allChannels.append(joeChannelDict)
                } else {
                    let chID = "ch-\(c)-\(ch)"
                    let chNumber = (c * 100) + ch + 1
                    allChannels.append([
                        "id": chID,
                        "callSign": "CH\(chNumber)",
                        "name": "Channel \(chNumber)",
                        "category": catTitle,
                        "channelNumber": chNumber,
                        "logoUrl": "\(MockMediaAssetServer.defaultBaseURL)/assets/joe_avatar.jpg",
                        "streamUrl": defaultStreamURL,
                        "currentProgram": [
                            "id": "prog-\(chID)-now",
                            "title": "Program on Channel \(chNumber)",
                            "synopsis": "Live synthetic broadcast program for channel \(chNumber).",
                            "rating": "TV-PG",
                            "genres": ["Entertainment", "General"],
                            "startTime": "2026-08-25T12:00:00Z",
                            "endTime": "2026-08-25T13:00:00Z",
                            "isLive": true
                        ],
                        "upcomingSchedule": []
                    ])
                }
            }
        }

        let payload: [String: Any] = [
            "categories": categories,
            "channels": allChannels
        ]

        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}
