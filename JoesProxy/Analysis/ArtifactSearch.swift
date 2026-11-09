import Foundation

/// A cursor compares the original UTF-8 bytes, including canonically distinct spellings.
struct ArtifactSearchQuery: Equatable, Sendable {
    enum Dataset: String, Sendable { case inventory, sourceUTF8, responseJSON }
    let dataset: Dataset
    let literal: [UInt8]
    let method: Data?
    let status: Int?
    let ordinals: [Int]?
    let limit: Int

    init(inventory: Bool, arguments: [String: Any]) throws {
        var keys: Set<String> = ["handle", "snapshotRevision", "method", "statusCode", "recordIndices", "limit", "cursor"]
        if !inventory { keys.formUnion(["dataset", "literal"]) }
        guard Set(arguments.keys).isSubset(of: keys),
              arguments["cursor"] == nil || (arguments["cursor"] as? String).flatMap(UUID.init(uuidString:)) != nil else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
        if inventory {
            dataset = .inventory
            literal = []
        } else {
            guard let name = arguments["dataset"] as? String, let value = Dataset(rawValue: name), value != .inventory,
                  let text = arguments["literal"] as? String, (3...4096).contains(text.utf8.count) else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            dataset = value
            literal = Array(text.utf8)
        }
        func integer(_ value: Any, _ range: ClosedRange<Int>) throws -> Int {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == Double(n.intValue), range.contains(n.intValue) else { throw ArtifactAnalysisFailure.malformedRequest }
            return n.intValue
        }
        limit = try arguments["limit"].map { try integer($0, 1...50) } ?? 20
        status = try arguments["statusCode"].map { try integer($0, 100...599) }
        method = try arguments["method"].map {
            guard let text = $0 as? String, (1...256).contains(text.utf8.count) else { throw ArtifactAnalysisFailure.malformedRequest }
            return Data(text.utf8)
        }
        ordinals = try arguments["recordIndices"].map {
            guard let array = $0 as? [Any], (1...256).contains(array.count) else { throw ArtifactAnalysisFailure.malformedRequest }
            let indices = try array.map { try integer($0, 0...999) }
            guard indices == indices.sorted(), Set(indices).count == indices.count else { throw ArtifactAnalysisFailure.malformedRequest }
            return indices
        }
    }
}

enum ArtifactSearch {
    struct Position: Sendable {
        var record = 0
        var offset = 0
        var prefix = 0
        var observed = 0
        var searched = 0
        var excluded = 0
        var omissions: [String: Int] = [:]
    }

    struct Item: Codable, Sendable {
        var recordIndex: Int?
        var method: String?
        var statusCode: Int?
        var representationAvailable: Bool?
        var matchRef: String?
        var byteOffset: Int?
        var byteLength: Int?
        var kind: String?
        var sourceBytes: Int?
        var datasets: [String]?
    }

    struct Page: Sendable {
        var items: [Item] = []
        var position: Position
        let domainCount: Int
        var scannedBytes = 0
        var completeTraversal: Bool { position.record == domainCount }
    }

    private static func prefixes(_ pattern: [UInt8]) -> [Int] {
        var table = Array(repeating: 0, count: pattern.count)
        var n = 0
        for i in pattern.indices.dropFirst() {
            while n > 0 && pattern[n] != pattern[i] { n = table[n - 1] }
            if pattern[n] == pattern[i] { n += 1 }
            table[i] = n
        }
        return table
    }

