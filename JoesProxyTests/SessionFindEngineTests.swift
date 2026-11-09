import XCTest
import zlib
@testable import JoesProxy

final class SessionFindEngineTests: XCTestCase {
    private let engine = SessionFindEngine()

    func testMatchesRequestBodyText() {
        let session = makeRecord(requestBody: "token=abc123")

        let outcome = engine.find(in: [session], query: "abc123")

        XCTAssertEqual(outcome.results.map(\.sessionID), [session.id])
        XCTAssertEqual(outcome.results.map(\.location), [.requestBody])
        XCTAssertEqual(outcome.results.first?.matchCount, 1)
    }

    func testMatchesResponseBodyText() {
        let session = makeRecord(responseBody: "{\"message\":\"needle\"}")

        let outcome = engine.find(in: [session], query: "needle")

        XCTAssertEqual(outcome.results.map(\.sessionID), [session.id])
        XCTAssertEqual(outcome.results.map(\.location), [.responseBody])
    }

    func testSkipsRequestBodyWithKnownBinaryContentTypeEvenIfUTF8Valid() {
        // Bytes are valid UTF-8 (so a naive decode would "succeed") but the request is
        // labeled protobuf — Find must not search accidentally-UTF8-valid binary bytes.
        let session = makeRecord(
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/x-protobuf")],
            requestBodyData: Data("needle_field_name(".utf8)
        )

        let outcome = engine.find(in: [session], query: "needle")

        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testMatchesTextInsideGzipJSONResponseBody() throws {
        let json = #"{"token":"gzip-needle-token"}"#.data(using: .utf8)!
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let session = makeRecord(
            responseBodyData: gzipped,
            responseHeaders: [
                HTTPHeaderField(name: "Content-Type", value: "application/json"),
                HTTPHeaderField(name: "Content-Encoding", value: "gzip")
            ]
        )

        let outcome = engine.find(in: [session], query: "gzip-needle-token")

        XCTAssertEqual(outcome.results.map(\.location), [.responseBody])
        XCTAssertEqual(outcome.decodedBodyTexts[session.id]?.responseText?.contains("gzip-needle-token"), true)
    }

    func testSkipsGzipResponseWhenDecodeLimitExceeded() throws {
        let json = Data(String(repeating: "z", count: 2_000_000).utf8)
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let session = makeRecord(
            responseBodyData: gzipped,
            responseHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )

        let decodeResult = try XCTUnwrap(
            CapturedBodyDecoder.decode(bodyData: gzipped, headers: session.response!.headers)
        )
        if case .limitExceeded = decodeResult.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected limitExceeded, got \(decodeResult.status)")
        }

        let outcome = engine.find(in: [session], query: "zzz")
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.decodedBodyTexts[session.id]?.responseBodySearchWasEvaluated, true)
        XCTAssertNil(outcome.decodedBodyTexts[session.id]?.responseText)
    }

    func testCachedUnsearchableGzipResponseIsNotDecodedAgain() throws {
        let json = Data(String(repeating: "z", count: 2_000_000).utf8)
        let gzipped = try XCTUnwrap(gzipCompress(json))
        let session = makeRecord(
            responseBodyData: gzipped,
            responseHeaders: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
        )
        let cache = [
            session.id: SessionBodyText(
                requestText: nil,
                responseText: nil,
                responseBodySearchWasEvaluated: true
            )
        ]

        let outcome = engine.find(in: [session], query: "zzz", bodyTextCache: cache)

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertTrue(outcome.decodedBodyTexts.isEmpty)
    }

    func testReturnsRequestAndResponseMatchesSeparately() {
        let session = makeRecord(requestBody: "shared-token", responseBody: "shared-token again")

        let outcome = engine.find(in: [session], query: "shared-token")

        XCTAssertEqual(outcome.results.map(\.location), [.requestBody, .responseBody])
    }

    func testSearchIsCaseInsensitive() {
        let session = makeRecord(requestBody: "Authorization: Bearer SecretToken")

        let outcome = engine.find(in: [session], query: "secrettoken")

        XCTAssertEqual(outcome.results.map(\.location), [.requestBody])
    }

    func testIgnoresHeadersHostAndPath() {
        let session = makeRecord(
            host: "needle.example.com",
            path: "/needle",
            headers: [HTTPHeaderField(name: "X-Needle", value: "needle")]
        )

        let outcome = engine.find(in: [session], query: "needle")

        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testSkipsNilDeferredOmittedAndNonUTF8Bodies() {
        let nilBody = makeRecord()
        let deferredBody = makeRecord(requestBody: "needle", requestBodyDeferred: true)
        let omittedBody = makeRecord(requestBody: "needle", requestOmissionReason: .metadataOnly)
        let nonUTF8Body = makeRecord(requestBodyData: Data([0xff, 0xfe, 0xfd]))
        let responseDeferred = makeRecord(responseBody: "needle", responseBodyDeferred: true)
        let responseOmitted = makeRecord(responseBody: "needle", responseOmissionReason: .metadataOnly)
        let responseNonUTF8 = makeRecord(responseBodyData: Data([0xff, 0xfe, 0xfd]))

        let outcome = engine.find(
            in: [
                nilBody,
                deferredBody,
                omittedBody,
                nonUTF8Body,
                responseDeferred,
                responseOmitted,
                responseNonUTF8
            ],
            query: "needle"
        )

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.searchedBodyCount, 0)
    }

    func testPreservesInputOrder() {
        let first = makeRecord(host: "first.example.com", requestBody: "needle")
        let second = makeRecord(host: "second.example.com", requestBody: "needle")
        let third = makeRecord(host: "third.example.com", responseBody: "needle")

        let outcome = engine.find(in: [first, second, third], query: "needle")

        XCTAssertEqual(outcome.results.map(\.sessionID), [first.id, second.id, third.id])
    }

    func testEmptyQueryReturnsNoResults() {
        let session = makeRecord(requestBody: "needle")

        let outcome = engine.find(in: [session], query: "   ")

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.searchedBodyCount, 0)
    }

    private func makeRecord(
        host: String = "api.example.com",
        path: String = "/v1/login",
        headers: [HTTPHeaderField] = [],
        requestBody: String? = nil,
        requestBodyData: Data? = nil,
        requestBodyDeferred: Bool = false,
        requestOmissionReason: RecordingBodyOmissionReason? = nil,
        responseBody: String? = nil,
        responseBodyData: Data? = nil,
        responseHeaders: [HTTPHeaderField] = [],
        responseBodyDeferred: Bool = false,
        responseOmissionReason: RecordingBodyOmissionReason? = nil
    ) -> SessionRecord {
        let requestData = requestBodyData ?? requestBody?.data(using: .utf8)
        let responseData = responseBodyData ?? responseBody?.data(using: .utf8)
        let startedAt = Date()

        return SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: host,
                port: 443,
                path: path,
                headers: headers,
                bodyData: requestData,
                bodySize: requestData?.count,
                recordingBodyOmissionReason: requestOmissionReason,
                bodyDeferred: requestBodyDeferred
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: responseHeaders,
                bodyData: responseData,
                bodySize: responseData?.count,
                recordingBodyOmissionReason: responseOmissionReason,
                bodyDeferred: responseBodyDeferred
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.1))
        )
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
        guard deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
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
