//
//  TemporalPermutationEngine.swift
//  JoesProxy
//
//  Permutation generation matrix, delay schedule calculator,
//  and async race-condition telemetry evaluator.
//

import Foundation

@MainActor
final class TemporalPermutationEngine {
    static let shared = TemporalPermutationEngine()

    private var activePlans: [UUID: TemporalPermutationPlan] = [:]
    private var completedReports: [UUID: RaceConditionFuzzReport] = [:]

    // MARK: - Plan Proposition

    func proposePlan(
        name: String,
        targetBatchDescription: String,
        endpoints: [PermutationEndpoint],
        spacingMs: Int = 150
    ) -> TemporalPermutationPlan {
        let endpointIDs = endpoints.map(\.id)
        let rawPermutations = generatePermutations(items: endpointIDs)

        var sequences: [PermutationSequence] = []
        for (index, order) in rawPermutations.enumerated() {
            var delayMap: [String: Int] = [:]
            for (step, epID) in order.enumerated() {
                delayMap[epID] = step * spacingMs
            }

            sequences.append(
                PermutationSequence(
                    id: index + 1,
                    order: order,
                    delaysMs: delayMap,
                    status: index == 0 ? .evaluating : .untested
                )
            )
        }

        var plan = TemporalPermutationPlan(
            name: name,
            targetBatchDescription: targetBatchDescription,
            endpoints: endpoints,
            sequences: sequences,
            activeSequenceIndex: sequences.isEmpty ? nil : 0
        )

        activePlans[plan.id] = plan
        return plan
    }

    func getPlan(id: UUID) -> TemporalPermutationPlan? {
        activePlans[id]
    }

    func allPlans() -> [TemporalPermutationPlan] {
        Array(activePlans.values)
    }

    func getReport(planID: UUID) -> RaceConditionFuzzReport? {
        completedReports[planID]
    }

    // MARK: - Step Plan Execution

    func stepPlan(
        planID: UUID,
        errorDetected: Bool,
        outcomeSummary: String
    ) -> (plan: TemporalPermutationPlan, report: RaceConditionFuzzReport?) {
        guard var plan = activePlans[planID] else {
            fatalError("Plan ID \(planID) not found")
        }

        guard let curIdx = plan.activeSequenceIndex, curIdx < plan.sequences.count else {
            return (plan, completedReports[planID])
        }

        // Record current sequence result
        plan.sequences[curIdx].errorDetected = errorDetected
        plan.sequences[curIdx].clientOutcomeSummary = outcomeSummary
        plan.sequences[curIdx].status = errorDetected ? .raceConditionDetected : .passed

        let nextIdx = curIdx + 1
        if nextIdx < plan.sequences.count {
            plan.activeSequenceIndex = nextIdx
            plan.sequences[nextIdx].status = .evaluating
        } else {
            // Plan completed
            plan.isCompleted = true
            plan.activeSequenceIndex = nil

            let report = buildReport(for: plan)
            completedReports[planID] = report
            activePlans[planID] = plan
            return (plan, report)
        }

        plan.updatedAt = Date()
        activePlans[planID] = plan
        return (plan, nil)
    }

    func resetPlan(id: UUID) -> TemporalPermutationPlan? {
        guard var plan = activePlans[id] else { return nil }
        for idx in 0..<plan.sequences.count {
            plan.sequences[idx].status = idx == 0 ? .evaluating : .untested
            plan.sequences[idx].clientOutcomeSummary = nil
            plan.sequences[idx].errorDetected = false
        }
        plan.activeSequenceIndex = plan.sequences.isEmpty ? nil : 0
        plan.isCompleted = false
        plan.updatedAt = Date()
        activePlans[id] = plan
        completedReports.removeValue(forKey: id)
        return plan
    }

    // MARK: - Permutation Generation

    private func generatePermutations(items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        var result: [[String]] = []

        for i in 0..<items.count {
            var sub = items
            let current = sub.remove(at: i)
            let remainingPerms = generatePermutations(items: sub)
            for p in remainingPerms {
                result.append([current] + p)
            }
        }
        return result
    }

    // MARK: - Report Construction

    private func buildReport(for plan: TemporalPermutationPlan) -> RaceConditionFuzzReport {
        let failing = plan.sequences.filter(\.errorDetected)
        let safe = plan.sequences.filter { !$0.errorDetected && $0.status == .passed }
        let total = plan.sequences.count
        let duration = max(1.0, Date().timeIntervalSince(plan.createdAt) * 1000.0)

        let minimalFailing = failing.first?.order

        let rootCause: String
        let remediation: String

        if let firstFail = minimalFailing {
            rootCause = "Race condition confirmed in sequence [\(firstFail.joined(separator: " -> "))]. Client application failed to handle concurrent resolution in this order."
            remediation = "Add async barrier/dependency guard: Ensure that preceding endpoints in successful sequences complete before resolving subsequent dependencies."
        } else {
            rootCause = "All \(total) temporal permutations passed without client error. Concurrency handling is resilient across all tested arrival orderings."
            remediation = "No concurrency defects detected. Maintain current async synchronization safeguards."
        }

        return RaceConditionFuzzReport(
            planID: plan.id,
            planName: plan.name,
            targetBatchDescription: plan.targetBatchDescription,
            totalSequencesTested: total,
            failingSequencesCount: failing.count,
            safeSequencesCount: safe.count,
            minimalFailingOrder: minimalFailing,
            rootCauseSummary: rootCause,
            recommendedDefensiveFix: remediation,
            executionDurationMs: duration
        )
    }
}
