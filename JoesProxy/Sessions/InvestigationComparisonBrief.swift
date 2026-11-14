import CoreFoundation
import Foundation

/// Explicit retained-session comparison. Callers resolve approval and snapshot records before
/// invoking this synchronous, bounded engine. No state is retained and no source values are emitted
/// unless value-diff mode is explicitly requested.
enum InvestigationComparisonBrief {
    static let maximumSessionsPerSide = 16
    static let maximumAggregateInputBytes = 1_048_576
    static let maximumChanges = 32
    static let maximumValueChanges = 32
    static let maximumValueDiffDepth = 6
    static let maximumValueDiffVisits = 10_000

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
        var bodyText: String? = nil
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

    struct ValueChange: Codable, Equatable, Sendable {
        var baselineSessionID: String
        var candidateSessionID: String
        var pointer: String
        var kind: String
        var beforeType: String?
        var afterType: String?
        var beforePreview: String?
        var afterPreview: String?
        var beforeValue: Bool?
        var afterValue: Bool?
        var isLikelyVolatile: Bool
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
        var valueChanges: [ValueChange]?
        var omittedValueChangeCount: Int?
        var volatileChangeCount: Int?
        var scope = "Explicit retained session IDs only; chronological heuristic alignment by method, origin and sanitized path without queries. Redaction and repeated endpoints can make alignment ambiguous. Capture gaps, target behavior, effect delivery and cleanup are not inferred. Changes describe observed counts/types, not contract validity."
        var contentTrust = "captured_untrusted"
        var targetOutcome = "not_observed"
        var nextTools = ["response_evidence_brief", "client_cleanup_status"]
    }

    static func validateIgnorePointers(_ ignorePointers: [String]) -> Bool {
        guard ignorePointers.count <= 16 else { return false }
        for pointer in ignorePointers {
            guard !pointer.isEmpty, pointer.utf8.count <= 128,
                  let tokens = try? CollectionMockCompiler.pointer(pointer),
                  !tokens.isEmpty, tokens.count <= 8 else {
                return false
            }
        }
        return true
    }

