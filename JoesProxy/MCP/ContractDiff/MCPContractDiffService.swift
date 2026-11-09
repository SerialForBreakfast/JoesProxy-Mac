//
//  MCPContractDiffService.swift
//  JoesProxy
//
//  MCP tool service for Autonomous API Regression and Breaking Schema Diffing.
//

import Foundation

@MainActor
final class MCPContractDiffService {

    private let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Evaluates contract differences between a live captured session and a baseline session.
    func diffSessions(
        liveSessionID: UUID,
        baselineSessionID: UUID
    ) throws -> MCPEndpointContractDiffDTO {
        guard let live = sessionStore.sessions.first(where: { $0.id == liveSessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Live session ID \(liveSessionID) not found.")
        }
        guard let baseline = sessionStore.sessions.first(where: { $0.id == baselineSessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Baseline session ID \(baselineSessionID) not found.")
        }

        let report = ContractDiffEngine.compareSessions(baseline: baseline, live: live)
        return mapReportToDTO(report)
    }

    /// Runs an autonomous contract regression suite comparing a batch of live sessions against baseline sessions.
    func runRegressionSuite(
        liveSessionIDs: [UUID],
        baselineSessionIDs: [UUID]
    ) throws -> MCPContractRegressionSummaryDTO {
        let liveSessions = sessionStore.sessions.filter { liveSessionIDs.contains($0.id) }
        let baselineSessions = sessionStore.sessions.filter { baselineSessionIDs.contains($0.id) }

        guard !liveSessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No matching live sessions found for provided IDs.")
        }
        guard !baselineSessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No matching baseline sessions found for provided IDs.")
        }

        let summary = ContractDiffEngine.runRegressionSuite(
            baselineSessions: baselineSessions,
            liveSessions: liveSessions
        )

        return MCPContractRegressionSummaryDTO(
            isSuitePassed: summary.isSuitePassed,
            totalEndpointsTested: summary.totalEndpointsTested,
            compliantEndpointsCount: summary.compliantEndpointsCount,
            breakingEndpointsCount: summary.breakingEndpointsCount,
            totalBreakingChanges: summary.totalBreakingChanges,
            endpointReports: summary.endpointReports.map(mapReportToDTO)
        )
    }

    // MARK: - Mapping Helper

    private func mapReportToDTO(_ report: EndpointContractDiffReport) -> MCPEndpointContractDiffDTO {
        let diffDTOs = report.fieldDiffs.map { diff in
            MCPSchemaFieldDiffDTO(
                jsonPath: diff.jsonPath,
                severity: diff.severity.rawValue,
                summary: diff.kind.summary,
                explanation: diff.explanation
            )
        }

        return MCPEndpointContractDiffDTO(
            endpoint: report.endpoint,
            method: report.method,
            path: report.path,
            isCompliant: report.isCompliant,
            breakingChangeCount: report.breakingChangeCount,
            compatibleAdditionCount: report.compatibleAdditionCount,
            diffs: diffDTOs
        )
    }
}
