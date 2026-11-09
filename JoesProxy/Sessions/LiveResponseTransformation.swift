import Foundation
import zlib

/// Size and encoding policy for live upstream JSON response transformation (AL-4).
struct LiveResponseTransformationPolicy: Equatable, Sendable {
    /// Maximum wire (encoded) body bytes before decode or after re-encode.
    let maxEncodedBodyBytes: Int
    /// Maximum decoded JSON bytes passed to the mutation engine.
    let maxDecodedBodyBytes: Int
    /// Maximum growth in wire body size (transformed − original encoded bytes); not an absolute
    /// cap — a mutation that holds size steady or shrinks the body is unaffected regardless of
    /// absolute size.
    let maxOutputGrowthBytes: Int

    static let `default` = LiveResponseTransformationPolicy(
        maxEncodedBodyBytes: LiveTransformationExecutionBudget.maxEncodedBodyBytes,
        maxDecodedBodyBytes: LiveTransformationExecutionBudget.maxDecodedBodyBytes,
        maxOutputGrowthBytes: LiveTransformationExecutionBudget.maxOutputGrowthBytes
    )
}

/// Why a live response can or cannot enter the transformation pipeline.
enum LiveResponseTransformationEligibilityReason: Equatable, Sendable {
    case eligible
    case ineligibleRequestMethod(String)
    case ineligibleStatusCode(Int)
    case unsupportedContentEncoding(String)
    case encodedBodyTooLarge(actualBytes: Int, limitBytes: Int)
    case emptyMutations
}

/// Outcome of attempting to transform a parsed upstream response in place.
///
/// When ``wasTransformed`` is false the caller must forward ``bodyData`` and ``headers`` unchanged
/// (fail-open v1). ``matchedButNotApplied`` distinguishes a rule that matched but every mutation
/// skipped from a response that never entered mutation at all.
struct LiveResponseTransformationResult: Equatable, Sendable {
    let bodyData: Data
    let headers: [HTTPHeaderField]
    let wasTransformed: Bool
    /// Set when transformation was never attempted because eligibility failed at the gate.
    let eligibilityReason: LiveResponseTransformationEligibilityReason?
    /// True when mutations were evaluated but none reported ``JSONMutationOutcome/applied``.
    let matchedButNotApplied: Bool
    /// True when the rule declared an `expectedSchemaFingerprint` and the live response's actual
    /// structure didn't match it — fails open (untouched response) rather than applying selectors
    /// to an unreviewed shape. Implies `matchedButNotApplied` but is reported separately so a
    /// caller can distinguish "shape drifted" from "mutations individually skipped."
    let schemaDriftDetected: Bool
    let mutationOutcomes: [UUID: JSONMutationOutcome]
    let appliedMutationIDs: [UUID]
    let skippedMutationIDs: [UUID]
    /// Original upstream wire body size for capture digest correlation (no second body copy).
    let originalBodyByteCount: Int
}

/// Standalone eligibility, decode/mutate/re-encode, and header-reconciliation layer for live
/// JSON response rewriting. Built and tested before any proxy rule kind wires into
/// ``ConnectionHandler`` (AL-5).
enum LiveResponseTransformation {
    private static let supportedEncodingTokens: Set<String> = ["identity", "gzip", "x-gzip"]
    private static let validatorHeaderNames: Set<String> = [
        "etag",
        "last-modified",
        "content-md5",
        "digest"
    ]
    /// RFC 7230 §3.3.3: when both Transfer-Encoding and Content-Length are present, a client
    /// must prefer Transfer-Encoding. Since the mutated body is sent with a recomputed
    /// Content-Length and is never re-chunked, any stale Transfer-Encoding header must be
    /// stripped or a chunked-aware client will misparse the reconciled response.
    private static let framingHeaderNames: Set<String> = ["transfer-encoding"]

    /// Evaluates whether a parsed upstream response may enter the transformation pipeline.
    static func evaluateEligibility(
        requestMethod: String,
        statusCode: Int,
        headers: [HTTPHeaderField],
        bodyData: Data,
        mutations: [JSONResponseMutation],
        policy: LiveResponseTransformationPolicy = .default
    ) -> LiveResponseTransformationEligibilityReason {
        guard !mutations.isEmpty else {
            return .emptyMutations
        }

        if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame {
            return .ineligibleRequestMethod(requestMethod)
        }

        switch statusCode {
        case 100..<200, 204, 304:
            return .ineligibleStatusCode(statusCode)
        default:
            break
        }

        if bodyData.count > policy.maxEncodedBodyBytes {
            return .encodedBodyTooLarge(
                actualBytes: bodyData.count,
                limitBytes: policy.maxEncodedBodyBytes
            )
        }

        for token in contentEncodingTokens(from: headers) where !supportedEncodingTokens.contains(token) {
            return .unsupportedContentEncoding(token)
        }

        return .eligible
    }

