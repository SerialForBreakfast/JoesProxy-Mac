//
//  MCPSyntheticInjectionDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects for MCP Schema-Inferred Collection Injection
//  and Synthetic Asset Binding tools.
//

import Foundation

struct MCPSyntheticAssetDescriptorDTO: Codable, Sendable, Equatable {
    var id: String
    var kind: String
    var displayName: String
    var description: String
    var localURL: String
    var contentType: String
    var isDRMFree: Bool
}

struct MCPSyntheticInjectionPlanDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var urlPattern: String
    var collectionKeypath: String
    var position: String
    var boundAssetKind: String?
    var customAssetURL: String?
    var fieldOverrides: [String: String]
    var clientScope: String
    var isEnabled: Bool
    var diagnostics: SyntheticInjectionDiagnostics? = nil
}

struct MCPInjectSyntheticItemResultDTO: Codable, Sendable, Equatable {
    var planID: String
    var status: String
    var urlPattern: String
    var collectionKeypath: String
    var position: String
    var boundAssetURL: String?
    var clientScope: String
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPListSyntheticAssetsResponseDTO: Codable, Sendable, Equatable {
    var assets: [MCPSyntheticAssetDescriptorDTO]
    var defaultProxyPort: Int
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPListSyntheticInjectionPlansResponseDTO: Codable, Sendable, Equatable {
    var plans: [MCPSyntheticInjectionPlanDTO]
    var disclosure: MCPMediaDisclosureContextDTO
}
