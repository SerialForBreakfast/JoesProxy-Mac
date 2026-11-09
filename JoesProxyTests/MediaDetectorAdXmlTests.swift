import XCTest
import zlib
@testable import JoesProxy

final class MediaDetectorAdXmlTests: XCTestCase {
    func testDetectsWebPBodyWhenContentTypeIsGeneric() throws {
        let session = imageSession(
            path: "/thumbnails/photos/w720-q70/ptv/series/5ec3040273354c001aa4e437/featured2_3_1780072922145.jpg?format=webp",
            contentType: "application/octet-stream",
            bodyData: Self.minimalWebPHeader()
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .image(mimeType: "image/webp"))
    }

    func testDetectedImageBodyWinsOverMismatchedImageContentType() throws {
        let session = imageSession(
            path: "/thumbnail.jpg?format=webp",
            contentType: "image/jpeg",
            bodyData: Self.minimalWebPHeader()
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .image(mimeType: "image/webp"))
    }

    func testEncodedBodyWithSpecificHeaderIsNotSniffed() throws {
        // Raw prefix of an encoded body is framing/compression bytes, not payload bytes.
        // A body whose raw prefix happens to look like JPEG magic must not be sniffed
        // when Content-Encoding is present and the header already classifies it.
        var jpegLookalike = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegLookalike.append(Data("garbage".utf8))

        let session = imageSession(
            path: "/api/data",
            contentType: "application/json",
            bodyData: jpegLookalike,
            extraHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), MediaType.none)
    }

    func testGzippedImageWithSpecificImageHeaderClassifiesFromHeader() throws {
        // Encoded + specific image header: classify from the header without decoding.
        let gzipped = try XCTUnwrap(Self.gzipCompress(Self.minimalWebPHeader()))
        let session = imageSession(
            path: "/photo.jpg",
            contentType: "image/jpeg",
            bodyData: gzipped,
            extraHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .image(mimeType: "image/jpeg"))
    }

    func testGzippedImageWithAmbiguousHeaderIsDecodedAndSniffed() throws {
        // Encoded + ambiguous header is the one case worth a decode.
        let gzipped = try XCTUnwrap(Self.gzipCompress(Self.minimalWebPHeader()))
        let session = imageSession(
            path: "/asset",
            contentType: "application/octet-stream",
            bodyData: gzipped,
            extraHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .image(mimeType: "image/webp"))
    }

    func testChunkedBodyIsNotRawSniffed() throws {
        // Chunked framing bytes must not be treated as payload magic bytes.
        var chunked = Data("4\r\n".utf8)
        chunked.append(Data([0xFF, 0xD8, 0xFF, 0xE0]))
        chunked.append(Data("\r\n0\r\n\r\n".utf8))

        let session = imageSession(
            path: "/api/stream",
            contentType: "application/json",
            bodyData: chunked,
            extraHeaders: [HTTPHeaderField(name: "Transfer-Encoding", value: "chunked")]
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), MediaType.none)
    }

    func testTunneledSessionWithoutBodyStaysNone() throws {
        let session = SessionRecord(
            request: CapturedRequest(
                method: "CONNECT",
                scheme: .https,
                inspectionKind: .tunneledTLS,
                host: "secure.example.com",
                port: 443,
                path: "secure.example.com:443",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), MediaType.none)
    }

    func testNonJSONContentTypeSkipsHLSDiscoveryParse() throws {
        // A JSON-shaped body labeled text/html must not be parsed for HLS discovery —
        // the gate exists so mediaType(for:) skips body decode + JSON parse for
        // clearly non-JSON responses.
        let discoveryShapedBody = Data(#"{"streamingUrl":"https://cdn.example.com/master.m3u8"}"#.utf8)
        let session = imageSession(
            path: "/page",
            contentType: "text/html",
            bodyData: discoveryShapedBody
        )

        XCTAssertNil(MediaDetector.hlsDiscovery(for: session))
        XCTAssertEqual(MediaDetector.mediaType(for: session), MediaType.none)
    }

    func testMissingContentTypeStillAttemptsHLSDiscoveryParse() throws {
        let discoveryShapedBody = Data(#"{"streamingUrl":"https://cdn.example.com/master.m3u8"}"#.utf8)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: "/playback",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: discoveryShapedBody,
                bodySize: discoveryShapedBody.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        XCTAssertNotNil(MediaDetector.hlsDiscovery(for: session))
    }

    func testDetectsCapturedVASTResponse() throws {
        let xml = "<VAST version=\"4.0\"><Ad><InLine></InLine></Ad></VAST>"
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "ads.example.com",
                port: 443,
                path: "/vast",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "text/xml")],
                bodyData: Data(xml.utf8),
                bodySize: xml.utf8.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        if case .adXml(let kind) = MediaDetector.mediaType(for: session) {
            XCTAssertEqual(kind, AdXmlKind.vast)
        } else {
            XCTFail("Expected adXml(.vast)")
        }
    }

    private func imageSession(
        path: String,
        contentType: String,
        bodyData: Data,
        extraHeaders: [HTTPHeaderField] = []
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "ads.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)] + extraHeaders,
                bodyData: bodyData,
                bodySize: bodyData.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }

    private static func minimalWebPHeader() -> Data {
        var bytes = Array("RIFF".utf8)
        bytes += [0x1A, 0x00, 0x00, 0x00]
        bytes += Array("WEBP".utf8)
        bytes += Array("VP8 ".utf8)
        bytes += [0x0E, 0x00, 0x00, 0x00]
        return Data(bytes)
    }

    private static func gzipCompress(_ data: Data) -> Data? {
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
