//
//  ByteRangeAuditorEngine.swift
//  JoesProxy
//
//  Auditor for HTTP Range requests, 200 OK vs 206 Partial Content validation,
//  CDN edge caching telemetry, and redundant bandwidth waste calculation.
//

import Foundation

enum ByteRangeAuditorEngine {

    /// Audits sessions for HTTP Range header compliance, 206 Partial Content handling, and CDN efficiency.
    static func audit(sessions: [SessionRecord]) -> ByteRangeEfficiencyReport {
        var transactions: [ByteRangeTransaction] = []
        var defects: [ByteRangeDefect] = []

        var totalReqBytes: Int64 = 0
        var totalTransBytes: Int64 = 0
        var totalRedundantBytes: Int64 = 0
        var count206 = 0
        var count200 = 0
        var cacheHits = 0

        for session in sessions {
            let reqHeaders = session.request.headers
            let respHeaders = session.response?.headers ?? []
            let statusCode = session.response?.statusCode ?? 0
            let urlStr = MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path

            // Check if request has Range header
            guard let rangeHeader = reqHeaders.first(where: { $0.name.lowercased() == "range" })?.value,
                  let rangeSpec = parseRangeHeader(rangeHeader) else {
                continue
            }

            let contentRangeHeader = respHeaders.first(where: { $0.name.lowercased() == "content-range" })?.value
            let contentRangeSpec = contentRangeHeader != nil ? parseContentRangeHeader(contentRangeHeader!) : nil

            let cdnInfo = parseCDNCacheInfo(respHeaders)
            if cdnInfo.status.isHit {
                cacheHits += 1
            }

            // Determine actual transferred bytes
            let transferredBytes: Int64
            if let bodySize = session.response?.bodySize, bodySize > 0 {
                transferredBytes = Int64(bodySize)
            } else if let bodyData = session.response?.bodyData, !bodyData.isEmpty {
                transferredBytes = Int64(bodyData.count)
            } else if let cl = respHeaders.first(where: { $0.name.lowercased() == "content-length" })?.value, let clInt = Int64(cl) {
                transferredBytes = clInt
            } else {
                transferredBytes = rangeSpec.requestedLength ?? 0
            }

            let requestedBytes = rangeSpec.requestedLength ?? transferredBytes
            totalReqBytes += requestedBytes
            totalTransBytes += transferredBytes

            var redundant: Int64 = 0
            var wasteRatio: Double = 1.0

            if statusCode == 206 {
                count206 += 1
                if let contentRange = contentRangeSpec, let pLen = contentRange.partialLength, pLen != transferredBytes {
                    // Slight variation
                }
            } else if statusCode == 200 {
                count200 += 1
                redundant = max(0, transferredBytes - requestedBytes)
                totalRedundantBytes += redundant
                wasteRatio = requestedBytes > 0 ? (Double(transferredBytes) / Double(requestedBytes)) : 1.0

                if redundant > 1024 { // Flag if > 1KB redundant
                    defects.append(
                        .fullContentServedForRangeRequest(
                            requestedBytes: requestedBytes,
                            transferredBytes: transferredBytes,
                            wasteRatio: wasteRatio
                        )
                    )
                }
            } else if statusCode == 416 {
                defects.append(.rangeNotSatisfiable416(url: urlStr))
            }

            // Check CDN cache misses on media segments
            if !cdnInfo.status.isHit && (urlStr.contains(".m4s") || urlStr.contains(".ts") || urlStr.contains(".mp4")) {
                let cacheName = cdnInfo.status.title
                if cacheName != "MISS" || respHeaders.contains(where: { $0.name.lowercased().contains("cache") }) {
                    defects.append(.cacheMissOnStaticSegment(url: urlStr, cacheHeader: cacheName))
                }
            }

            let transaction = ByteRangeTransaction(
                id: session.id.uuidString,
                requestURL: urlStr,
                requestMethod: session.request.method,
                rangeRequest: rangeSpec,
                contentRangeResponse: contentRangeSpec,
                statusCode: statusCode,
                transferredBytes: transferredBytes,
                requestedBytes: requestedBytes,
                redundantBytes: redundant,
                wasteRatio: wasteRatio,
                cacheStatus: cdnInfo.status,
                cacheAgeSeconds: cdnInfo.age,
                edgePOP: cdnInfo.pop
            )
            transactions.append(transaction)
        }

        let overallWastePct = totalTransBytes > 0 ? (Double(totalRedundantBytes) / Double(totalTransBytes)) * 100.0 : 0.0
        let cacheHitRatio = transactions.isEmpty ? 0.0 : (Double(cacheHits) / Double(transactions.count))

        // Calculate Efficiency Score
        var score: Double = 100.0
        for defect in defects {
            score -= defect.isCritical ? 25.0 : 5.0
        }
        let efficiencyScore = max(0.0, min(100.0, score))
        let isEfficient = !defects.contains(where: \.isCritical)

        return ByteRangeEfficiencyReport(
            totalTransactions: transactions.count,
            partialContent206Count: count206,
            fullContent200Count: count200,
            totalRequestedBytes: totalReqBytes,
            totalTransferredBytes: totalTransBytes,
            totalRedundantBytes: totalRedundantBytes,
            overallWastePercentage: overallWastePct,
            cacheHitRatio: cacheHitRatio,
            defects: defects,
            transactions: transactions,
            efficiencyScore: efficiencyScore,
            isEfficient: isEfficient
        )
    }

