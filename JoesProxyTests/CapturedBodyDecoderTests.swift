import XCTest
import zlib
@testable import JoesProxy

final class CapturedBodyDecoderTests: XCTestCase {
    func testDecodesGzipJSONResponse() throws {
        let json = #"{"message":"hello-gzip"}"#.data(using: .utf8)!
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let headers = [
            HTTPHeaderField(name: "Content-Type", value: "application/json"),
            HTTPHeaderField(name: "Content-Encoding", value: "gzip")
        ]

        let result = try XCTUnwrap(CapturedBodyDecoder.decode(bodyData: gzipped, headers: headers))

        XCTAssertEqual(result.status, .decoded(appliedCodings: ["gzip"]))
        XCTAssertEqual(result.rawByteCount, gzipped.count)
        XCTAssertEqual(result.analysisByteCount, json.count)
        XCTAssertEqual(String(data: result.analysisData, encoding: .utf8), #"{"message":"hello-gzip"}"#)
    }

    func testContentEncodingHeaderIsCaseInsensitive() throws {
        let json = Data("ok".utf8)
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let headers = [HTTPHeaderField(name: "Content-Encoding", value: "GZIP")]

        let result = try XCTUnwrap(CapturedBodyDecoder.decode(bodyData: gzipped, headers: headers))

        if case .decoded(let codings) = result.status {
            XCTAssertEqual(codings, ["gzip"])
        } else {
            XCTFail("Expected decoded gzip, got \(result.status)")
        }
    }

    func testProtobufBodyThatHappensToBeUTF8ValidIsNotRenderedAsText() {
        // Bytes chosen to be valid UTF-8 (all ASCII-range) while representing a
        // realistic protobuf field-name fragment, matching the observed bug: a
        // clients3.google.com/cast/senderconfig response rendered as garbled text
        // ("enable_analytics(", "allow_ipv6(") because the accidental UTF-8 validity
        // of protobuf bytes bypassed any Content-Type check.
        let protobufLikeBytes = Data("enable_analytics(\u{01}\u{02}allow_ipv6(\u{03}".utf8)
        let headers = [HTTPHeaderField(name: "Content-Type", value: "application/x-protobuf")]

        let result = try? XCTUnwrap(CapturedBodyDecoder.decode(bodyData: protobufLikeBytes, headers: headers))

        XCTAssertEqual(result?.status, .unchanged)
        XCTAssertTrue(result?.isKnownBinaryContentType == true)
        XCTAssertNil(result?.analysisUTF8Text(), "Binary content types must never render as text, even if UTF-8-valid")
        XCTAssertFalse(result?.isAnalysisTextSearchable == true)
    }

    func testKnownBinaryContentTypesAreDetected() {
        let binaryTypes = [
            "application/x-protobuf",
            "application/protobuf",
            "application/vnd.google.protobuf",
            "application/grpc",
            "application/grpc+proto",
            "image/png",
            "video/mp4",
            "audio/mpeg",
            "font/woff2",
            "application/pdf",
            "application/zip",
            "application/wasm"
        ]
        for mime in binaryTypes {
            let headers = [HTTPHeaderField(name: "Content-Type", value: mime)]
            XCTAssertTrue(
                CapturedBodyDecoder.isKnownBinaryContentType(headers: headers),
                "\(mime) should be classified as binary"
            )
        }
    }

    /// Real-world HLS master/media playlists are frequently served with an `audio/`-prefixed
    /// Content-Type (RFC 8216 does not mandate one single type, and CDNs vary), which is plain
    /// UTF-8 M3U8 text, not binary audio. Found live 2026-08-07 capturing
    /// `test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`: the response's real `Content-Type:
    /// audio/mpegurl` matched the blanket `"audio/"` binary prefix, which forced
    /// `ResponseBodyRevision.completeness` to `.unsupportedEncoding` and made the entire generic
    /// response-edit/Map Local pipeline (the same one that shipped NOBLENDER/NOMEDY) refuse to
    /// treat the playlist as editable text — even though the bytes are ordinary UTF-8 M3U8.
    func testPlaylistManifestContentTypesAreNotTreatedAsBinaryDespiteAudioPrefix() {
        let playlistTypes = [
            "audio/mpegurl",
            "audio/x-mpegurl",
            "AUDIO/MPEGURL" // Content-Type matching is case-insensitive elsewhere in this decoder
        ]
        for mime in playlistTypes {
            let headers = [HTTPHeaderField(name: "Content-Type", value: mime)]
            XCTAssertFalse(
                CapturedBodyDecoder.isKnownBinaryContentType(headers: headers),
                "\(mime) is a text M3U8 playlist manifest, not binary audio, and must not be classified as binary"
            )
        }
    }

    func testAmbiguousAndTextContentTypesAreNotTreatedAsBinary() {
        let nonBinaryTypes = [
            "application/json",
            "application/xml",
            "text/plain",
            "text/html",
            "application/octet-stream", // deliberately ambiguous — see production comment
            "application/hal+json",
            "application/rss+xml"
        ]
        for mime in nonBinaryTypes {
            let headers = [HTTPHeaderField(name: "Content-Type", value: mime)]
            XCTAssertFalse(
                CapturedBodyDecoder.isKnownBinaryContentType(headers: headers),
                "\(mime) should not be classified as binary"
            )
        }

        XCTAssertFalse(CapturedBodyDecoder.isKnownBinaryContentType(headers: []))
    }

    func testMalformedGzipReturnsFailedStatusWithRawFallback() {
        let raw = Data([0x1f, 0x8b, 0x08, 0x00, 0x00])
        let headers = [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]

        let result = CapturedBodyDecoder.decode(bodyData: raw, headers: headers)

        XCTAssertEqual(result?.rawData, raw)
        XCTAssertEqual(result?.analysisData, raw)
        if case .failed = result?.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected failed decode status")
        }
    }

