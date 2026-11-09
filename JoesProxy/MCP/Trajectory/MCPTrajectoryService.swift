//
//  MCPTrajectoryService.swift
//  JoesProxy
//
//  MCP tool endpoints for Multi-Session Trajectory Diffing,
//  sequence alignment, and behavioral divergence isolation.
//

import Foundation

@MainActor
final class MCPTrajectoryService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    func diffSessionTrajectories(
        baselineSessionIDs: [UUID],
        candidateSessionIDs: [UUID],
        baselineName: String = "Baseline Run",
        candidateName: String = "Candidate Run",
        policyRevision: MCPPolicyRevision
    ) throws -> MCPTrajectoryDiffReportDTO {
        let baselineSessions = sessionStore.sessions.filter { baselineSessionIDs.contains($0.id) }
        let candidateSessions = sessionStore.sessions.filter { candidateSessionIDs.contains($0.id) }

        guard !baselineSessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No baseline sessions found matching provided IDs.")
        }
        guard !candidateSessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No candidate sessions found matching provided IDs.")
        }

        let report = TrajectoryDiffEngine.diffTrajectories(
            baseline: baselineSessions,
            candidate: candidateSessions,
            baselineName: baselineName,
            candidateName: candidateName
        )

        let stepDTOs = report.alignedSteps.map { s in
            MCPTrajectoryAlignedStepDTO(
                id: s.id,
                stepType: s.stepType.rawValue,
                baselineSessionID: s.baselineSessionID?.uuidString,
                candidateSessionID: s.candidateSessionID?.uuidString,
                requestSignature: s.requestSignature,
                baselineStatusCode: s.baselineStatusCode,
                candidateStatusCode: s.candidateStatusCode,
                relativeTimestampDeltaMs: s.relativeTimestampDeltaMs,
                divergenceSummary: s.divergenceSummary
            )
        }

        return MCPTrajectoryDiffReportDTO(
            reportID: report.reportID.uuidString,
            baselineRunName: report.baselineRunName,
            candidateRunName: report.candidateRunName,
            totalBaselineRequests: report.totalBaselineRequests,
            totalCandidateRequests: report.totalCandidateRequests,
            alignedSteps: stepDTOs,
            divergencePointIndex: report.divergencePointIndex,
            divergencePointSummary: report.divergencePointSummary,
            divergenceKindDescription: report.divergenceKind?.description,
            similarityScore: report.similarityScore,
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
