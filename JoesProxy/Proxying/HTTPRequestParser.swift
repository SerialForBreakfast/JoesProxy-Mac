import Foundation

enum HTTPRequestParserError: LocalizedError, Equatable {
    case invalidEncoding
    case incompleteRequest
    case invalidRequestLine
    case unsupportedMethod(String)
    case unsupportedTarget(String)
    case missingHostHeader

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "The HTTP request used an unsupported text encoding."
        case .incompleteRequest:
            return "The HTTP request is incomplete."
        case .invalidRequestLine:
            return "The HTTP request line is invalid."
        case .unsupportedMethod(let method):
            return "The HTTP method '\(method)' is not supported."
        case .unsupportedTarget(let target):
            return "The HTTP target '\(target)' is not supported."
        case .missingHostHeader:
            return "The HTTP request is missing a Host header."
        }
    }
}

struct HTTPProxyRequest: Sendable {
    enum Kind: Equatable, Sendable {
        case standard
        case connect
    }

    let kind: Kind
    let method: String
    let version: String
    let host: String
    let port: Int
    let path: String
    let headers: [HTTPHeaderField]
    let body: Data
    /// For spooled uploads, body contains only the governed capture prefix.
    var bodySpool: UploadBodySpool? = nil
    var originalBodySize: Int? = nil

    func capturedBody(using limiter: CaptureBodyLimiter) -> CapturedBody {
        let retained = limiter.retainedBody(from: body)
        guard let originalBodySize else { return retained }
        return CapturedBody(data: retained.data, size: originalBodySize,
                            truncated: originalBodySize > (retained.data?.count ?? 0))
    }
}

struct ParsedHTTPProxyRequest: Sendable {
    let request: HTTPProxyRequest
    let consumedLength: Int
}

struct HTTPRequestParser: Sendable {
    private let headerDelimiter = Data("\r\n\r\n".utf8)

    func isCompleteRequest(_ data: Data) -> Bool {
        isCompleteRequestAnalysis(data).isComplete
    }

    func isCompleteRequestAnalysis(_ data: Data) -> HTTPRequestCompletionAnalysis {
        guard let headerRange = data.range(of: headerDelimiter) else {
            return HTTPRequestCompletionAnalysis(
                isComplete: false,
                reason: "Missing header delimiter",
                contentLength: nil,
                expectedLength: nil
            )
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return HTTPRequestCompletionAnalysis(
                isComplete: false,
                reason: "Header bytes are not valid UTF-8",
                contentLength: nil,
                expectedLength: nil
            )
        }

        let contentLength = parseHeaderFields(from: headerString)
            .first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0

        let headerLength = data.distance(from: data.startIndex, to: headerRange.upperBound)
        let expectedLength = headerLength + contentLength
        return HTTPRequestCompletionAnalysis(
            isComplete: data.count >= expectedLength,
            reason: data.count >= expectedLength
                ? "Complete request frame"
                : "Body bytes missing",
            contentLength: contentLength,
            expectedLength: expectedLength
        )
    }

    func parse(_ data: Data) throws -> HTTPProxyRequest {
        try parseRequestFrame(data).request
    }

    func parseRequestFrame(_ data: Data) throws -> ParsedHTTPProxyRequest {
        try parseRequestFrame(data, headOnly: false)
    }

    func parseRequestHead(_ data: Data) throws -> ParsedHTTPProxyRequest {
        try parseRequestFrame(data, headOnly: true)
    }

    private func parseRequestFrame(_ data: Data, headOnly: Bool) throws -> ParsedHTTPProxyRequest {
        let signpost = ProxyIOPerformanceSignposts.beginParseRequest()
        defer { ProxyIOPerformanceSignposts.endParseRequest(signpost) }

        guard let headerRange = data.range(of: headerDelimiter) else {
            throw HTTPRequestParserError.incompleteRequest
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPRequestParserError.invalidEncoding
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestParserError.invalidRequestLine
        }
        lines.removeFirst()

        let components = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 3 else {
            throw HTTPRequestParserError.invalidRequestLine
        }

        let method = String(components[0]).uppercased()
        let target = String(components[1])
        let version = String(components[2])

        let headers = parseHeaderFields(from: lines.joined(separator: "\r\n"))
        let targetComponents: (kind: HTTPProxyRequest.Kind, host: String, port: Int, path: String)
        if method == "CONNECT" {
            targetComponents = try resolveConnectTarget(target: target)
        } else {
            let resolved = try resolveTarget(target: target, headers: headers)
            targetComponents = (.standard, resolved.host, resolved.port, resolved.path)
        }

        let contentLength = headers
            .first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        let headerLength = data.distance(from: data.startIndex, to: headerRange.upperBound)
        let (consumedLength, overflow) = headerLength.addingReportingOverflow(contentLength)
        guard contentLength >= 0, !overflow else { throw HTTPRequestParserError.invalidRequestLine }

        guard headOnly || data.count >= consumedLength else {
            throw HTTPRequestParserError.incompleteRequest
        }

        let bodyEndIndex = data.index(headerRange.upperBound, offsetBy: headOnly ? 0 : contentLength)
        let body = data.subdata(in: headerRange.upperBound..<bodyEndIndex)

        return ParsedHTTPProxyRequest(
            request: HTTPProxyRequest(
                kind: targetComponents.kind,
                method: method,
                version: version,
                host: targetComponents.host,
                port: targetComponents.port,
                path: targetComponents.path,
                headers: headers,
                body: body
            ),
            consumedLength: headOnly ? headerLength : consumedLength
        )
    }

    private func resolveTarget(target: String, headers: [HTTPHeaderField]) throws -> (host: String, port: Int, path: String) {
        if let urlComponents = URLComponents(string: target), let host = urlComponents.host {
            let port = urlComponents.port ?? 80
            let path = makePath(from: urlComponents)
            return (host, port, path)
        }

        guard target.hasPrefix("/") else {
            throw HTTPRequestParserError.unsupportedTarget(target)
        }

        guard let hostHeader = headers.first(where: { $0.name.caseInsensitiveCompare("Host") == .orderedSame }) else {
            throw HTTPRequestParserError.missingHostHeader
        }

        let hostComponents = hostHeader.value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let host = String(hostComponents[0])
        let port = hostComponents.count == 2 ? Int(hostComponents[1]) ?? 80 : 80
        return (host, port, target)
    }

    private func resolveConnectTarget(target: String) throws -> (kind: HTTPProxyRequest.Kind, host: String, port: Int, path: String) {
        let components = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard let hostComponent = components.first, !hostComponent.isEmpty else {
            throw HTTPRequestParserError.unsupportedTarget(target)
        }

        let host = String(hostComponent)
        let port = components.count == 2 ? Int(components[1]) ?? 443 : 443
        return (.connect, host, port, target)
    }

    private func makePath(from components: URLComponents) -> String {
        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }

        return path
    }

    private func parseHeaderFields(from headerString: String) -> [HTTPHeaderField] {
        headerString
            .components(separatedBy: "\r\n")
            .compactMap { line in
                guard let separator = line.firstIndex(of: ":") else {
                    return nil
                }

                let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                return HTTPHeaderField(name: name, value: value)
            }
    }
}

struct HTTPRequestCompletionAnalysis: Sendable {
    let isComplete: Bool
    let reason: String
    let contentLength: Int?
    let expectedLength: Int?
}