    static func page(snapshot: ArtifactSnapshot, query: ArtifactSearchQuery, from start: Position,
                     byteBudget: Int = 1_048_576, recordBudget: Int = 256, nativeProbe: Bool = false) throws -> Page {
        let records = snapshot.kind == .har || snapshot.kind == .recording
        guard query.dataset == .inventory ||
                (query.dataset == .sourceUTF8 && [.text, .json].contains(snapshot.kind)) ||
                (query.dataset == .responseJSON && records) else { throw ArtifactAnalysisFailure.unsupportedKind }
        guard records || (query.ordinals == nil && query.method == nil && query.status == nil),
              query.ordinals?.last.map({ $0 < snapshot.records.count }) != false else { throw ArtifactAnalysisFailure.malformedRequest }
        let domain = records ? query.ordinals?.count ?? snapshot.records.count : 1
        var page = Page(position: start, domainCount: domain)
        let pattern = query.literal
        let needle = nativeProbe ? Data(pattern) : nil
        let failure = prefixes(pattern)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var itemBytes = 0
        // Leave room for fixed-size provenance, coverage, RPC framing and the compact text summary.
        func append(_ item: Item) throws -> Bool {
            let bytes = try JSONEncoder().encode(item).count
            guard itemBytes + bytes <= 5900 else { return false }
            itemBytes += bytes
            page.items.append(item)
            page.position.observed += 1
            return true
        }
        while page.position.record < domain, page.items.count < query.limit,
              page.position.record - start.record < recordBudget, page.scannedBytes < byteBudget {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { break }
            let ordinal = query.ordinals?[page.position.record] ?? page.position.record
            let record = records ? snapshot.records[ordinal] : nil
            let searchableResponse = record?.hasSearchableUTF8 == true ? record?.responseJSON : nil
            var method: String?
            var status: Int?
            if case .string(let value) = record?.metadata.member("method") { method = value }
            if case .number(let value) = record?.metadata.member("statusCode") { status = Int(value) }
            if let expected = query.method, let method, expected != Data(method.utf8) {
                page.position.excluded += 1
            } else if let expected = query.status, let status, expected != status {
                page.position.excluded += 1
            } else if records && (record == nil || (query.status != nil && status == nil) || (query.method != nil && method == nil)) {
                page.position.omissions[record == nil ? "invalid_record" : "filter_field_missing", default: 0] += 1
            } else if query.dataset == .inventory {
                let item = records ? Item(recordIndex: ordinal, method: method, statusCode: status, representationAvailable: searchableResponse != nil)
                    : Item(kind: snapshot.kind.rawValue, sourceBytes: snapshot.byteCount, datasets: [.text, .json].contains(snapshot.kind) ? ["sourceUTF8"] : [])
                guard try append(item) else { break }
                page.position.searched += 1
            } else if let bytes = records ? searchableResponse : snapshot.originalBytes {
                if records, let needle, page.position.offset == 0, bytes.count <= 16_384,
                   bytes.count * 2 <= byteBudget - page.scannedBytes {
                    page.scannedBytes += bytes.count
                    if bytes.range(of: needle) == nil {
                        page.position.record += 1
                        page.position.searched += 1
                        continue
                    }
                }
                // Stop before an unreportable match. Each reference row is under 160 encoded bytes.
                let stop = min(bytes.count, page.position.offset + byteBudget - page.scannedBytes)
                while page.position.offset < stop && page.items.count < query.limit && itemBytes <= 5740 {
                    if page.scannedBytes.isMultiple(of: 4096) {
                        try Task.checkCancellation()
                        if ContinuousClock.now >= deadline { break }
                    }
                    let byte = bytes[bytes.startIndex + page.position.offset]
                    while page.position.prefix > 0 && byte != pattern[page.position.prefix] {
                        page.position.prefix = failure[page.position.prefix - 1]
                    }
                    if byte == pattern[page.position.prefix] { page.position.prefix += 1 }
                    page.position.offset += 1
                    page.scannedBytes += 1
                    if page.position.prefix == pattern.count {
                        guard try append(Item(recordIndex: records ? ordinal : nil, matchRef: UUID().uuidString,
                                              byteOffset: page.position.offset - pattern.count, byteLength: pattern.count)) else {
                            throw ArtifactAnalysisFailure.outputLimit
                        }
                        page.position.prefix = 0
                    }
                }
                if page.position.offset < bytes.count { break }
                page.position.searched += 1
            } else {
                page.position.omissions["representation_unavailable", default: 0] += 1
            }
            page.position.record += 1
            page.position.offset = 0
            page.position.prefix = 0
        }
        if query.ordinals == nil && snapshot.warnings.contains("declared_count_mismatch") {
            page.position.omissions["declared_count_mismatch"] = 1
        }
        guard page.completeTraversal || page.position.record != start.record || page.position.offset != start.offset else {
            throw ArtifactAnalysisFailure.deadlineExceeded
        }
        return page
    }
}