    /// Attempts to decode, mutate, re-encode, and reconcile headers for a live upstream response.
    ///
    /// Fail-open v1: any gate failure, decode failure, malformed JSON, zero successful mutations,
    /// gzip re-encode failure, or post-mutation size cap violation returns the untouched upstream
    /// body and headers. Per-mutation engine failures skip individually; at least one `.applied`
    /// outcome is required to emit a patched response.
    static func transform(
        requestMethod: String,
        statusCode: Int,
        headers: [HTTPHeaderField],
        bodyData: Data,
        mutations: [JSONResponseMutation],
        policy: LiveResponseTransformationPolicy = .default,
        expectedSchemaFingerprint: JSONSchemaShapeFingerprint? = nil
    ) -> LiveResponseTransformationResult {
        let originalBodyByteCount = bodyData.count
        let transformState = LiveRewritePerformanceSignposts.beginTransform(
            bodyBytes: bodyData.count,
            mutationCount: mutations.count
        )
        defer { LiveRewritePerformanceSignposts.endTransform(transformState) }

        let eligibility = evaluateEligibility(
            requestMethod: requestMethod,
            statusCode: statusCode,
            headers: headers,
            bodyData: bodyData,
            mutations: mutations,
            policy: policy
        )
        guard eligibility == .eligible else {
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations,
                eligibilityReason: eligibility
            )
        }

