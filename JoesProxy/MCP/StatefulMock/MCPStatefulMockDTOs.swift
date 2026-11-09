//
//  MCPStatefulMockDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects for MCP Stateful Virtual Backend tool endpoints.
//

import Foundation

struct MCPStatefulBackendDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var originHost: String
    var activeState: String
    var possibleStates: [String]
    var supportedCollections: [String]
    var isEnabled: Bool
}

struct MCPStatefulMockEntityDTO: Codable, Sendable, Equatable {
    var id: String
    var collection: String
    var fields: [String: String]
}

struct MCPStatefulMockCollectionDTO: Codable, Sendable, Equatable {
    var backendID: String
    var collection: String
    var entityCount: Int
    var entities: [MCPStatefulMockEntityDTO]
}

struct MCPStatefulMockPresetSummaryDTO: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var summary: String
    var defaultHost: String
}
