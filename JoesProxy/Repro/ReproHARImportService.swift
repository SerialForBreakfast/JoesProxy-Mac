import Foundation

struct ReproHARImportResult: Sendable {
    let sessions: [SessionRecord]
    let skippedEntryCount: Int
}

enum ReproHARImportError: LocalizedError {
    case fileNotFound(URL)
    case fileTooLarge(Int)
    case malformedHAR(Error)
    case entryLimitExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "HAR file not found: \(url.lastPathComponent)"
        case .fileTooLarge(let count):
            return "The HAR file is too large to import safely (\(count) bytes)."
        case .malformedHAR(let error):
            return "The HAR file could not be read: \(error.localizedDescription)"
        case .entryLimitExceeded(let count):
            return "The HAR contains \(count) entries, exceeding the supported limit."
        }
    }
}

struct ReproHARImportService: Sendable {
    static let maximumEntryCount = ReproPackageEngine.maximumSessionCount
    static let maximumFileByteCount = ReproPackageEngine.maximumFileByteCount

    func open(from url: URL) async throws -> ReproHARImportResult {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ReproHARImportError.fileNotFound(url)
            }
            let data = try Data(contentsOf: url)
            return try decode(data: data)
        }.value
    }

    func decode(data: Data) throws -> ReproHARImportResult {
        guard data.count <= Self.maximumFileByteCount else {
            throw ReproHARImportError.fileTooLarge(data.count)
        }
        let root: HARImportRoot
        do {
            root = try JSONDecoder().decode(HARImportRoot.self, from: data)
        } catch {
            throw ReproHARImportError.malformedHAR(error)
        }
        guard root.log.entries.count <= Self.maximumEntryCount else {
            throw ReproHARImportError.entryLimitExceeded(root.log.entries.count)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var sessions: [SessionRecord] = []
        var skipped = 0
        sessions.reserveCapacity(root.log.entries.count)

        for entry in root.log.entries {
            guard let session = session(from: entry, formatter: formatter) else {
                skipped += 1
                continue
            }
            sessions.append(session)
        }
        return ReproHARImportResult(sessions: sessions, skippedEntryCount: skipped)
    }

    private func session(from entry: HARImportEntry, formatter: ISO8601DateFormatter) -> SessionRecord? {
        guard let components = URLComponents(string: entry.request.url),
              let schemeValue = components.scheme?.lowercased(),
              let scheme = SessionScheme(rawValue: schemeValue),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        let port = components.port ?? (scheme == .https ? 443 : 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }
        let startedAt = formatter.date(from: entry.startedDateTime) ?? Date(timeIntervalSince1970: 0)
        let duration = max(0, entry.time) / 1_000
        let requestBody = decodedBody(text: entry.request.postData?.text, encoding: nil)
        let responseBody = decodedBody(text: entry.response.content.text, encoding: entry.response.content.encoding)
        let request = CapturedRequest(
            method: entry.request.method,
            scheme: scheme,
            inspectionKind: scheme == .https ? .interceptedTLS : .plain,
            host: host,
            port: port,
            path: path,
            headers: entry.request.headers.map { HTTPHeaderField(name: $0.name, value: $0.value) },
            bodyData: requestBody,
            bodySize: entry.request.bodySize >= 0 ? entry.request.bodySize : requestBody?.count
        )
        let response = CapturedResponse(
            statusCode: entry.response.status,
            headers: entry.response.headers.map { HTTPHeaderField(name: $0.name, value: $0.value) },
            bodyData: responseBody,
            bodySize: entry.response.bodySize >= 0 ? entry.response.bodySize : responseBody?.count
        )
        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(duration))
        )
    }

    private func decodedBody(text: String?, encoding: String?) -> Data? {
        guard let text else { return nil }
        if encoding?.lowercased() == "base64" {
            return Data(base64Encoded: text)
        }
        return Data(text.utf8)
    }
}

private struct HARImportRoot: Decodable {
    let log: HARImportLog
}

private struct HARImportLog: Decodable {
    let entries: [HARImportEntry]
}

private struct HARImportEntry: Decodable {
    let startedDateTime: String
    let time: Double
    let request: HARImportRequest
    let response: HARImportResponse
}

private struct HARImportRequest: Decodable {
    let method: String
    let url: String
    let headers: [HARImportHeader]
    let postData: HARImportPostData?
    let bodySize: Int

    private enum CodingKeys: String, CodingKey {
        case method, url, headers, postData, bodySize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        headers = (try? container.decode([HARImportHeader].self, forKey: .headers)) ?? []
        postData = try container.decodeIfPresent(HARImportPostData.self, forKey: .postData)
        bodySize = (try? container.decode(Int.self, forKey: .bodySize)) ?? -1
    }
}

private struct HARImportResponse: Decodable {
    let status: Int
    let headers: [HARImportHeader]
    let content: HARImportContent
    let bodySize: Int

    private enum CodingKeys: String, CodingKey {
        case status, headers, content, bodySize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)
        headers = (try? container.decode([HARImportHeader].self, forKey: .headers)) ?? []
        content = (try? container.decode(HARImportContent.self, forKey: .content)) ?? HARImportContent()
        bodySize = (try? container.decode(Int.self, forKey: .bodySize)) ?? -1
    }
}

private struct HARImportHeader: Decodable {
    let name: String
    let value: String
}

private struct HARImportPostData: Decodable {
    let text: String?
}

private struct HARImportContent: Decodable {
    let text: String?
    let encoding: String?

    init(text: String? = nil, encoding: String? = nil) {
        self.text = text
        self.encoding = encoding
    }
}

