//
//  CacheFreshnessEvaluator.swift
//  JoesProxy
//
//  Evaluates HTTP caching policies, validation tokens, CDN indicators, and effective
//  freshness lifetimes from captured request and response headers.
//

import Foundation

enum CachePolicyKind: Equatable, Hashable, Sendable, Codable {
    case noStore
    case noCache
    case maxAge(seconds: Int, isPublic: Bool, isImmutable: Bool)
    case expires(Date)
    case heuristic(lastModified: Date)
    case notSpecified
}

struct CacheFreshnessSummary: Equatable, Hashable, Sendable, Codable {
    let policyKind: CachePolicyKind
    let revalidationRequired: Bool
    let staleWhileRevalidateSeconds: Int?
    let staleIfErrorSeconds: Int?
    let etag: String?
    let lastModified: String?
    let ageSeconds: Int?
    let cdnStatus: String?
    let effectiveTTLSeconds: Int?
    let isStale: Bool
    let displayBadgeText: String
    let badgeTintName: String
    let conflictingDirectives: [String]

    init(
        policyKind: CachePolicyKind,
        revalidationRequired: Bool,
        staleWhileRevalidateSeconds: Int? = nil,
        staleIfErrorSeconds: Int? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        ageSeconds: Int? = nil,
        cdnStatus: String? = nil,
        effectiveTTLSeconds: Int? = nil,
        isStale: Bool = false,
        displayBadgeText: String,
        badgeTintName: String,
        conflictingDirectives: [String] = []
    ) {
        self.policyKind = policyKind
        self.revalidationRequired = revalidationRequired
        self.staleWhileRevalidateSeconds = staleWhileRevalidateSeconds
        self.staleIfErrorSeconds = staleIfErrorSeconds
        self.etag = etag
        self.lastModified = lastModified
        self.ageSeconds = ageSeconds
        self.cdnStatus = cdnStatus
        self.effectiveTTLSeconds = effectiveTTLSeconds
        self.isStale = isStale
        self.displayBadgeText = displayBadgeText
        self.badgeTintName = badgeTintName
        self.conflictingDirectives = conflictingDirectives
    }
}

enum CacheFreshnessEvaluator {

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()

    static func evaluate(
        requestHeaders: [HTTPHeaderField] = [],
        responseHeaders: [HTTPHeaderField] = [],
        statusCode: Int? = nil,
        now: Date = Date()
    ) -> CacheFreshnessSummary {
        let respHeaderDict = dictionary(from: responseHeaders)
        let cacheControl = respHeaderDict["cache-control"]?.lowercased()
        let pragma = respHeaderDict["pragma"]?.lowercased()
        let expiresStr = respHeaderDict["expires"]
        let etag = respHeaderDict["etag"]
        let lastModifiedStr = respHeaderDict["last-modified"]
        let ageStr = respHeaderDict["age"]
        
        let ageSeconds = ageStr.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let cdnStatus = extractCDNStatus(from: respHeaderDict)

        var isNoStore = false
        var isNoCache = false
        var isMustRevalidate = false
        var isPublic = false
        var isImmutable = false
        var maxAgeSeconds: Int? = nil
        var sMaxAgeSeconds: Int? = nil
        var swrSeconds: Int? = nil
        var sieSeconds: Int? = nil
        var conflicts: [String] = []

        if let cacheControl {
            let tokens = cacheControl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for token in tokens {
                if token == "no-store" {
                    isNoStore = true
                } else if token == "no-cache" {
                    isNoCache = true
                } else if token == "must-revalidate" || token == "proxy-revalidate" {
                    isMustRevalidate = true
                } else if token == "public" {
                    isPublic = true
                } else if token == "immutable" {
                    isImmutable = true
                } else if token.hasPrefix("max-age=") {
                    let val = String(token.dropFirst("max-age=".count))
                    maxAgeSeconds = Int(val)
                } else if token.hasPrefix("s-maxage=") || token.hasPrefix("s-max-age=") {
                    let val = token.contains("s-maxage=")
                        ? String(token.dropFirst("s-maxage=".count))
                        : String(token.dropFirst("s-max-age=".count))
                    sMaxAgeSeconds = Int(val)
                } else if token.hasPrefix("stale-while-revalidate=") {
                    let val = String(token.dropFirst("stale-while-revalidate=".count))
                    swrSeconds = Int(val)
                } else if token.hasPrefix("stale-if-error=") {
                    let val = String(token.dropFirst("stale-if-error=".count))
                    sieSeconds = Int(val)
                }
            }
        }

        if pragma?.contains("no-cache") == true && !isNoCache {
            isNoCache = true
        }

        var expiresDate: Date? = nil
        if let expiresStr, !expiresStr.isEmpty {
            if expiresStr == "0" || expiresStr == "-1" {
                if !isNoCache && !isNoStore && maxAgeSeconds == nil {
                    isNoCache = true
                }
            } else {
                expiresDate = httpDateFormatter.date(from: expiresStr)
            }
        }

        var lastModifiedDate: Date? = nil
        if let lastModifiedStr, !lastModifiedStr.isEmpty {
            lastModifiedDate = httpDateFormatter.date(from: lastModifiedStr)
        }

        // Conflict checks
        if isNoStore && (maxAgeSeconds != nil || sMaxAgeSeconds != nil) {
            conflicts.append("Cache-Control combines no-store with max-age")
        }
        if isNoStore && isPublic {
            conflicts.append("Cache-Control combines no-store with public")
        }
        if isNoCache && expiresDate != nil && (expiresDate ?? now) > now {
            conflicts.append("Cache-Control specifies no-cache while Expires is in the future")
        }

        // Determine primary policy kind
        let policyKind: CachePolicyKind
        let effectiveTTL: Int?
        let isStale: Bool
        let revalidationRequired = isMustRevalidate || isNoCache || (maxAgeSeconds == 0)

        if statusCode == 304 {
            policyKind = .noCache
            effectiveTTL = 0
            isStale = false
        } else if isNoStore {
            policyKind = .noStore
            effectiveTTL = 0
            isStale = false
        } else if isNoCache {
            policyKind = .noCache
            effectiveTTL = 0
            isStale = false
        } else if let effectiveMaxAge = sMaxAgeSeconds ?? maxAgeSeconds {
            policyKind = .maxAge(seconds: effectiveMaxAge, isPublic: isPublic, isImmutable: isImmutable)
            let age = ageSeconds ?? 0
            let remaining = max(0, effectiveMaxAge - age)
            effectiveTTL = remaining
            isStale = remaining <= 0 && effectiveMaxAge > 0
        } else if let expires = expiresDate {
            policyKind = .expires(expires)
            let remaining = Int(expires.timeIntervalSince(now))
            effectiveTTL = max(0, remaining)
            isStale = remaining <= 0
        } else if let lastMod = lastModifiedDate {
            policyKind = .heuristic(lastModified: lastMod)
            // RFC 9111 heuristic: 10% of time since Last-Modified
            let timeSinceLastMod = max(0, now.timeIntervalSince(lastMod))
            let heuristicTTL = Int(timeSinceLastMod * 0.10)
            effectiveTTL = heuristicTTL
            isStale = false
        } else {
            policyKind = .notSpecified
            effectiveTTL = nil
            isStale = false
        }

        // Format Badge & Tint
        let (badgeText, badgeTint) = formatBadge(
            policyKind: policyKind,
            statusCode: statusCode,
            effectiveTTL: effectiveTTL,
            cdnStatus: cdnStatus,
            revalidationRequired: revalidationRequired,
            isStale: isStale,
            hasValidationToken: etag != nil || lastModifiedStr != nil
        )

        return CacheFreshnessSummary(
            policyKind: policyKind,
            revalidationRequired: revalidationRequired,
            staleWhileRevalidateSeconds: swrSeconds,
            staleIfErrorSeconds: sieSeconds,
            etag: etag,
            lastModified: lastModifiedStr,
            ageSeconds: ageSeconds,
            cdnStatus: cdnStatus,
            effectiveTTLSeconds: effectiveTTL,
            isStale: isStale,
            displayBadgeText: badgeText,
            badgeTintName: badgeTint,
            conflictingDirectives: conflicts
        )
    }

