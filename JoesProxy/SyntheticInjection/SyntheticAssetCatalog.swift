//
//  SyntheticAssetCatalog.swift
//  JoesProxy
//
//  Catalog of standard local synthetic media assets, test streams,
//  images, and ad payloads generated and hosted in-process by JoesProxy.
//

import Foundation

/// Type of local synthetic asset available for binding into wire payloads.
enum SyntheticAssetKind: String, Codable, Equatable, Sendable, CaseIterable {
    case clearLiveHLS = "Clear Live HLS Stream (Non-DRM)"
    case clearVODHLS = "Clear VOD HLS Stream"
    case testPatternImage = "Diagnostic Test Pattern Image (PNG)"
    case syntheticVASTAd = "Synthetic VAST 4.0 Ad XML"
    case customURL = "Custom Local URL"
}

/// A resolved synthetic asset with local loopback URL and description.
struct SyntheticAssetDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: SyntheticAssetKind
    var displayName: String
    var description: String
    var localURL: String
    var contentType: String
    var isDRMFree: Bool
}

/// In-process catalog provider for local synthetic test fixtures.
enum SyntheticAssetCatalog {

    /// Standard virtual host for device-reachable synthetic assets.
    static let defaultVirtualHost: String = SyntheticAssetOriginServer.defaultHost

    /// Standard port for JoesProxy loopback server.
    static let defaultProxyPort: Int = 9090

    /// Returns standard synthetic assets with device-reachable virtual host URLs.
    static func availableAssets(
        host: String = defaultVirtualHost,
        scheme: String = "https"
    ) -> [SyntheticAssetDescriptor] {
        [
            SyntheticAssetDescriptor(
                id: "clear_live_hls",
                kind: .clearLiveHLS,
                displayName: "Clear Live HLS Stream (Non-DRM)",
                description: "Live rolling non-DRM HLS stream with multi-rendition fMP4/TS segments and clean timestamps for player playback.",
                localURL: "\(scheme)://\(host)/fixtures/hls/clear_live_profile.m3u8",
                contentType: "application/vnd.apple.mpegurl",
                isDRMFree: true
            ),
            SyntheticAssetDescriptor(
                id: "clear_vod_hls",
                kind: .clearVODHLS,
                displayName: "Clear VOD HLS Stream",
                description: "Static VOD HLS playlist with SCTE-35 ad break markers for player testing.",
                localURL: "\(scheme)://\(host)/fixtures/hls/clear_vod_scte35.m3u8",
                contentType: "application/vnd.apple.mpegurl",
                isDRMFree: true
            ),
            SyntheticAssetDescriptor(
                id: "test_pattern_image",
                kind: .testPatternImage,
                displayName: "Diagnostic Test Pattern Image",
                description: "High-contrast color bars and resolution grid image for poster and artwork testing.",
                localURL: "\(scheme)://\(host)/fixtures/images/test_pattern.png",
                contentType: "image/png",
                isDRMFree: true
            ),
            SyntheticAssetDescriptor(
                id: "synthetic_vast_ad",
                kind: .syntheticVASTAd,
                displayName: "Synthetic VAST 4.0 Ad XML",
                description: "Standard VAST 4.0 linear video ad response with valid tracking events and non-DRM media file.",
                localURL: "\(scheme)://\(host)/fixtures/ads/vast_linear_sample.xml",
                contentType: "application/xml",
                isDRMFree: true
            )
        ]
    }
}
