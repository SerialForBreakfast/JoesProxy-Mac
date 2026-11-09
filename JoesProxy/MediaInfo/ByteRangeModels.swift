//
//  ByteRangeModels.swift
//  JoesProxy
//
//  Domain models for HTTP Byte-Range requests, Content-Range responses,
//  CDN edge caching efficiency, and bandwidth waste diagnostics.
//

import Foundation

/// Parsed HTTP `Range` request specification.
struct ByteRangeSpec: Codable, Equatable, Sendable {
    var start: Int64?
    var end: Int64?
    var suffixLength: Int64?
    var rawHeader: String

    var requestedLength: Int64? {
        if let s = start, let e = end, e >= s {
            return (e - s) + 1
        } else if let suffix = suffixLength {
            return suffix
        }
        return nil
    }

    var displayString: String {
        if let s = start, let e = end {
            return "bytes=\(s)-\(e)"
        } else if let s = start {
            return "bytes=\(s)-"
        } else if let suffix = suffixLength {
            return "bytes=-\(suffix)"
        }
        return rawHeader
    }
}

/// Parsed HTTP `Content-Range` response specification.
struct ContentRangeSpec: Codable, Equatable, Sendable {
    var unit: String // e.g. "bytes"
    var start: Int64?
    var end: Int64?
    var totalLength: Int64?
    var rawHeader: String

    var partialLength: Int64? {
        if let s = start, let e = end, e >= s {
            return (e - s) + 1
        }
        return nil
    }

    var displayString: String {
        rawHeader
    }
}

/// Standardized CDN edge cache hit status.
enum ByteRangeCacheStatus: Codable, Equatable, Sendable {
    case hit
    case miss
    case expired
    case bypass
    case revalidated
    case unknown(String)

    var title: String {
        switch self {
        case .hit: return "HIT"
        case .miss: return "MISS"
        case .expired: return "EXPIRED"
        case .bypass: return "BYPASS"
        case .revalidated: return "REVALIDATED"
        case .unknown(let raw): return raw
        }
    }

    var isHit: Bool {
        switch self {
        case .hit, .revalidated: return true
        default: return false
        }
    }

    static func from(headerValue: String) -> ByteRangeCacheStatus {
        let clean = headerValue.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("HIT") {
            return .hit
        } else if clean.contains("MISS") {
            return .miss
        } else if clean.contains("EXPIRED") {
            return .expired
        } else if clean.contains("BYPASS") {
            return .bypass
        } else if clean.contains("REVALIDATED") {
            return .revalidated
        }
        return .unknown(headerValue)
    }
}

/// A single audited Byte-Range transaction.
struct ByteRangeTransaction: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var requestURL: String
    var requestMethod: String
    var rangeRequest: ByteRangeSpec
    var contentRangeResponse: ContentRangeSpec?
    var statusCode: Int
    var transferredBytes: Int64
    var requestedBytes: Int64
    var redundantBytes: Int64 // max(0, transferredBytes - requestedBytes)
    var wasteRatio: Double // transferredBytes / requestedBytes
    var cacheStatus: ByteRangeCacheStatus
    var cacheAgeSeconds: Int?
    var edgePOP: String?
}

/// Defects identified during Byte-Range and CDN cache auditing.
enum ByteRangeDefect: Codable, Equatable, Sendable {
    case fullContentServedForRangeRequest(requestedBytes: Int64, transferredBytes: Int64, wasteRatio: Double)
    case rangeNotSatisfiable416(url: String)
    case missingAcceptRangesHeader(url: String)
    case cacheMissOnStaticSegment(url: String, cacheHeader: String)
    case malformedContentRange(headerValue: String)

    var userFacingMessage: String {
        switch self {
        case .fullContentServedForRangeRequest(let req, let trans, let ratio):
            let wasted = max(0, trans - req)
            let formattedWasted = ByteCountFormatter.string(fromByteCount: wasted, countStyle: .file)
            return "Full content served for Range request: HTTP 200 OK returned instead of 206 Partial Content, transferring \(formattedWasted) redundant data (\(String(format: "%.1fx", ratio)) bandwidth waste)."
        case .rangeNotSatisfiable416(let url):
            return "HTTP 416 Range Not Satisfiable returned for '\(url)' (offset exceeds total asset size)."
        case .missingAcceptRangesHeader(let url):
            return "Missing Accept-Ranges header for media asset at '\(url)'."
        case .cacheMissOnStaticSegment(let url, let header):
            return "CDN Cache Miss on static media segment at '\(url)' (\(header))."
        case .malformedContentRange(let val):
            return "Malformed Content-Range response header: '\(val)'."
        }
    }

    var isCritical: Bool {
        switch self {
        case .fullContentServedForRangeRequest, .rangeNotSatisfiable416:
            return true
        case .missingAcceptRangesHeader, .cacheMissOnStaticSegment, .malformedContentRange:
            return false
        }
    }
}

/// Comprehensive inspection report for Byte-Range transactions and CDN cache efficiency.
struct ByteRangeEfficiencyReport: Codable, Equatable, Sendable {
    var totalTransactions: Int
    var partialContent206Count: Int
    var fullContent200Count: Int
    var totalRequestedBytes: Int64
    var totalTransferredBytes: Int64
    var totalRedundantBytes: Int64
    var overallWastePercentage: Double
    var cacheHitRatio: Double // 0.0 to 1.0
    var defects: [ByteRangeDefect]
    var transactions: [ByteRangeTransaction]
    var efficiencyScore: Double // 0 to 100
    var isEfficient: Bool

    var criticalDefectsCount: Int {
        defects.filter(\.isCritical).count
    }
}
