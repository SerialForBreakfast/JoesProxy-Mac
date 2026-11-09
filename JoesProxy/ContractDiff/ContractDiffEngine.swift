//
//  ContractDiffEngine.swift
//  JoesProxy
//
//  Deterministic recursive JSON shape diffing and API contract regression evaluation engine.
//

import Foundation

enum ContractDiffEngine {

    /// Recursively computes the structural diff between a baseline and a live JSONShape.
    static func diff(
        baseline: JSONShape?,
        live: JSONShape?,
        path: String = "$"
    ) -> [SchemaFieldDiff] {
        var diffs: [SchemaFieldDiff] = []

        guard let baseline else {
            if let live {
                diffs.append(
                    SchemaFieldDiff(
                        jsonPath: path,
                        kind: .addedField(actualType: describe(live)),
                        severity: .compatibleAddition,
                        explanation: "Field '\(path)' added in live response (\(describe(live)))."
                    )
                )
            }
            return diffs
        }

        guard let live else {
            diffs.append(
                SchemaFieldDiff(
                    jsonPath: path,
                    kind: .removedField(expectedType: describe(baseline)),
                    severity: .breaking,
                    explanation: "Field '\(path)' was removed from the response (expected \(describe(baseline)))."
                )
            )
            return diffs
        }

        switch (baseline, live) {
        case (.object(let baseProps), .object(let liveProps)):
            // Check missing or modified keys
            for (key, baseShape) in baseProps {
                let currentPath = path == "$" ? "$.\(key)" : "\(path).\(key)"
                if let liveShape = liveProps[key] {
                    diffs.append(contentsOf: diff(baseline: baseShape, live: liveShape, path: currentPath))
                } else {
                    diffs.append(
                        SchemaFieldDiff(
                            jsonPath: currentPath,
                            kind: .removedField(expectedType: describe(baseShape)),
                            severity: .breaking,
                            explanation: "Required property '\(key)' missing from object at '\(path)'."
                        )
                    )
                }
            }

            // Check newly added keys
            for (key, liveShape) in liveProps where baseProps[key] == nil {
                let currentPath = path == "$" ? "$.\(key)" : "\(path).\(key)"
                diffs.append(
                    SchemaFieldDiff(
                        jsonPath: currentPath,
                        kind: .addedField(actualType: describe(liveShape)),
                        severity: .compatibleAddition,
                        explanation: "New property '\(key)' added at '\(path)' (\(describe(liveShape)))."
                    )
                )
            }

        case (.array(let baseElem, _, _), .array(let liveElem, _, _)):
            let elementPath = "\(path)[*]"
            if let baseElem, let liveElem {
                diffs.append(contentsOf: diff(baseline: baseElem, live: liveElem, path: elementPath))
            } else if baseElem != nil && liveElem == nil {
                diffs.append(
                    SchemaFieldDiff(
                        jsonPath: elementPath,
                        kind: .removedField(expectedType: "element"),
                        severity: .breaking,
                        explanation: "Array at '\(path)' is empty; could not verify element contract."
                    )
                )
            }

        case (let baseScalar, .null):
            if baseScalar != .null {
                diffs.append(
                    SchemaFieldDiff(
                        jsonPath: path,
                        kind: .unexpectedNull(expectedType: describe(baseScalar)),
                        severity: .breaking,
                        explanation: "Field '\(path)' is null; expected non-null \(describe(baseScalar))."
                    )
                )
            }

        case (.string, .string), (.number, .number), (.bool, .bool), (.null, .null):
            // Types match identically; no diff
            break

        case (.mixed(let baseTypes), .mixed(let liveTypes)):
            if Set(baseTypes) != Set(liveTypes) {
                diffs.append(
                    SchemaFieldDiff(
                        jsonPath: path,
                        kind: .typeMutation(expectedType: describe(baseline), actualType: describe(live)),
                        severity: .breaking,
                        explanation: "Union types mismatch at '\(path)'."
                    )
                )
            }

        default:
            // Incompatible type mutation
            diffs.append(
                SchemaFieldDiff(
                    jsonPath: path,
                    kind: .typeMutation(expectedType: describe(baseline), actualType: describe(live)),
                    severity: .breaking,
                    explanation: "Type mutation at '\(path)': expected \(describe(baseline)), received \(describe(live))."
                )
            )
        }

        return diffs
    }

