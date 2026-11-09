//
//  HARExportService.swift
//  JoesProxy
//
//  Exports captured sessions to HAR 1.2 format for interoperability with
//  browser DevTools, Proxyman, mitmproxy, and other HTTP inspection tools.
//

import Foundation

/// HAR 1.2 log structure per the HTTP Archive specification.
private struct HARLog: Codable {
    let version: String
    let creator: HARCreator
    let entries: [HAREntry]
    let comment: String?

    init(creator: HARCreator, entries: [HAREntry], comment: String? = nil) {
        self.version = "1.2"
        self.creator = creator
        self.entries = entries
        self.comment = comment
    }
}

private struct HARCreator: Codable {
    let name: String
    let version: String
    let comment: String?
}

private struct HAREntry: Codable {
    let startedDateTime: String
    let time: Double
    let request: HARRequest
    let response: HARResponse
    let cache: HARCache
    let timings: HARTimings
    let comment: String?
}

private struct HARRequest: Codable {
    let method: String
    let url: String
    let httpVersion: String
    let cookies: [HARCookie]
    let headers: [HARHeader]
    let queryString: [HARQueryParam]
    let postData: HARPostData?
    let headersSize: Int
    let bodySize: Int
    let comment: String?
}

private struct HARResponse: Codable {
    let status: Int
    let statusText: String
    let httpVersion: String
    let cookies: [HARCookie]
    let headers: [HARHeader]
    let content: HARContent
    let redirectURL: String
    let headersSize: Int
    let bodySize: Int
    let comment: String?
}

private struct HARHeader: Codable {
    let name: String
    let value: String
    let comment: String?
}

private struct HARCookie: Codable {
    let name: String
    let value: String
    let path: String?
    let domain: String?
    let expires: String?
    let httpOnly: Bool?
    let secure: Bool?
    let comment: String?
}

private struct HARQueryParam: Codable {
    let name: String
    let value: String
    let comment: String?
}

private struct HARPostData: Codable {
    let mimeType: String
    let text: String?
    let params: [HARPostParam]?
    let comment: String?
}

private struct HARPostParam: Codable {
    let name: String
    let value: String?
    let fileName: String?
    let contentType: String?
    let comment: String?
}

private struct HARContent: Codable {
    let size: Int
    let compression: Int?
    let mimeType: String
    let text: String?
    let encoding: String?
    let comment: String?
}

private struct HARCache: Codable {
    let beforeRequest: HARCacheEntry?
    let afterRequest: HARCacheEntry?
    let comment: String?
}

private struct HARCacheEntry: Codable {
    let expires: String?
    let lastAccess: String?
    let eTag: String?
    let hitCount: Int?
    let comment: String?
}

private struct HARTimings: Codable {
    let blocked: Double
    let dns: Double
    let connect: Double
    let send: Double
    let wait: Double
    let receive: Double
    let ssl: Double
    let comment: String?
}

/// Exports captured sessions to HAR 1.2 format.
final class HARSessionExportService: ExportService {
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter

