import Foundation

struct CDNHeaderSignals: Equatable, Sendable {
    let cacheStatus: CDNCacheStatus?
    let cdnRegion: String?
}

struct CDNHeaderReader: Sendable {
    func read(headers: [HTTPHeaderField]) -> CDNHeaderSignals {
        let lookup = HeaderLookup(headers: headers)
        return CDNHeaderSignals(
            cacheStatus: cacheStatus(from: lookup),
            cdnRegion: cdnRegion(from: lookup)
        )
    }

    private func cacheStatus(from headers: HeaderLookup) -> CDNCacheStatus? {
        if let cfCacheStatus = headers.value(for: "CF-Cache-Status") {
            return cloudflareStatus(cfCacheStatus)
        }

        if headers.value(for: "X-Amz-Cf-Pop") != nil,
           let xCache = headers.value(for: "X-Cache") {
            return cloudFrontStatus(xCache)
        }

        if isFastlyServedBy(headers.value(for: "X-Served-By")),
           let xCache = headers.value(for: "X-Cache") {
            return genericStatus(xCache)
        }

        if let xCache = headers.value(for: "X-Cache"),
           xCache.uppercased().contains("TCP_") {
            return akamaiStatus(xCache)
        }

        if let xCache = headers.value(for: "X-Cache") {
            return genericStatus(xCache)
        }

        return nil
    }

    private func cdnRegion(from headers: HeaderLookup) -> String? {
        if let cfRay = headers.value(for: "CF-Ray"),
           let region = cfRay.split(separator: "-").last.map(String.init),
           !region.isEmpty {
            return region
        }

        if let pop = headers.value(for: "X-Amz-Cf-Pop"),
           !pop.isEmpty {
            return pop
        }

        if let servedBy = headers.value(for: "X-Served-By"),
           let region = servedBy.split(separator: "-").last.map(String.init),
           region.count == 3 {
            return region
        }

        return nil
    }

    private func cloudflareStatus(_ rawValue: String) -> CDNCacheStatus {
        switch normalized(rawValue) {
        case "HIT":
            return .hit
        case "MISS":
            return .miss
        case "STALE":
            return .stale
        case "BYPASS", "DYNAMIC":
            return .bypass
        case "EXPIRED":
            return .expired
        default:
            return .unknown
        }
    }

    private func cloudFrontStatus(_ rawValue: String) -> CDNCacheStatus {
        let normalizedValue = normalized(rawValue)
        if normalizedValue.contains("REFRESHHIT FROM CLOUDFRONT") {
            return .expired
        }
        if normalizedValue.contains("HIT FROM CLOUDFRONT") {
            return .hit
        }
        if normalizedValue.contains("MISS FROM CLOUDFRONT") {
            return .miss
        }
        if normalizedValue.contains("ERROR FROM CLOUDFRONT") {
            return .unknown
        }
        return genericStatus(rawValue)
    }

    private func akamaiStatus(_ rawValue: String) -> CDNCacheStatus {
        let normalizedValue = normalized(rawValue)
        if normalizedValue.contains("TCP_HIT") || normalizedValue.contains("TCP_MEM_HIT") {
            return .hit
        }
        if normalizedValue.contains("TCP_MISS") {
            return .miss
        }
        if normalizedValue.contains("TCP_EXPIRED_HIT") || normalizedValue.contains("TCP_REFRESH_HIT") {
            return .stale
        }
        if normalizedValue.contains("TCP_EXPIRED_MISS") || normalizedValue.contains("TCP_REFRESH_MISS") {
            return .expired
        }
        return .unknown
    }

    private func genericStatus(_ rawValue: String) -> CDNCacheStatus {
        let normalizedValue = normalized(rawValue)
        if normalizedValue.contains("HIT") {
            return .hit
        }
        if normalizedValue.contains("MISS") {
            return .miss
        }
        if normalizedValue.contains("STALE") {
            return .stale
        }
        if normalizedValue.contains("BYPASS") {
            return .bypass
        }
        if normalizedValue.contains("EXPIRED") {
            return .expired
        }
        return .unknown
    }

    private func isFastlyServedBy(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.lowercased().contains("cache-")
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private struct HeaderLookup {
    private let headers: [HTTPHeaderField]

    init(headers: [HTTPHeaderField]) {
        self.headers = headers
    }

    func value(for name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
