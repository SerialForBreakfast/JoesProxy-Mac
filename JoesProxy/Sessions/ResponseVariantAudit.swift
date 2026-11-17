import CryptoKit
import Foundation

enum ResponseVariantAudit {
    struct Group: Encodable {
        var statusCode: Int
        var representativeSessionID: UUID
        var occurrences = 0
    }

    struct Groups: Encodable {
        let distinct: Int
        let omitted: Int
        let examples: [Group]
    }

    struct Report: Encodable {
        let matchedSessions: Int
        let bodyVariants: Groups
        let jsonShapes: Groups
        let skippedBodies: [String: Int]
        let skippedShapes: [String: Int]

        func encoded(compact: Bool) throws -> Data {
            let encoder = JSONEncoder()
            let ordinary = try encoder.encode(self)
            guard compact else { return ordinary }
            let table = try encoder.encode(TableReport(self))
            return table.count < ordinary.count ? table : ordinary
        }
    }

    struct ErrorReport: Encodable {
        let matchedHTTPFailures: Int
        let clusters: Groups
        let skippedBodies: [String: Int]
        let rawBodyFallbacks: [String: Int]

        init(_ records: [SessionRecord]) throws {
            let report = try inspect(records, endpoint: nil)
            matchedHTTPFailures = report.matchedSessions
            clusters = report.bodyVariants
            skippedBodies = report.skippedBodies
            rawBodyFallbacks = report.skippedShapes
        }
    }

    private struct TableReport: Encodable {
        let columns = ["statusCode", "occurrences", "representativeSessionID"]
        let matchedSessions: Int
        let bodyVariants: Table
        let jsonShapes: Table
        let skippedBodies: [String: Int]
        let skippedShapes: [String: Int]

        init(_ report: Report) {
            matchedSessions = report.matchedSessions
            skippedBodies = report.skippedBodies
            skippedShapes = report.skippedShapes
            bodyVariants = Table(report.bodyVariants)
            jsonShapes = Table(report.jsonShapes)
        }

        struct Table: Encodable {
            let distinct: Int
            let omitted: Int
            let rows: [Row]

            init(_ groups: Groups) {
                distinct = groups.distinct
                omitted = groups.omitted
                rows = groups.examples.map(Row.init)
            }
        }

        struct Row: Encodable {
            let group: Group
            func encode(to encoder: Encoder) throws {
                var row = encoder.unkeyedContainer()
                try row.encode(group.statusCode)
                try row.encode(group.occurrences)
                try row.encode(group.representativeSessionID)
            }
        }
    }

    private struct Key: Hashable {
        let status: Int
        let digest: SHA256.Digest
        var normalizedJSON = false
    }

    /// Hash a type tree. Object fields use length-prefixed UTF-8 keys and fixed-size child
    /// digests. Arrays describe the set of element shapes, independent of order and length.
    private static func signature(_ value: ArtifactJSONValue, preserveValues: Bool) -> SHA256.Digest {
        var hash = SHA256()
        switch value {
        case .null: hash.update(data: [0])
        case .boolean(let flag):
            hash.update(data: [1])
            if preserveValues { hash.update(data: [flag ? 1 : 0]) }
        case .number(let lexeme):
            hash.update(data: [2])
            if preserveValues { hash.update(data: Data(lexeme.utf8)) }
        case .string(let text):
            hash.update(data: [3])
            if preserveValues { hash.update(data: Data(text.utf8)) }
        case .array(let values):
            hash.update(data: [4])
            let elements = values.map { Data(signature($0, preserveValues: preserveValues)) }
            let ordered = preserveValues ? elements : Set(elements).sorted { $0.lexicographicallyPrecedes($1) }
            for child in ordered { hash.update(data: child) }
        case .object(let members):
            hash.update(data: [5])
            for (key, child) in members.sorted(by: { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }) {
                let length = UInt64(key.utf8.count).bigEndian
                withUnsafeBytes(of: length) { hash.update(bufferPointer: $0) }
                hash.update(data: Data(key.utf8))
                hash.update(data: Data(signature(child, preserveValues: preserveValues)))
            }
        }
        return hash.finalize()
    }

