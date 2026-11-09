//
//  MCPLLMDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP LLM streaming wire inspection,
//  token jitter, and stream fault sandbox tools.
//

import Foundation

struct MCPLLMTokenDeltaDTO: Codable, Sendable, Equatable {
    var index: Int
    var text: String
    var role: String?
    var toolCallDelta: String?
    var relativeTimestampMs: Double
}

struct MCPLLMToolCallDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var argumentsJSON: String
    var isComplete: Bool
}

struct MCPLLMStreamReportDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var modelName: String?
    var format: String
    var totalTokens: Int
    var totalChunks: Int
    var timeToFirstTokenMs: Double
    var totalStreamDurationMs: Double
    var tokensPerSecond: Double
    var interTokenJitterMs: Double
    var finishReason: String?
    var tokens: [MCPLLMTokenDeltaDTO]
    var assembledText: String
    var toolCalls: [MCPLLMToolCallDTO]
    var canaryViolations: [String]
    var qualityScore: Double
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPLLMStreamFaultProposalDTO: Codable, Sendable, Equatable {
    var ruleID: String
    var name: String
    var urlPattern: String
    var faultKindDescription: String
    var isEnabled: Bool
    var status: String
    var disclosure: MCPMediaDisclosureContextDTO
}
