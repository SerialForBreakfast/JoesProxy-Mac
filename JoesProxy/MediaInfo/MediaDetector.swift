//
//  MediaDetector.swift
//  JoesProxy
//
//  Detects media type from session request/response for Media Info panel.
//

import Foundation

struct HLSStreamDiscovery: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case content
        case ad
        case live
        case unknown
    }

    let manifestURL: URL
    let kind: Kind
    let manifestFormat: String?
    let contentID: String?
    let daiCMSID: String?
    let drmLicenseURL: URL?
    let timeEventsURL: URL?
}

enum MediaDetector {

    private static let imageMimePrefix = "image/"
    private static let videoMimePrefix = "video/"
    private static let hlsMimeTypes = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]
    private static let dashMimeType = "application/dash+xml"
    private static let hlsPathExtensions = ["m3u8", "m3u"]
    private static let dashPathExtension = "mpd"
    private static let videoPathExtensions = ["mp4", "m4v", "m4s", "mov", "ts"]

    /// Returns the media type for the session, or .none if not media.
    static func mediaType(for session: SessionRecord) -> MediaType {
        if let response = session.response {
            if let type = detectFromResponse(response, request: session.request, lightweight: false) {
                return type
            }
        }
        if hlsDiscovery(for: session) != nil {
            return .hlsDiscovery
        }
        if let type = detectFromRequest(session.request) {
            return type
        }
        return .none
    }

    /// Lightweight media classification for list rendering.
    /// Avoids response body decoding so the main traffic table stays responsive.
    static func listMediaType(for session: SessionRecord) -> MediaType {
        if let response = session.response,
           let type = detectFromResponse(response, request: session.request, lightweight: true) {
            return type
        }

        if isLikelyHLSDiscoveryRequest(session) {
            return .hlsDiscovery
        }

        if let type = detectFromRequest(session.request) {
            return type
        }

        return .none
    }

    static func hlsDiscovery(for session: SessionRecord) -> HLSStreamDiscovery? {
        guard let response = session.response,
              isPlausibleJSONResponse(response),
              let payload = decodedResponseBody(for: response),
              let jsonObject = try? JSONSerialization.jsonObject(with: payload) else {
            return nil
        }

        return parseHLSDiscovery(from: jsonObject, request: session.request)
    }

    /// Discovery payloads are JSON APIs. Gating on the header lets `mediaType(for:)` skip
    /// a body decode + full JSON parse for XML/HTML/CSS/image/etc. responses; unlabeled
    /// and generic content types still get the parse attempt.
    private static func isPlausibleJSONResponse(_ response: CapturedResponse) -> Bool {
        guard let contentType = response.headers.first(where: {
            $0.name.lowercased() == "content-type"
        })?.value.lowercased() else {
            return true
        }

        let mime = contentType.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? contentType
        return mime.contains("json") || isAmbiguousMIMEType(mime)
    }

    static func primaryMediaURL(for session: SessionRecord) -> URL? {
        if let discovery = hlsDiscovery(for: session) {
            return discovery.manifestURL
        }

        return absoluteURL(for: session.request)
    }

    /// Returns response bytes decoded for JSON/media analysis; raw capture bytes are unchanged in storage.
    static func decodedResponseBody(for response: CapturedResponse) -> Data? {
        guard let decoded = CapturedBodyDecoder.decode(response: response) else {
            return nil
        }

        switch decoded.status {
        case .unsupported, .failed, .limitExceeded:
            return nil
        case .unchanged, .decoded:
            return decoded.analysisData
        }
    }

    private static func detectFromResponse(
        _ response: CapturedResponse,
        request: CapturedRequest,
        lightweight: Bool
    ) -> MediaType? {
        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased()
        let mimeType = contentType?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)

        if !lightweight,
           let detectedImageMIMEType = sniffedImageMIMEType(from: response, headerMIMEType: mimeType) {
            return .image(mimeType: detectedImageMIMEType)
        }

        if let mime = mimeType {
            if mime.hasPrefix(imageMimePrefix) {
                return .image(mimeType: mime)
            }
            if mime.hasPrefix(videoMimePrefix) {
                return .video(mimeType: mime)
            }
            if hlsMimeTypes.contains(mime) {
                return .hls
            }
            if mime == dashMimeType {
                return .dash
            }
        }

        if let manifestType = sniffedManifestType(from: response, lightweight: lightweight) {
            return manifestType
        }

        if let type = detectAdXml(from: response, request: request, lightweight: lightweight) {
            return type
        }

        return nil
    }

    /// Magic-byte image detection that corrects mislabeled Content-Type headers
    /// (e.g. WebP served as image/jpeg) without paying a body decode on well-labeled
    /// responses. Raw bytes are sniffed directly when the body carries no transfer or
    /// content codings; an encoded body is only decoded when the header can't classify it.
    private static func sniffedImageMIMEType(
        from response: CapturedResponse,
        headerMIMEType: String?
    ) -> String? {
        guard let bodyData = response.bodyData,
              !bodyData.isEmpty,
              !response.bodyDeferred,
              response.recordingBodyOmissionReason == nil else {
            return nil
        }

        if !hasBodyCodings(response.headers) {
            return detectImageMIMEType(from: bodyData)
        }

        // Encoded body: the raw prefix is chunk framing or compression magic, not image
        // bytes. Trust a specific header; decode only when it can't classify the body.
        guard isAmbiguousMIMEType(headerMIMEType) else {
            return nil
        }
        guard let decoded = decodedResponseBody(for: response) else {
            return nil
        }
        return detectImageMIMEType(from: decoded)
    }

    /// Mirrors CapturedBodyDecoder's coding detection: chunked transfer framing or any
    /// non-identity content coding means raw bytes are not the payload bytes.
    private static func hasBodyCodings(_ headers: [HTTPHeaderField]) -> Bool {
        if headers.contains(where: {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame &&
            $0.value.localizedCaseInsensitiveContains("chunked")
        }) {
            return true
        }

        guard let contentEncoding = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
        })?.value else {
            return false
        }

        return contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { !$0.isEmpty && $0 != "identity" }
    }

    private static func isAmbiguousMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType, !mimeType.isEmpty else { return true }
        return mimeType == "application/octet-stream" || mimeType == "text/plain"
    }

    private static func detectImageMIMEType(from data: Data) -> String? {
        guard data.count >= 4 else { return nil }

        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0...3].elementsEqual(Array("RIFF".utf8)),
           bytes[8...11].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        if bytes.starts(with: Array("BM".utf8)) {
            return "image/bmp"
        }
        if bytes.count >= 12,
           bytes[4...7].elementsEqual(Array("ftyp".utf8)),
           bytes[8...11].elementsEqual(Array("avif".utf8)) {
            return "image/avif"
        }

        return nil
    }

    private static func detectAdXml(
        from response: CapturedResponse,
        request: CapturedRequest,
        lightweight: Bool
    ) -> MediaType? {
        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased()
        let mimeType = contentType?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)

        guard isXmlMimeType(mimeType) || isXmlPathExtension(request) else {
            return nil
        }

        if lightweight {
            return .adXml(.unknownXml)
        }

        guard let bodyData = decodedResponseBody(for: response),
              let xml = String(data: bodyData, encoding: .utf8) else {
            return .adXml(.unknownXml)
        }

        return .adXml(AdXMLParser.classifyKind(in: xml))
    }

    private static func isXmlMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType, !mimeType.isEmpty else { return false }
        if mimeType == "text/xml" || mimeType == "application/xml" {
            return true
        }
        return mimeType.hasSuffix("+xml")
    }

    private static func isXmlPathExtension(_ request: CapturedRequest) -> Bool {
        let path = request.path.lowercased()
        return path.hasSuffix(".xml") || path.contains("vast") || path.contains("vmap")
    }

    private static func detectFromRequest(_ request: CapturedRequest) -> MediaType? {
        let pathLower = normalizedPath(request.path)
        if hlsPathExtensions.contains(where: { pathLower.hasSuffix(".\($0)") }) {
            return .hls
        }
        if pathLower.hasSuffix(".\(dashPathExtension)") {
            return .dash
        }
        if videoPathExtensions.contains(where: { pathLower.hasSuffix(".\($0)") }) {
            return .video(mimeType: "application/octet-stream")
        }
        return nil
    }

    private static func normalizedPath(_ requestTarget: String) -> String {
        let withoutFragment = requestTarget.split(separator: "#", maxSplits: 1).first.map(String.init) ?? requestTarget
        return (withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment).lowercased()
    }

    /// Bounded manifest sniffing corrects missing/generic Content-Type values without parsing a
    /// complete body. List rendering only inspects raw, unencoded prefixes; full inspection may
    /// decode an encoded response through the shared bounded decoder.
    private static func sniffedManifestType(from response: CapturedResponse, lightweight: Bool) -> MediaType? {
        guard !response.bodyDeferred, response.recordingBodyOmissionReason == nil else { return nil }
        let data: Data?
        if hasBodyCodings(response.headers) {
            data = lightweight ? nil : decodedResponseBody(for: response)
        } else {
            data = response.bodyData
        }
        guard let data, !data.isEmpty else { return nil }
        let prefix = data.prefix(4_096)
        let text = String(decoding: prefix, as: UTF8.self)
        let normalized = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#EXTM3U") {
            return .hls
        }
        if normalized.hasPrefix("<MPD")
            || normalized.hasPrefix("<?xml") && normalized.prefix(1_024).contains("<MPD") {
            return .dash
        }
        return nil
    }

    private static func isLikelyHLSDiscoveryRequest(_ session: SessionRecord) -> Bool {
        guard let response = session.response else {
            return false
        }

        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard contentType.contains("application/json") else {
            return false
        }

        let host = session.request.host.lowercased()
        let path = session.request.path.lowercased()

        if host.contains("irdeto-control") && path.contains("session-token") {
            return true
        }

        return false
    }

    /// Builds an absolute URL from the request for AVAsset or manifest resolution.
    static func absoluteURL(for request: CapturedRequest) -> URL? {
        let scheme = request.scheme == .https ? "https" : "http"
        let host = request.host
        let portPart: String
        if let p = request.port, (request.scheme == .http && p != 80) || (request.scheme == .https && p != 443) {
            portPart = ":\(p)"
        } else {
            portPart = ""
        }
        let path = request.path.hasPrefix("/") ? request.path : "/\(request.path)"
        let urlString = "\(scheme)://\(host)\(portPart)\(path)"
        return URL(string: urlString)
    }

    private static func parseHLSDiscovery(
        from jsonObject: Any,
        request: CapturedRequest
    ) -> HLSStreamDiscovery? {
        let manifestURLString = firstString(
            forKeys: ["streamingUrl", "playback_url", "stream_manifest"],
            in: jsonObject
        )

        guard let manifestURLString,
              let manifestURL = URL(string: manifestURLString),
              manifestURL.pathExtension.lowercased() == "m3u8" else {
            return nil
        }

        let drmLicenseURL = firstString(forKeys: ["url"], in: jsonObject)
            .flatMap(URL.init(string:))
        let timeEventsURL = firstString(forKeys: ["time_events_url"], in: jsonObject)
            .flatMap(URL.init(string:))
        let manifestFormat = firstString(forKeys: ["manifest_format"], in: jsonObject)
        let contentID = firstString(forKeys: ["contentId", "ContentId", "content_id"], in: jsonObject) ??
            queryValue(forKeys: ["ContentId", "contentId", "content_id"], in: drmLicenseURL)
        let daiCMSID = firstString(forKeys: ["daiCmsId"], in: jsonObject)

        let lowercasedHost = manifestURL.host?.lowercased() ?? ""
        let kind: HLSStreamDiscovery.Kind
        if MediaHostSignals.isAdServingHost(lowercasedHost)
            || MediaHostSignals.isAdServingHost(request.host) {
            kind = .ad
        } else if MediaHostSignals.indicatesLivePlayback(manifestURL) {
            kind = .live
        } else if contentID != nil || daiCMSID != nil {
            kind = .content
        } else {
            kind = .unknown
        }

        return HLSStreamDiscovery(
            manifestURL: manifestURL,
            kind: kind,
            manifestFormat: manifestFormat,
            contentID: contentID,
            daiCMSID: daiCMSID,
            drmLicenseURL: drmLicenseURL,
            timeEventsURL: timeEventsURL
        )
    }

    private static func firstString(forKeys keys: [String], in object: Any) -> String? {
        for key in keys {
            if let value = firstString(forKey: key, in: object) {
                return value
            }
        }
        return nil
    }

    private static func queryValue(forKeys keys: [String], in url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        for key in keys {
            if let value = components.queryItems?.first(where: { $0.name == key })?.value {
                return value
            }
        }

        return nil
    }

    private static func firstString(forKey key: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? String {
                return value
            }

            for child in dictionary.values {
                if let value = firstString(forKey: key, in: child) {
                    return value
                }
            }
        } else if let array = object as? [Any] {
            for child in array {
                if let value = firstString(forKey: key, in: child) {
                    return value
                }
            }
        }

        return nil
    }

}
