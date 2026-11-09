//
//  MCPLocalizationMockDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects for Localization Mock MCP tool endpoints.
//

import Foundation

struct MCPLocalizationPresetDTO: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var summary: String
}

struct MCPLocalizationTransformDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var preset: String
    var mutatedStringCount: Int
    var skippedStringCount: Int
    var expansionPercentage: Double
    var previewTransformedJSON: String
}