    private static func summarize(_ groups: [Key: Group], includeRarest: Bool = false) -> Groups {
        let sorted = groups.values.sorted {
            let lhsError = $0.statusCode >= 400, rhsError = $1.statusCode >= 400
            if lhsError != rhsError { return lhsError }
            if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
            return $0.representativeSessionID.uuidString < $1.representativeSessionID.uuidString
        }
        var examples = Array(sorted.prefix(16))
        if includeRarest, sorted.count > 16, let rare = sorted.last, let last = examples.last,
           rare.occurrences < last.occurrences { examples[15] = rare }
        return Groups(distinct: groups.count, omitted: groups.count - examples.count, examples: examples)
    }

    // An endpoint selects the variant audit. A nil endpoint selects capture-wide HTTP errors.
    static func inspect(_ records: [SessionRecord], endpoint: CapturedRequest?) throws -> Report {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var bodies: [Key: Group] = [:], shapes: [Key: Group] = [:]
        var cachedShapes: [SHA256.Digest: SHA256.Digest] = [:]
        var skippedBodies: [String: Int] = [:], skippedShapes: [String: Int] = [:]
        var matched = 0, remaining = 32 * 1024 * 1024
        for session in records {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
            let request = session.request
            guard request.inspectionKind != .tunneledTLS, !CaptureMarkerConstants.isMarkerRecord(session) else { continue }
            if let endpoint {
                let port = endpoint.port ?? (endpoint.scheme == .https ? 443 : 80)
                guard request.scheme == endpoint.scheme, (request.port ?? (request.scheme == .https ? 443 : 80)) == port,
                      request.host.caseInsensitiveCompare(endpoint.host) == .orderedSame,
                      request.method.utf8.elementsEqual(endpoint.method.utf8),
                      request.path.utf8.elementsEqual(endpoint.path.utf8) else { continue }
            } else if !(400...599).contains(session.response?.statusCode ?? 0) { continue }
            matched += 1
            guard session.state == .completed, let response = session.response,
                  let bytes = RepeatedRequestAudit.completeResponseBody(session) else {
                skippedBodies["incomplete", default: 0] += 1
                continue
            }
            guard matched <= 4096, bytes.count <= remaining else {
                skippedBodies["work_limit", default: 0] += 1
                continue
            }
            remaining -= bytes.count
            let key = Key(status: response.statusCode, digest: SHA256.hash(data: bytes))
            let example = Group(statusCode: key.status, representativeSessionID: session.id)
            var cluster = key
            defer { bodies[cluster, default: example].occurrences += 1 }
            let mime = response.headers.first { $0.name.lowercased() == "content-type" }?.value
                .components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard mime == "application/json" || mime.hasSuffix("+json") else {
                skippedShapes["not_json", default: 0] += 1
                continue
            }
            var json = bytes
            var jsonDigest = key.digest
            if response.headers.contains(where: { ["content-encoding", "transfer-encoding"].contains($0.name.lowercased()) }) {
                guard bytes.count <= 262_144, remaining > 0,
                      let decoded = CapturedBodyDecoder.decode(bodyData: bytes, headers: response.headers,
                        maxDecodedBytes: min(remaining, 262_144)), decoded.canUseAnalysisDataForInspection,
                      decoded.analysisData.count <= min(remaining, 262_144) else {
                    skippedShapes["decode_unavailable_or_limit", default: 0] += 1
                    continue
                }
                json = decoded.analysisData
                remaining -= json.count
                jsonDigest = SHA256.hash(data: json)
            }
            let signature: SHA256.Digest
            if let cached = cachedShapes[jsonDigest] { signature = cached }
            else {
                do {
                    var reader = try ArtifactJSONReader(data: json,
                        limits: .init(bytes: 262_144, tokens: 4096, depth: 32), deadline: deadline)
                    signature = Self.signature(try reader.read(), preserveValues: endpoint == nil)
                    cachedShapes[jsonDigest] = signature
                } catch let failure as ArtifactAnalysisFailure where failure == .inputLimit || failure == .malformedSource {
                    skippedShapes[failure.rawValue, default: 0] += 1
                    continue
                }
            }
            if endpoint == nil {
                cluster = Key(status: key.status, digest: signature, normalizedJSON: true)
            } else {
                shapes[Key(status: key.status, digest: signature), default: example].occurrences += 1
            }
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
        return Report(matchedSessions: matched, bodyVariants: summarize(bodies, includeRarest: endpoint == nil), jsonShapes: summarize(shapes),
                      skippedBodies: skippedBodies, skippedShapes: skippedShapes)
    }
}
