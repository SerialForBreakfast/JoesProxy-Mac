//
//  MCPTrajectoryDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP Multi-Session Trajectory Diffing
//  and Behavioral Branching Tree tools.
//

import Foundation

struct MCPTrajectoryAlignedStepDTO: Codable, Sendable, Equatable {
    var id: Int
    var stepType: String
    var baselineSessionID: String?
    var candidateSessionID: String?
    var requestSignature: String
    var baselineStatusCode: Int?
    var candidateStatusCode: Int?
    var relativeTimestampDeltaMs: Double
    var divergenceSummary: String?
}

struct MCPTrajectoryDiffReportDTO: Codable, Sendable, Equatable {
    var reportID: String
    var baselineRunName: String
    var candidateRunName: String
    var totalBaselineRequests: Int
    var totalCandidateRequests: Int
    var alignedSteps: [MCPTrajectoryAlignedStepDTO]
    var divergencePointIndex: Int?
    var divergencePointSummary: String?
    var divergenceKindDescription: String?
    var similarityScore: Double
    var executionDurationMs: Double
    var disclosure: MCPMediaDisclosureContextDTO
}