    private static func formatBadge(
        policyKind: CachePolicyKind,
        statusCode: Int?,
        effectiveTTL: Int?,
        cdnStatus: String?,
        revalidationRequired: Bool,
        isStale: Bool,
        hasValidationToken: Bool
    ) -> (String, String) {
        if statusCode == 304 {
            return ("304 Validated", "green")
        }

        if let cdnStatus, !cdnStatus.isEmpty {
            let upper = cdnStatus.uppercased()
            if upper.contains("HIT") {
                return ("CDN HIT", "green")
            }
        }

        switch policyKind {
        case .noStore:
            return ("No-Store", "orange")
        case .noCache:
            return (hasValidationToken ? "Revalidate (ETag)" : "No-Cache", "orange")
        case .maxAge(let seconds, _, let isImmutable):
            if isStale {
                return ("Stale", "red")
            }
            if isImmutable {
                return ("Immutable (\(formatDuration(seconds)))", "green")
            }
            return ("Cache: \(formatDuration(effectiveTTL ?? seconds))", "green")
        case .expires:
            if isStale {
                return ("Expired", "red")
            }
            if let effectiveTTL {
                return ("Expires in \(formatDuration(effectiveTTL))", "green")
            }
            return ("Expires", "green")
        case .heuristic(let date):
            _ = date
            return ("Heuristic (\(formatDuration(effectiveTTL ?? 0)))", "secondary")
        case .notSpecified:
            return (hasValidationToken ? "Conditional" : "Uncached", "secondary")
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else if seconds < 86400 {
            return "\(seconds / 3600)h"
        } else {
            return "\(seconds / 86400)d"
        }
    }

    private static func extractCDNStatus(from headers: [String: String]) -> String? {
        if let cf = headers["cf-cache-status"] {
            return "Cloudflare: \(cf)"
        }
        if let xcache = headers["x-cache"] {
            return xcache
        }
        if let akamai = headers["akamai-cache-status"] {
            return "Akamai: \(akamai)"
        }
        if let fastly = headers["x-served-by"] {
            return "Fastly: \(fastly)"
        }
        return nil
    }

    private static func dictionary(from headers: [HTTPHeaderField]) -> [String: String] {
        var dict: [String: String] = [:]
        for header in headers {
            dict[header.name.lowercased()] = header.value
        }
        return dict
    }
}
