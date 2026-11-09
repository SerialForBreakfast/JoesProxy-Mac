import Foundation

struct SessionFindResult: Identifiable, Equatable, Sendable {
    enum MatchLocation: String, Equatable, Sendable {
        case requestBody
        case responseBody

        var title: String {
            switch self {
            case .requestBody:
                return "Request Body"
            case .responseBody:
                return "Response Body"
            }
        }
    }

    let sessionID: SessionRecord.ID
    let location: MatchLocation
    let matchCount: Int
    let method: String
    let host: String
    let path: String
    let statusCode: Int?

    var id: String {
        "\(sessionID.uuidString)-\(location.rawValue)"
    }
}

struct SessionFindOutcome: Equatable, Sendable {
    let results: [SessionFindResult]
    let searchedBodyCount: Int
    /// Body texts decoded fresh during this run (cache misses only).
    /// Keyed by session ID so the caller can populate its body text cache.
    let decodedBodyTexts: [SessionRecord.ID: SessionBodyText]
}

/// Pre-decoded body text for a single session, used to avoid re-decoding on repeated find runs.
struct SessionBodyText: Equatable, Sendable {
    let requestText: String?
    let responseText: String?
    /// True when response search extraction has already been attempted, even if no text was found.
    let responseBodySearchWasEvaluated: Bool

    init(
        requestText: String?,
        responseText: String?,
        responseBodySearchWasEvaluated: Bool = false
    ) {
        self.requestText = requestText
        self.responseText = responseText
        self.responseBodySearchWasEvaluated = responseBodySearchWasEvaluated
    }
}

struct SessionFindEngine: Sendable {
    func find(
        in sessions: [SessionRecord],
        query: String,
        bodyTextCache: [SessionRecord.ID: SessionBodyText] = [:]
    ) -> SessionFindOutcome {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return SessionFindOutcome(results: [], searchedBodyCount: 0, decodedBodyTexts: [:])
        }

        let foldedQuery = trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var results: [SessionFindResult] = []
        var searchedBodyCount = 0
        var decodedBodyTexts: [SessionRecord.ID: SessionBodyText] = [:]

        for (index, session) in sessions.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled {
                return SessionFindOutcome(
                    results: results,
                    searchedBodyCount: searchedBodyCount,
                    decodedBodyTexts: decodedBodyTexts
                )
            }
            let requestText: String?
            let responseText: String?

            if let cached = bodyTextCache[session.id] {
                requestText = cached.requestText
                responseText = cached.responseText
            } else {
                requestText = textBody(from: session.request)
                let responseSearch = session.response.map { textBody(from: $0) }
                responseText = responseSearch?.text
                // Collect freshly decoded texts and response skip states so the caller can populate its cache.
                if requestText != nil || responseText != nil || responseSearch?.wasEvaluated == true {
                    decodedBodyTexts[session.id] = SessionBodyText(
                        requestText: requestText,
                        responseText: responseText,
                        responseBodySearchWasEvaluated: responseSearch?.wasEvaluated == true
                    )
                }
            }

            if let text = requestText {
                searchedBodyCount += 1
                if let count = matchCount(in: text, foldedQuery: foldedQuery) {
                    results.append(makeResult(for: session, location: .requestBody, matchCount: count))
                }
            }

            if let text = responseText {
                searchedBodyCount += 1
                if let count = matchCount(in: text, foldedQuery: foldedQuery) {
                    results.append(makeResult(for: session, location: .responseBody, matchCount: count))
                }
            }
        }

        return SessionFindOutcome(results: results, searchedBodyCount: searchedBodyCount, decodedBodyTexts: decodedBodyTexts)
    }

    private func textBody(from request: CapturedRequest) -> String? {
        guard !request.bodyDeferred,
              request.recordingBodyOmissionReason == nil,
              let bodyData = request.bodyData,
              !CapturedBodyDecoder.isKnownBinaryContentType(headers: request.headers) else {
            return nil
        }

        return String(data: bodyData, encoding: .utf8)
    }

    private func textBody(from response: CapturedResponse) -> (text: String?, wasEvaluated: Bool) {
        guard let decoded = CapturedBodyDecoder.decode(response: response) else {
            return (nil, false)
        }
        guard decoded.isAnalysisTextSearchable else {
            return (nil, true)
        }

        return (decoded.analysisUTF8Text(), true)
    }

    /// O(n) single-pass match count via fold + split. Replaces the prior O(m×n) while-range loop.
    private func matchCount(in body: String, foldedQuery: String) -> Int? {
        let foldedBody = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let count = foldedBody.components(separatedBy: foldedQuery).count - 1
        return count > 0 ? count : nil
    }

    private func makeResult(
        for session: SessionRecord,
        location: SessionFindResult.MatchLocation,
        matchCount: Int
    ) -> SessionFindResult {
        SessionFindResult(
            sessionID: session.id,
            location: location,
            matchCount: matchCount,
            method: session.request.method,
            host: session.request.host,
            path: session.request.path,
            statusCode: session.response?.statusCode
        )
    }
}
