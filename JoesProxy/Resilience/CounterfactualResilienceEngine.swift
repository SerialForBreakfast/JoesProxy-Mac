//
//  CounterfactualResilienceEngine.swift
//  JoesProxy
//
//  Payload keypath extractor, counterfactual mutation synthesizer,
//  and evaluator-optimizer breaking-point bisection engine.
//

import Foundation

@MainActor
final class CounterfactualResilienceEngine {
    static let shared = CounterfactualResilienceEngine()

    private var activePlans: [UUID: ResilienceBisectionPlan] = [:]
    private var completedReports: [UUID: ClientResilienceMatrixReport] = [:]

    // MARK: - Propose Plan

    func proposePlan(
        name: String,
        sessionID: UUID,
        targetURL: String,
        payloadJSON: String
    ) -> ResilienceBisectionPlan {
        let candidates = generateCandidates(from: payloadJSON)

        var plan = ResilienceBisectionPlan(
            name: name,
            targetSessionID: sessionID,
            targetURL: targetURL,
            baselinePayloadJSON: payloadJSON,
            candidates: candidates,
            activeCandidateIndex: candidates.isEmpty ? nil : 0
        )

        if !plan.candidates.isEmpty {
            plan.candidates[0].status = .evaluating
        }

        activePlans[plan.id] = plan
        return plan
    }

    func getPlan(id: UUID) -> ResilienceBisectionPlan? {
        activePlans[id]
    }

    func allPlans() -> [ResilienceBisectionPlan] {
        Array(activePlans.values)
    }

    func getReport(planID: UUID) -> ClientResilienceMatrixReport? {
        completedReports[planID]
    }

    // MARK: - Step Bisection Plan

    func stepPlan(
        planID: UUID,
        clientCrashed: Bool,
        observedError: String?
    ) -> (plan: ResilienceBisectionPlan, report: ClientResilienceMatrixReport?) {
        guard var plan = activePlans[planID] else {
            fatalError("Plan ID \(planID) not found")
        }

        guard let curIdx = plan.activeCandidateIndex, curIdx < plan.candidates.count else {
            return (plan, completedReports[planID])
        }

        plan.candidates[curIdx].observedClientError = observedError
        plan.candidates[curIdx].status = clientCrashed ? .breakingPoint : .safe

        let nextIdx = curIdx + 1
        if nextIdx < plan.candidates.count {
            plan.activeCandidateIndex = nextIdx
            plan.candidates[nextIdx].status = .evaluating
        } else {
            // Completed bisection
            plan.isCompleted = true
            plan.activeCandidateIndex = nil

            let report = buildReport(for: plan)
            completedReports[planID] = report
            activePlans[planID] = plan
            return (plan, report)
        }

        plan.updatedAt = Date()
        activePlans[planID] = plan
        return (plan, nil)
    }

    func resetPlan(id: UUID) -> ResilienceBisectionPlan? {
        guard var plan = activePlans[id] else { return nil }
        for idx in 0..<plan.candidates.count {
            plan.candidates[idx].status = idx == 0 ? .evaluating : .untested
            plan.candidates[idx].observedClientError = nil
        }
        plan.activeCandidateIndex = plan.candidates.isEmpty ? nil : 0
        plan.isCompleted = false
        plan.updatedAt = Date()
        activePlans[id] = plan
        completedReports.removeValue(forKey: id)
        return plan
    }

    // MARK: - Candidate Generation

    func generateCandidates(from jsonString: String) -> [FieldMutationCandidate] {
        guard let data = jsonString.data(using: .utf8),
              let rootObj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }

        var candidates: [FieldMutationCandidate] = []
        var counter = 1

