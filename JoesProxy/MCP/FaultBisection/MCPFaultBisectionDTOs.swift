//
//  MCPFaultBisectionDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects for MCP AI Fault Bisection tool endpoints.
//

import Foundation

struct MCPFaultBisectionStartDTO: Codable, Sendable, Equatable {
    var bisectionID: String
    var anchorSessionID: String
    var status: String
    var candidateCount: Int
    var distinctEndpointCount: Int
    var currentStepNumber: Int
    var currentStepKind: String
    var actionDescription: String
}

struct MCPFaultBisectionStepDTO: Codable, Sendable, Equatable {
    var bisectionID: String
    var stepNumber: Int
    var kind: String
    var actionDescription: String
    var isTerminal: Bool
    var status: String
    var finding: MCPFaultBisectionFindingDTO?
}

struct MCPFaultBisectionFindingDTO: Codable, Sendable, Equatable {
    var culpritEndpoint: String
    var culpritKeyPath: String?
    var exactWireFault: String
    var observedClientError: String?
    var confidenceScore: Double
    var proposedFixTitle: String
    var proposedMockJSON: String?
    var curlReproducer: String
}

struct MCPFaultBisectionReportDTO: Codable, Sendable, Equatable {
    var bisectionID: String
    var anchorSessionID: String
    var status: String
    var stepCount: Int
    var candidateEndpointCount: Int
    var finding: MCPFaultBisectionFindingDTO?
}
