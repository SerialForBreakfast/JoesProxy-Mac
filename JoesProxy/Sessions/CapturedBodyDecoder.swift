import Foundation
import zlib

/// How stored capture bytes were transformed for analysis, search, and inspection.
enum CapturedBodyDecodeStatus: Equatable, Sendable {
    case unchanged
    case decoded(appliedCodings: [String])
    case unsupported(coding: String)
    case failed(reason: String)
    case limitExceeded(maxBytes: Int)
}

/// Result of decoding a captured body for display and search without mutating stored bytes.
struct CapturedBodyDecodeResult: Equatable, Sendable {
    let rawData: Data
    let analysisData: Data
    let appliedCodings: [String]
    let status: CapturedBodyDecodeStatus
    /// True when Content-Type unambiguously names a binary format (protobuf, images,
    /// zip, etc). Gates ``analysisUTF8Text()`` so binary bytes that happen to be valid
    /// UTF-8 (protobuf field names and varints frequently are) never render as garbled text.
    let isKnownBinaryContentType: Bool

    var rawByteCount: Int { rawData.count }
    var analysisByteCount: Int { analysisData.count }

    /// UTF-8 text when ``analysisData`` is valid text after decoding. Returns nil for
    /// known-binary content types even if the bytes happen to be UTF-8-valid by chance.
    func analysisUTF8Text() -> String? {
        guard canUseAnalysisDataForInspection, !isKnownBinaryContentType else { return nil }
        return String(data: analysisData, encoding: .utf8)
    }

    /// Whether ``analysisData`` represents usable decoded/raw content rather than a fallback.
    var canUseAnalysisDataForInspection: Bool {
        switch status {
        case .unchanged, .decoded:
            return true
        case .unsupported, .failed, .limitExceeded:
            return false
        }
    }

    /// Whether Find and similar tools should treat the response body as searchable text.
    var isAnalysisTextSearchable: Bool {
        canUseAnalysisDataForInspection && analysisUTF8Text() != nil
    }
}

/// Decodes stored HTTP bodies for inspection, Media Info, and Find while preserving raw capture bytes.
enum CapturedBodyDecoder {
    static let defaultMaxDecodedBytes = RecordingConstants.bodySizeLimit

