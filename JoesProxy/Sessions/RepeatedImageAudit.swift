import CryptoKit
import Foundation

enum RepeatedImageAudit {
    struct Group: Encodable, Sendable {
        let representativeSessionID: UUID
        let distinctURLCount: Int
        let occurrences: Int
        let repeatedRepresentationBytes: Int
    }

    struct Report: Encodable, Sendable {
        let inspectedImages: Int
        let skippedByReason: [String: Int]
        let omittedGroups: Int
        let groups: [Group]
    }

    private struct Matches {
        let representative: UUID
        let bytes: Int
        var locations: Set<String> = []
        var occurrences = 0
    }

    static func inspect(_ sessions: [SessionRecord]) throws -> Report {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var matches: [SHA256.Digest: Matches] = [:]
        var skipped: [String: Int] = [:]
        var inspected = 0
        var remaining = 64 * 1024 * 1024
        for session in sessions {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
            guard let response = session.response,
                  response.headers.contains(where: { $0.name.lowercased() == "content-type" && $0.value.lowercased().hasPrefix("image/") }) else { continue }
            guard response.statusCode != 304, response.statusCode != 206,
                  !response.headers.contains(where: { $0.name.lowercased() == "content-range" }) else {
                skipped["range_or_revalidation", default: 0] += 1
                continue
            }
            guard response.statusCode == 200, session.state == .completed,
                  !response.bodyTruncated, !response.bodyDeferred, response.recordingBodyOmissionReason == nil,
                  let data = response.bodyData, !data.isEmpty, response.bodySize.map({ $0 == data.count }) ?? true else {
                skipped["incomplete_representation", default: 0] += 1
                continue
            }
            let limit = min(remaining, ImageInspectionPreflight.maximumEncodedBytes)
            guard data.count <= limit, inspected < 4096 else {
                skipped["work_limit", default: 0] += 1
                continue
            }
            guard let decoded = CapturedBodyDecoder.decode(bodyData: data, headers: response.headers, maxDecodedBytes: limit),
                  decoded.canUseAnalysisDataForInspection, !decoded.analysisData.isEmpty, decoded.analysisData.count <= limit else {
                skipped["decode_unavailable", default: 0] += 1
                continue
            }
            let bytes = decoded.analysisData
            remaining -= max(data.count, bytes.count)
            let digest = SHA256.hash(data: bytes)
            let request = session.request
            let port = request.port ?? (request.scheme == .https ? 443 : 80)
            let location = "\(request.scheme.rawValue)://\(request.host.lowercased()):\(port)\(request.path)"
            matches[digest, default: Matches(representative: session.id, bytes: bytes.count)].locations.insert(location)
            matches[digest]?.occurrences += 1
            inspected += 1
        }
        let groups = matches.values.filter { $0.occurrences > 1 }.map {
            Group(representativeSessionID: $0.representative, distinctURLCount: $0.locations.count,
                  occurrences: $0.occurrences, repeatedRepresentationBytes: $0.bytes * ($0.occurrences - 1))
        }.sorted {
            if $0.repeatedRepresentationBytes == $1.repeatedRepresentationBytes {
                return $0.representativeSessionID.uuidString < $1.representativeSessionID.uuidString
            }
            return $0.repeatedRepresentationBytes > $1.repeatedRepresentationBytes
        }
        return Report(inspectedImages: inspected, skippedByReason: skipped, omittedGroups: max(0, groups.count - 16),
                      groups: Array(groups.prefix(16)))
    }
}
