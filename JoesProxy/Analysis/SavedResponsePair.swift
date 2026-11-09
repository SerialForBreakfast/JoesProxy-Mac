import Foundation

struct SavedResponsePair: Sendable {
    static let version = "artifact-response-comparison-v1"
    struct Side: Codable, Sendable {
        let handle: String
        let snapshotRevision: String
        let recordIndex: Int

        init(_ raw: Any?) throws {
            guard let fields = raw as? [String: Any], Set(fields.keys) == ["handle", "snapshotRevision", "recordIndex"],
                  let handle = fields["handle"] as? String, UUID(uuidString: handle) != nil,
                  let revision = fields["snapshotRevision"] as? String, UUID(uuidString: revision) != nil else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            self.handle = handle
            snapshotRevision = revision
            recordIndex = try SavedResponseBrief(arguments: fields).recordIndex
        }
    }

    let baseline: Side
    let candidate: Side
    let pointer: String

    init(_ arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["baseline", "candidate", "selectionPointer"]),
              arguments["selectionPointer"] == nil || arguments["selectionPointer"] is String else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
        baseline = try Side(arguments["baseline"])
        candidate = try Side(arguments["candidate"])
        pointer = arguments["selectionPointer"] as? String ?? ""
        guard pointer.utf8.count <= 512, (try? CollectionMockCompiler.pointer(pointer)) != nil else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
    }

    struct Coverage: Encodable, Sendable {
        let source: Side
        let reason: String
        let structureCoverage: String?
        let limits: [String]
        let sourceWarnings: [String]
    }
    struct Report: Encodable, Sendable {
        let analyzerVersion = SavedResponsePair.version
        let contentTrust = "captured_untrusted"
        let selectionPointer: String
        let baseline: Coverage
        let candidate: Coverage
        let wholeResponseBytesEqual: Bool?
        var changes: [ResponseStructureChange]
        var omittedChangeCount: Int
        var status: String
    }

    func report(baseline old: ArtifactSnapshot, candidate new: ArtifactSnapshot,
                isConnected: @Sendable () -> Bool = { true }) throws -> Report {
        func analyze(_ side: Side, _ snapshot: ArtifactSnapshot) throws -> ResponseEvidenceBrief.Report {
            try Task.checkCancellation()
            guard isConnected() else { throw ArtifactAnalysisFailure.cancelled }
            return try SavedResponseBrief(arguments: ["recordIndex": side.recordIndex, "selectionPointer": pointer,
                "includeStructure": true]).report(snapshot: snapshot)
        }
        let lhs = try analyze(baseline, old)
        let rhs = try analyze(candidate, new)
        let complete = lhs.structureCoverage == "complete" && rhs.structureCoverage == "complete"
        let changes = ResponseStructureChange.compare(lhs, rhs).sorted { ($0.path, $0.kind) < ($1.path, $1.kind) }
        let limit = InvestigationComparisonBrief.maximumChanges
        return Report(selectionPointer: pointer,
            baseline: .init(source: baseline, reason: lhs.status, structureCoverage: lhs.structureCoverage,
                limits: lhs.structureLimits ?? [], sourceWarnings: old.warnings),
            candidate: .init(source: candidate, reason: rhs.status, structureCoverage: rhs.structureCoverage,
                limits: rhs.structureLimits ?? [], sourceWarnings: new.warnings),
            wholeResponseBytesEqual: lhs.sourceSHA256.flatMap { a in rhs.sourceSHA256.map { a == $0 } },
            changes: Array(changes.prefix(limit)), omittedChangeCount: max(0, changes.count - limit),
            status: complete && changes.count <= limit ? "complete" : "incomplete")
    }
}

struct ResponseStructureChange: Encodable, Sendable {
    let path: String
    let kind: String
    let before: Value?
    let after: Value?

    enum Value: Encodable, Sendable {
        case count(Int), types([String: Int])
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .count(let n): try container.encode(n)
            case .types(let counts): try container.encode(counts)
            }
        }
    }

    static func compare(_ lhs: ResponseEvidenceBrief.Report, _ rhs: ResponseEvidenceBrief.Report) -> [Self] {
        guard lhs.status == "complete", rhs.status == "complete" else { return [] }
        var changes: [Self] = []
        func record(_ path: String, _ kind: String, _ before: Value?, _ after: Value?) {
            changes.append(.init(path: path, kind: kind, before: before, after: after))
        }
        if lhs.itemCount != rhs.itemCount { record("$", "selected_item_count_changed", lhs.itemCount.map(Value.count), rhs.itemCount.map(Value.count)) }
        if lhs.itemTypes != rhs.itemTypes { record("$", "selected_item_types_changed", .types(lhs.itemTypes), .types(rhs.itemTypes)) }
        let old = Dictionary(uniqueKeysWithValues: (lhs.structure ?? []).map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: (rhs.structure ?? []).map { ($0.path, $0) })
        for path in Set(old.keys).union(new.keys).sorted() {
            if let a = old[path], let b = new[path] {
                if a.types != b.types { record(path, "type_counts_changed", .types(a.types), .types(b.types)) }
                if a.occurrences != b.occurrences { record(path, "occurrence_count_changed", .count(a.occurrences), .count(b.occurrences)) }
                if a.missingFromParentObjects != b.missingFromParentObjects {
                    record(path, "missing_count_changed", .count(a.missingFromParentObjects), .count(b.missingFromParentObjects))
                }
            } else if lhs.structureCoverage == "complete", rhs.structureCoverage == "complete" {
                record(path, old[path] == nil ? "observed_path_added" : "observed_path_removed",
                    old[path].map { .count($0.occurrences) }, new[path].map { .count($0.occurrences) })
            }
        }
        return changes
    }
}
