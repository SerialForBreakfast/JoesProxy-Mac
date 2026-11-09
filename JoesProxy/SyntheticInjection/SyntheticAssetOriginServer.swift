//
//  SyntheticAssetOriginServer.swift
//  JoesProxy
//
//  In-process HTTP/HTTPS responder for virtual synthetic assets (*.joesproxy.invalid)
//  enabling physical client devices on LAN to reach synthetic test fixtures.
//

import Foundation

struct SyntheticAssetResponse: Sendable {
    var statusCode: Int
    var headers: [HTTPHeaderField]
    var bodyData: Data

    init(statusCode: Int = 200, headers: [HTTPHeaderField], bodyData: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyData = bodyData
    }
}

final class SyntheticAssetOriginServer: Sendable {
    static let shared = SyntheticAssetOriginServer()

    static let defaultHost = "assets.joesproxy.invalid"
    static let authoredRevisionPathPrefix = "/mock-revisions/"
    static let syntheticHostSuffix = ".synthetic.joesproxy.invalid"

    private let testPatternPNG: Data
    private let vastAdXML: Data
    private let clearVodM3U8: Data

    init() {
        // Generate high-contrast 1x1 test pattern PNG if not bundled
        self.testPatternPNG = SyntheticAssetOriginServer.generateTestPatternPNG()
        self.vastAdXML = SyntheticAssetOriginServer.generateVASTSampleXML()
        self.clearVodM3U8 = SyntheticAssetOriginServer.generateClearVODM3U8()
    }

    /// Checks if a hostname belongs to the in-process synthetic asset origin.
    static func isSyntheticHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == defaultHost || h == "synthetic.joesproxy.invalid" || h.hasSuffix(syntheticHostSuffix)
    }

    /// Generates response for a requested synthetic asset.
    func response(for request: CapturedRequest) -> SyntheticAssetResponse? {
        let path = request.path.lowercased()
        // Authored assets are owned and scoped by effect-bundle Map Local rules, not built-in fixtures.
        if path.hasPrefix(Self.authoredRevisionPathPrefix) { return nil }

        if path.contains("test_pattern.png") || path.hasSuffix(".png") {
            return makeResponse(
                body: testPatternPNG,
                contentType: "image/png"
            )
        }

        if path.contains("vast_linear_sample.xml") || path.hasSuffix(".xml") {
            return makeResponse(
                body: vastAdXML,
                contentType: "application/xml; charset=utf-8"
            )
        }

        if path.contains("clear_vod_scte35.m3u8") || path.contains("clear_vod") {
            return makeResponse(
                body: clearVodM3U8,
                contentType: "application/vnd.apple.mpegurl"
            )
        }

        if path.contains("clear_live_profile.m3u8") || path.contains("clear_live") {
            let livePlaylist = generateLiveSlidingPlaylist()
            return makeResponse(
                body: livePlaylist,
                contentType: "application/vnd.apple.mpegurl"
            )
        }

        // Generic fallback for any segment or resource
        if path.hasSuffix(".ts") || path.hasSuffix(".m4s") || path.hasSuffix(".mp4") {
            let dummyMedia = Data(repeating: 0x00, count: 188 * 4) // 4 MPEG-TS packets
            return makeResponse(
                body: dummyMedia,
                contentType: "video/mp2t"
            )
        }

        return nil
    }

    private func makeResponse(body: Data, contentType: String) -> SyntheticAssetResponse {
        let headers = [
            HTTPHeaderField(name: "Content-Type", value: contentType),
            HTTPHeaderField(name: "Content-Length", value: String(body.count)),
            HTTPHeaderField(name: "Access-Control-Allow-Origin", value: "*"),
            HTTPHeaderField(name: "Access-Control-Allow-Methods", value: "GET, HEAD, OPTIONS"),
            HTTPHeaderField(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        ]
        return SyntheticAssetResponse(statusCode: 200, headers: headers, bodyData: body)
    }

    private func generateLiveSlidingPlaylist() -> Data {
        let sequence = Int(Date().timeIntervalSince1970 / 6.0)
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:\(sequence)
        #EXTINF:6.0,
        https://\(Self.defaultHost)/fixtures/hls/segment_\(sequence).ts
        #EXTINF:6.0,
        https://\(Self.defaultHost)/fixtures/hls/segment_\(sequence + 1).ts
        #EXTINF:6.0,
        https://\(Self.defaultHost)/fixtures/hls/segment_\(sequence + 2).ts
        """
        return text.data(using: .utf8) ?? Data()
    }

    private static func generateClearVODM3U8() -> Data {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:6.0,
        https://\(defaultHost)/fixtures/hls/vod_seg_0.ts
        #EXTINF:6.0,
        https://\(defaultHost)/fixtures/hls/vod_seg_1.ts
        #EXT-X-CUE-OUT:DURATION=30.0
        #EXTINF:6.0,
        https://\(defaultHost)/fixtures/hls/vod_seg_2.ts
        #EXT-X-CUE-IN
        #EXTINF:6.0,
        https://\(defaultHost)/fixtures/hls/vod_seg_3.ts
        #EXT-X-ENDLIST
        """
        return text.data(using: .utf8) ?? Data()
    }

    private static func generateVASTSampleXML() -> Data {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="4.0">
          <Ad id="synthetic-ad-1">
            <InLine>
              <AdSystem>JoesProxy Synthetic</AdSystem>
              <AdTitle>Synthetic Linear Test Ad</AdTitle>
              <Creatives>
                <Creative id="creative-1">
                  <Linear>
                    <Duration>00:00:15</Duration>
                    <MediaFiles>
                      <MediaFile delivery="progressive" type="video/mp4" width="1920" height="1080">
                        https://\(defaultHost)/fixtures/media/ad_linear.mp4
                      </MediaFile>
                    </MediaFiles>
                  </Linear>
                </Creative>
              </Creatives>
            </InLine>
          </Ad>
        </VAST>
        """
        return text.data(using: .utf8) ?? Data()
    }

    private static func generateTestPatternPNG() -> Data {
        // 1x1 base64 PNG fallback
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64) ?? Data()
    }
}