        traverseJSON(root: rootObj, currentPath: "$") { keyPath, value in
            let origDesc = String(describing: value)

            // 1. Nullify Candidate
            candidates.append(
                FieldMutationCandidate(
                    id: "MUT_\(counter)",
                    keyPath: keyPath,
                    mutationType: .nullify,
                    originalValueDescription: origDesc,
                    mutatedValueDescription: "null"
                )
            )
            counter += 1

            // 2. Remove Key Candidate
            candidates.append(
                FieldMutationCandidate(
                    id: "MUT_\(counter)",
                    keyPath: keyPath,
                    mutationType: .removeKey,
                    originalValueDescription: origDesc,
                    mutatedValueDescription: "<key omitted>"
                )
            )
            counter += 1

            // 3. Type Coerce Candidate
            if value is String {
                candidates.append(
                    FieldMutationCandidate(
                        id: "MUT_\(counter)",
                        keyPath: keyPath,
                        mutationType: .typeCoerce,
                        originalValueDescription: origDesc,
                        mutatedValueDescription: "99999 (Int)"
                    )
                )
                counter += 1
            } else if value is NSNumber {
                candidates.append(
                    FieldMutationCandidate(
                        id: "MUT_\(counter)",
                        keyPath: keyPath,
                        mutationType: .typeCoerce,
                        originalValueDescription: origDesc,
                        mutatedValueDescription: "\"coerced_string\""
                    )
                )
                counter += 1
            }
        }

        return candidates
    }

    // MARK: - JSON Traversal

    private func traverseJSON(root: Any, currentPath: String, visitor: (String, Any) -> Void) {
        if let dict = root as? [String: Any] {
            for (k, v) in dict {
                let path = currentPath == "$" ? "$.\(k)" : "\(currentPath).\(k)"
                if !(v is [String: Any]) && !(v is [Any]) {
                    visitor(path, v)
                } else {
                    traverseJSON(root: v, currentPath: path, visitor: visitor)
                }
            }
        } else if let arr = root as? [Any] {
            for (idx, item) in arr.enumerated() {
                let path = "\(currentPath)[\(idx)]"
                if !(item is [String: Any]) && !(item is [Any]) {
                    visitor(path, item)
                } else {
                    traverseJSON(root: item, currentPath: path, visitor: visitor)
                }
            }
        }
    }

    // MARK: - Report Construction

    private func buildReport(for plan: ResilienceBisectionPlan) -> ClientResilienceMatrixReport {
        let total = plan.candidates.count
        let breaking = plan.candidates.filter { $0.status == .breakingPoint }
        let safe = plan.candidates.filter { $0.status == .safe }
        let duration = max(1.0, Date().timeIntervalSince(plan.createdAt) * 1000.0)

        let score = total > 0 ? (Double(safe.count) / Double(total)) * 100.0 : 100.0

        let findings = breaking.map { c in
            BreakingPointFinding(
                candidateID: c.id,
                keyPath: c.keyPath,
                mutationType: c.mutationType,
                mutatedPayloadSnippet: "{\(c.keyPath): \(c.mutatedValueDescription)}",
                observedClientError: c.observedClientError,
                defensiveFixRecommendation: synthesizeRemediation(for: c)
            )
        }

        return ClientResilienceMatrixReport(
            planID: plan.id,
            planName: plan.name,
            targetURL: plan.targetURL,
            totalFieldsTested: total,
            breakingPointsCount: breaking.count,
            resilientFieldsCount: safe.count,
            resilienceScore: score,
            breakingPoints: findings,
            executionDurationMs: duration
        )
    }

    private func synthesizeRemediation(for candidate: FieldMutationCandidate) -> String {
        let lastKey = candidate.keyPath.components(separatedBy: ".").last ?? "field"
        switch candidate.mutationType {
        case .nullify:
            return "Make property optional in client model: `decodeIfPresent(\(lastKey).self, forKey: .\(lastKey))` or provide safe default fallback."
        case .removeKey:
            return "Handle missing key in JSON decoder: Provide a default initialization value if `\(lastKey)` is absent from upstream."
        case .typeCoerce:
            return "Use lossy or polymorphic decoding wrapper (e.g. `FailableString` or `@StringOrInt`) for `\(lastKey)`."
        case .emptyCollection:
            return "Ensure collection view or list gracefully handles empty arrays `[]` without zero-index out-of-bounds access."
        case .boundaryExplosion:
            return "Validate integer boundaries before rendering to avoid numeric overflow or negative count exceptions."
        }
    }
}
