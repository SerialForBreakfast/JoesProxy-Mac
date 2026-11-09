//
//  MediaManifestCorrelation.swift
//  JoesProxy
//
//  Shared manifest-correlation models for HLS and DASH session matching.
//

import Foundation

enum MediaManifestReferenceKind: String, Sendable {
    case initSegment = "Init Segment Reference"
    case mediaSegment = "Media Segment Reference"
}

struct ManifestReferenceMatch: Sendable, Equatable {
    enum Strategy: String, Sendable {
        case exactURL = "Exact URL"
        case hostAndPath = "Host + Path"
        case templatePattern = "Template Pattern"
    }

    let manifestSessionID: UUID
    let manifestHost: String
    let manifestPath: String
    let matchedReference: String
    let strategy: Strategy
}

struct HLSManifestCorrelation: Sendable, Equatable {
    let referenceKind: MediaManifestReferenceKind
    let matches: [ManifestReferenceMatch]

    var manifestSessionIDs: [UUID] {
        matches.map(\.manifestSessionID)
    }

    var manifestHosts: [String] {
        Array(Set(matches.map(\.manifestHost))).sorted()
    }
}

struct DASHManifestCorrelation: Sendable, Equatable {
    let referenceKind: MediaManifestReferenceKind
    let matches: [ManifestReferenceMatch]

    var manifestSessionIDs: [UUID] {
        matches.map(\.manifestSessionID)
    }

    var manifestHosts: [String] {
        Array(Set(matches.map(\.manifestHost))).sorted()
    }
}
