//
//  MCPContractDiffDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects for Autonomous API Regression and Contract Diff MCP tool endpoints.
//

import Foundation

struct MCPSchemaFieldDiffDTO: Codable, Sendable, Equatable {
    var jsonPath: String
    var severity: String
    var summary: String
    var explanation: String
}

struct MCPEndpointContractDiffDTO: Codable, Sendable, Equatable {
    var endpoint: String
    var method: String
    var path: String
    var isCompliant: Bool
    var breakingChangeCount: Int
    var compatibleAdditionCount: Int
    var diffs: [MCPSchemaFieldDiffDTO]
}

struct MCPContractRegressionSummaryDTO: Codable, Sendable, Equatable {
    var isSuitePassed: Bool
    var totalEndpointsTested: Int
    var compliantEndpointsCount: Int
    var breakingEndpointsCount: Int
    var totalBreakingChanges: Int
    var endpointReports: [MCPEndpointContractDiffDTO]
}
