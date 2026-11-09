//
//  MCPResilienceService.swift
//  JoesProxy
//
//  MCP tool endpoints for Counterfactual Payload Mutation,
//  Evaluator-Optimizer Bisection, and Client Resilience Matrices.
//

import Foundation

@MainActor
final class MCPResilienceService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - Propose Resilience Plan

    func proposeResilienceBisectionPlan(
        sessionID: UUID,
        name: String = "Payload Resilience Bisection",
        policyRevision: MCPPolicyRevision
    ) throws -> MCPResilienceBisectionPlanDTO {
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionID) not found in store.")
        }

        guard let respData = session.response?.bodyData,
              let payloadJSON = String(data: respData, encoding: .utf8), !payloadJSON.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionID) has no JSON response payload.")
        }

        let plan = CounterfactualResilienceEngine.shared.proposePlan(
            name: name,
            sessionID: sessionID,
            targetURL: session.request.path,
            payloadJSON: payloadJSON
        )

        return mapPlanToDTO(plan, policyRevision: policyRevision)
    }

    // MARK: - Step Resilience Plan

    func stepResilienceBisectionPlan(
        planID: UUID,
        clientCrashed: Bool,
        observedError: String?,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPStepResilienceResultDTO {
        guard let currentPlan = CounterfactualResilienceEngine.shared.getPlan(id: planID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Resilience plan \(planID) not found.")
        }

        let evaluatedCandID = currentPlan.activeCandidate?.id ?? "unknown"
        let (updatedPlan, report) = CounterfactualResilienceEngine.shared.stepPlan(
            planID: planID,
            clientCrashed: clientCrashed,
            observedError: observedError
        )

        let evaluatedStatus = updatedPlan.candidates.first(where: { $0.id == evaluatedCandID })?.status.rawValue ?? "Evaluated"
        let reportDTO = report.map { r in
            mapReportToDTO(r, policyRevision: policyRevision)
        }

        return MCPStepResilienceResultDTO(
            planID: updatedPlan.id.uuidString,
            isCompleted: updatedPlan.isCompleted,
            evaluatedCandidateID: evaluatedCandID,
            evaluatedStatus: evaluatedStatus,
            nextCandidateIDToEvaluate: updatedPlan.activeCandidate?.id,
            matrixReport: reportDTO,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Get Resilience Report

    func getResilienceMatrixReport(
        planID: UUID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPClientResilienceMatrixReportDTO {
        guard let report = CounterfactualResilienceEngine.shared.getReport(planID: planID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Report not yet generated for plan \(planID). Complete all candidate mutations first.")
        }

        return mapReportToDTO(report, policyRevision: policyRevision)
    }

    // MARK: - DTO Mappings

    private func mapPlanToDTO(_ plan: ResilienceBisectionPlan, policyRevision: MCPPolicyRevision) -> MCPResilienceBisectionPlanDTO {
        let candDTOs = plan.candidates.map { c in
            MCPFieldMutationCandidateDTO(
                id: c.id,
                keyPath: c.keyPath,
                mutationType: c.mutationType.rawValue,
                originalValue: c.originalValueDescription,
                mutatedValue: c.mutatedValueDescription,
                status: c.status.rawValue,
                observedClientError: c.observedClientError
            )
        }

        return MCPResilienceBisectionPlanDTO(
            id: plan.id.uuidString,
            name: plan.name,
            targetURL: plan.targetURL,
            candidates: candDTOs,
            activeCandidateIndex: plan.activeCandidateIndex,
            isCompleted: plan.isCompleted,
            progressPercentage: plan.progressPercentage,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    private func mapReportToDTO(_ report: ClientResilienceMatrixReport, policyRevision: MCPPolicyRevision) -> MCPClientResilienceMatrixReportDTO {
        let findings = report.breakingPoints.map { b in
            MCPBreakingPointFindingDTO(
                candidateID: b.candidateID,
                keyPath: b.keyPath,
                mutationType: b.mutationType.rawValue,
                mutatedPayloadSnippet: b.mutatedPayloadSnippet,
                observedClientError: b.observedClientError,
                defensiveFixRecommendation: b.defensiveFixRecommendation
            )
        }

        return MCPClientResilienceMatrixReportDTO(
            planID: report.planID.uuidString,
            planName: report.planName,
            targetURL: report.targetURL,
            totalFieldsTested: report.totalFieldsTested,
            breakingPointsCount: report.breakingPointsCount,
            resilientFieldsCount: report.resilientFieldsCount,
            resilienceScore: report.resilienceScore,
            breakingPoints: findings,
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
