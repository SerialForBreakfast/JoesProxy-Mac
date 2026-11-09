//
//  MCPAgenticService.swift
//  JoesProxy
//
//  MCP tool endpoints for Hypothesis DAGs, autonomous fault bisection,
//  and state-machine graph evaluation.
//

import Foundation

struct MCPHypothesisNodeInput: Codable, Sendable {
    var id: String
    var title: String
    var explanation: String
    var parentID: String?
    var mutationType: String // "jsonRewrite", "statusCodeFault", "latencyInjection", "headerMutation", "dropConnection"
    var mutationTarget: String // URL pattern
    var mutationValue: String? // JSON path or status code or header value
    var expectedOutcome: String
}

@MainActor
final class MCPAgenticService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - Propose Hypothesis DAG

    func proposeHypothesisDAG(
        name: String,
        targetBug: String,
        nodeInputs: [MCPHypothesisNodeInput],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPHypothesisGraphDTO {
        let domainNodes = nodeInputs.map { input -> HypothesisNode in
            let mutation: EphemeralMicroMutation
            let cleanType = input.mutationType.lowercased()
            if cleanType.contains("status") || cleanType.contains("code") {
                let code = Int(input.mutationValue ?? "500") ?? 500
                mutation = .statusCodeFault(urlPattern: input.mutationTarget, statusCode: code, responseBody: nil)
            } else if cleanType.contains("latency") || cleanType.contains("delay") {
                let delay = Int(input.mutationValue ?? "1000") ?? 1000
                mutation = .latencyInjection(urlPattern: input.mutationTarget, delayMs: delay)
            } else if cleanType.contains("header") {
                mutation = .headerMutation(urlPattern: input.mutationTarget, headerName: "X-Test-Header", value: input.mutationValue)
            } else if cleanType.contains("drop") {
                mutation = .dropConnection(urlPattern: input.mutationTarget)
            } else {
                mutation = .jsonRewrite(urlPattern: input.mutationTarget, locator: input.mutationValue ?? "$", operation: "set", value: "null")
            }

            return HypothesisNode(
                id: input.id,
                title: input.title,
                explanation: input.explanation,
                parentID: input.parentID,
                mutation: mutation,
                expectedOutcome: .customEvidenceMatch(key: "outcome", expectedValue: input.expectedOutcome),
                status: .untested
            )
        }

        let graph = HypothesisDAGEngine.shared.proposeGraph(
            name: name,
            targetBugDescription: targetBug,
            nodes: domainNodes
        )

        return mapGraphToDTO(graph, policyRevision: policyRevision)
    }

    // MARK: - Step Hypothesis Graph

    func stepHypothesisGraph(
        graphID: UUID,
        evidenceMatches: Bool,
        evidenceSummary: String,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPStepHypothesisResultDTO {
        guard let currentGraph = HypothesisDAGEngine.shared.getGraph(id: graphID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Hypothesis graph \(graphID) not found.")
        }

        let evaluatedNodeID = currentGraph.currentNodeID ?? "unknown"
        let (updatedGraph, report) = HypothesisDAGEngine.shared.step(
            graphID: graphID,
            observedEvidenceMatches: evidenceMatches,
            evidenceSummary: evidenceSummary
        )

        let evaluatedStatus = updatedGraph.nodes.first(where: { $0.id == evaluatedNodeID })?.status.rawValue ?? "Evaluated"
        let nextMutation = updatedGraph.currentNodeID.flatMap { curID in
            updatedGraph.nodes.first(where: { $0.id == curID })?.mutation.description
        }

        let reportDTO = report.map { r in
            mapReportToDTO(r, policyRevision: policyRevision)
        }

        return MCPStepHypothesisResultDTO(
            graphID: updatedGraph.id.uuidString,
            isCompleted: updatedGraph.isCompleted,
            evaluatedNodeID: evaluatedNodeID,
            evaluatedNodeStatus: evaluatedStatus,
            nextNodeIDToEvaluate: updatedGraph.currentNodeID,
            nextMutationToExecute: nextMutation,
            bisectionReport: reportDTO,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Get Fault Bisection Report

    func getFaultBisectionReport(
        graphID: UUID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPHypothesisBisectionReportDTO {
        guard let report = HypothesisDAGEngine.shared.getReport(graphID: graphID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Bisection report not yet generated for graph \(graphID). Step the graph until completion.")
        }

        return mapReportToDTO(report, policyRevision: policyRevision)
    }

    // MARK: - DTO Mappings

    private func mapGraphToDTO(_ graph: HypothesisGraph, policyRevision: MCPPolicyRevision) -> MCPHypothesisGraphDTO {
        let nodeDTOs = graph.nodes.map { n in
            MCPHypothesisNodeDTO(
                id: n.id,
                title: n.title,
                explanation: n.explanation,
                parentID: n.parentID,
                mutationDescription: n.mutation.description,
                expectedOutcome: n.expectedOutcome.description,
                status: n.status.rawValue,
                evidenceSummary: n.evidenceSummary
            )
        }

        return MCPHypothesisGraphDTO(
            id: graph.id.uuidString,
            name: graph.name,
            targetBugDescription: graph.targetBugDescription,
            nodes: nodeDTOs,
            currentNodeID: graph.currentNodeID,
            isCompleted: graph.isCompleted,
            progressPercentage: graph.progressPercentage,
            isolatedRootCauseNodeID: graph.isolatedRootCauseNodeID,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    private func mapReportToDTO(_ report: HypothesisBisectionReport, policyRevision: MCPPolicyRevision) -> MCPHypothesisBisectionReportDTO {
        let provenDTO = report.provenRootCauseNode.map { n in
            MCPHypothesisNodeDTO(
                id: n.id,
                title: n.title,
                explanation: n.explanation,
                parentID: n.parentID,
                mutationDescription: n.mutation.description,
                expectedOutcome: n.expectedOutcome.description,
                status: n.status.rawValue,
                evidenceSummary: n.evidenceSummary
            )
        }

        return MCPHypothesisBisectionReportDTO(
            graphID: report.graphID.uuidString,
            graphName: report.graphName,
            targetBugDescription: report.targetBugDescription,
            totalNodesEvaluated: report.totalNodesEvaluated,
            prunedBranchesCount: report.prunedBranchesCount,
            provenRootCauseNode: provenDTO,
            confidenceScore: report.confidenceScore,
            recommendedRemediation: report.recommendedRemediation,
            executionTimeMs: report.executionTimeMs,
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
