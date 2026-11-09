import Foundation

enum HTTPResponseParserError: LocalizedError {
    case invalidEncoding
    case incompleteResponse
    case invalidChunkFraming
    case invalidStatusLine

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "The upstream HTTP response used an unsupported text encoding."
        case .incompleteResponse:
            return "The upstream HTTP response is incomplete."
        case .invalidChunkFraming:
            return "The upstream HTTP chunk framing is invalid."
        case .invalidStatusLine:
            return "The upstream HTTP status line is invalid."
        }
    }
}

struct HTTPProxyResponse: Sendable {
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let body: Data
}

struct HTTPResponseFrameState: Sendable {
    enum BodyFraming: Sendable {
        case empty
        case fixedLength(expectedTotalBytes: Int)
        case chunked(bodyOffset: Int)
        case closeDelimited
    }

    let statusCode: Int
    let headers: [HTTPHeaderField]
    let bodyOffset: Int
    let framing: BodyFraming
}

struct HTTPResponseParser: Sendable {
    private let headerDelimiter = Data("\r\n\r\n".utf8)

    func parseFrameState(from data: Data, requestMethod: String) -> HTTPResponseFrameState? {
        guard let metadata = try? parseMetadata(from: data) else {
            return nil
        }

        if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame {
            return HTTPResponseFrameState(
                statusCode: metadata.statusCode,
                headers: metadata.headers,
                bodyOffset: metadata.bodyOffset,
                framing: .empty
            )
        }

        switch metadata.statusCode {
        case 100..<200, 204, 304:
            return HTTPResponseFrameState(
                statusCode: metadata.statusCode,
                headers: metadata.headers,
                bodyOffset: metadata.bodyOffset,
                framing: .empty
            )
        default:
            break
        }

        if let transferEncoding = metadata.headers.first(where: {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
        })?.value,
           transferEncoding.localizedCaseInsensitiveContains("chunked") {
            return HTTPResponseFrameState(
                statusCode: metadata.statusCode,
                headers: metadata.headers,
                bodyOffset: metadata.bodyOffset,
                framing: .chunked(bodyOffset: metadata.bodyOffset)
            )
        }

        if let lengthHeader = metadata.headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame
        }) {
            guard let contentLength = Int(lengthHeader.value.trimmingCharacters(in: .whitespaces)),
                  contentLength >= 0, contentLength <= Int.max - metadata.bodyOffset else { return nil }
            return HTTPResponseFrameState(
                statusCode: metadata.statusCode,
                headers: metadata.headers,
                bodyOffset: metadata.bodyOffset,
                framing: .fixedLength(expectedTotalBytes: metadata.bodyOffset + contentLength)
            )
        }

        return HTTPResponseFrameState(
            statusCode: metadata.statusCode,
            headers: metadata.headers,
            bodyOffset: metadata.bodyOffset,
            framing: .closeDelimited
        )
    }

    func isComplete(dataCount: Int, bodyData: Data?, frameState: HTTPResponseFrameState) -> Bool {
        switch frameState.framing {
        case .empty:
            return true
        case .fixedLength(let expectedTotalBytes):
            return dataCount >= expectedTotalBytes
        case .chunked(let bodyOffset):
            guard let bodyData, bodyData.count >= bodyOffset else { return false }
            return hasCompleteChunkedBody(bodyData[bodyOffset...])
        case .closeDelimited:
            return false
        }
    }

    func isCompleteResponse(_ data: Data, requestMethod: String) -> Bool {
        let signpost = ProxyIOPerformanceSignposts.beginParseResponseChunk()
        defer { ProxyIOPerformanceSignposts.endParseResponseChunk(signpost) }

        guard let frameState = parseFrameState(from: data, requestMethod: requestMethod) else {
            return false
        }

        return isComplete(dataCount: data.count, bodyData: data, frameState: frameState)
    }

    func parse(_ data: Data) throws -> HTTPProxyResponse {
        let signpost = ProxyIOPerformanceSignposts.beginParseResponseChunk()
        defer { ProxyIOPerformanceSignposts.endParseResponseChunk(signpost) }

        let metadata = try parseMetadata(from: data)
        let rawBody = data.subdata(in: metadata.bodyOffset..<data.endIndex)

        let isChunked = metadata.headers.contains {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
            && $0.value.localizedCaseInsensitiveContains("chunked")
        }

        let body: Data
        let headers: [HTTPHeaderField]
        if isChunked {
            // Decode the chunk framing so captured body data is raw content.
            // Drop the Transfer-Encoding header since the stored body is no longer chunked.
            body = dechunkBody(rawBody) ?? rawBody
            headers = metadata.headers.filter {
                $0.name.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame
            }
        } else {
            body = rawBody
            headers = metadata.headers
        }

        return HTTPProxyResponse(
            statusCode: metadata.statusCode,
            headers: headers,
            body: body
        )
    }

    /// Strips HTTP/1.1 chunked-transfer framing and returns the concatenated chunk bodies.
    /// Returns `nil` if the data is malformed (caller falls back to the raw body).
    private func dechunkBody(_ data: Data) -> Data? {
        var result = Data()
        var index = data.startIndex

        while index < data.endIndex {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: index..<data.endIndex) else {
                return nil
            }

            let sizeSlice = data[index..<lineEnd.lowerBound]
            guard let sizeString = String(data: Data(sizeSlice), encoding: .utf8) else { return nil }

            // Chunk size may have an extension after ";"; ignore it.
            let sizeToken = sizeString
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let chunkSize = Int(sizeToken, radix: 16), chunkSize >= 0 else { return nil }

            // The terminal chunk has size 0; any trailing headers are ignored.
            if chunkSize == 0 { return result }

            let chunkStart = lineEnd.upperBound
            guard data.endIndex - chunkStart >= 2,
                  chunkSize <= data.endIndex - chunkStart - 2 else { return nil }
            let chunkEnd = chunkStart + chunkSize

            result.append(data[chunkStart..<chunkEnd])
            // Advance past the chunk data and its trailing \r\n.
            index = chunkEnd + 2
        }

        return result
    }

    private func parseMetadata(from data: Data) throws -> HTTPResponseMetadata {
        guard let headerRange = data.range(of: headerDelimiter) else {
            throw HTTPResponseParserError.incompleteResponse
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPResponseParserError.invalidEncoding
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTPResponseParserError.invalidStatusLine
        }
        lines.removeFirst()

        let components = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2, let statusCode = Int(components[1]) else {
            throw HTTPResponseParserError.invalidStatusLine
        }

        let headers = lines.compactMap { line -> HTTPHeaderField? in
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }

            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            return HTTPHeaderField(name: name, value: value)
        }

        return HTTPResponseMetadata(
            statusCode: statusCode,
            headers: headers,
            bodyOffset: headerRange.upperBound
        )
    }

    private func hasCompleteChunkedBody(_ body: Data.SubSequence) -> Bool {
        var validator = HTTPChunkedFramingValidator()
        validator.consume(body)
        return validator.isComplete
    }
}

private struct HTTPResponseMetadata: Sendable {
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let bodyOffset: Int
}
