import Foundation

struct SavedResponseBrief: Sendable {
    let recordIndex: Int
    let pointer: String
    let structure: Bool

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["handle", "snapshotRevision", "recordIndex", "selectionPointer", "includeStructure"]),
              let n = arguments["recordIndex"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue == Double(n.intValue), (0..<1000).contains(n.intValue),
              arguments["selectionPointer"] == nil || arguments["selectionPointer"] is String else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
        recordIndex = n.intValue
        pointer = arguments["selectionPointer"] as? String ?? ""
        guard pointer.utf8.count <= 512, (try? CollectionMockCompiler.pointer(pointer)) != nil else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
        if let supplied = arguments["includeStructure"] {
            guard let value = supplied as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            structure = value.boolValue
        } else { structure = false }
    }

    func report(snapshot: ArtifactSnapshot) throws -> ResponseEvidenceBrief.Report {
        func unavailable(_ reason: String) -> ResponseEvidenceBrief.Report {
            .init(status: reason, selectionPointer: pointer)
        }
        guard snapshot.kind == .recording || snapshot.kind == .har else { throw ArtifactAnalysisFailure.unsupportedKind }
        guard snapshot.records.indices.contains(recordIndex) else { return unavailable("record_out_of_range") }
        guard let record = snapshot.records[recordIndex] else { return unavailable("invalid_record") }
        guard record.responseComplete else { return unavailable("incomplete_body") }
        guard let bytes = record.responseJSON else { return unavailable("representation_unavailable") }
        guard bytes.count <= ResponseEvidenceBrief.maximumInputBytes else { return unavailable("input_limit") }
        guard let text = String(data: bytes, encoding: .utf8) else { return unavailable("invalid_utf8") }
        try Task.checkCancellation()
        var report = ResponseEvidenceBrief.analyze(text: text, truncated: false, unavailableReason: nil,
            pointer: pointer, includeStructure: structure)
        let encoder = JSONEncoder()
        while try encoder.encode(report).count > 60_000 {
            guard report.structure?.isEmpty == false else { throw ArtifactAnalysisFailure.outputLimit }
            report.structure?.removeLast()
            report.structureCoverage = "bounded"
            report.structureLimits = Array(Set((report.structureLimits ?? []) + ["output_limit"])).sorted()
        }
        return report
    }
}
