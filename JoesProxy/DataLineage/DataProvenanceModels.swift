//
//  DataProvenanceModels.swift
//  JoesProxy
//
//  Domain models for Data Provenance, MITM Response Watermarking,
//  and Analytics Egress Attribution.
//

import Foundation

/// Strategy for injecting synthetic provenance watermarks into incoming API responses.
enum WatermarkInjectionStrategy: Codable, Equatable, Sendable {
    case suffix(tag: String)
    case prefix(tag: String)
    case property(key: String, value: String)
    case autoAllStrings(tagPrefix: String)

    var title: String {
        switch self {
        case .suffix(let tag): return "Suffix ('\(tag)')"
        case .prefix(let tag): return "Prefix ('\(tag)')"
        case .property(let key, let val): return "Property ('\(key)': '\(val)')"
        case .autoAllStrings(let prefix): return "Auto-All Strings ('\(prefix)')"
        }
    }
}

/// A configured rule for watermarking API responses.
struct DataWatermarkRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var urlPattern: String // e.g. "*/api/v2/catalog*" or "*/feed*"
    var targetKeypaths: [String] = [] // empty = all properties
    var strategy: WatermarkInjectionStrategy
    var isEnabled: Bool = true
}

/// Represents a source or sink endpoint where data originated or was emitted.
struct DataLineageNode: Codable, Equatable, Sendable {
    var sessionID: UUID
    var endpointURL: String
    var httpMethod: String
    var timestamp: Date
    var keypath: String // e.g. "$.data.items[0].id", "query.content_id", "header.X-Tracking"
    var value: String
}

/// Type of lineage match discovered between source and sink.
enum LineageFlowType: String, Codable, Equatable, Sendable {
    case watermarkedToken = "Watermark Token Match"
    case exactValueMatch = "Exact Value Match"
    case substringMatch = "Substring / Transformed Match"
    case urlDecodedMatch = "URL-Decoded Match"
    case base64DecodedMatch = "Base64-Decoded Match"
}

/// Represents an end-to-end lineage path from upstream response origin to downstream tracking egress.
struct DataLineageFlow: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var sourceNode: DataLineageNode
    var watermarkToken: String?
    var sinkNode: DataLineageNode
    var latencyMs: Double
    var matchConfidence: Double // 0.0 to 1.0
    var flowType: LineageFlowType
}

/// Full attribution report for an analytics beacon or tracking session.
struct AnalyticsAttributionReport: Codable, Equatable, Sendable {
    var sinkSessionID: UUID
    var sinkURL: String
    var totalTrackingParameters: Int
    var attributedCount: Int
    var unattributedCount: Int
    var flows: [DataLineageFlow]
    var unattributedParameters: [DataLineageNode]

    var attributionPercentage: Double {
        totalTrackingParameters > 0 ? (Double(attributedCount) / Double(totalTrackingParameters)) * 100.0 : 0.0
    }
}