    static func compare(
        baseline: [Input],
        candidate: [Input],
        selectionPointer: String = "",
        includeValueDiff: Bool = false,
        ignorePointers: [String] = []
    ) -> Report {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.source.sessionID, $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.source.sessionID, $0) })
        let alignment = TrajectoryDiffEngine.diffTrajectories(
            baseline: baseline.compactMap(\.record), candidate: candidate.compactMap(\.record),
            comparePayloadValues: false, includeOriginInSignature: true)
        var steps: [Step] = []
        var changes: [Change] = []
        var omitted = 0
        var incomparable = 0
        var valueChanges: [ValueChange] = []
        var omittedValueChanges = 0
        var volatileChanges = 0
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
               let beforeInput = baselineByID[baselineID], let afterInput = candidateByID[candidateID],
               let before = beforeInput.brief, let after = afterInput.brief,
               before.status == "complete", after.status == "complete" {
                step.wholeResponseBytesChanged = before.sourceSHA256 != after.sourceSHA256
                let complete = before.structureCoverage == "complete" && after.structureCoverage == "complete"
                step.structureComparison = complete ? "complete" : "bounded"
                if !complete { incomparable += 1 }
                for difference in ResponseStructureChange.compare(before, after) {
                    change(baselineID, candidateID, difference.path, difference.kind)
                }
                if includeValueDiff, before.sourceSHA256 != after.sourceSHA256,
                   let beforeText = beforeInput.bodyText, let afterText = afterInput.bodyText {
                    diffJSONValues(
                        baselineID: baselineID,
                        candidateID: candidateID,
                        beforeText: beforeText,
                        afterText: afterText,
                        selectionPointer: selectionPointer,
                        ignorePointers: ignorePointers,
                        valueChanges: &valueChanges,
                        omittedCount: &omittedValueChanges,
                        volatileCount: &volatileChanges
                    )
                }
            } else if baselineID != nil && candidateID != nil { incomparable += 1 }
            steps.append(step)
        }
        let unavailable = (baseline + candidate).contains { $0.source.analysisStatus != "complete" }
        var report = Report(
            status: unavailable || incomparable > 0 || omitted > 0 || omittedValueChanges > 0 ? "incomplete" : "complete",
            baseline: baseline.map(\.source),
            candidate: candidate.map(\.source),
            steps: steps,
            changes: changes,
            omittedChangeCount: omitted,
            incomparablePairCount: incomparable
        )
        if includeValueDiff {
            report.valueChanges = valueChanges
            report.omittedValueChangeCount = omittedValueChanges
            report.volatileChangeCount = volatileChanges
        }
        return report
    }

    private static func diffJSONValues(
        baselineID: String,
        candidateID: String,
        beforeText: String,
        afterText: String,
        selectionPointer: String,
        ignorePointers: [String],
        valueChanges: inout [ValueChange],
        omittedCount: inout Int,
        volatileCount: inout Int
    ) {
        guard let beforeRoot = try? JSONSerialization.jsonObject(with: Data(beforeText.utf8), options: [.fragmentsAllowed]),
              let afterRoot = try? JSONSerialization.jsonObject(with: Data(afterText.utf8), options: [.fragmentsAllowed]),
              let tokens = try? CollectionMockCompiler.pointer(selectionPointer),
              let beforeSelected = ResponseEvidenceBrief.select(beforeRoot, tokens: tokens),
              let afterSelected = ResponseEvidenceBrief.select(afterRoot, tokens: tokens) else {
            return
        }
        var visits = 0
        func shouldIgnore(_ pointer: String) -> Bool {
            ignorePointers.contains { ignored in
                pointer == ignored || pointer.hasPrefix(ignored + "/")
            }
        }
        func recordChange(pointer: String, leafKey: String, kind: String, beforeVal: Any?, afterVal: Any?) {
            let effPointer = pointer.isEmpty ? "/" : pointer
            if shouldIgnore(effPointer) { return }
            let sensitive = SensitiveDataRedaction.isSensitiveKey(leafKey)
            let volatile = isLikelyVolatile(pointer: effPointer, leafKey: leafKey, beforeVal: beforeVal, afterVal: afterVal)
            if volatile { volatileCount += 1 }
            guard valueChanges.count < maximumValueChanges else {
                omittedCount += 1
                return
            }
            func boolean(_ value: Any?) -> Bool? {
                guard !sensitive, let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                return number.boolValue
            }
            let beforeBoolean = boolean(beforeVal)
            let afterBoolean = boolean(afterVal)
            valueChanges.append(
                ValueChange(
                    baselineSessionID: baselineID,
                    candidateSessionID: candidateID,
                    pointer: effPointer,
                    kind: kind,
                    beforeType: beforeVal.map(ResponseEvidenceBrief.type),
                    afterType: afterVal.map(ResponseEvidenceBrief.type),
                    beforePreview: beforeBoolean == nil ? beforeVal.flatMap { ResponseEvidenceBrief.formatProjectedScalar($0, sensitiveKey: sensitive) } : nil,
                    afterPreview: afterBoolean == nil ? afterVal.flatMap { ResponseEvidenceBrief.formatProjectedScalar($0, sensitiveKey: sensitive) } : nil,
                    beforeValue: beforeBoolean,
                    afterValue: afterBoolean,
                    isLikelyVolatile: volatile
                )
            )
        }
        func walk(pointer: String, leafKey: String, lhs: Any, rhs: Any, depth: Int) {
            guard visits < maximumValueDiffVisits else { return }
            visits += 1
            let effPointer = pointer.isEmpty ? "/" : pointer
            if shouldIgnore(effPointer) { return }
            let lhsType = ResponseEvidenceBrief.type(lhs)
            let rhsType = ResponseEvidenceBrief.type(rhs)
            guard lhsType == rhsType else {
                recordChange(pointer: pointer, leafKey: leafKey, kind: "type_changed", beforeVal: lhs, afterVal: rhs)
                return
            }
            if let lhsDict = lhs as? [String: Any], let rhsDict = rhs as? [String: Any] {
                guard depth < maximumValueDiffDepth else {
                    if !NSDictionary(dictionary: lhsDict).isEqual(to: rhsDict) {
                        recordChange(pointer: pointer, leafKey: leafKey, kind: "modified", beforeVal: lhs, afterVal: rhs)
                    }
                    return
                }
                let keys = Set(lhsDict.keys).union(rhsDict.keys).sorted()
                for key in keys {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    let childPointer = pointer + "/" + escaped
                    switch (lhsDict[key], rhsDict[key]) {
                    case (let l?, let r?):
                        walk(pointer: childPointer, leafKey: key, lhs: l, rhs: r, depth: depth + 1)
                    case (let l?, nil):
                        recordChange(pointer: childPointer, leafKey: key, kind: "removed", beforeVal: l, afterVal: nil)
                    case (nil, let r?):
                        recordChange(pointer: childPointer, leafKey: key, kind: "added", beforeVal: nil, afterVal: r)
                    case (nil, nil):
                        break
                    }
                }
                return
            }
            if let lhsArr = lhs as? [Any], let rhsArr = rhs as? [Any] {
                guard depth < maximumValueDiffDepth else {
                    if !NSArray(array: lhsArr).isEqual(to: rhsArr) {
                        recordChange(pointer: pointer, leafKey: leafKey, kind: "modified", beforeVal: lhs, afterVal: rhs)
                    }
                    return
                }
                let maxCount = min(max(lhsArr.count, rhsArr.count), 64)
                for idx in 0..<maxCount {
                    let childPointer = pointer + "/\(idx)"
                    if idx < lhsArr.count && idx < rhsArr.count {
                        walk(pointer: childPointer, leafKey: leafKey, lhs: lhsArr[idx], rhs: rhsArr[idx], depth: depth + 1)
                    } else if idx < lhsArr.count {
                        recordChange(pointer: childPointer, leafKey: leafKey, kind: "removed", beforeVal: lhsArr[idx], afterVal: nil)
                    } else {
                        recordChange(pointer: childPointer, leafKey: leafKey, kind: "added", beforeVal: nil, afterVal: rhsArr[idx])
                    }
                }
                return
            }
            if !scalarsEqual(lhs, rhs) {
                recordChange(pointer: pointer, leafKey: leafKey, kind: "modified", beforeVal: lhs, afterVal: rhs)
            }
        }
        walk(pointer: "", leafKey: "", lhs: beforeSelected, rhs: afterSelected, depth: 0)
    }

    private static func scalarsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull && rhs is NSNull { return true }
        if let lStr = lhs as? String, let rStr = rhs as? String { return lStr == rStr }
        if let lNum = lhs as? NSNumber, let rNum = rhs as? NSNumber {
            let lBool = CFGetTypeID(lNum) == CFBooleanGetTypeID()
            let rBool = CFGetTypeID(rNum) == CFBooleanGetTypeID()
            guard lBool == rBool else { return false }
            return lBool ? (lNum.boolValue == rNum.boolValue) : (lNum.doubleValue == rNum.doubleValue)
        }
        return false
    }

    private static func isLikelyVolatile(pointer: String, leafKey: String, beforeVal: Any?, afterVal: Any?) -> Bool {
        let lowerKey = leafKey.lowercased()
        let lowerPointer = pointer.lowercased()
        let volatileFragments = [
            "timestamp", "created_at", "createdat", "updated_at", "updatedat",
            "expires_at", "expiresat", "nonce", "request_id", "requestid",
            "trace_id", "traceid", "span_id", "spanid", "etag"
        ]
        if volatileFragments.contains(where: { lowerKey.contains($0) || lowerPointer.contains($0) }) {
            return true
        }
        if let bStr = beforeVal as? String, let aStr = afterVal as? String {
            if UUID(uuidString: bStr) != nil && UUID(uuidString: aStr) != nil {
                return true
            }
            if looksLikeISO8601(bStr) && looksLikeISO8601(aStr) {
                return true
            }
        }
        return false
    }

    private static func looksLikeISO8601(_ value: String) -> Bool {
        guard value.count >= 19, value.count <= 40 else { return false }
        let bytes = Array(value.utf8)
        return bytes.count >= 19 &&
            bytes[4] == UInt8(ascii: "-") &&
            bytes[7] == UInt8(ascii: "-") &&
            (bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ")) &&
            bytes[13] == UInt8(ascii: ":") &&
            bytes[16] == UInt8(ascii: ":")
    }
}
