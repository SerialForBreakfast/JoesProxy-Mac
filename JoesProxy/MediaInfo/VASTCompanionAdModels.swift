//
//  VASTCompanionAdModels.swift
//  JoesProxy
//
//  Domain models for VAST Companion Ads (Static, IFrame, and HTML resources).
//

import Foundation

/// Type of creative resource provided for a VAST companion ad.
enum VASTCompanionResourceType: String, Codable, Equatable, Sendable {
    case staticResource = "StaticResource"
    case iFrameResource = "IFrameResource"
    case htmlResource = "HTMLResource"
}

/// Creative resource payload for a companion ad.
enum VASTCompanionResource: Codable, Equatable, Sendable {
    case staticResource(mimeType: String, url: String)
    case iFrameResource(url: String)
    case htmlResource(content: String)

    var resourceType: VASTCompanionResourceType {
        switch self {
        case .staticResource:
            return .staticResource
        case .iFrameResource:
            return .iFrameResource
        case .htmlResource:
            return .htmlResource
        }
    }

    var displayString: String {
        switch self {
        case .staticResource(let mime, let url):
            return "[\(mime)] \(url)"
        case .iFrameResource(let url):
            return "[iFrame] \(url)"
        case .htmlResource(let content):
            return "[HTML] \(content.prefix(40))..."
        }
    }
}

/// Parsed VAST Companion Ad summary.
struct VASTCompanionAd: Identifiable, Codable, Equatable, Sendable {
    let id: String?
    let width: Int?
    let height: Int?
    let assetWidth: Int?
    let assetHeight: Int?
    let resource: VASTCompanionResource?
    let clickThroughURL: String?
    let clickTrackers: [String]
    let altText: String?

    var dimensionString: String {
        guard let w = width, let h = height else { return "Dynamic Size" }
        return "\(w)x\(h)"
    }
}
