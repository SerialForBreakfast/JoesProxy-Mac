import Foundation

enum HLSAudioTopology: String, Codable, Equatable, Sendable, CaseIterable {
    case muxedOnly
    case demuxedAll
    case hybridInBandProgramAD

    var displayName: String {
        switch self {
        case .muxedOnly: return "Muxed Only"
        case .demuxedAll: return "Fully Demuxed"
        case .hybridInBandProgramAD: return "Hybrid In-Band + AD"
        }
    }
}

enum HLSAudioDeliveryKind: String, Codable, Equatable, Sendable, CaseIterable {
    case inBand
    case uriBacked
}

enum HLSAudioPublicationSchedule: String, Codable, Equatable, Sendable, CaseIterable {
    case `static`
    case scheduledJIT
}

enum HLSJITPublicationState: String, Codable, Equatable, Sendable, CaseIterable {
    case current
    case laggingByOneInterval
    case initiallyAbsent
    case playlistPresentSegmentPending
    case overLagFault

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .laggingByOneInterval: return "Lagging (1 Interval)"
        case .initiallyAbsent: return "Initially Absent"
        case .playlistPresentSegmentPending: return "Playlist Present / Segment Pending"
        case .overLagFault: return "Over-Lag Fault"
        }
    }
}

enum HLSID3Carrier: String, Codable, Equatable, Sendable, CaseIterable {
    case mpeg2TS
    case packedAudioTimestamp
    case cmafEMSG

    var displayName: String {
        switch self {
        case .mpeg2TS: return "MPEG-2 TS Timed Metadata"
        case .packedAudioTimestamp: return "Packed-Audio Timestamp PRIV"
        case .cmafEMSG: return "CMAF / fMP4 emsg Box"
        }
    }
}

enum HLSID3Version: String, Codable, Equatable, Sendable, CaseIterable {
    case id3v2_3 = "id3v2.3"
    case id3v2_4 = "id3v2.4"
}

enum HLSID3EventClass: String, Codable, Equatable, Sendable, CaseIterable {
    case segmentStart
    case intraSegment
    case preDiscontinuity
    case postDiscontinuity
    case repeatedState
    case liveJIT
}

struct HLSID3Event: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var eventClass: String
    var mediaTime: Double
    var programDateTimeOffset: Double?
    var segmentIndex: Int
    var frameID: String
    var label: String
    var payloadDigest: String?
    var payloadSummary: String?
    var toleratedDriftSeconds: Double?
}

struct HLSID3Schedule: Codable, Equatable, Sendable {
    var carrier: String
    var version: String
    var allowedFrameIDs: [String]
    var events: [HLSID3Event]
}

struct HLSSwitchMarker: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var sourceRendition: String
    var sourceTopology: String
    var destinationRendition: String
    var destinationTopology: String
    var videoVariant: String
    var lastProgramMediaTime: Double
    var firstAlternateMediaTime: Double
    var destinationPlaylistAgeSeconds: Double
    var destinationLiveEdgeLagSeconds: Double
    var destinationGridSeconds: Double
    var requestedSequence: Int
    var nearestDiscontinuityTime: Double?
    var nearestDiscontinuitySequence: Int?
    var requestLatencyMilliseconds: Double?
    var requestStatusCode: Int?
    var playerAudibleTransitionObserved: Bool?

    init(
        id: UUID = UUID(),
        sourceRendition: String,
        sourceTopology: String,
        destinationRendition: String,
        destinationTopology: String,
        videoVariant: String,
        lastProgramMediaTime: Double,
        firstAlternateMediaTime: Double,
        destinationPlaylistAgeSeconds: Double,
        destinationLiveEdgeLagSeconds: Double,
        destinationGridSeconds: Double,
        requestedSequence: Int,
        nearestDiscontinuityTime: Double? = nil,
        nearestDiscontinuitySequence: Int? = nil,
        requestLatencyMilliseconds: Double? = nil,
        requestStatusCode: Int? = nil,
        playerAudibleTransitionObserved: Bool? = nil
    ) {
        self.id = id
        self.sourceRendition = sourceRendition
        self.sourceTopology = sourceTopology
        self.destinationRendition = destinationRendition
        self.destinationTopology = destinationTopology
        self.videoVariant = videoVariant
        self.lastProgramMediaTime = lastProgramMediaTime
        self.firstAlternateMediaTime = firstAlternateMediaTime
        self.destinationPlaylistAgeSeconds = destinationPlaylistAgeSeconds
        self.destinationLiveEdgeLagSeconds = destinationLiveEdgeLagSeconds
        self.destinationGridSeconds = destinationGridSeconds
        self.requestedSequence = requestedSequence
        self.nearestDiscontinuityTime = nearestDiscontinuityTime
        self.nearestDiscontinuitySequence = nearestDiscontinuitySequence
        self.requestLatencyMilliseconds = requestLatencyMilliseconds
        self.requestStatusCode = requestStatusCode
        self.playerAudibleTransitionObserved = playerAudibleTransitionObserved
    }
}

