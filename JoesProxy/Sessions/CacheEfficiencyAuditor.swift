//
//  CacheEfficiencyAuditor.swift
//  JoesProxy
//
//  Audits captured sessions for cache inefficiencies, redundant un-cached duplicate requests,
//  conflicting HTTP caching headers, and missing validation tokens on large assets.
//

import Foundation

struct UncachedDuplicateGroup: Equatable, Hashable, Sendable, Codable {
    let method: String
    let url: String
    let count: Int
    let totalTransferBytes: Int
    let sampleSessionIDs: [UUID]

    init(method: String, url: String, count: Int, totalTransferBytes: Int, sampleSessionIDs: [UUID]) {
        self.method = method
        self.url = url
        self.count = count
        self.totalTransferBytes = totalTransferBytes
        self.sampleSessionIDs = sampleSessionIDs
    }
}

struct ConflictingHeaderSession: Equatable, Hashable, Sendable, Codable {
    let sessionID: UUID
    let method: String
    let url: String
    let conflicts: [String]

    init(sessionID: UUID, method: String, url: String, conflicts: [String]) {
        self.sessionID = sessionID
        self.method = method
        self.url = url
        self.conflicts = conflicts
    }
}

struct MissingValidationTokenSession: Equatable, Hashable, Sendable, Codable {
    let sessionID: UUID
    let method: String
    let url: String
    let bodySizeBytes: Int

    init(sessionID: UUID, method: String, url: String, bodySizeBytes: Int) {
        self.sessionID = sessionID
        self.method = method
        self.url = url
        self.bodySizeBytes = bodySizeBytes
    }
}

struct CacheEfficiencyAuditReport: Equatable, Hashable, Sendable, Codable {
    let totalSessionsEvaluated: Int
    let uncachedDuplicateRequests: [UncachedDuplicateGroup]
    let conflictingHeaderSessions: [ConflictingHeaderSession]
    let missingValidationTokens: [MissingValidationTokenSession]
    let potentialBandwidthWasteBytes: Int

    init(
        totalSessionsEvaluated: Int,
        uncachedDuplicateRequests: [UncachedDuplicateGroup],
        conflictingHeaderSessions: [ConflictingHeaderSession],
        missingValidationTokens: [MissingValidationTokenSession],
        potentialBandwidthWasteBytes: Int
    ) {
        self.totalSessionsEvaluated = totalSessionsEvaluated
        self.uncachedDuplicateRequests = uncachedDuplicateRequests
        self.conflictingHeaderSessions = conflictingHeaderSessions
        self.missingValidationTokens = missingValidationTokens
        self.potentialBandwidthWasteBytes = potentialBandwidthWasteBytes
    }

    var isClean: Bool {
        uncachedDuplicateRequests.isEmpty &&
        conflictingHeaderSessions.isEmpty &&
        missingValidationTokens.isEmpty
    }
}

enum CacheEfficiencyAuditor {

    private static let largeAssetThresholdBytes = 100 * 1024 // 100 KB

    static func audit(sessions: [SessionRecord]) -> CacheEfficiencyAuditReport {
        var duplicateMap: [String: [SessionRecord]] = [:]
        var conflictingSessions: [ConflictingHeaderSession] = []
        var missingTokenSessions: [MissingValidationTokenSession] = []
        var totalWastedBytes = 0

        for session in sessions {
            guard let response = session.response else { continue }

            let url = "\(session.request.scheme.rawValue)://\(session.request.host)\(session.request.path)"
            let key = "\(session.request.method.uppercased()) \(url)"
            duplicateMap[key, default: []].append(session)

            let freshness = session.cacheFreshness
            if !freshness.conflictingDirectives.isEmpty {
                conflictingSessions.append(
                    ConflictingHeaderSession(
                        sessionID: session.id,
                        method: session.request.method,
                        url: url,
                        conflicts: freshness.conflictingDirectives
                    )
                )
            }

            let bodySize = response.bodySize ?? response.bodyData?.count ?? 0
            if response.statusCode == 200 && bodySize >= largeAssetThresholdBytes {
                if freshness.etag == nil && freshness.lastModified == nil {
                    missingTokenSessions.append(
                        MissingValidationTokenSession(
                            sessionID: session.id,
                            method: session.request.method,
                            url: url,
                            bodySizeBytes: bodySize
                        )
                    )
                }
            }
        }

        var duplicateGroups: [UncachedDuplicateGroup] = []
        for (key, group) in duplicateMap where group.count >= 2 {
            // Check if requests in this group lacked caching headers
            let unCachedCount = group.filter { s in
                s.cacheFreshness.policyKind == .notSpecified && (s.response?.statusCode == 200)
            }.count

            if unCachedCount >= 2 {
                let parts = key.split(separator: " ", maxSplits: 1)
                let method = parts.first.map(String.init) ?? "GET"
                let url = parts.count > 1 ? String(parts[1]) : key

                let totalBytes = group.reduce(0) { $0 + ($1.response?.bodySize ?? $1.response?.bodyData?.count ?? 0) }
                let avgBytes = group.isEmpty ? 0 : totalBytes / group.count
                let wasted = (group.count - 1) * avgBytes
                totalWastedBytes += wasted

                duplicateGroups.append(
                    UncachedDuplicateGroup(
                        method: method,
                        url: url,
                        count: group.count,
                        totalTransferBytes: totalBytes,
                        sampleSessionIDs: group.map(\.id)
                    )
                )
            }
        }

        return CacheEfficiencyAuditReport(
            totalSessionsEvaluated: sessions.count,
            uncachedDuplicateRequests: duplicateGroups.sorted(by: { $0.totalTransferBytes > $1.totalTransferBytes }),
            conflictingHeaderSessions: conflictingSessions,
            missingValidationTokens: missingTokenSessions.sorted(by: { $0.bodySizeBytes > $1.bodySizeBytes }),
            potentialBandwidthWasteBytes: totalWastedBytes
        )
    }
}