    init(encoder: JSONEncoder = JSONEncoder(), dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()) {
        // Compact output: pretty-printing inflated HAR files 30-50% with no interop benefit.
        // sortedKeys is kept for deterministic output.
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.dateFormatter = dateFormatter
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func export(_ envelope: SessionExportEnvelope, to destinationURL: URL) throws {
        try harData(envelope).write(to: destinationURL, options: .atomic)
    }

    /// In-memory HAR 1.2 JSON, for callers that don't want a file on disk (e.g. the
    /// `sessions_export` MCP tool, which returns the content as tool result text instead).
    func harData(_ envelope: SessionExportEnvelope) throws -> Data {
        let signpost = CapturePerformanceSignposts.signposter.beginInterval(
            "HARSessionExportService.export",
            "\(envelope.sessions.count) sessions"
        )
        defer { CapturePerformanceSignposts.signposter.endInterval("HARSessionExportService.export", signpost) }

        let creator = HARCreator(
            name: "JoesProxy",
            version: envelope.appVersion,
            comment: nil
        )

        let entries = envelope.sessions
            .filter { !CaptureMarkerConstants.isMarkerRecord($0) }
            .sorted { $0.timing.startedAt < $1.timing.startedAt }
            .map { harEntry(from: $0) }

        let log = HARLog(
            creator: creator,
            entries: entries,
            comment: "Exported from JoesProxy proxy port \(envelope.proxyPort)"
        )

        let harRoot = ["log": log]
        return try encoder.encode(harRoot)
    }

    private func harEntry(from session: SessionRecord) -> HAREntry {
        let durationMs = (session.timing.duration ?? 0) * 1000
        let startedDateTime = dateFormatter.string(from: session.timing.startedAt)

        let request = harRequest(from: session.request)
        let response = harResponse(from: session.response, scheme: session.request.scheme)
        let cache = HARCache(beforeRequest: nil, afterRequest: nil, comment: nil)
        let timings = HARTimings(
            blocked: -1,
            dns: -1,
            connect: -1,
            send: 0,
            wait: max(0, durationMs),
            receive: 0,
            ssl: session.request.scheme == .https ? -1 : -1,
            comment: nil
        )

        return HAREntry(
            startedDateTime: startedDateTime,
            time: max(0, durationMs),
            request: request,
            response: response,
            cache: cache,
            timings: timings,
            comment: nil
        )
    }

    private func harRequest(from request: CapturedRequest) -> HARRequest {
        let url = buildAbsoluteURL(scheme: request.scheme, host: request.host, port: request.port, path: request.path)
        let queryString = parseQueryString(from: request.path)

        let headers = request.headers.map { HARHeader(name: $0.name, value: $0.value, comment: nil) }
        let bodySize = request.bodySize ?? request.bodyData?.count ?? -1
        let headersSize = estimateHeadersSize(method: request.method, path: request.path, headers: request.headers)

        let postData: HARPostData?
        if let bodyData = request.bodyData, !bodyData.isEmpty {
            postData = harPostData(from: bodyData)
        } else {
            postData = nil
        }

        return HARRequest(
            method: request.method,
            url: url,
            httpVersion: "HTTP/1.1",
            cookies: [],
            headers: headers,
            queryString: queryString,
            postData: postData,
            headersSize: headersSize,
            bodySize: bodySize >= 0 ? bodySize : -1,
            comment: bodyEvidenceComment(data: request.bodyData, size: request.bodySize,
                                         truncated: request.bodyTruncated,
                                         omission: request.recordingBodyOmissionReason)
        )
    }

    private func harResponse(from response: CapturedResponse?, scheme: SessionScheme) -> HARResponse {
        guard let response else {
            return HARResponse(
                status: 0,
                statusText: "",
                httpVersion: "HTTP/1.1",
                cookies: [],
                headers: [],
                content: HARContent(size: 0, compression: nil, mimeType: "", text: nil, encoding: nil, comment: nil),
                redirectURL: "",
                headersSize: -1,
                bodySize: -1,
                comment: nil
            )
        }

        let headers = response.headers.map { HARHeader(name: $0.name, value: $0.value, comment: nil) }
        let content = harContent(from: response.bodyData, headers: response.headers)
        let bodySize = response.bodySize ?? response.bodyData?.count ?? -1
        let headersSize = estimateResponseHeadersSize(statusCode: response.statusCode, headers: response.headers)
        let redirectURL = response.headers.first { $0.name.lowercased() == "location" }?.value ?? ""

        return HARResponse(
            status: response.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            httpVersion: "HTTP/1.1",
            cookies: [],
            headers: headers,
            content: content,
            redirectURL: redirectURL,
            headersSize: headersSize,
            bodySize: bodySize >= 0 ? bodySize : -1,
            comment: bodyEvidenceComment(data: response.bodyData, size: response.bodySize,
                                         truncated: response.bodyTruncated,
                                         omission: response.recordingBodyOmissionReason)
        )
    }

    private func bodyEvidenceComment(
        data: Data?, size: Int?, truncated: Bool, omission: RecordingBodyOmissionReason?
    ) -> String? {
        var evidence: [String] = []
        if truncated { evidence.append("Body was truncated; exported bytes are incomplete.") }
        if let omission { evidence.append(omission.userFacingMessage) }
        if data == nil, let size, size > 0 {
            evidence.append("Body unavailable: 0 of \(size) observed bytes exported.")
        }
        return evidence.isEmpty ? nil : evidence.joined(separator: " ")
    }

    private func harPostData(from bodyData: Data) -> HARPostData {
        // Cheap size check first — the all-ASCII scan is O(n) and only needed for large bodies.
        if let text = String(data: bodyData, encoding: .utf8), bodyData.count < 1024 * 1024 || text.allSatisfy(\.isASCII) {
            return HARPostData(
                mimeType: "application/octet-stream",
                text: text,
                params: nil,
                comment: nil
            )
        }
        return HARPostData(
            mimeType: "application/octet-stream",
            text: bodyData.base64EncodedString(),
            params: nil,
            comment: nil
        )
    }

    private func harContent(from bodyData: Data?, headers: [HTTPHeaderField]) -> HARContent {
        let mimeType = headers.first { $0.name.lowercased() == "content-type" }?.value ?? "application/octet-stream"
        let size = bodyData?.count ?? 0

        guard let bodyData, !bodyData.isEmpty else {
            return HARContent(size: size, compression: nil, mimeType: mimeType, text: nil, encoding: nil, comment: nil)
        }

        if let text = String(data: bodyData, encoding: .utf8), isValidUTF8Text(bodyData) {
            return HARContent(size: size, compression: nil, mimeType: mimeType, text: text, encoding: nil, comment: nil)
        }
        return HARContent(
            size: size,
            compression: nil,
            mimeType: mimeType,
            text: bodyData.base64EncodedString(),
            encoding: "base64",
            comment: nil
        )
    }

    private func isValidUTF8Text(_ data: Data) -> Bool {
        guard let _ = String(data: data, encoding: .utf8) else { return false }
        return data.count < 10 * 1024 * 1024
    }

    private func buildAbsoluteURL(scheme: SessionScheme, host: String, port: Int?, path: String) -> String {
        let schemeStr = scheme == .https ? "https" : "http"
        let portPart: String
        if let port, (scheme == .http && port != 80) || (scheme == .https && port != 443) {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        let pathPart = path.hasPrefix("/") ? path : "/\(path)"
        return "\(schemeStr)://\(host)\(portPart)\(pathPart)"
    }

    private func parseQueryString(from path: String) -> [HARQueryParam] {
        guard let idx = path.firstIndex(of: "?") else {
            return []
        }
        let queryStart = path.index(after: idx)
        guard queryStart < path.endIndex else { return [] }
        let query = String(path[queryStart...])
        return query.split(separator: "&").compactMap { pair -> HARQueryParam? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first else { return nil }
            let value = parts.count > 1 ? String(parts[1]) : ""
            return HARQueryParam(name: String(name), value: value, comment: nil)
        }
    }

    private func estimateHeadersSize(method: String, path: String, headers: [HTTPHeaderField]) -> Int {
        var count = "\(method) \(path) HTTP/1.1\r\n".utf8.count
        for h in headers {
            count += "\(h.name): \(h.value)\r\n".utf8.count
        }
        count += 2
        return count
    }

    private func estimateResponseHeadersSize(statusCode: Int, headers: [HTTPHeaderField]) -> Int {
        var count = "HTTP/1.1 \(statusCode) \r\n".utf8.count
        for h in headers {
            count += "\(h.name): \(h.value)\r\n".utf8.count
        }
        count += 2
        return count
    }
}