    static func decode(
        bodyData: Data?,
        headers: [HTTPHeaderField],
        maxDecodedBytes: Int = defaultMaxDecodedBytes
    ) -> CapturedBodyDecodeResult? {
        guard let bodyData else {
            return nil
        }

        let isBinaryContentType = isKnownBinaryContentType(headers: headers)
        var payload = bodyData
        var appliedCodings: [String] = []

        if headers.contains(where: {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame &&
            $0.value.localizedCaseInsensitiveContains("chunked")
        }), let dechunked = dechunk(payload) {
            payload = dechunked
            appliedCodings.append("chunked")
        }

        let contentEncoding = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
        })?.value ?? ""

        let encodingTokens = contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for token in encodingTokens where token != "identity" {
            guard token == "gzip" || token == "x-gzip" else {
                return CapturedBodyDecodeResult(
                    rawData: bodyData,
                    analysisData: bodyData,
                    appliedCodings: appliedCodings,
                    status: .unsupported(coding: token),
                    isKnownBinaryContentType: isBinaryContentType
                )
            }
        }

        for token in encodingTokens.reversed() {
            if token == "gzip" || token == "x-gzip" {
                switch gunzip(payload, maxOutputBytes: maxDecodedBytes) {
                case .success(let decompressed):
                    payload = decompressed
                    appliedCodings.append("gzip")
                case .limitExceeded(let maxBytes):
                    return CapturedBodyDecodeResult(
                        rawData: bodyData,
                        analysisData: bodyData,
                        appliedCodings: appliedCodings,
                        status: .limitExceeded(maxBytes: maxBytes),
                        isKnownBinaryContentType: isBinaryContentType
                    )
                case .failure(let reason):
                    return CapturedBodyDecodeResult(
                        rawData: bodyData,
                        analysisData: bodyData,
                        appliedCodings: appliedCodings,
                        status: .failed(reason: reason),
                        isKnownBinaryContentType: isBinaryContentType
                    )
                }
            }
        }

        if appliedCodings.isEmpty {
            return CapturedBodyDecodeResult(
                rawData: bodyData,
                analysisData: payload,
                appliedCodings: [],
                status: .unchanged,
                isKnownBinaryContentType: isBinaryContentType
            )
        }

        return CapturedBodyDecodeResult(
            rawData: bodyData,
            analysisData: payload,
            appliedCodings: appliedCodings,
            status: .decoded(appliedCodings: appliedCodings),
            isKnownBinaryContentType: isBinaryContentType
        )
    }

    static func decode(response: CapturedResponse, maxDecodedBytes: Int = defaultMaxDecodedBytes) -> CapturedBodyDecodeResult? {
        guard !response.bodyDeferred, response.recordingBodyOmissionReason == nil else {
            return nil
        }
        return decode(bodyData: response.bodyData, headers: response.headers, maxDecodedBytes: maxDecodedBytes)
    }

    /// True when Content-Type unambiguously names a binary format. Deliberately narrow —
    /// only formats that are never legitimately text (protobuf, gRPC, images, archives,
    /// fonts) — so real text mislabeled with a loose type (e.g. `application/octet-stream`
    /// used for SSE) still gets a chance at UTF-8 rendering. `+json`/`+xml` suffixes always
    /// stay text-eligible regardless of the base type.
    static func isKnownBinaryContentType(headers: [HTTPHeaderField]) -> Bool {
        guard let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() else {
            return false
        }

        let mime = contentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? contentType

        if mime.hasSuffix("+json") || mime.hasSuffix("+xml") {
            return false
        }

        // M3U8 playlist manifests are plain UTF-8 text, but real servers/CDNs frequently label
        // them with an `audio/`-prefixed type (RFC 8216 does not mandate one canonical MIME
        // type) — found live 2026-08-07 capturing a real HLS master
        // (`test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`, `Content-Type: audio/mpegurl`), which the
        // blanket `audio/` binary-prefix rule below misclassified as binary, forcing
        // `ResponseBodyRevision.completeness` to `.unsupportedEncoding` and blocking the entire
        // generic response-edit/Map Local pipeline for an extremely common real-world case.
        if playlistManifestMIMETypes.contains(mime) {
            return false
        }

        if binaryMIMETypePrefixes.contains(where: mime.hasPrefix) {
            return true
        }

        return binaryMIMETypes.contains(mime)
    }

    private static let binaryMIMETypePrefixes = ["image/", "video/", "audio/", "font/"]

    /// M3U8 MIME types that would otherwise be misclassified as binary by
    /// ``binaryMIMETypePrefixes``'s `audio/` prefix. `application/vnd.apple.mpegurl` and
    /// `application/x-mpegurl` are unaffected (`application/` is never in the binary-prefix
    /// list) and are listed here only for readability/documentation, not because the prefix
    /// check would otherwise catch them.
    private static let playlistManifestMIMETypes: Set<String> = [
        "audio/mpegurl",
        "audio/x-mpegurl",
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl"
    ]

    private static let binaryMIMETypes: Set<String> = [
        // Deliberately excludes application/octet-stream: that type is used ambiguously
        // in the wild for both genuine binaries and mislabeled text (e.g. some SSE/event
        // streams), so it's left to fall through to the UTF-8 validity check as before.
        "application/pdf",
        "application/zip",
        "application/gzip",
        "application/x-gzip",
        "application/x-bzip2",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
        "application/x-tar",
        "application/wasm",
        "application/java-archive",
        "application/vnd.ms-fontobject",
        "application/x-protobuf",
        "application/protobuf",
        "application/vnd.google.protobuf",
        "application/grpc",
        "application/grpc+proto",
        "application/grpc-web",
        "application/grpc-web+proto"
    ]

    // MARK: - Private

    private enum GunzipOutcome {
        case success(Data)
        case failure(String)
        case limitExceeded(Int)
    }

    private static func dechunk(_ data: Data) -> Data? {
        var cursor = data.startIndex
        var output = Data()

        while cursor < data.endIndex {
            guard let lineEnd = data.range(
                of: Data("\r\n".utf8),
                in: cursor..<data.endIndex
            ) else {
                return nil
            }

            let sizeData = data[cursor..<lineEnd.lowerBound]
            guard let sizeString = String(data: sizeData, encoding: .utf8) else {
                return nil
            }

            let sizeToken = sizeString
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return nil
            }

            let chunkStart = lineEnd.upperBound
            let chunkEnd = chunkStart + chunkSize
            let terminatorEnd = chunkEnd + 2
            guard terminatorEnd <= data.endIndex else {
                return nil
            }
            guard data[chunkEnd..<terminatorEnd] == Data("\r\n".utf8) else {
                return nil
            }

            output.append(data[chunkStart..<chunkEnd])
            cursor = terminatorEnd

            if chunkSize == 0 {
                return output
            }
        }

        return output
    }

    private static func gunzip(_ data: Data, maxOutputBytes: Int) -> GunzipOutcome {
        guard !data.isEmpty else {
            return .success(Data())
        }

        var stream = z_stream()

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.baseAddress)
            stream.avail_in = uInt(data.count)
        }

        let windowBits: Int32 = 15 + 32
        let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            return .failure("gzip inflate could not start")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var output = Data()
        var inflateStatus: Int32

        repeat {
            stream.next_out = buffer
            stream.avail_out = uInt(chunkSize)
            inflateStatus = inflate(&stream, Z_NO_FLUSH)

            guard inflateStatus == Z_OK || inflateStatus == Z_STREAM_END else {
                return .failure("gzip payload is malformed or unsupported")
            }

            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                let nextSize = output.count + produced
                if nextSize > maxOutputBytes {
                    return .limitExceeded(maxOutputBytes)
                }
                output.append(buffer, count: produced)
            }
        } while inflateStatus != Z_STREAM_END

        return .success(output)
    }
}
