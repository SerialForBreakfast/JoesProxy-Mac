import Foundation

/// Resource budget constants for MCP responses (ADR Phase 1).
enum MCPResourceBudget {
    static let defaultPageSize = 10
    static let maxPageSize = 100
    /// Final encoded MCP response byte cap measured post-serialization.
    static let maxResponseBytes = 1_048_576
    /// Post-approval single disclosed session item byte cap.
    static let maxDisclosedItemBytes = 65_536
    /// Post-approval aggregate disclosure byte cap for one tool call payload.
    static let maxDisclosedCallBytes = 262_144
}

/// Host category classification for Metadata Only disclosure.
enum MCPHostCategory: String, Equatable, Sendable, CaseIterable {
    case local
    case api
    case cdn
    case other

    static func classify(host: String) -> MCPHostCategory {
        let normalized = host.lowercased()
        if normalized.isEmpty || normalized == "localhost" || normalized.hasSuffix(".local") {
            return .local
        }
        if normalized.contains("cdn") || normalized.contains("cloudfront") || normalized.contains("akamai") {
            return .cdn
        }
        if normalized.contains("api") || normalized.hasPrefix("api.") {
            return .api
        }
        return .other
    }
}

/// Marks captured strings as untrusted structured content for MCP clients.
enum MCPUntrustedAnnotation {
    static let contentKey = "captured_untrusted"

    static func wrap(_ value: String) -> [String: String] {
        [contentKey: value]
    }
}

/// Single production boundary for MCP session disclosure and resource payloads.
///
/// Concurrency: `Sendable` and stateless; callers pass resolved profiles and records from
/// `@MainActor` stores at request time.
struct MCPDisclosureSerializer: Sendable {
    struct PaginationRequest: Equatable, Sendable {
        var limit: Int
        var cursor: MCPSessionQueryCursor?
    }

    struct PaginationResult: Equatable, Sendable {
        var items: [MCPSessionSummaryDTO]
        var nextCursor: MCPSessionQueryCursor?
        var truncated: Bool
        var truncationReason: String?
    }

    /// Sanitizes a hostname label for Shareable tier using existing redaction heuristics.
    func sanitizedHost(_ host: String) -> String {
        host
            .split(separator: ".")
            .map { segment in
                let segmentString = String(segment)
                if SensitiveDataRedaction.isSensitiveKey(segmentString) {
                    return "<redacted>"
                }
                return segmentString
            }
            .joined(separator: ".")
    }

    /// Sanitizes a path for Shareable tier: strips the query string, then redacts individual path
    /// segments that look like opaque tokens (JWTs, session IDs, reset/confirmation tokens embedded
    /// directly in the path — a common real-world pattern that a query-string strip alone misses).
    func sanitizedPath(_ path: String) -> String {
        var withoutQuery = path
        if withoutQuery.contains("?") {
            withoutQuery = String(withoutQuery.split(separator: "?", maxSplits: 1).first ?? Substring(withoutQuery))
        }
        let segments = withoutQuery.split(separator: "/", omittingEmptySubsequences: false)
        let sanitizedSegments = segments.map { segment -> String in
            let segmentString = String(segment)
            guard !segmentString.isEmpty else { return segmentString }
            return Self.looksLikeOpaqueToken(segmentString) ? "<redacted>" : segmentString
        }
        return sanitizedSegments.joined(separator: "/")
    }

