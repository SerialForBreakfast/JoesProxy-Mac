import XCTest
import zlib
@testable import JoesProxy

final class LiveResponseTransformationTests: XCTestCase {
    private let jsonBody = #"{"name":"alice","score":10}"#.data(using: .utf8)!

    // MARK: - Eligibility

    func testEvaluateEligibilityRejectsHEAD() {
        let reason = LiveResponseTransformation.evaluateEligibility(
            requestMethod: "HEAD",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))]
        )
        XCTAssertEqual(reason, .ineligibleRequestMethod("HEAD"))
    }

    func testEvaluateEligibilityRejectsInformationalAndNoContentStatuses() {
        for statusCode in [102, 204, 304] {
            let reason = LiveResponseTransformation.evaluateEligibility(
                requestMethod: "GET",
                statusCode: statusCode,
                headers: jsonHeaders(),
                bodyData: Data(),
                mutations: [setMutation(locator: "name", value: .string("bob"))]
            )
            XCTAssertEqual(reason, .ineligibleStatusCode(statusCode))
        }
    }

    func testEvaluateEligibilityRejectsUnsupportedContentEncoding() {
        var headers = jsonHeaders()
        headers.append(HTTPHeaderField(name: "Content-Encoding", value: "br"))

        let reason = LiveResponseTransformation.evaluateEligibility(
            requestMethod: "GET",
            statusCode: 200,
            headers: headers,
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))]
        )
        XCTAssertEqual(reason, .unsupportedContentEncoding("br"))
    }

    func testEvaluateEligibilityRejectsOversizedEncodedBody() {
        let policy = LiveResponseTransformationPolicy(maxEncodedBodyBytes: 8, maxDecodedBodyBytes: 1_048_576, maxOutputGrowthBytes: 1_048_576)
        let reason = LiveResponseTransformation.evaluateEligibility(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))],
            policy: policy
        )
        XCTAssertEqual(reason, .encodedBodyTooLarge(actualBytes: jsonBody.count, limitBytes: 8))
    }

    func testEvaluateEligibilityAcceptsIdentityAndGzip() {
        XCTAssertEqual(
            LiveResponseTransformation.evaluateEligibility(
                requestMethod: "GET",
                statusCode: 200,
                headers: jsonHeaders(),
                bodyData: jsonBody,
                mutations: [setMutation(locator: "name", value: .string("bob"))]
            ),
            .eligible
        )

        var gzipHeaders = jsonHeaders()
        gzipHeaders.append(HTTPHeaderField(name: "Content-Encoding", value: "gzip"))
        XCTAssertEqual(
            LiveResponseTransformation.evaluateEligibility(
                requestMethod: "GET",
                statusCode: 200,
                headers: gzipHeaders,
                bodyData: try XCTUnwrap(gzipCompress(jsonBody)),
                mutations: [setMutation(locator: "name", value: .string("bob"))]
            ),
            .eligible
        )
    }

    func testEvaluateEligibilityRejectsEmptyMutations() {
        XCTAssertEqual(
            LiveResponseTransformation.evaluateEligibility(
                requestMethod: "GET",
                statusCode: 200,
                headers: jsonHeaders(),
                bodyData: jsonBody,
                mutations: []
            ),
            .emptyMutations
        )
    }

    // MARK: - Identity transform

    func testTransformAppliesSetMutationOnIdentityBody() throws {
        let headers = validatorHeaders()
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: headers,
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))]
        )

        XCTAssertTrue(result.wasTransformed)
        XCTAssertFalse(result.matchedButNotApplied)
        XCTAssertEqual(result.appliedMutationIDs.count, 1)
        XCTAssertEqual(result.skippedMutationIDs, [])
        XCTAssertEqual(result.originalBodyByteCount, jsonBody.count)

        let object = try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "bob")
        XCTAssertEqual(object?["score"] as? Int, 10)

        XCTAssertNil(headerValue(named: "ETag", in: result.headers))
        XCTAssertNil(headerValue(named: "Last-Modified", in: result.headers))
        XCTAssertNil(headerValue(named: "Content-MD5", in: result.headers))
        XCTAssertNil(headerValue(named: "Digest", in: result.headers))
        XCTAssertEqual(headerValue(named: "Content-Length", in: result.headers), String(result.bodyData.count))
        XCTAssertNil(headerValue(named: "Content-Encoding", in: result.headers))
    }

    // MARK: - Schema-fingerprint eligibility gate

    func testTransformSucceedsWhenExpectedSchemaFingerprintMatches() throws {
        let expectedFingerprint = JSONStructuralProfiler.profile(bodyData: jsonBody).schemaFingerprint
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))],
            expectedSchemaFingerprint: expectedFingerprint
        )
        XCTAssertTrue(result.wasTransformed)
        XCTAssertFalse(result.schemaDriftDetected)
    }

    func testTransformFailsOpenWithDistinctSchemaDriftReasonWhenShapeDrifted() throws {
        // Fingerprint computed against a differently-shaped body (extra property) than what's
        // actually served — simulates the backend's response shape drifting after the rule was
        // created against an earlier structural profile.
        let driftedFixture = #"{"name":"alice","score":10,"subtitle":"extra"}"#.data(using: .utf8)!
        let expectedFingerprint = JSONStructuralProfiler.profile(bodyData: driftedFixture).schemaFingerprint

        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))],
            expectedSchemaFingerprint: expectedFingerprint
        )
        XCTAssertFalse(result.wasTransformed)
        XCTAssertTrue(result.schemaDriftDetected)
        XCTAssertTrue(result.matchedButNotApplied)
        XCTAssertEqual(result.bodyData, jsonBody, "untouched original response must be returned on schema drift")
    }

    func testTransformUnaffectedWhenExpectedSchemaFingerprintIsNil() throws {
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))],
            expectedSchemaFingerprint: nil
        )
        XCTAssertTrue(result.wasTransformed)
        XCTAssertFalse(result.schemaDriftDetected)
    }

    // MARK: - Gzip round-trip

    func testTransformReencodesGzipBodyAfterMutation() throws {
        let gzipped = try XCTUnwrap(gzipCompress(jsonBody))
        var headers = validatorHeaders()
        headers.append(HTTPHeaderField(name: "Content-Encoding", value: "gzip"))
        headers.append(HTTPHeaderField(name: "Content-Length", value: String(gzipped.count)))

        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: headers,
            bodyData: gzipped,
            mutations: [setMutation(locator: "score", value: .number("99"))]
        )

        XCTAssertTrue(result.wasTransformed)
        XCTAssertEqual(headerValue(named: "Content-Encoding", in: result.headers), "gzip")
        XCTAssertEqual(headerValue(named: "Content-Length", in: result.headers), String(result.bodyData.count))

        let decodeResult = try XCTUnwrap(
            CapturedBodyDecoder.decode(bodyData: result.bodyData, headers: result.headers)
        )
        let object = try JSONSerialization.jsonObject(with: decodeResult.analysisData) as? [String: Any]
        XCTAssertEqual(object?["score"] as? Int, 99)
    }

    // MARK: - Fail-open

    func testTransformPassesThroughMalformedJSON() {
        let invalidBody = Data("{not-json".utf8)
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: invalidBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))]
        )

        XCTAssertFalse(result.wasTransformed)
        XCTAssertFalse(result.matchedButNotApplied)
        XCTAssertEqual(result.bodyData, invalidBody)
    }

    func testTransformPassesThroughWhenLocatorDoesNotResolve() {
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [setMutation(locator: "missing.field", value: .string("x"))]
        )

        XCTAssertFalse(result.wasTransformed)
        XCTAssertTrue(result.matchedButNotApplied)
        XCTAssertEqual(result.bodyData, jsonBody)
        XCTAssertEqual(result.skippedMutationIDs.count, 1)
    }

    func testTransformAppliesPartialMutationsWhenSomeLocatorsFail() throws {
        let good = setMutation(locator: "name", value: .string("bob"))
        let bad = setMutation(locator: "missing.field", value: .string("x"))
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: jsonBody,
            mutations: [bad, good]
        )

        XCTAssertTrue(result.wasTransformed)
        XCTAssertFalse(result.matchedButNotApplied)
        XCTAssertEqual(result.appliedMutationIDs, [good.id])
        XCTAssertEqual(result.skippedMutationIDs, [bad.id])

        let object = try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "bob")
    }

    func testTransformPassesThroughUnsupportedEncodingWithoutMutating() {
        var headers = jsonHeaders()
        headers.append(HTTPHeaderField(name: "Content-Encoding", value: "deflate"))
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: headers,
            bodyData: jsonBody,
            mutations: [setMutation(locator: "name", value: .string("bob"))]
        )

        XCTAssertFalse(result.wasTransformed)
        XCTAssertEqual(result.eligibilityReason, .unsupportedContentEncoding("deflate"))
        XCTAssertEqual(result.bodyData, jsonBody)
    }

    func testTransformPassesThroughWhenPatchedBodyExceedsEncodedCap() {
        let smallJSON = #"{"name":"x"}"#.data(using: .utf8)!
        let policy = LiveResponseTransformationPolicy(maxEncodedBodyBytes: 30, maxDecodedBodyBytes: 1_048_576, maxOutputGrowthBytes: 1_048_576)
        let hugeValue = String(repeating: "z", count: 40)

        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: smallJSON,
            mutations: [setMutation(locator: "name", value: .string(hugeValue))],
            policy: policy
        )

        XCTAssertFalse(result.wasTransformed)
        XCTAssertEqual(result.bodyData, smallJSON)
    }

    func testTransformPassesThroughWhenGrowthExceedsGrowthCapEvenUnderEncodedCap() {
        let smallJSON = #"{"name":"x"}"#.data(using: .utf8)!
        // Encoded cap is generous, but growth cap is tiny — the mutation grows the body well past
        // the growth budget even though the absolute result size is nowhere near maxEncodedBodyBytes.
        let policy = LiveResponseTransformationPolicy(
            maxEncodedBodyBytes: 1_048_576,
            maxDecodedBodyBytes: 1_048_576,
            maxOutputGrowthBytes: 5
        )
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: smallJSON,
            mutations: [setMutation(locator: "name", value: .string(String(repeating: "z", count: 40)))],
            policy: policy
        )

        XCTAssertFalse(result.wasTransformed)
        XCTAssertEqual(result.bodyData, smallJSON)
    }

    func testDefaultPolicyUsesDedicatedExecutionBudgetNotRecordingConstants() {
        XCTAssertEqual(LiveResponseTransformationPolicy.default.maxEncodedBodyBytes, LiveTransformationExecutionBudget.maxEncodedBodyBytes)
        XCTAssertEqual(LiveResponseTransformationPolicy.default.maxDecodedBodyBytes, LiveTransformationExecutionBudget.maxDecodedBodyBytes)
        XCTAssertEqual(LiveResponseTransformationPolicy.default.maxOutputGrowthBytes, LiveTransformationExecutionBudget.maxOutputGrowthBytes)
    }

    // MARK: - Header hygiene

    func testReconcileHeadersAfterMutationStripsValidatorsAndUpdatesLength() {
        let headers = validatorHeaders()
        let newBody = Data("{\"patched\":true}".utf8)
        let reconciled = LiveResponseTransformation.reconcileHeadersAfterMutation(
            headers,
            newBodyData: newBody,
            reencodedAsGzip: false
        )

        XCTAssertNil(headerValue(named: "ETag", in: reconciled))
        XCTAssertNil(headerValue(named: "Last-Modified", in: reconciled))
        XCTAssertNil(headerValue(named: "Content-MD5", in: reconciled))
        XCTAssertNil(headerValue(named: "Digest", in: reconciled))
        XCTAssertEqual(headerValue(named: "Content-Length", in: reconciled), String(newBody.count))
        XCTAssertEqual(headerValue(named: "Cache-Control", in: reconciled), "max-age=60")
    }

    func testReconcileHeadersAfterMutationStripsStaleTransferEncoding() {
        let headers = [
            HTTPHeaderField(name: "Transfer-Encoding", value: "chunked"),
            HTTPHeaderField(name: "Content-Type", value: "application/json")
        ]
        let newBody = Data("{\"patched\":true}".utf8)
        let reconciled = LiveResponseTransformation.reconcileHeadersAfterMutation(
            headers,
            newBodyData: newBody,
            reencodedAsGzip: false
        )

        XCTAssertNil(headerValue(named: "Transfer-Encoding", in: reconciled))
        XCTAssertEqual(headerValue(named: "Content-Length", in: reconciled), String(newBody.count))
    }

    func testReconcileHeadersAfterMutationKeepsGzipEncodingWhenRequested() {
        let reconciled = LiveResponseTransformation.reconcileHeadersAfterMutation(
            jsonHeaders(),
            newBodyData: Data(repeating: 0xAB, count: 12),
            reencodedAsGzip: true
        )
        XCTAssertEqual(headerValue(named: "Content-Encoding", in: reconciled), "gzip")
    }

    // MARK: - Helpers

    func testTransformSetsTopLevelBoolFlag() throws {
        let body = #"{"flag":false}"#.data(using: .utf8)!
        let result = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: body,
            mutations: [setMutation(locator: "flag", value: .bool(true))]
        )

        XCTAssertTrue(result.wasTransformed)
        let object = try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any]
        XCTAssertEqual((object?["flag"] as? NSNumber)?.boolValue, true)
    }

    func testAppendStringIfMissingSuffixIsIdempotentAcrossRepeatedLiveTransforms() throws {
        let body = #"{"title":"Morning News"}"#.data(using: .utf8)!
        let mutation = JSONResponseMutation(
            locator: "title",
            operation: .appendString,
            value: .string("!"),
            repeatPolicy: .ifMissingSuffix
        )

        let firstResult = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: body,
            mutations: [mutation]
        )
        XCTAssertTrue(firstResult.wasTransformed)
        let firstObject = try JSONSerialization.jsonObject(with: firstResult.bodyData) as? [String: Any]
        XCTAssertEqual(firstObject?["title"] as? String, "Morning News!")

        // Same never-mutated-at-origin body (as a real upstream would keep serving), transformed
        // a second time — must not accumulate "!!".
        let secondResult = LiveResponseTransformation.transform(
            requestMethod: "GET",
            statusCode: 200,
            headers: jsonHeaders(),
            bodyData: body,
            mutations: [mutation]
        )
        let secondObject = try JSONSerialization.jsonObject(with: secondResult.bodyData) as? [String: Any]
        XCTAssertEqual(secondObject?["title"] as? String, "Morning News!")
    }

    private func jsonHeaders() -> [HTTPHeaderField] {
        [HTTPHeaderField(name: "Content-Type", value: "application/json")]
    }

    private func validatorHeaders() -> [HTTPHeaderField] {
        [
            HTTPHeaderField(name: "Content-Type", value: "application/json"),
            HTTPHeaderField(name: "ETag", value: "\"abc123\""),
            HTTPHeaderField(name: "Last-Modified", value: "Wed, 21 Oct 2015 07:28:00 GMT"),
            HTTPHeaderField(name: "Content-MD5", value: "d41d8cd98f00b204e9800998ecf8427e"),
            HTTPHeaderField(name: "Digest", value: "sha-256=abc"),
            HTTPHeaderField(name: "Cache-Control", value: "max-age=60")
        ]
    }

    private func setMutation(locator: String, value: BookmarkJSONValue) -> JSONResponseMutation {
        JSONResponseMutation(locator: locator, operation: .set, value: value)
    }

    private func headerValue(named name: String, in headers: [HTTPHeaderField]) -> String? {
        headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
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