    // MARK: - Range Header Parsing

    static func parseRangeHeader(_ value: String) -> ByteRangeSpec? {
        let clean = value.trimmingCharacters(in: .whitespaces)
        guard clean.lowercased().hasPrefix("bytes=") else { return nil }

        let rangeContent = clean.replacingOccurrences(of: "bytes=", with: "").trimmingCharacters(in: .whitespaces)
        let parts = rangeContent.components(separatedBy: "-")
        guard !parts.isEmpty else { return nil }

        if parts.count == 2 {
            let startStr = parts[0].trimmingCharacters(in: .whitespaces)
            let endStr = parts[1].trimmingCharacters(in: .whitespaces)

            if startStr.isEmpty && !endStr.isEmpty, let suffix = Int64(endStr) {
                // Suffix range: bytes=-500
                return ByteRangeSpec(start: nil, end: nil, suffixLength: suffix, rawHeader: value)
            } else if !startStr.isEmpty && endStr.isEmpty, let start = Int64(startStr) {
                // Open range: bytes=500-
                return ByteRangeSpec(start: start, end: nil, suffixLength: nil, rawHeader: value)
            } else if let start = Int64(startStr), let end = Int64(endStr) {
                // Closed range: bytes=500-999
                return ByteRangeSpec(start: start, end: end, suffixLength: nil, rawHeader: value)
            }
        }

        return ByteRangeSpec(start: nil, end: nil, suffixLength: nil, rawHeader: value)
    }

    // MARK: - Content-Range Header Parsing

    static func parseContentRangeHeader(_ value: String) -> ContentRangeSpec? {
        let clean = value.trimmingCharacters(in: .whitespaces)
        // Format: bytes 0-499/1234 or bytes */1234
        let tokens = clean.components(separatedBy: " ")
        guard tokens.count >= 2 else { return nil }

        let unit = tokens[0]
        let rangeAndTotal = tokens[1].components(separatedBy: "/")
        guard !rangeAndTotal.isEmpty else { return nil }

        let rangePart = rangeAndTotal[0]
        let totalPart = rangeAndTotal.count > 1 ? rangeAndTotal[1] : nil

        var start: Int64? = nil
        var end: Int64? = nil
        var totalLength: Int64? = totalPart != nil ? Int64(totalPart!) : nil

        if rangePart.contains("-") {
            let parts = rangePart.components(separatedBy: "-")
            if parts.count == 2 {
                start = Int64(parts[0])
                end = Int64(parts[1])
            }
        }

        return ContentRangeSpec(
            unit: unit,
            start: start,
            end: end,
            totalLength: totalLength,
            rawHeader: value
        )
    }

    // MARK: - CDN Cache Info Parsing

    private static func parseCDNCacheInfo(_ headers: [HTTPHeaderField]) -> (status: ByteRangeCacheStatus, age: Int?, pop: String?) {
        var status: ByteRangeCacheStatus = .unknown("UNCACHED")
        var age: Int? = nil
        var pop: String? = nil

        for header in headers {
            let name = header.name.lowercased()
            let val = header.value

            if name == "cf-cache-status" || name == "x-cache" || name == "x-cache-lookup" {
                status = ByteRangeCacheStatus.from(headerValue: val)
            } else if name == "age", let num = Int(val) {
                age = num
            } else if name == "cf-ray" || name == "x-served-by" || name == "x-cdn-pop" {
                pop = val
            }
        }

        return (status, age, pop)
    }
}
