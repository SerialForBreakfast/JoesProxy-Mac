import Foundation

struct SessionFilterCriteria: Equatable, Sendable {
    enum StatusMatch: Equatable, Sendable {
        case exact(Int)
        case range(ClosedRange<Int>)
        /// Sessions where the proxy could not complete the upstream connection (`state == .failed`).
        case failedConnection
    }

    enum InspectionMatch: Equatable, Sendable {
        case exact(SessionInspectionKind)
        case notTunneled
    }

    var hostContains: String = ""
    var method: String?
    var scheme: SessionScheme?
    var inspectionMatch: InspectionMatch?
    var statusMatch: StatusMatch?
    var sourceMatch: TrafficSource?
    var clientAddressMatch: String?

    var isEmpty: Bool {
        hostContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        method == nil &&
        scheme == nil &&
        inspectionMatch == nil &&
        statusMatch == nil &&
        sourceMatch == nil &&
        (clientAddressMatch == nil || clientAddressMatch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }
}

struct SessionFilterEngine: Sendable {
    /// Filters sessions by structured criteria and free-text search.
    ///
    /// `searchTextCache` holds one lowercased searchable blob per session (fields +
    /// joined headers), built lazily on first search-active pass and reused afterwards
    /// so the header join runs once per session lifetime instead of once per pass.
    /// The caller owns the cache and must evict entries whose sessions changed.
    /// Background callers can supply cooperative cancellation; a thrown checkpoint leaves
    /// only the visited entries in the caller's cache and does not return a partial result.
    func filter(
        _ sessions: [SessionRecord],
        criteria: SessionFilterCriteria,
        searchText: String,
        searchTextCache: inout [SessionRecord.ID: String],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SessionRecord] {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHostFilter = criteria.hostContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var result: [SessionRecord] = []
        for session in sessions {
            try cancellationCheck()
            guard matchesStructuredCriteria(session, criteria: criteria, normalizedHostFilter: normalizedHostFilter),
                  matchesSearchText(session, searchText: normalizedSearchText, searchTextCache: &searchTextCache) else {
                continue
            }
            result.append(session)
        }
        return result
    }

    /// Non-cancellable overload for synchronous callers that retain their search-text cache.
    func filter(
        _ sessions: [SessionRecord],
        criteria: SessionFilterCriteria,
        searchText: String,
        searchTextCache: inout [SessionRecord.ID: String]
    ) -> [SessionRecord] {
        filter(sessions, criteria: criteria, searchText: searchText,
               searchTextCache: &searchTextCache, cancellationCheck: {})
    }

    /// Convenience overload for callers that don't retain a search-text cache.
    func filter(
        _ sessions: [SessionRecord],
        criteria: SessionFilterCriteria,
        searchText: String
    ) -> [SessionRecord] {
        var throwawayCache: [SessionRecord.ID: String] = [:]
        return filter(sessions, criteria: criteria, searchText: searchText, searchTextCache: &throwawayCache)
    }

    private func matchesStructuredCriteria(
        _ session: SessionRecord,
        criteria: SessionFilterCriteria,
        normalizedHostFilter: String
    ) -> Bool {
        if !normalizedHostFilter.isEmpty &&
            !session.request.host.lowercased().contains(normalizedHostFilter) {
            return false
        }

        if let method = criteria.method,
           session.request.method.caseInsensitiveCompare(method) != .orderedSame {
            return false
        }

        if let scheme = criteria.scheme,
           session.request.scheme != scheme {
            return false
        }

        if let inspectionMatch = criteria.inspectionMatch {
            switch inspectionMatch {
            case .exact(let inspectionKind):
                if session.request.inspectionKind != inspectionKind {
                    return false
                }
            case .notTunneled:
                if session.request.inspectionKind == .tunneledTLS {
                    return false
                }
            }
        }

        if let statusMatch = criteria.statusMatch {
            switch statusMatch {
            case .failedConnection:
                if session.state != .failed {
                    return false
                }
            case .exact(let expectedCode):
                guard let statusCode = session.response?.statusCode, statusCode == expectedCode else {
                    return false
                }
            case .range(let range):
                guard let statusCode = session.response?.statusCode, range.contains(statusCode) else {
                    return false
                }
            }
        }

        if let sourceMatch = criteria.sourceMatch {
            let source = TrafficSource.classify(
                clientAddress: session.request.clientAddress,
                userAgent: session.request.userAgent
            )
            if source != sourceMatch {
                return false
            }
        }

        if let clientAddressMatch = criteria.clientAddressMatch?.trimmingCharacters(in: .whitespacesAndNewlines), !clientAddressMatch.isEmpty {
            guard let clientAddress = session.request.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  clientAddress == clientAddressMatch else {
                return false
            }
        }

        return true
    }

    private func matchesSearchText(
        _ session: SessionRecord,
        searchText: String,
        searchTextCache: inout [SessionRecord.ID: String]
    ) -> Bool {
        guard !searchText.isEmpty else {
            return true
        }

        if let blob = searchTextCache[session.id] {
            return blob.contains(searchText)
        }

        let blob = Self.searchBlob(for: session)
        searchTextCache[session.id] = blob
        return blob.contains(searchText)
    }

    /// One lowercased newline-joined blob of every searchable field. Built on demand
    /// during search-active passes only — never at capture time.
    static func searchBlob(for session: SessionRecord) -> String {
        var parts: [String] = [
            session.request.host,
            session.request.path,
            session.request.method,
            session.request.inspectionReason ?? "",
            session.response.map { String($0.statusCode) } ?? ""
        ]
        parts.append(contentsOf: session.request.headers.map { "\($0.name): \($0.value)" })
        parts.append(contentsOf: (session.response?.headers ?? []).map { "\($0.name): \($0.value)" })
        return parts.joined(separator: "\n").lowercased()
    }
}
