//
//  MediaType.swift
//  JoesProxy
//
//  Media type classification for session response inspection.
//

import Foundation

/// Classifies captured session responses as media for the Media Info panel.
enum MediaType: Equatable, Sendable {
    case image(mimeType: String)
    case hls
    case hlsDiscovery
    case dash
    case video(mimeType: String)
    case adXml(AdXmlKind)
    case none
}

/// Shared media-analysis facets. Inspector presentation chooses how to display these facets, but
/// their availability is also needed by non-visual analysis and must not live in an Inspector view.
enum MediaInfoTab: String, CaseIterable {
    case image
    case avAsset
    case hls
    case dash
    case waterfall
    case adXml
    case timedMetadata

    var title: String {
        switch self {
        case .image: return "Image"
        case .avAsset: return "AVAsset"
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .waterfall: return "Waterfall"
        case .adXml: return "Ad XML"
        case .timedMetadata: return "ID3"
        }
    }

    func isAvailable(for session: SessionRecord) -> Bool {
        let type = MediaDetector.mediaType(for: session)
        switch self {
        case .image: return type.isImage
        case .avAsset: return type.isVideoOrStream
        case .hls: return type == .hls || type == .hlsDiscovery
        case .dash: return type == .dash
        case .waterfall: return type.isVideoOrStream || type == .hls || type == .hlsDiscovery || type == .dash
        case .adXml: return type.isAdXml
        case .timedMetadata:
            if case .video = type { return true }
            return false
        }
    }
}

extension MediaType {
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    var isAdXml: Bool {
        if case .adXml = self { return true }
        return false
    }

    var isVideoOrStream: Bool {
        switch self {
        case .hls, .hlsDiscovery, .dash, .video: return true
        default: return false
        }
    }
}
