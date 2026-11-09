//
//  MCPResilienceDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP Payload Counterfactual Mutation,
//  Evaluator-Optimizer Bisection, and Client Resilience Matrices.
//

import Foundation

struct MCPFieldMutationCandidateDTO: Codable, Sendable, Equatable {
    var id: String
    var keyPath: String
    var mutationType: String
    var originalValue: String
    var mutatedValue: String
    var status: String
    var observedClientError: String?
}

struct MCPBreakingPointFindingDTO: Codable, Sendable, Equatable {
    var candidateID: String
    var keyPath: String
    var mutationType: String
    var mutatedPayloadSnippet: String
    var observedClientError: String?
    var defensiveFixRecommendation: String
}

struct MCPResilienceBisectionPlanDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var targetURL: String
    var candidates: [MCPFieldMutationCandidateDTO]
    var activeCandidateIndex: Int?
    var isCompleted: Bool
    var progressPercentage: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPClientResilienceMatrixReportDTO: Codable, Sendable, Equatable {
    var planID: String
    var planName: String
    var targetURL: String
    var totalFieldsTested: Int
    var breakingPointsCount: Int
    var resilientFieldsCount: Int
    var resilienceScore: Double
    var breakingPoints: [MCPBreakingPointFindingDTO]
    var executionDurationMs: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPStepResilienceResultDTO: Codable, Sendable, Equatable {
    var planID: String
    var isCompleted: Bool
    var evaluatedCandidateID: String
    var evaluatedStatus: String
    var nextCandidateIDToEvaluate: String?
    var matrixReport: MCPClientResilienceMatrixReportDTO?
    var disclosure: MCPMediaDisclosureContextDTO
}
