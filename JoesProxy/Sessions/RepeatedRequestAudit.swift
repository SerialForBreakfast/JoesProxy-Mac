import CryptoKit
import Foundation

enum RepeatedRequestAudit {
    struct Group: Encodable, Sendable {
        let representativeSessionID: UUID
        var occurrences = 0
        var comparableResponses = 0
        var repeatedResponses = 0
        var repeatedRequestBodyBytes = 0
        var repeatedResponseBodyBytes = 0
        var distinctComparableResponses = 0
        var firstHTTPErrorSessionID: UUID?
    }

    struct Report: Encodable, Sendable {
        let inspectedRequests: Int
        let skippedRequests: [String: Int]
        let skippedResponses: [String: Int]
        let omittedGroups: Int
        let groups: [Group]
    }

    private struct RequestKey: Hashable {
        let method: Data
        let scheme: String
        let host: String
        let port: Int
        let target: Data
        let body: SHA256.Digest
    }

    private struct ResponseKey: Hashable {
        let status: Int
        let body: SHA256.Digest
    }

    private struct Bucket {
        var group: Group
        var responses: Set<ResponseKey> = []
        var recordIndices: [Int] = []

        mutating func observeRequest(at index: Int, bytes: Int) {
            if group.occurrences > 0 { group.repeatedRequestBodyBytes += bytes }
            group.occurrences += 1
            recordIndices.append(index)
        }

        mutating func observeResponse(_ key: ResponseKey, bytes: Int) {
            group.comparableResponses += 1
            if !responses.insert(key).inserted {
                group.repeatedResponses += 1
                group.repeatedResponseBodyBytes += bytes
            }
            group.distinctComparableResponses = responses.count
        }
    }

    /// Captured entity bytes before HTTP content decoding. Missing legacy sizes with no
    /// retained data cannot establish that the original body was empty.
    private static func completeBody(_ data: Data?, size: Int?, incomplete: Bool) -> Data? {
        guard !incomplete else { return nil }
        if let data { return size == nil || size == data.count ? data : nil }
        return size == 0 ? Data() : nil
    }

    static func completeResponseBody(_ session: SessionRecord) -> Data? {
        guard let response = session.response, response.statusCode != 206, response.statusCode != 304,
              !response.headers.contains(where: { $0.name.lowercased() == "content-range" }) else { return nil }
        return completeBody(response.bodyData, size: response.bodySize,
            incomplete: response.bodyTruncated || response.bodyDeferred || response.recordingBodyOmissionReason != nil
                || session.responseCaptureLimitedByPressure == true)
    }

    static func inspect(_ records: [SessionRecord]) throws -> Report {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var remaining = 64 * 1024 * 1024
        var inspected = 0
        var skipped: [String: Int] = [:]
        var responseSkips: [String: Int] = [:]
        var buckets: [RequestKey: Bucket] = [:]
        var orderedKeys: [RequestKey] = []
        for (index, session) in records.enumerated() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
            let request = session.request
            guard session.state == .completed, request.inspectionKind != .tunneledTLS,
                  !CaptureMarkerConstants.isMarkerRecord(session) else {
                skipped["not_completed_http", default: 0] += 1
                continue
            }
            guard let body = completeBody(request.bodyData, size: request.bodySize,
                incomplete: request.bodyTruncated || request.bodyDeferred || request.recordingBodyOmissionReason != nil) else {
                skipped["incomplete_request_body", default: 0] += 1
                continue
            }
            let targetBytes = request.path.utf8.count + request.host.utf8.count + request.method.utf8.count
            guard inspected < 4096, targetBytes <= 16_384, targetBytes <= remaining,
                  body.count <= remaining - targetBytes else {
                skipped["work_limit", default: 0] += 1
                continue
            }
            remaining -= targetBytes + body.count
            inspected += 1
            let key = RequestKey(method: Data(request.method.utf8), scheme: request.scheme.rawValue,
                host: request.host.lowercased(), port: request.port ?? (request.scheme == .https ? 443 : 80),
                target: Data(request.path.utf8), body: SHA256.hash(data: body))
            if buckets[key] == nil { orderedKeys.append(key) }
            buckets[key, default: Bucket(group: Group(representativeSessionID: session.id))].observeRequest(at: index, bytes: body.count)
        }
        // Group requests first so a large one-off download never consumes the response budget.
        // Evaluate repeat groups in first-seen order for deterministic budget coverage.
        var groups: [Group] = []
        for key in orderedKeys {
            guard var bucket = buckets.removeValue(forKey: key), bucket.group.occurrences > 1 else { continue }
            for index in bucket.recordIndices {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
                let session = records[index]
                if bucket.group.firstHTTPErrorSessionID == nil, let status = session.response?.statusCode, status >= 400 {
                    bucket.group.firstHTTPErrorSessionID = session.id
                }
                guard let response = session.response, let bytes = completeResponseBody(session) else {
                    responseSkips["incomplete_or_partial_response", default: 0] += 1
                    continue
                }
                guard bytes.count <= remaining else {
                    responseSkips["work_limit", default: 0] += 1
                    continue
                }
                remaining -= bytes.count
                bucket.observeResponse(.init(status: response.statusCode, body: SHA256.hash(data: bytes)), bytes: bytes.count)
            }
            groups.append(bucket.group)
        }
        groups.sort {
            if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
            return $0.representativeSessionID.uuidString < $1.representativeSessionID.uuidString
        }
        return Report(inspectedRequests: inspected, skippedRequests: skipped, skippedResponses: responseSkips,
            omittedGroups: max(0, groups.count - 16), groups: Array(groups.prefix(16)))
    }
}
