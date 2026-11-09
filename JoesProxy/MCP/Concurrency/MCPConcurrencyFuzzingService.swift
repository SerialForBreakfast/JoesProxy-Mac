//
//  MCPConcurrencyFuzzingService.swift
//  JoesProxy
//
//  MCP tool endpoints for Temporal Request Permutations,
//  arrival order scheduling, and async race-condition fuzzing.
//

import Foundation

struct MCPPermutationEndpointInput: Codable, Sendable {
    var id: String
    var name: String
    var urlPattern: String
    var method: String?
}

@MainActor
final class MCPConcurrencyFuzzingService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - Propose Permutation Plan

    func proposeTemporalPermutationPlan(
        name: String,
        targetBatch: String,
        endpoints: [MCPPermutationEndpointInput],
        spacingMs: Int = 150,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPTemporalPermutationPlanDTO {
        let domainEndpoints = endpoints.map { ep in
            PermutationEndpoint(
                id: ep.id,
                name: ep.name,
                urlPattern: ep.urlPattern,
                method: ep.method ?? "GET"
            )
        }

        let plan = TemporalPermutationEngine.shared.proposePlan(
            name: name,
            targetBatchDescription: targetBatch,
            endpoints: domainEndpoints,
            spacingMs: spacingMs
        )

        return mapPlanToDTO(plan, policyRevision: policyRevision)
    }

    // MARK: - Step Permutation Plan

    func stepTemporalPermutationPlan(
        planID: UUID,
        errorDetected: Bool,
        outcomeSummary: String,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPStepPermutationResultDTO {
        guard let currentPlan = TemporalPermutationEngine.shared.getPlan(id: planID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Permutation plan \(planID) not found.")
        }

        let evaluatedSeqID = (currentPlan.activeSequenceIndex ?? 0) + 1
        let (updatedPlan, report) = TemporalPermutationEngine.shared.stepPlan(
            planID: planID,
            errorDetected: errorDetected,
            outcomeSummary: outcomeSummary
        )

        let evaluatedStatus = updatedPlan.sequences.first(where: { $0.id == evaluatedSeqID })?.status.rawValue ?? "Evaluated"
        let nextDelays = updatedPlan.activeSequence?.delaysMs

        let reportDTO = report.map { r in
            mapReportToDTO(r, policyRevision: policyRevision)
        }

        return MCPStepPermutationResultDTO(
            planID: updatedPlan.id.uuidString,
            isCompleted: updatedPlan.isCompleted,
            evaluatedSequenceID: evaluatedSeqID,
            evaluatedStatus: evaluatedStatus,
            nextSequenceIDToExecute: updatedPlan.activeSequence?.id,
            nextDelaysToInject: nextDelays,
            fuzzReport: reportDTO,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Get Race Condition Fuzz Report

    func getRaceConditionFuzzReport(
        planID: UUID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPRaceConditionFuzzReportDTO {
        guard let report = TemporalPermutationEngine.shared.getReport(planID: planID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Fuzz report not yet generated for plan \(planID). Complete all permutation sequences first.")
        }

        return mapReportToDTO(report, policyRevision: policyRevision)
    }

    // MARK: - Mappings & Helpers

    private func mapPlanToDTO(_ plan: TemporalPermutationPlan, policyRevision: MCPPolicyRevision) -> MCPTemporalPermutationPlanDTO {
        let epDTOs = plan.endpoints.map { ep in
            MCPPermutationEndpointDTO(
                id: ep.id,
                name: ep.name,
                urlPattern: ep.urlPattern,
                method: ep.method
            )
        }

        let seqDTOs = plan.sequences.map { seq in
            MCPPermutationSequenceDTO(
                id: seq.id,
                order: seq.order,
                delaysMs: seq.delaysMs,
                status: seq.status.rawValue,
                clientOutcomeSummary: seq.clientOutcomeSummary,
                errorDetected: seq.errorDetected
            )
        }

        return MCPTemporalPermutationPlanDTO(
            id: plan.id.uuidString,
            name: plan.name,
            targetBatchDescription: plan.targetBatchDescription,
            endpoints: epDTOs,
            sequences: seqDTOs,
            activeSequenceIndex: plan.activeSequenceIndex,
            isCompleted: plan.isCompleted,
            progressPercentage: plan.progressPercentage,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    private func mapReportToDTO(_ report: RaceConditionFuzzReport, policyRevision: MCPPolicyRevision) -> MCPRaceConditionFuzzReportDTO {
        MCPRaceConditionFuzzReportDTO(
            planID: report.planID.uuidString,
            planName: report.planName,
            targetBatchDescription: report.targetBatchDescription,
            totalSequencesTested: report.totalSequencesTested,
            failingSequencesCount: report.failingSequencesCount,
            safeSequencesCount: report.safeSequencesCount,
            minimalFailingOrder: report.minimalFailingOrder,
            rootCauseSummary: report.rootCauseSummary,
            recommendedDefensiveFix: report.recommendedDefensiveFix,
            executionDurationMs: report.executionDurationMs,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    private func makeDisclosure(policyRevision: MCPPolicyRevision) -> MCPMediaDisclosureContextDTO {
        MCPMediaDisclosureContextDTO(
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyRevision,
            generatedAt: Date(),
            removedFields: [],
            partialResultReason: nil,
            truncated: false
        )
    }
}
