//
//  MCPConcurrencyDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP Temporal Request Permutation
//  and Async Race-Condition Fuzzing tools.
//

import Foundation

struct MCPPermutationEndpointDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var urlPattern: String
    var method: String
}

struct MCPPermutationSequenceDTO: Codable, Sendable, Equatable {
    var id: Int
    var order: [String]
    var delaysMs: [String: Int]
    var status: String
    var clientOutcomeSummary: String?
    var errorDetected: Bool
}

struct MCPTemporalPermutationPlanDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var targetBatchDescription: String
    var endpoints: [MCPPermutationEndpointDTO]
    var sequences: [MCPPermutationSequenceDTO]
    var activeSequenceIndex: Int?
    var isCompleted: Bool
    var progressPercentage: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPRaceConditionFuzzReportDTO: Codable, Sendable, Equatable {
    var planID: String
    var planName: String
    var targetBatchDescription: String
    var totalSequencesTested: Int
    var failingSequencesCount: Int
    var safeSequencesCount: Int
    var minimalFailingOrder: [String]?
    var rootCauseSummary: String
    var recommendedDefensiveFix: String
    var executionDurationMs: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPStepPermutationResultDTO: Codable, Sendable, Equatable {
    var planID: String
    var isCompleted: Bool
    var evaluatedSequenceID: Int
    var evaluatedStatus: String
    var nextSequenceIDToExecute: Int?
    var nextDelaysToInject: [String: Int]?
    var fuzzReport: MCPRaceConditionFuzzReportDTO?
    var disclosure: MCPMediaDisclosureContextDTO
}
