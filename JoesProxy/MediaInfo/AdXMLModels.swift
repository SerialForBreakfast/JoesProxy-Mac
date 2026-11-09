//
//  AdXMLModels.swift
//  JoesProxy
//
//  Summary models for captured VAST/VMAP XML inspection in Media Info.
//

import Foundation

/// Classifies captured ad-related XML documents.
enum AdXmlKind: String, Equatable, Sendable {
    case vast
    case vmap
    case unknownXml
}

struct VASTMediaFileSummary: Sendable, Equatable, Identifiable {
    let id: String
    let delivery: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let urlRedacted: String?
}

struct VASTCreativeSummary: Sendable, Equatable, Identifiable {
    let id: String
    let adID: String?
    let sequence: Int?
    let durationSeconds: Double?
    let mediaFiles: [VASTMediaFileSummary]
    let companionCount: Int
    let companions: [VASTCompanionAd]
}

struct VASTAdSummary: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case inline
        case wrapper
    }

    let id: String
    let kind: Kind
    let wrapperURLRedacted: String?
    let creatives: [VASTCreativeSummary]
}

/// Parsed summary of a captured VAST document.
struct VASTSummary: Sendable, Equatable {
    let version: String?
    let ads: [VASTAdSummary]
    let impressionURLCount: Int
    let clickTrackingURLCount: Int
    let maxWrapperDepth: Int
}

struct VMAPAdBreakSummary: Sendable, Equatable, Identifiable {
    let id: String
    let timeOffset: String?
    let breakID: String?
    let breakType: String?
    let adSourceURI: String?
    let vastAdCount: Int
}

/// Parsed summary of a captured VMAP document.
struct VMAPSummary: Sendable, Equatable {
    let version: String?
    let adBreaks: [VMAPAdBreakSummary]
}
