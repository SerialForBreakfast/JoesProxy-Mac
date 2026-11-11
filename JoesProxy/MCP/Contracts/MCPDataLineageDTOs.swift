//
//  MCPDataLineageDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP Data Lineage, Provenance Watermarking,
//  and Analytics Attribution tools.
//

import Foundation

struct MCPDataLineageNodeDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var endpointURL: String
    var httpMethod: String
    var keypath: String
    var value: String
}

struct MCPDataLineageFlowDTO: Codable, Sendable, Equatable {
    var id: String
    var sourceNode: MCPDataLineageNodeDTO
    var watermarkToken: String?
    var sinkNode: MCPDataLineageNodeDTO
    var latencyMs: Double
    var matchConfidence: Double
    var flowType: String
}

struct MCPAnalyticsAttributionDTO: Codable, Sendable, Equatable {
    var sinkSessionID: String
    var sinkURL: String
    var totalTrackingParameters: Int
    var attributedCount: Int
    var unattributedCount: Int
    var attributionPercentage: Double
    var flows: [MCPDataLineageFlowDTO]
    var unattributedParameters: [MCPDataLineageNodeDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPDataLineageSearchResultDTO: Codable, Sendable, Equatable {
    var targetQuery: String
    var candidateSessionsInspected: Int
    var matchingFlowsCount: Int
    var flows: [MCPDataLineageFlowDTO]
    var authChain: AuthChainBrief.Report? = nil
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPWatermarkProposalDTO: Codable, Sendable, Equatable {
    var ruleID: String
    var urlPattern: String
    var strategy: String
    var targetKeypaths: [String]
    var isEnabled: Bool
    var status: String
    var disclosure: MCPMediaDisclosureContextDTO
}