    /// Evaluates contract differences between a baseline session and a live session.
    static func compareSessions(
        baseline: SessionRecord,
        live: SessionRecord
    ) -> EndpointContractDiffReport {
        var diffs: [SchemaFieldDiff] = []

        let baseStatus = baseline.response?.statusCode ?? 0
        let liveStatus = live.response?.statusCode ?? 0

        if baseStatus != liveStatus {
            let isBreaking = (baseStatus >= 200 && baseStatus < 300) && (liveStatus >= 400)
            diffs.append(
                SchemaFieldDiff(
                    jsonPath: "$status",
                    kind: .statusCodeMismatch(expectedCode: baseStatus, actualCode: liveStatus),
                    severity: isBreaking ? .breaking : .informational,
                    explanation: "HTTP status code changed from \(baseStatus) to \(liveStatus)."
                )
            )
        }

        let baseBody = baseline.response?.bodyData ?? Data()
        let liveBody = live.response?.bodyData ?? Data()

        let baseProfile = JSONStructuralProfiler.profile(bodyData: baseBody)
        let liveProfile = JSONStructuralProfiler.profile(bodyData: liveBody)

        let bodyDiffs = diff(baseline: baseProfile.shape, live: liveProfile.shape)
        diffs.append(contentsOf: bodyDiffs)

        let breakingCount = diffs.filter { $0.severity == .breaking }.count
        let additionsCount = diffs.filter { $0.severity == .compatibleAddition }.count

        let method = live.request.method
        let path = live.request.path
        let endpoint = "\(method) \(live.request.host)\(path)"

        return EndpointContractDiffReport(
            endpoint: endpoint,
            method: method,
            path: path,
            isCompliant: breakingCount == 0,
            breakingChangeCount: breakingCount,
            compatibleAdditionCount: additionsCount,
            fieldDiffs: diffs
        )
    }

    /// Runs a full regression suite across multiple baseline and live sessions.
    static func runRegressionSuite(
        baselineSessions: [SessionRecord],
        liveSessions: [SessionRecord]
    ) -> ContractRegressionSuiteSummary {
        var reports: [EndpointContractDiffReport] = []

        // Match live sessions to baseline by method + path
        for live in liveSessions {
            let matchingBaseline = baselineSessions.first(where: {
                $0.request.method == live.request.method && $0.request.path == live.request.path
            }) ?? baselineSessions.first(where: { $0.request.path == live.request.path })

            if let base = matchingBaseline {
                reports.append(compareSessions(baseline: base, live: live))
            }
        }

        let totalTested = reports.count
        let breakingEndpoints = reports.filter { !$0.isCompliant }.count
        let compliantEndpoints = totalTested - breakingEndpoints
        let totalBreaking = reports.reduce(0) { $0 + $1.breakingChangeCount }

        return ContractRegressionSuiteSummary(
            timestamp: Date(),
            totalEndpointsTested: totalTested,
            compliantEndpointsCount: compliantEndpoints,
            breakingEndpointsCount: breakingEndpoints,
            totalBreakingChanges: totalBreaking,
            endpointReports: reports
        )
    }

    // MARK: - Helper

    private static func describe(_ shape: JSONShape) -> String {
        switch shape {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .object(let props): return "object{\(props.keys.sorted().joined(separator: ","))}"
        case .array(let elem, _, _): return "array[\(elem.map(describe) ?? "any")]"
        case .mixed(let types): return "mixed(\(types.map(describe).joined(separator: "|")))"
        }
    }
}