        let decodeState = LiveRewritePerformanceSignposts.beginDecode()
        let decodeResultOptional = CapturedBodyDecoder.decode(
            bodyData: bodyData,
            headers: headers,
            maxDecodedBytes: policy.maxDecodedBodyBytes
        )
        LiveRewritePerformanceSignposts.endDecode(decodeState)
        guard let decodeResult = decodeResultOptional, decodeResult.canUseAnalysisDataForInspection else {
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations
            )
        }

        // Schema drift is a decode-time-and-later concern (the fingerprint can only be computed
        // once JSON has actually parsed) — it extends the matched-but-not-applied fail-open path
        // rather than being a new pre-decode eligibility case.
        if let expectedSchemaFingerprint {
            let actualFingerprint = JSONStructuralProfiler.profile(bodyData: decodeResult.analysisData).schemaFingerprint
            guard actualFingerprint == expectedSchemaFingerprint else {
                return passthrough(
                    bodyData: bodyData,
                    headers: headers,
                    originalBodyByteCount: originalBodyByteCount,
                    mutations: mutations,
                    matchedButNotApplied: true,
                    schemaDriftDetected: true
                )
            }
        }

        let applyResult: BookmarkJSONRewriteEngine.MutationApplyResult
        let mutationApplyState = LiveRewritePerformanceSignposts.beginMutationApply(
            bodyBytes: decodeResult.analysisData.count,
            mutationCount: mutations.count
        )
        do {
            applyResult = try BookmarkJSONRewriteEngine.apply(
                bodyData: decodeResult.analysisData,
                mutations: mutations
            )
            LiveRewritePerformanceSignposts.endMutationApply(mutationApplyState)
        } catch {
            LiveRewritePerformanceSignposts.endMutationApply(mutationApplyState)
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations
            )
        }

        let appliedMutationIDs = mutations.compactMap {
            applyResult.outcomes[$0.id] == .applied ? $0.id : nil
        }
        guard !appliedMutationIDs.isEmpty else {
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations,
                outcomes: applyResult.outcomes,
                matchedButNotApplied: true
            )
        }

        let encodingTokens = contentEncodingTokens(from: headers)
        let reencodeAsGzip = encodingTokens.contains(where: { $0 == "gzip" || $0 == "x-gzip" })

        var wireBody = applyResult.patchedData
        if reencodeAsGzip {
            // v1: keep Content-Encoding: gzip on the wire — do not silently downgrade to identity.
            let gzipState = LiveRewritePerformanceSignposts.beginGzipReencode(bodyBytes: applyResult.patchedData.count)
            let gzippedOptional = gzipCompress(applyResult.patchedData)
            LiveRewritePerformanceSignposts.endGzipReencode(gzipState)
            guard let gzipped = gzippedOptional else {
                return passthrough(
                    bodyData: bodyData,
                    headers: headers,
                    originalBodyByteCount: originalBodyByteCount,
                    mutations: mutations,
                    outcomes: applyResult.outcomes
                )
            }
            guard gzipped.count <= policy.maxEncodedBodyBytes else {
                return passthrough(
                    bodyData: bodyData,
                    headers: headers,
                    originalBodyByteCount: originalBodyByteCount,
                    mutations: mutations,
                    outcomes: applyResult.outcomes
                )
            }
            wireBody = gzipped
        } else if wireBody.count > policy.maxEncodedBodyBytes {
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations,
                outcomes: applyResult.outcomes
            )
        }

        if wireBody.count - originalBodyByteCount > policy.maxOutputGrowthBytes {
            return passthrough(
                bodyData: bodyData,
                headers: headers,
                originalBodyByteCount: originalBodyByteCount,
                mutations: mutations,
                outcomes: applyResult.outcomes
            )
        }

        let reconciledHeaders = reconcileHeadersAfterMutation(
            headers,
            newBodyData: wireBody,
            reencodedAsGzip: reencodeAsGzip
        )
        let skippedMutationIDs = mutations.compactMap {
            applyResult.outcomes[$0.id] != .applied ? $0.id : nil
        }

        return LiveResponseTransformationResult(
            bodyData: wireBody,
            headers: reconciledHeaders,
            wasTransformed: true,
            eligibilityReason: nil,
            matchedButNotApplied: false,
            schemaDriftDetected: false,
            mutationOutcomes: applyResult.outcomes,
            appliedMutationIDs: appliedMutationIDs,
            skippedMutationIDs: skippedMutationIDs,
            originalBodyByteCount: originalBodyByteCount
        )
    }

    /// Strips body validators and updates wire metadata after a successful body mutation.
    static func reconcileHeadersAfterMutation(
        _ headers: [HTTPHeaderField],
        newBodyData: Data,
        reencodedAsGzip: Bool
    ) -> [HTTPHeaderField] {
        var result = headers.filter { header in
            let lowercasedName = header.name.lowercased()
            return lowercasedName != "content-length" &&
                lowercasedName != "content-encoding" &&
                !validatorHeaderNames.contains(lowercasedName) &&
                !framingHeaderNames.contains(lowercasedName)
        }

        if reencodedAsGzip {
            result.append(HTTPHeaderField(name: "Content-Encoding", value: "gzip"))
        }

        result.append(
            HTTPHeaderField(name: "Content-Length", value: String(newBodyData.count))
        )
        return result
    }

    // MARK: - Private

    private static func passthrough(
        bodyData: Data,
        headers: [HTTPHeaderField],
        originalBodyByteCount: Int,
        mutations: [JSONResponseMutation],
        eligibilityReason: LiveResponseTransformationEligibilityReason? = nil,
        outcomes: [UUID: JSONMutationOutcome] = [:],
        matchedButNotApplied: Bool = false,
        schemaDriftDetected: Bool = false
    ) -> LiveResponseTransformationResult {
        LiveResponseTransformationResult(
            bodyData: bodyData,
            headers: headers,
            wasTransformed: false,
            eligibilityReason: eligibilityReason,
            matchedButNotApplied: matchedButNotApplied,
            schemaDriftDetected: schemaDriftDetected,
            mutationOutcomes: outcomes,
            appliedMutationIDs: mutations.compactMap { outcomes[$0.id] == .applied ? $0.id : nil },
            skippedMutationIDs: mutations.compactMap { outcomes[$0.id] != .applied ? $0.id : nil },
            originalBodyByteCount: originalBodyByteCount
        )
    }

    private static func contentEncodingTokens(from headers: [HTTPHeaderField]) -> [String] {
        guard let contentEncoding = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
        })?.value else {
            return []
        }

        return contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
    }

    /// Gzip-compresses `data` for the live-response write path (zlib wrapper, not raw deflate).
    static func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.baseAddress)
            stream.avail_in = uInt(data.count)
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

    /// Adapts persisted bookmark-style rewrite rows into neutral JSON mutations for the engine.
    static func jsonMutations(from rewrites: [BookmarkResponseFieldRewrite]) -> [JSONResponseMutation] {
        rewrites.filter(\.isRuleEnabled).map {
            JSONResponseMutation(
                id: $0.id,
                locator: $0.jsonPath,
                operation: $0.operation,
                value: $0.overrideValue,
                repeatPolicy: $0.repeatPolicy ?? .always
            )
        }
    }
}
