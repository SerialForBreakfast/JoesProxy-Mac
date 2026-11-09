import Foundation

/// Explicit retained-session comparison. Callers resolve approval and snapshot records before
/// invoking this synchronous, bounded engine. No state is retained and no source values are emitted.
enum InvestigationComparisonBrief {
    static let maximumSessionsPerSide = 16
    static let maximumAggregateInputBytes = 1_048_576
    static let maximumChanges = 32

    struct Source: Codable, Equatable, Sendable {
        var sessionID: String
        var captureSequence: UInt64?
        var analysisStatus: String
        var unavailableReason: String?
        var sourceSHA256: String?
    }

    struct Input: Sendable {
        var source: Source
        var record: SessionRecord?
        var brief: ResponseEvidenceBrief.Report?
    }

    struct Step: Codable, Equatable, Sendable {
        var baselineSessionID: String?
        var candidateSessionID: String?
        var alignment: String
        var structureComparison: String
        var wholeResponseBytesChanged: Bool?
    }

    struct Change: Codable, Equatable, Sendable {
        var baselineSessionID: String
        var candidateSessionID: String
        var path: String
        var kind: String
    }

    struct Report: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var status: String
        var baseline: [Source]
        var candidate: [Source]
        var steps: [Step]
        var changes: [Change]
        var omittedChangeCount: Int
        var incomparablePairCount: Int
        var scope = "Explicit retained session IDs only; chronological heuristic alignment by method, origin and sanitized path without queries. Redaction and repeated endpoints can make alignment ambiguous. Capture gaps, target behavior, effect delivery and cleanup are not inferred. Changes describe observed counts/types, not contract validity."
        var contentTrust = "captured_untrusted"
        var targetOutcome = "not_observed"
        var nextTools = ["response_evidence_brief", "client_cleanup_status"]
    }

    static func compare(baseline: [Input], candidate: [Input]) -> Report {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.source.sessionID, $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.source.sessionID, $0) })
        let alignment = TrajectoryDiffEngine.diffTrajectories(
            baseline: baseline.compactMap(\.record), candidate: candidate.compactMap(\.record),
            comparePayloadValues: false, includeOriginInSignature: true)
        var steps: [Step] = []
        var changes: [Change] = []
        var omitted = 0
        var incomparable = 0
        func change(_ baselineID: String, _ candidateID: String, _ path: String, _ kind: String) {
            if changes.count < maximumChanges {
                changes.append(Change(baselineSessionID: baselineID, candidateSessionID: candidateID, path: path, kind: kind))
            } else { omitted += 1 }
        }
        for aligned in alignment.alignedSteps {
            let baselineID = aligned.baselineSessionID?.uuidString
            let candidateID = aligned.candidateSessionID?.uuidString
            var step = Step(baselineSessionID: baselineID, candidateSessionID: candidateID,
                alignment: aligned.stepType == .matched ? "aligned_metadata" : aligned.stepType.rawValue,
                structureComparison: "unavailable")
            if let baselineID, let candidateID,
               let before = baselineByID[baselineID]?.brief, let after = candidateByID[candidateID]?.brief,
               before.status == "complete", after.status == "complete" {
                step.wholeResponseBytesChanged = before.sourceSHA256 != after.sourceSHA256
                let complete = before.structureCoverage == "complete" && after.structureCoverage == "complete"
                step.structureComparison = complete ? "complete" : "bounded"
                if !complete { incomparable += 1 }
                for difference in ResponseStructureChange.compare(before, after) {
                    change(baselineID, candidateID, difference.path, difference.kind)
                }
            } else if baselineID != nil && candidateID != nil { incomparable += 1 }
            steps.append(step)
        }
        let unavailable = (baseline + candidate).contains { $0.source.analysisStatus != "complete" }
        return Report(status: unavailable || incomparable > 0 || omitted > 0 ? "incomplete" : "complete",
            baseline: baseline.map(\.source), candidate: candidate.map(\.source), steps: steps,
            changes: changes, omittedChangeCount: omitted, incomparablePairCount: incomparable)
    }
}
