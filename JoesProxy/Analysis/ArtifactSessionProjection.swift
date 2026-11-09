import Foundation

/// Same retained-evidence rules for captured records and decoded saved records. No body hydration,
/// refetch, spool reads, or inference from a completed lifecycle alone.
struct ArtifactSessionProjection: Sendable {
    let metadata: ArtifactJSONValue
    let responseJSON: Data?
    let responseComplete: Bool
    let hasSearchableUTF8: Bool

    init(record: SessionRecord, responseOverride: Data? = nil, completenessOverride: Bool? = nil, includeBody: Bool = true,
         prepareSearch: Bool = false) {
        let response = record.response
        let raw = responseOverride ?? response?.bodyData
        let complete = completenessOverride ?? (record.state == .completed && response != nil &&
            response?.bodyTruncated == false && response?.bodyDeferred == false &&
            response?.recordingBodyOmissionReason == nil && record.responseCaptureLimitedByPressure != true &&
            (raw != nil || response?.bodySize == 0) && (response?.bodySize ?? raw?.count ?? 0) <= (raw?.count ?? 0))
        responseComplete = complete
        var fields: [(String, ArtifactJSONValue)] = [
            ("method", .string(record.request.method)), ("responseBodyComplete", .boolean(complete))
        ]
        if let status = response?.statusCode { fields.append(("statusCode", .number(String(status)))) }
        if let count = record.request.bodyData?.count ?? (record.request.bodySize == 0 ? 0 : nil) { fields.append(("requestBodyRetainedBytes", .number(String(count)))) }
        if let count = raw?.count ?? (complete && response?.bodySize == 0 ? 0 : nil) { fields.append(("responseBodyRetainedBytes", .number(String(count)))) }
        if let count = response?.bodySize, count >= 0 { fields.append(("responseBodyDeclaredBytes", .number(String(count)))) }
        metadata = .object(fields)
        let headers = response?.headers ?? []
        let type = headers.first { $0.name.lowercased() == "content-type" }?.value
            .lowercased().split(separator: ";").first.map(String.init) ?? ""
        let jsonType = type == "application/json" || type == "text/json" || type.hasSuffix("+json")
        if includeBody, complete, jsonType, let raw, raw.count <= 1_048_576,
           let decoded = CapturedBodyDecoder.decode(bodyData: raw, headers: headers, maxDecodedBytes: 1_048_576),
           decoded.canUseAnalysisDataForInspection, decoded.analysisData.count <= 1_048_576 {
            responseJSON = decoded.analysisData
        } else { responseJSON = nil }
        hasSearchableUTF8 = prepareSearch && responseJSON.flatMap { String(data: $0, encoding: .utf8) } != nil
    }

    static func validateMetadata(_ query: ArtifactCalculation.Query) throws {
        let fields: Set<String> = ["/method", "/statusCode", "/requestBodyRetainedBytes",
            "/responseBodyRetainedBytes", "/responseBodyDeclaredBytes", "/responseBodyComplete"]
        guard query.selectionPointer.isEmpty,
              query.kind == .rowCount || fields.contains(query.fieldPointer) else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
    }
}
