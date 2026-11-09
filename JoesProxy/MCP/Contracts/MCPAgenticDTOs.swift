//
//  MCPAgenticDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for Agentic Hypothesis Testing,
//  DAG State Machines, and Fault Bisection tools.
//

import Foundation

struct MCPHypothesisNodeDTO: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var explanation: String
    var parentID: String?
    var mutationDescription: String
    var expectedOutcome: String
    var status: String
    var evidenceSummary: String?
}

struct MCPHypothesisGraphDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var targetBugDescription: String
    var nodes: [MCPHypothesisNodeDTO]
    var currentNodeID: String?
    var isCompleted: Bool
    var progressPercentage: Double
    var isolatedRootCauseNodeID: String?
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPHypothesisBisectionReportDTO: Codable, Sendable, Equatable {
    var graphID: String
    var graphName: String
    var targetBugDescription: String
    var totalNodesEvaluated: Int
    var prunedBranchesCount: Int
    var provenRootCauseNode: MCPHypothesisNodeDTO?
    var confidenceScore: Double
    var recommendedRemediation: String
    var executionTimeMs: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPStepHypothesisResultDTO: Codable, Sendable, Equatable {
    var graphID: String
    var isCompleted: Bool
    var evaluatedNodeID: String
    var evaluatedNodeStatus: String
    var nextNodeIDToEvaluate: String?
    var nextMutationToExecute: String?
    var bisectionReport: MCPHypothesisBisectionReportDTO?
    var disclosure: MCPMediaDisclosureContextDTO
}
