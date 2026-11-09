//
//  DASHManifest.swift
//  JoesProxy
//
//  Parsed DASH MPD manifest metadata.
//

import Foundation

/// Parsed DASH MPD manifest.
struct DASHManifest: Sendable {
    let type: String?
    let mediaPresentationDuration: String?
    let baseURL: String?
    let periods: [DASHPeriod]
    let contentProtection: [DASHContentProtection]
}

/// DASH Period element.
struct DASHPeriod: Sendable {
    let start: String?
    let duration: String?
    let baseURL: String?
    let adaptationSets: [DASHAdaptationSet]
}

/// DASH AdaptationSet.
struct DASHAdaptationSet: Sendable {
    let id: String?
    let contentType: String?
    let lang: String?
    let mimeType: String?
    let codecs: String?
    let baseURL: String?
    let roles: [DASHDescriptor]
    let accessibility: [DASHDescriptor]
    let audioChannelConfigurations: [DASHAudioChannelConfiguration]
    let eventStreams: [DASHEventStream]
    let segmentTemplate: DASHSegmentTemplate?
    let representations: [DASHRepresentation]
}

/// DASH Representation.
struct DASHRepresentation: Sendable {
    let id: String?
    let mimeType: String?
    let codecs: String?
    let bandwidth: Int?
    let width: Int?
    let height: Int?
    let frameRate: String?
    let audioSamplingRate: Int?
    let baseURL: String?
    let segmentTemplate: DASHSegmentTemplate?
}

struct DASHSegmentTemplate: Sendable, Equatable {
    let initialization: String?
    let media: String?
    let timescale: Int?
    let duration: Int?
    let startNumber: Int?
}

/// ContentProtection descriptor.
struct DASHContentProtection: Sendable {
    let schemeIdUri: String
    let value: String?
    let defaultKid: String?
    let pssh: String?
}

struct DASHDescriptor: Sendable, Equatable {
    let schemeIdUri: String?
    let value: String?
}

struct DASHAudioChannelConfiguration: Sendable, Equatable {
    let schemeIdUri: String?
    let value: String?
}

struct DASHEventStream: Sendable, Equatable {
    let schemeIdUri: String?
    let value: String?
    let timescale: Int?
}