    /// Heuristic for an opaque, likely-sensitive path segment: a JWT-shaped three-part token, or a
    /// long mixed alphanumeric run typical of a generated identifier, session token, or signed
    /// value. Deliberately biased toward redacting: a false positive hides an ordinary word, a
    /// false negative leaks a credential.
    private static func looksLikeOpaqueToken(_ segment: String) -> Bool {
        let base64URLCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

        let jwtParts = segment.split(separator: ".", omittingEmptySubsequences: false)
        if jwtParts.count == 3,
           jwtParts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(base64URLCharacters.contains) }) {
            return true
        }

        guard segment.count >= 16,
              segment.unicodeScalars.allSatisfy(base64URLCharacters.contains) else {
            return false
        }
        return segment.contains(where: \.isNumber) && segment.contains(where: \.isLetter)
    }

    /// Builds a session summary honoring the resolved disclosure profile; unknown fields fail closed.
    ///
    /// - Parameter approvedCapabilities: Post-approval sensitive-read tiers to include beyond the profile.
    /// - Parameter headerSource: Which HTTP message headers to disclose at Shareable and approved tiers.
    func sessionSummary(
        record: SessionRecord,
        captureSequence: UInt64,
        profile: MCPDisclosureProfileDocument,
        approvedCapabilities: Set<MCPCapabilityID> = [],
        bodySource: MCPSessionBodySource = .response,
        headerSource: MCPSessionHeaderSource = .both
    ) throws -> MCPSessionSummaryDTO {
        var summary = MCPSessionSummaryDTO(
            id: record.id.uuidString,
            captureSequence: captureSequence
        )

        try include(.method, profile: profile) { summary.method = record.request.method }
        try include(.statusCode, profile: profile) { summary.statusCode = record.response?.statusCode }
        try include(.timestamps, profile: profile) { summary.startedAt = record.timing.startedAt }
        try include(.duration, profile: profile) {
            summary.durationSeconds = record.timing.duration
            summary.transportEvidence = record.timing.wireProfile?.transport
            summary.transportEvidenceSource = summary.transportEvidence == nil ? "unavailable_or_evicted" : "recorded"
            summary.transportDiagnostic = .assess(summary.transportEvidence)
        }
        try include(.mediaCategory, profile: profile) {
            if CaptureMarkerConstants.isMarkerRecord(record) {
                summary.mediaCategory = CaptureMarkerConstants.mediaCategoryLabel
            } else {
                summary.mediaCategory = MediaDetector.listMediaType(for: record).categoryLabel
            }
        }
        try include(.hostCategory, profile: profile) {
            if CaptureMarkerConstants.isMarkerRecord(record) {
                summary.hostCategory = CaptureMarkerConstants.hostCategory
            } else {
                summary.hostCategory = MCPHostCategory.classify(host: record.request.host).rawValue
            }
        }
        try include(.sanitizedHost, profile: profile) {
            summary.sanitizedHost = sanitizedHost(record.request.host)
        }
        try include(.sanitizedPath, profile: profile) {
            summary.sanitizedPath = sanitizedPath(record.request.path)
        }
        if headerSource == .request || headerSource == .both {
            try include(.safeHeaders, profile: profile) {
                summary.safeHeaders = safeHeaders(from: record.request.headers)
            }
        }
        if headerSource == .response || headerSource == .both {
            try include(.safeHeaders, profile: profile) {
                summary.safeResponseHeaders = safeHeaders(from: record.response?.headers ?? [])
            }
        }
        let requestStored = bodyStoredAvailable(record.request.bodyData, bodySize: record.request.bodySize, deferred: record.request.bodyDeferred)
        let responseStored = bodyStoredAvailable(
            record.response?.bodyData,
            bodySize: record.response?.bodySize,
            deferred: record.response?.bodyDeferred ?? false
        )
        let excerptEligibility = bodyExcerptEligibility(from: record, source: bodySource)
        try include(.bodyAvailabilityFlags, profile: profile) {
            summary.requestBodyAvailable = requestStored
            summary.responseBodyAvailable = responseStored
            summary.bodyExcerptAvailable = excerptEligibility.isAvailable
            summary.bodyAvailable = excerptEligibility.isAvailable
            // Unsupported coding may contain an untrusted header value. Before approval,
            // disclose only the fixed category, never that value.
            let reason = excerptEligibility.unavailableReason
            summary.bodyUnavailableReason = reason?.hasPrefix("unsupported_encoding:") == true
                ? "unsupported_encoding" : reason
            summary.bodyRecoveryAction = Self.bodyRecoveryAction(for: summary.bodyUnavailableReason,
                                                               available: excerptEligibility.isAvailable)
            summary.bodyTruncated = record.request.bodyTruncated || (record.response?.bodyTruncated ?? false)
        }
        try include(.parserSummaries, profile: profile) {
            summary.parserSummaries = Self.parserSummaries(for: record)
        }
        if approvedCapabilities.contains(.headerRead) {
            if headerSource == .request || headerSource == .both {
                summary.approvedHeaders = approvedHeaders(from: record.request.headers)
            }
            if headerSource == .response || headerSource == .both {
                summary.approvedResponseHeaders = approvedHeaders(from: record.response?.headers ?? [])
            }
        }
        if approvedCapabilities.contains(.queryRead) {
            summary.queryParameters = approvedQueryParameters(from: record.request.path)
        }
        if approvedCapabilities.contains(.bodyRead) {
            let excerpt = approvedBodyExcerpt(from: record, source: bodySource)
            summary.bodyExcerpt = excerpt.text
            summary.bodyExcerptTruncated = excerpt.truncated
            summary.bodyExcerptSource = bodySource.rawValue
            summary.bodyDecodeStatus = excerpt.decodeStatus
            summary.bodyUnavailableReason = excerpt.unavailableReason
        }
        // Every other field in this function goes through `include(_:profile:)` — provenance must
        // too, or a client on a restrictive profile (e.g. Metadata Only) still receives full
        // attribution (originating MCP clientID, operationID, capability, timestamp) regardless of
        // what their profile actually permits.
        try include(.provenance, profile: profile) {
            summary.provenance = record.response?.mcpAttribution?.provenance
            summary.mcpEffectKinds = record.response?.mcpAttribution?.effectKinds
        }
        return summary
    }

    /// Clamps page size to ADR defaults and maximum.
    func normalizedPageSize(_ requested: Int?) -> Int {
        let value = requested ?? MCPResourceBudget.defaultPageSize
        return min(max(1, value), MCPResourceBudget.maxPageSize)
    }

    /// Header names whose *values* are safe to disclose verbatim at the Shareable tier. There is no
    /// reliable way to detect an arbitrary secret-looking value from its contents alone — real
    /// tokens rarely contain literal words like "token" or "secret" — so this fails closed: only
    /// structurally-known-safe headers keep their value, everything else is redacted regardless of
    /// whether its *name* was already recognized as sensitive.
    private static let valueDisclosureAllowlist: Set<String> = [
        "accept",
        "accept-encoding",
        "accept-language",
        "cache-control",
        "connection",
        "content-encoding",
        "content-length",
        "content-type",
        "vary"
    ]

    private func safeHeaders(from headers: [HTTPHeaderField]) -> [MCPDisclosedHeaderField] {
        headers.compactMap { field in
            let normalizedName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { return nil }
            guard !SensitiveDataRedaction.isSensitiveHeaderName(normalizedName) else { return nil }
            let redactedValue = Self.valueDisclosureAllowlist.contains(normalizedName.lowercased())
                ? field.value
                : "<redacted>"
            return MCPDisclosedHeaderField(name: normalizedName, redactedValue: redactedValue)
        }
    }

    private func approvedHeaders(from headers: [HTTPHeaderField]) -> [MCPDisclosedHeaderField] {
        let mapped = headers.compactMap { field -> MCPDisclosedHeaderField? in
            let normalizedName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { return nil }
            return MCPDisclosedHeaderField(name: normalizedName, redactedValue: field.value)
        }
        return boundedDisclosureItems(mapped) { $0.name.utf8.count + $0.redactedValue.utf8.count }
    }

    private func approvedQueryParameters(from path: String) -> [MCPDisclosedQueryParameter] {
        guard let queryStart = path.firstIndex(of: "?") else { return [] }
        let query = String(path[path.index(after: queryStart)...])
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let mapped = pairs.compactMap { pair -> MCPDisclosedQueryParameter? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let namePart = parts.first else { return nil }
            let name = String(namePart)
            let value = parts.count > 1 ? String(parts[1]) : ""
            guard !name.isEmpty else { return nil }
            return MCPDisclosedQueryParameter(name: name, value: value)
        }
        return boundedDisclosureItems(mapped) { $0.name.utf8.count + $0.value.utf8.count }
    }

    /// Whether MCP can return a body excerpt for a selected source once `bodyRead` is approved.
    struct BodyExcerptEligibility: Equatable, Sendable {
        var isAvailable: Bool
        var unavailableReason: String?
    }

    private func bodyStoredAvailable(_ bodyData: Data?, bodySize: Int?, deferred: Bool) -> Bool {
        guard !deferred else { return false }
        if let bodyData { return !bodyData.isEmpty || bodySize == 0 }
        return false
    }

    private static func bodyRecoveryAction(for reason: String?, available: Bool) -> String {
        if available { return "request_session_summary_includeBody_with_bodyRead_approval" }
        switch reason {
        case "capture_pressure": return "capture_status; wait_for_automatic_recovery_then_generate_new_authorized_traffic; do_not_restart_or_reinstall_device_profile"
        case "body_deferred": return "wait_for_recording_body_load_then_retry"
        case "body_omitted": return "open_original_full_recording_or_generate_new_authorized_traffic; never_automatically_refetch"
        case "tls_passthrough": return "inspect_setup_readiness_and_TLS_policy; tunnel_is_not_proof_of_bad_trust; do_not_reinstall_device_profile_without_separate_evidence"
        case "response_pending": return "wait_for_response_completion_then_retry"
        case "body_missing": return "capture_status; missing_bytes_cannot_be_restored_by_capture_resume; do_not_reinstall_device_profile_based_on_missing_bodies"
        case "binary_content", "invalid_utf8": return "use_approved_binary_or_media_inspection; do_not_enable_capture_again"
        case nil: return "no_nonempty_body_to_read"
        default: return "inspect_body_decode_status_and_documentation; do_not_automatically_replay"
        }
    }

    /// Determines whether MCP could return a body excerpt for `source` once `bodyRead` is approved.
    func bodyExcerptEligibility(
        from record: SessionRecord,
        source: MCPSessionBodySource
    ) -> BodyExcerptEligibility {
        let excerpt = approvedBodyExcerpt(from: record, source: source)
        if let reason = excerpt.unavailableReason {
            return BodyExcerptEligibility(isAvailable: false, unavailableReason: reason)
        }
        if excerpt.decodeStatus == "empty" {
            return BodyExcerptEligibility(isAvailable: false, unavailableReason: nil)
        }
        guard let text = excerpt.text, !text.isEmpty else {
            return BodyExcerptEligibility(isAvailable: false, unavailableReason: excerpt.unavailableReason)
        }
        return BodyExcerptEligibility(isAvailable: true, unavailableReason: nil)
    }

    struct BodyExcerptResult {
        var text: String?
        var truncated: Bool
        var decodeStatus: String
        var unavailableReason: String?
    }

    private func approvedBodyExcerpt(
        from record: SessionRecord,
        source: MCPSessionBodySource,
        maxBytes: Int = MCPResourceBudget.maxDisclosedItemBytes
    ) -> BodyExcerptResult {
        if source == .response, record.responseCaptureLimitedByPressure == true {
            return BodyExcerptResult(text: nil, truncated: true, decodeStatus: "unavailable", unavailableReason: "capture_pressure")
        }
        if record.request.inspectionKind == .tunneledTLS {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "tls_passthrough")
        }
        if source == .response, record.response == nil, record.state == .pending {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "response_pending")
        }
        let bodyData: Data?
        let headers: [HTTPHeaderField]
        let deferred: Bool
        let omissionReason: RecordingBodyOmissionReason?
        let captureTruncated: Bool
        switch source {
        case .response:
            bodyData = record.response?.bodyData
            headers = record.response?.headers ?? []
            deferred = record.response?.bodyDeferred ?? false
            omissionReason = record.response?.recordingBodyOmissionReason
            captureTruncated = record.response?.bodyTruncated ?? false
        case .request:
            bodyData = record.request.bodyData
            headers = record.request.headers
            deferred = record.request.bodyDeferred
            omissionReason = record.request.recordingBodyOmissionReason
            captureTruncated = record.request.bodyTruncated
        }
        if deferred {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "body_deferred")
        }
        if omissionReason != nil {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "body_omitted")
        }
        guard let bodyData else {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "body_missing")
        }
        guard !bodyData.isEmpty else {
            return BodyExcerptResult(text: "", truncated: false, decodeStatus: "empty", unavailableReason: nil)
        }
        guard let decoded = CapturedBodyDecoder.decode(
            bodyData: bodyData,
            headers: headers,
            maxDecodedBytes: MCPResourceBudget.maxDisclosedCallBytes
        ) else {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable", unavailableReason: "decode_unavailable")
        }
        let decodeStatus: String
        switch decoded.status {
        case .unchanged:
            decodeStatus = "unchanged"
        case .decoded:
            decodeStatus = "decoded"
        case .unsupported(let coding):
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unsupported", unavailableReason: "unsupported_encoding:\(coding)")
        case .failed:
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "failed", unavailableReason: "decode_failed")
        case .limitExceeded:
            return BodyExcerptResult(text: nil, truncated: true, decodeStatus: "limit_exceeded", unavailableReason: "decoded_body_too_large")
        }
        guard !decoded.isKnownBinaryContentType else {
            return BodyExcerptResult(text: nil, truncated: captureTruncated, decodeStatus: decodeStatus, unavailableReason: "binary_content")
        }
        guard let combined = decoded.analysisUTF8Text() else {
            return BodyExcerptResult(text: nil, truncated: captureTruncated, decodeStatus: decodeStatus, unavailableReason: "invalid_utf8")
        }
        if combined.utf8.count <= maxBytes {
            return BodyExcerptResult(text: combined, truncated: captureTruncated, decodeStatus: decodeStatus, unavailableReason: nil)
        }
        let truncated = Self.truncatedToUTF8Boundary(combined, maxBytes: maxBytes)
        return BodyExcerptResult(text: truncated, truncated: true, decodeStatus: decodeStatus, unavailableReason: nil)
    }

    /// Analysis may inspect a larger complete decoded response locally, but must never return this
    /// text through the ordinary excerpt path. The caller must have resolved body-read approval.
    func responseAnalysisInput(from record: SessionRecord, approvedCapabilities: Set<MCPCapabilityID>) throws -> BodyExcerptResult {
        guard approvedCapabilities.contains(.bodyRead) else {
            throw MCPStructuredError(code: .policyDenied, message: "Response analysis requires body-read approval.")
        }
        guard record.state == .completed else {
            return BodyExcerptResult(text: nil, truncated: false, decodeStatus: "unavailable",
                unavailableReason: "response_\(record.state.rawValue)")
        }
        return approvedBodyExcerpt(from: record, source: .response, maxBytes: ResponseEvidenceBrief.maximumInputBytes)
    }

    /// Cuts `text` to at most `maxBytes` UTF-8 bytes at a valid `Character` boundary.
    ///
    /// A prior version repeatedly called `dropLast()` byte-by-byte to shrink oversized bodies
    /// down to budget; each call reallocates the whole remaining string, making that loop
    /// effectively O(n²) and, for a large decompressed API response (hundreds of KB), slow
    /// enough to block the caller for tens of seconds — including callers running on the main
    /// thread, where it read as an app-wide freeze rather than an MCP-only slowdown. This does
    /// the cut in a single `index(_:offsetBy:limitedBy:)` step, then walks back at most a few
    /// UTF-8 continuation bytes to land on a boundary `String.Index(_:within:)` accepts.
    private static func truncatedToUTF8Boundary(_ text: String, maxBytes: Int) -> String {
        let utf8View = text.utf8
        var cutIndex = utf8View.index(utf8View.startIndex, offsetBy: maxBytes, limitedBy: utf8View.endIndex)
            ?? utf8View.endIndex
        while cutIndex > utf8View.startIndex, String.Index(cutIndex, within: text) == nil {
            cutIndex = utf8View.index(before: cutIndex)
        }
        let boundary = String.Index(cutIndex, within: text) ?? text.startIndex
        return String(text[text.startIndex..<boundary])
    }

    private func boundedDisclosureItems<T>(
        _ items: [T],
        byteCount: (T) -> Int
    ) -> [T] {
        var total = 0
        var kept: [T] = []
        for item in items {
            let next = total + byteCount(item)
            guard next <= MCPResourceBudget.maxDisclosedItemBytes else { break }
            kept.append(item)
            total = next
        }
        return kept
    }

    private func include(
        _ field: MCPPolicyFieldClass,
        profile: MCPDisclosureProfileDocument,
        apply: () -> Void
    ) throws {
        guard profile.allowedFieldClasses.contains(field) else { return }
        apply()
    }

    /// One-line parser outcomes for Shareable profile session summaries.
    static func parserSummaries(for record: SessionRecord) -> [String]? {
        let mediaType = MediaDetector.mediaType(for: record)
        switch mediaType {
        case .hls:
            guard let response = record.response,
                  let data = MediaDetector.decodedResponseBody(for: response),
                  let text = String(data: data, encoding: .utf8) else {
                return ["hls_manifest"]
            }
            let manifest = HLSParser.parse(text, baseURL: nil)
            return [manifest.isMasterPlaylist ? "hls_master" : "hls_media"]
        case .dash:
            return ["dash"]
        case .hlsDiscovery:
            return ["hls_discovery"]
        case .image:
            if let mime = contentType(from: record.response) {
                return [mime]
            }
            return ["image"]
        case .video:
            if let mime = contentType(from: record.response) {
                return [mime]
            }
            return ["video"]
        case .adXml(let kind):
            return ["ad_xml_\(kind.rawValue.lowercased())"]
        case .none:
            return nil
        }
    }

    private static func contentType(from response: CapturedResponse?) -> String? {
        response?.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.split(separator: ";").first.map(String.init)
    }
}

private extension MediaType {
    var categoryLabel: String {
        switch self {
        case .image: return "image"
        case .hls, .hlsDiscovery: return "hls"
        case .dash: return "dash"
        case .video: return "video"
        case .adXml: return "ad_xml"
        case .none: return "none"
        }
    }
}