/// Human- and agent-readable metadata for one bundled HLS fixture profile.
struct HLSFixtureProfileDescriptor: Codable, Equatable, Identifiable, Sendable {
    struct Rendition: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var bandwidth: Int
        var codecs: String
    }

    struct AudioRendition: Codable, Equatable, Sendable {
        var name: String
        var language: String
        var associatedLanguage: String?
        var channels: String
        var isDefault: Bool
        var isAutoSelect: Bool
        var characteristics: [String]
        var audibleSignature: String
        var deliveryKind: String?
        var variantsCarryingInBand: [String]?
        var publicationSchedule: String?
        var segmentGridDuration: Double?
        var hasDiscontinuities: Bool?
    }

    var id: String
    var version: String
    var displayName: String
    var purpose: String
    var featureTags: [String]
    var renditions: [Rendition]
    var audioRenditions: [AudioRendition]?
    var audioTopology: String?
    var audioDescription: String?
    var bundleSizeBudgetBytes: Int?
    var isRecommended: Bool
    var conformanceClass: String? = nil
    var controlledFaults: [String]? = nil
    var expectedClientBehavior: String? = nil
    var id3Schedule: HLSID3Schedule? = nil
    var jitPublicationState: String? = nil
    var textFixture: HLSWebVTTFixture.Specification? = nil

    var supportedPresentationModes: [HLSPresentationMode] {
        HLSPresentationMode.allCases
    }

    var defaultPlaybackConfiguration: HLSPlaybackConfiguration {
        var configuration = HLSPlaybackConfiguration.conformant
        if textFixture != nil { configuration.presentationMode = .vodStatic }
        return configuration
    }

    static func load(from profileDirectory: URL) -> HLSFixtureProfileDescriptor {
        let metadataURL = profileDirectory.appendingPathComponent("profile.json")
        if let data = try? Data(contentsOf: metadataURL),
           let descriptor = try? JSONDecoder().decode(HLSFixtureProfileDescriptor.self, from: data) {
            return descriptor
        }

        let profileID = profileDirectory.lastPathComponent
        let knownMetadata = fallbackExperimentMetadata(profileID: profileID)
        return HLSFixtureProfileDescriptor(
            id: profileID,
            version: profileVersion(from: profileDirectory) ?? "1",
            displayName: profileID
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " "),
            purpose: knownMetadata.purpose,
            featureTags: knownMetadata.featureTags,
            renditions: [],
            audioRenditions: nil,
            audioDescription: nil,
            bundleSizeBudgetBytes: nil,
            isRecommended: false,
            conformanceClass: knownMetadata.conformanceClass,
            controlledFaults: knownMetadata.controlledFaults,
            expectedClientBehavior: knownMetadata.expectedClientBehavior
        )
    }

    private static func fallbackExperimentMetadata(
        profileID: String
    ) -> (
        purpose: String,
        featureTags: [String],
        conformanceClass: String?,
        controlledFaults: [String]?,
        expectedClientBehavior: String?
    ) {
        let canonicalID: String
        switch profileID {
        case "param-aligned-4s": canonicalID = "baseline-aligned-codecs"
        case "param-misaligned-v4-a3": canonicalID = "misaligned-audio-boundary"
        case "param-cross-disc-v3-aen5-aes4": canonicalID = "discontinuity-cross-rendition-drift"
        default: canonicalID = profileID
        }
        switch canonicalID {
        case "baseline-aligned-codecs":
            return (
                "Positive control with declared codecs and aligned audio/video segment grids.",
                ["positive-control", "aligned", "codecs", "alternate-audio"],
                "conformantControl",
                [],
                "Playback and alternate-audio switching should remain stable."
            )
        case "missing-codecs-only":
            return (
                "Isolates missing CODECS attributes in the multivariant playlist.",
                ["manifest-fault", "missing-codecs"],
                "deliberateFault",
                ["missingCodecs"],
                "Observe variant discovery, selection, and playback startup behavior."
            )
        case "bogus-ad-alias-only":
            return (
                "Labels an audio-description option that resolves to program-audio bytes.",
                ["manifest-fault", "audio-description", "alias"],
                "deliberateFault",
                ["audioDescriptionAlias"],
                "The option may appear selectable while producing the wrong audible content."
            )
        case "discontinuity-at-switch":
            return (
                "Places aligned discontinuities in every rendition for boundary-switch testing.",
                ["discontinuity", "alternate-audio", "aligned"],
                "stressCase",
                ["scheduledDiscontinuity"],
                "Switches should recover without losing audio/video synchronization."
            )
        case "key-rotation-only":
            return (
                "Exercises rotating HLS key declarations with bundled nonsecret test keys.",
                ["key-rotation", "encryption-metadata"],
                "stressCase",
                ["keyRotation"],
                "The client should fetch the declared key and continue playback."
            )
        case "misaligned-audio-boundary":
            return (
                "Uses a three-second audio grid against four-second video segments.",
                ["segment-alignment", "alternate-audio", "timing-fault"],
                "deliberateFault",
                ["misalignedAudioVideoBoundaries"],
                "Measure switch delay, waiting state, and timeline recovery."
            )
        case "combined-defects":
            return (
                "Combines missing codecs, audio aliasing, discontinuities, key rotation, and grid misalignment.",
                ["combined-faults", "manifest-fault", "timing-fault"],
                "deliberateFault",
                ["missingCodecs", "audioDescriptionAlias", "scheduledDiscontinuity", "keyRotation", "misalignedAudioVideoBoundaries"],
                "Use only after isolated controls establish which single faults affect the client."
            )
        case "discontinuity-cross-rendition-drift":
            return (
                "Places discontinuities at different positions across video and audio renditions.",
                ["discontinuity", "cross-rendition-drift", "alternate-audio"],
                "deliberateFault",
                ["crossRenditionDiscontinuityDrift", "misalignedAudioVideoBoundaries"],
                "Measure whether rendition switches stall or resume on a coherent timeline."
            )
        case "param-lang-en-es":
            return (
                "Tests language metadata selection while keeping the underlying audio bytes equivalent.",
                ["language-metadata", "alternate-audio", "controlled-content"],
                "stressCase",
                ["languageMetadataOnly"],
                "Any behavioral difference is attributable to metadata rather than audio payload."
            )
        case "audio-muxed-only-aligned":
            return (
                "Positive control where all A/V variants carry in-band program audio without a separate audio group.",
                ["positive-control", "audio-topology", "muxed-only", "aligned"],
                "conformantControl",
                [],
                "Playback and variant switching should remain stable with in-band audio."
            )
        case "audio-demuxed-all-aligned":
            return (
                "Positive control where video-only variants reference an audio group with separate program and AD playlists.",
                ["positive-control", "audio-topology", "demuxed-all", "alternate-audio", "audio-description", "aligned"],
                "conformantControl",
                [],
                "Rendition switching between Program and AD should maintain audio/video synchronization."
            )
        case "audio-hybrid-inband-program-ad-aligned":
            return (
                "Positive control where default audio is carried in-band and AD is delivered as a URI-backed alternate rendition.",
                ["positive-control", "audio-topology", "hybrid", "alternate-audio", "audio-description", "aligned"],
                "conformantControl",
                [],
                "Switching between in-band program audio and URI-backed AD should work seamlessly in both directions."
            )
        case "audio-hybrid-inband-program-ad-fine-grid":
            return (
                "Hybrid audio positive control with a shorter physical AD segment grid on an aligned timeline.",
                ["positive-control", "audio-topology", "hybrid", "fine-grid", "alternate-audio", "audio-description"],
                "conformantControl",
                [],
                "Switching across different valid segment grids should preserve presentation timing."
            )
        case "audio-hybrid-inband-program-ad-jit":
            return (
                "Simulated JIT alternate-audio publication near the moving live edge.",
                ["jit-publication", "hybrid", "audio-topology", "scheduled-publication", "live-edge"],
                "stressCase",
                [],
                "Rendition switching should adapt to JIT publication lag and availability."
            )
        case "id3-muxed-av-equivalent":
            return (
                "Multiplexed MPEG-2 TS ID3 timed metadata across all A/V variants.",
                ["id3", "timed-metadata", "mpeg2ts", "abr-consistency"],
                "conformantControl",
                [],
                "ID3 timed metadata callbacks should remain consistent across ABR switches."
            )
        case "id3-demuxed-program":
            return (
                "Demuxed program audio carrying MPEG-2 TS ID3 timed metadata.",
                ["id3", "timed-metadata", "demuxed-audio"],
                "conformantControl",
                [],
                "Timed metadata should arrive through the independent audio rendition."
            )
        case "id3-hybrid-program-only":
            return (
                "Hybrid in-band program audio with ID3 metadata where alternate AD carries no metadata.",
                ["id3", "hybrid", "metadata-availability"],
                "stressCase",
                [],
                "Metadata availability should follow the active in-band program audio track."
            )
        case "id3-hybrid-equivalent":
            return (
                "Hybrid audio topology with matching logical ID3 schedules on both paths.",
                ["id3", "hybrid", "duplicate-suppression"],
                "conformantControl",
                [],
                "Switching between in-band program and alternate AD should not duplicate or lose callbacks."
            )
        case "id3-packed-audio-timestamp":
            return (
                "Packed-audio transport timestamp PRIV validation profile.",
                ["id3", "packed-audio", "timestamp-priv"],
                "conformantControl",
                [],
                "Packed-audio segment timestamps should match the first audio sample."
            )
        default:
            return ("Bundled deterministic HLS fixture.", [], nil, nil, nil)
        }
    }

    private static func profileVersion(from profileDirectory: URL) -> String? {
        let hashesURL = profileDirectory.appendingPathComponent("expected-hashes.json")
        guard let data = try? Data(contentsOf: hashesURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["profileVersion"] as? String
    }
}