    func testMalformedGzipUTF8FallbackIsNotInspectableText() {
        let raw = Data("not actually gzipped".utf8)
        let headers = [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]

        let result = CapturedBodyDecoder.decode(bodyData: raw, headers: headers)

        XCTAssertFalse(result?.canUseAnalysisDataForInspection == true)
        XCTAssertNil(result?.analysisUTF8Text())
        XCTAssertFalse(result?.isAnalysisTextSearchable == true)
    }

    func testUnsupportedContentEncodingReturnsRawFallback() {
        let raw = Data("brotli bytes placeholder".utf8)
        let headers = [HTTPHeaderField(name: "Content-Encoding", value: "br")]

        let result = CapturedBodyDecoder.decode(bodyData: raw, headers: headers)

        XCTAssertEqual(result?.rawData, raw)
        XCTAssertEqual(result?.analysisData, raw)
        XCTAssertEqual(result?.status, .unsupported(coding: "br"))
        XCTAssertNil(result?.analysisUTF8Text())
        XCTAssertFalse(result?.isAnalysisTextSearchable == true)
    }

    func testGzipExpansionPastLimitReturnsLimitExceeded() throws {
        let json = Data(String(repeating: "a", count: 256).utf8)
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let headers = [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]

        let result = try XCTUnwrap(
            CapturedBodyDecoder.decode(bodyData: gzipped, headers: headers, maxDecodedBytes: 32)
        )

        if case .limitExceeded(let maxBytes) = result.status {
            XCTAssertEqual(maxBytes, 32)
        } else {
            XCTFail("Expected limitExceeded, got \(result.status)")
        }
        XCTAssertEqual(result.analysisData, gzipped)
        XCTAssertFalse(result.isAnalysisTextSearchable)
    }

    func testPlainJSONReturnsUnchangedBytes() {
        let json = #"{"plain":true}"#.data(using: .utf8)!
        let headers = [HTTPHeaderField(name: "Content-Type", value: "application/json")]

        let result = CapturedBodyDecoder.decode(bodyData: json, headers: headers)

        XCTAssertEqual(result?.status, .unchanged)
        XCTAssertEqual(result?.analysisData, json)
    }

    func testMalformedChunkedBodyDoesNotFeedGzipDecoder() throws {
        let json = Data(#"{"message":"chunked"}"#.utf8)
        let gzipped = try XCTUnwrap(gzipCompress(json))
        var malformedChunk = Data("3\r\n".utf8)
        malformedChunk.append(gzipped.prefix(3))
        malformedChunk.append(Data("xx0\r\n\r\n".utf8))
        let headers = [
            HTTPHeaderField(name: "Transfer-Encoding", value: "chunked"),
            HTTPHeaderField(name: "Content-Encoding", value: "gzip")
        ]

        let result = CapturedBodyDecoder.decode(bodyData: malformedChunk, headers: headers)

        XCTAssertEqual(result?.status, .failed(reason: "gzip payload is malformed or unsupported"))
        XCTAssertNil(result?.analysisUTF8Text())
    }

    func testGenericGzipJSONIsNotClassifiedAsMediaInfo() throws {
        let json = #"{"status":"ok"}"#.data(using: .utf8)!
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/config",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json"),
                    HTTPHeaderField(name: "Content-Encoding", value: "gzip")
                ],
                bodyData: gzipped,
                bodySize: gzipped.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .none)
        XCTAssertNil(MediaDetector.hlsDiscovery(for: session))
    }

    func testDecodedJSONIsInspectableText() throws {
        let json = #"{"needle":"value"}"#.data(using: .utf8)!
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let headers = [
            HTTPHeaderField(name: "Content-Type", value: "application/json"),
            HTTPHeaderField(name: "Content-Encoding", value: "gzip")
        ]

        let result = try XCTUnwrap(CapturedBodyDecoder.decode(bodyData: gzipped, headers: headers))
        let text = try XCTUnwrap(result.analysisUTF8Text())

        XCTAssertTrue(text.contains("needle"))
        XCTAssertFalse(text.contains("Binary body"))
        XCTAssertFalse(text.contains("Base64:"))
    }

    private func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.baseAddress)
            stream.avail_in = uInt(data.count)
        }

        let windowBits: Int32 = 15 + 16
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var output = Data()
        var deflateStatus: Int32

        repeat {
            stream.next_out = buffer
            stream.avail_out = uInt(chunkSize)
            deflateStatus = deflate(&stream, Z_FINISH)

            guard deflateStatus == Z_OK || deflateStatus == Z_STREAM_END else {
                return nil
            }

            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(buffer, count: produced)
            }
        } while deflateStatus != Z_STREAM_END

        return output
    }
}
