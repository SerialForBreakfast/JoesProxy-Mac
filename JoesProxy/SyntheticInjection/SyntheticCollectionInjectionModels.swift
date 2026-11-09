//
//  SyntheticCollectionInjectionModels.swift
//  JoesProxy
//
//  Domain models for schema-inferred collection injection,
//  synthetic item positioning, and client-scoped filtering.
//

import Foundation

/// Position where the synthesized item should be inserted or replaced in the collection array.
enum CollectionInjectionPosition: Codable, Equatable, Sendable {
    case prepend // Index 0 (top of guide / feed)
    case append  // End of array
    case replaceIndex(Int)
    case replaceWhereKey(key: String, equals: String)

    var title: String {
        switch self {
        case .prepend: return "Prepend (Top of list)"
        case .append: return "Append (End of list)"
        case .replaceIndex(let idx): return "Replace at Index \(idx)"
        case .replaceWhereKey(let k, let v): return "Replace where '\(k)' = '\(v)'"
        }
    }
}

/// Scope of clients to which the injection rule should apply.
enum ClientScope: Codable, Equatable, Sendable {
    case simulatorOnly
    case allClients
    case customHeader(name: String, valueContains: String)

    var title: String {
        switch self {
        case .simulatorOnly: return "Xcode Simulator Only"
        case .allClients: return "All Clients"
        case .customHeader(let n, let v): return "Header '\(n)' contains '\(v)'"
        }
    }

    func matches(headers: [HTTPHeaderField]) -> Bool {
        switch self {
        case .allClients:
            return true
        case .simulatorOnly:
            guard let ua = headers.first(where: { $0.name.lowercased() == "user-agent" })?.value.lowercased() else {
                return true
            }
            return ua.contains("simulator") || ua.contains("darwin") || ua.contains("cfnetwork") || ua.contains("x86_64")
        case .customHeader(let name, let val):
            guard let headerVal = headers.first(where: { $0.name.lowercased() == name.lowercased() })?.value else {
                return false
            }
            return headerVal.lowercased().contains(val.lowercased())
        }
    }
}

/// A configured plan for schema-inferred collection injection.
struct SyntheticCollectionInjectionPlan: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var urlPattern: String // e.g. "*/epg/channels*" or "*/catalog/feed*"
    var collectionKeypath: String // e.g. "$.channels", "$.data.items", "$" (root array)
    var position: CollectionInjectionPosition = .prepend
    var boundAssetKind: SyntheticAssetKind? = .clearLiveHLS
    var customAssetURL: String? = nil
    var fieldOverrides: [String: String] = [:] // e.g. ["name": "Simulator Test Feed", "stream_url": "$ASSET_URL", "is_drm": "false"]
    var clientScope: ClientScope = .simulatorOnly
    var isEnabled: Bool = true
}

/// Result of evaluating and applying a collection injection on an HTTP response.
struct SyntheticInjectionResult: Codable, Equatable, Sendable {
    var planID: UUID
    var matchedURL: String
    var wasTransformed: Bool
    var injectedItemKeys: [String]
    var collectionCountBefore: Int
    var collectionCountAfter: Int
    var clientUserAgent: String?
}
