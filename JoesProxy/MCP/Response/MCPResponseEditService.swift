import CryptoKit
import Foundation

/// Capture-only response inspection, exact-text search, and bounded body reads for generic editing.
///
/// Concurrency: `@MainActor` — owns in-memory match-ref and read-budget state keyed by client and
/// logical MCP session. Callers must stay on the main actor with ``MCPSessionSnapshotService``.
@MainActor
final class MCPResponseEditService {
    private struct MatchRefRecord {
        let matchRef: String
        let clientID: String
        let mcpSessionID: String?
        let captureEpoch: MCPCaptureEpoch
        let policyRevision: MCPPolicyRevision
        let sessionID: SessionRecord.ID
        let captureSequence: UInt64
        let bodySHA256: String
        let byteRange: Range<Int>
        let matchedBytesSHA256: String
        let expiresAt: Date
    }

    private struct ReadCursorRecord {
        let clientID: String
        let mcpSessionID: String?
        let captureEpoch: MCPCaptureEpoch
        let policyRevision: MCPPolicyRevision
        let sessionID: SessionRecord.ID
        let bodySHA256: String
        let nextOffset: Int
        let expiresAt: Date
    }

    private let snapshotService: MCPSessionSnapshotService
    private let policyStore: MCPPolicyStore
    private let policyEvaluator: MCPPolicyEvaluator
    private let auditStore: MCPAuditStore?
    private var matchRefsByID: [String: MatchRefRecord] = [:]
    private var readCursorsByToken: [String: ReadCursorRecord] = [:]
    private var disclosedBytesBySessionKey: [String: Int] = [:]

    static let maxFindBytes = 4 * 1024
    static let minFindBytes = 3
    static let maxMatchesReturned = 100
    static let maxContextBytes = 128
    static let matchRefTTL: TimeInterval = 300
    static let readCursorTTL: TimeInterval = 300
    static let maxRevisionBytes = MCPResourceBudget.maxDisclosedCallBytes
    static let maxReadBytesPerCall = MCPResourceBudget.maxDisclosedItemBytes
    static let maxReadBytesPerLogicalSession = MCPResourceBudget.maxDisclosedCallBytes

    init(
        snapshotService: MCPSessionSnapshotService,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore? = nil
    ) {
        self.snapshotService = snapshotService
        self.policyStore = policyStore
        self.policyEvaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
        self.auditStore = auditStore
    }

    /// Metadata-only body availability and editability for one captured session.
    func responseContext(
        sessionID: SessionRecord.ID,
        client: MCPClientRecord
    ) throws -> MCPResponseContextDTO {
        try requireInspectAccess(client: client, capability: .responseContext)
        if let indexed = snapshotService.indexedSession(id: sessionID),
           let response = indexed.record.response, response.bodyData == nil {
            let completeness = response.bodyDeferred ? "bodyDeferred"
                : response.recordingBodyOmissionReason != nil ? "bodyOmitted"
                : response.bodyTruncated ? "captureTruncated" : "bodyUnavailable"
            return MCPResponseContextDTO(
                sessionID: sessionID.uuidString, captureSequence: indexed.captureSequence,
                statusCode: response.statusCode, contentType: nil, charset: nil,
                representation: "unavailable", completeness: completeness,
                rawBodyByteCount: 0, revisionBodyByteCount: 0, bodySHA256: nil,
                isUTF8TextEditable: false,
                recommendedNextAction: response.bodyDeferred ? "wait_for_recording_load" : "session_summary",
                contentTrust: "metadata_only", captureEpoch: snapshotService.captureEpoch.rawValue,
                policyRevision: policyStore.policyRevision.rawValue)
        }
        let inspected = try inspectRevision(sessionID: sessionID, clientID: client.id)
        let recommended: String
        if inspected.isUTF8TextEditable {
            recommended = "response_text_search"
        } else if inspected.revision.completeness == .bodyDeferred {
            recommended = "wait_for_recording_load"
        } else if inspected.revision.completeness == .unsupportedEncoding
                    || inspected.revision.completeness == .invalidUTF8 {
            recommended = "session_summary"
        } else if inspected.revision.completeness == .captureTruncated
                    || inspected.revision.completeness == .decodeTruncated {
            recommended = "capture_a_complete_response"
        } else {
            recommended = "session_summary"
        }
        return MCPResponseContextDTO(
            sessionID: sessionID.uuidString,
            captureSequence: inspected.captureSequence,
            statusCode: inspected.revision.statusCode,
            contentType: inspected.revision.contentType,
            charset: inspected.revision.charset,
            representation: inspected.revision.representation == .decodedIdentity ? "decodedIdentity" : "raw",
            completeness: completenessString(inspected.revision.completeness),
            rawBodyByteCount: inspected.rawBodyByteCount,
            revisionBodyByteCount: inspected.revision.bodyBytes.count,
            bodySHA256: inspected.revision.bodySHA256,
            isUTF8TextEditable: inspected.isUTF8TextEditable,
            recommendedNextAction: recommended,
            contentTrust: "metadata_only",
            captureEpoch: snapshotService.captureEpoch.rawValue,
            policyRevision: policyStore.policyRevision.rawValue
        )
    }

    /// Exact case-sensitive UTF-8 byte search. Context windows require body-read approval.
    func responseTextSearch(
        sessionID: SessionRecord.ID,
        find: String,
        includeContext: Bool,
        client: MCPClientRecord,
        mcpSessionID: String?
    ) throws -> MCPResponseTextSearchDTO {
        try requireInspectAccess(client: client, capability: .responseTextSearch)
        let findData = Data(find.utf8)
        guard findData.count >= Self.minFindBytes else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "find must be at least \(Self.minFindBytes) UTF-8 bytes."
            )
        }
        guard findData.count <= Self.maxFindBytes else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "find must be at most \(Self.maxFindBytes) UTF-8 bytes."
            )
        }
        let inspected = try editableRevision(sessionID: sessionID, clientID: client.id)
        let ranges = exactMatchRanges(in: inspected.revision.bodyBytes, find: findData)
        let truncated = ranges.count > Self.maxMatchesReturned
        let limited = Array(ranges.prefix(Self.maxMatchesReturned))
        let expiresAt = Date().addingTimeInterval(Self.matchRefTTL)
        var matches: [MCPResponseTextMatchDTO] = []
        for range in limited {
            let matched = Data(inspected.revision.bodyBytes[range])
            let matchedHash = sha256Hex(matched)
            let matchRef = storeMatchRef(
                client: client,
                mcpSessionID: mcpSessionID,
                sessionID: sessionID,
                captureSequence: inspected.captureSequence,
                bodySHA256: inspected.revision.bodySHA256,
                byteRange: range,
                matchedBytesSHA256: matchedHash,
                expiresAt: expiresAt
            )
            let context: MCPUntrustedCapturedTextDTO?
            if includeContext {
                context = MCPUntrustedCapturedTextDTO(
                    contextWindow(in: inspected.revision.bodyBytes, around: range)
                )
            } else {
                context = nil
            }
            matches.append(
                MCPResponseTextMatchDTO(
                    matchRef: matchRef,
                    byteOffset: range.lowerBound,
                    byteLength: range.count,
                    matchedBytesSHA256: matchedHash,
                    context: context
                )
            )
        }
        // G6-03: exact case-sensitive search can correctly return zero matches while the text is
        // still on the page under different casing — a real, reproduced source of agent confusion
        // (see Live-NOBLENDER-Audit-2026-08-05.md). Only computed on the zero-match path so the
        // common case pays no extra cost, and only a count is disclosed, never matched text.
        let caseInsensitiveHint = ranges.isEmpty
            ? caseInsensitiveMatchCount(in: inspected.revision.bodyBytes, find: findData)
            : nil

        return MCPResponseTextSearchDTO(
            sessionID: sessionID.uuidString,
            findByteCount: findData.count,
            matchCount: ranges.count,
            matches: matches,
            truncated: truncated,
            contentTrust: includeContext ? "captured_untrusted" : "metadata_only",
            captureEpoch: snapshotService.captureEpoch.rawValue,
            policyRevision: policyStore.policyRevision.rawValue,
            bodySHA256: inspected.revision.bodySHA256,
            caseInsensitiveMatchCount: caseInsensitiveHint
        )
    }

    /// Bounded UTF-8 page read of an editable captured revision after body-read approval.
    func responseTextRead(
        sessionID: SessionRecord.ID,
        offset: Int?,
        length: Int?,
        cursor: String?,
        client: MCPClientRecord,
        mcpSessionID: String?
    ) throws -> MCPResponseTextReadDTO {
        try requireInspectAccess(client: client, capability: .bodyRead)
        let inspected = try editableRevision(sessionID: sessionID, clientID: client.id)
        let start: Int
        if let cursor {
            guard let record = readCursorsByToken[cursor],
                  record.clientID == client.id,
                  record.mcpSessionID == mcpSessionID,
                  record.captureEpoch == snapshotService.captureEpoch,
                  record.policyRevision == policyStore.policyRevision,
                  record.sessionID == sessionID,
                  record.bodySHA256 == inspected.revision.bodySHA256,
                  Date() < record.expiresAt else {
                throw MCPStructuredError(code: .staleCursor, message: "The response read cursor is no longer valid.")
            }
            start = record.nextOffset
            readCursorsByToken.removeValue(forKey: cursor)
        } else {
            start = max(0, offset ?? 0)
        }
        guard start <= inspected.revision.bodyBytes.count else {
            throw MCPStructuredError(code: .malformedRequest, message: "byteOffset is past the end of the body.")
        }
        let requestedLength = min(
            max(1, length ?? Self.maxReadBytesPerCall),
            Self.maxReadBytesPerCall
        )
        let end = min(inspected.revision.bodyBytes.count, start + requestedLength)
        var slice = Data(inspected.revision.bodyBytes[start..<end])
        // Avoid splitting a trailing multibyte UTF-8 scalar in the disclosed window.
        while !slice.isEmpty, String(data: slice, encoding: .utf8) == nil {
            slice.removeLast()
        }
        let disclosed = slice.count
        let sessionKey = disclosureSessionKey(clientID: client.id, mcpSessionID: mcpSessionID)
        let used = disclosedBytesBySessionKey[sessionKey, default: 0]
        guard used + disclosed <= Self.maxReadBytesPerLogicalSession else {
            throw MCPStructuredError(
                code: .policyDenied,
                message: "response_text_read aggregate budget for this logical session is exhausted."
            )
        }
        disclosedBytesBySessionKey[sessionKey] = used + disclosed
        let nextOffset = start + disclosed
        let hasMore = nextOffset < inspected.revision.bodyBytes.count
        let nextCursor: String?
        if hasMore {
            let token = "read-cursor-\(UUID().uuidString)"
            readCursorsByToken[token] = ReadCursorRecord(
                clientID: client.id,
                mcpSessionID: mcpSessionID,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision,
                sessionID: sessionID,
                bodySHA256: inspected.revision.bodySHA256,
                nextOffset: nextOffset,
                expiresAt: Date().addingTimeInterval(Self.readCursorTTL)
            )
            nextCursor = token
        } else {
            nextCursor = nil
        }
        let text = String(decoding: slice, as: UTF8.self)
        return MCPResponseTextReadDTO(
            sessionID: sessionID.uuidString,
            byteOffset: start,
            byteLength: disclosed,
            nextCursor: nextCursor,
            truncated: hasMore,
            text: MCPUntrustedCapturedTextDTO(text),
            contentTrust: "captured_untrusted",
            aggregateBytesDisclosed: disclosedBytesBySessionKey[sessionKey, default: 0],
            aggregateBudgetBytes: Self.maxReadBytesPerLogicalSession,
            captureEpoch: snapshotService.captureEpoch.rawValue,
            policyRevision: policyStore.policyRevision.rawValue,
            bodySHA256: inspected.revision.bodySHA256
        )
    }

    /// Resolves a previously issued match ref for later edit selectors (G3).
    func resolvedMatchRef(
        _ matchRef: String,
        client: MCPClientRecord,
        mcpSessionID: String?
    ) throws -> (sessionID: SessionRecord.ID, byteRange: Range<Int>, matchedBytesSHA256: String) {
        guard let record = matchRefsByID[matchRef] else {
            throw MCPStructuredError(code: .staleProposal, message: "The matchRef is missing, consumed, or expired.")
        }
        guard Date() < record.expiresAt else {
            matchRefsByID.removeValue(forKey: matchRef)
            throw MCPStructuredError(code: .staleProposal, message: "The matchRef expired; search again.")
        }
        guard record.clientID == client.id,
              record.mcpSessionID == mcpSessionID,
              record.captureEpoch == snapshotService.captureEpoch,
              record.policyRevision == policyStore.policyRevision,
              let indexed = snapshotService.indexedSession(id: record.sessionID),
              indexed.captureSequence == record.captureSequence else {
            throw MCPStructuredError(
                code: .staleProposal,
                message: "The matchRef no longer matches the client, capture, or policy."
            )
        }
        let inspected = try editableRevision(sessionID: record.sessionID, clientID: client.id)
        guard inspected.revision.bodySHA256 == record.bodySHA256,
              record.byteRange.upperBound <= inspected.revision.bodyBytes.count,
              sha256Hex(Data(inspected.revision.bodyBytes[record.byteRange])) == record.matchedBytesSHA256 else {
            throw MCPStructuredError(code: .staleProposal, message: "The matchRef no longer matches the captured body.")
        }
        return (record.sessionID, record.byteRange, record.matchedBytesSHA256)
    }

    func invalidateTransientState(clientID: String? = nil) {
        if let clientID {
            matchRefsByID = matchRefsByID.filter { $0.value.clientID != clientID }
            readCursorsByToken = readCursorsByToken.filter { $0.value.clientID != clientID }
            disclosedBytesBySessionKey = disclosedBytesBySessionKey.filter { !$0.key.hasPrefix("\(clientID)|") }
        } else {
            matchRefsByID.removeAll()
            readCursorsByToken.removeAll()
            disclosedBytesBySessionKey.removeAll()
        }
    }

    // MARK: - Internals

    private struct InspectedRevision {
        let revision: ResponseBodyRevision
        let captureSequence: UInt64
        let rawBodyByteCount: Int
        let isUTF8TextEditable: Bool
    }

    private func requireInspectAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore?.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Response inspection denied by profile or policy."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Profile does not allow \(capability.rawValue).")
        }
    }

    private func inspectRevision(sessionID: SessionRecord.ID, clientID: String) throws -> InspectedRevision {
        guard let indexed = snapshotService.indexedSession(id: sessionID),
              let response = indexed.record.response else {
            throw MCPStructuredError(code: .malformedRequest, message: "No captured response is available for this session.")
        }
        guard let rawBody = response.bodyData else {
            let reason = response.bodyDeferred ? "bodyDeferred: wait for recording loading to finish."
                : response.recordingBodyOmissionReason != nil ? "bodyOmitted: this recording does not contain the response bytes."
                : response.bodyTruncated ? "captureTruncated: complete response bytes were not retained."
                : "bodyUnavailable: no response bytes are retained."
            throw MCPStructuredError(code: .malformedRequest, message: reason)
        }
        let revision = try ResponseBodyRevision.fromCapturedSession(
            sessionID,
            snapshotService: snapshotService,
            clientID: clientID,
            maxBytes: Self.maxRevisionBytes
        )
        let editable = revision.completeness == .complete
            && String(data: revision.bodyBytes, encoding: .utf8) != nil
            && !revision.bodyBytes.isEmpty
        return InspectedRevision(
            revision: revision,
            captureSequence: indexed.captureSequence,
            rawBodyByteCount: rawBody.count,
            isUTF8TextEditable: editable
        )
    }

    private func editableRevision(sessionID: SessionRecord.ID, clientID: String) throws -> InspectedRevision {
        let inspected = try inspectRevision(sessionID: sessionID, clientID: clientID)
        guard inspected.isUTF8TextEditable else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "The captured response is not editable (\(completenessString(inspected.revision.completeness))). Use response_context to inspect availability; no upstream request was made."
            )
        }
        return inspected
    }

    private func exactMatchRanges(in haystack: Data, find: Data) -> [Range<Int>] {
        guard !find.isEmpty, find.count <= haystack.count else { return [] }
        var ranges: [Range<Int>] = []
        var searchStart = haystack.startIndex
        while searchStart <= haystack.endIndex - find.count {
            let window = searchStart..<(searchStart + find.count)
            if haystack[window].elementsEqual(find) {
                ranges.append(window)
                searchStart += find.count
            } else {
                searchStart += 1
            }
        }
        return ranges
    }

    /// Best-effort case-insensitive count for the zero-exact-match hint. `nil` when either side
    /// isn't valid UTF-8 text (shouldn't happen — `body` is already confirmed UTF-8-editable by
    /// `editableRevision` — but fails closed to no hint rather than a crash if that ever changes).
    private func caseInsensitiveMatchCount(in body: Data, find: Data) -> Int? {
        guard let haystack = String(data: body, encoding: .utf8),
              let needle = String(data: find, encoding: .utf8),
              !needle.isEmpty else {
            return nil
        }
        let lowerHaystack = haystack.lowercased()
        let lowerNeedle = needle.lowercased()
        var count = 0
        var searchRange = lowerHaystack.startIndex..<lowerHaystack.endIndex
        while let found = lowerHaystack.range(of: lowerNeedle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<lowerHaystack.endIndex
        }
        return count
    }

    private func contextWindow(in body: Data, around range: Range<Int>) -> String {
        let before = max(0, range.lowerBound - Self.maxContextBytes / 2)
        let after = min(body.count, range.upperBound + Self.maxContextBytes / 2)
        var window = Data(body[before..<after])
        while !window.isEmpty, String(data: window, encoding: .utf8) == nil {
            if window.count > 1 {
                window.removeFirst()
            } else {
                window.removeAll()
            }
        }
        while !window.isEmpty, String(data: window, encoding: .utf8) == nil {
            window.removeLast()
        }
        return String(decoding: window, as: UTF8.self)
    }

    private func storeMatchRef(
        client: MCPClientRecord,
        mcpSessionID: String?,
        sessionID: SessionRecord.ID,
        captureSequence: UInt64,
        bodySHA256: String,
        byteRange: Range<Int>,
        matchedBytesSHA256: String,
        expiresAt: Date
    ) -> String {
        let source = [
            client.id,
            mcpSessionID ?? "",
            snapshotService.captureEpoch.rawValue,
            policyStore.policyRevision.rawValue,
            sessionID.uuidString,
            String(captureSequence),
            bodySHA256,
            "\(byteRange.lowerBound):\(byteRange.upperBound)",
            matchedBytesSHA256,
            String(Int(expiresAt.timeIntervalSince1970))
        ].joined(separator: "|")
        let matchRef = "match-\(sha256Hex(Data(source.utf8)).prefix(20))"
        matchRefsByID[matchRef] = MatchRefRecord(
            matchRef: matchRef,
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            sessionID: sessionID,
            captureSequence: captureSequence,
            bodySHA256: bodySHA256,
            byteRange: byteRange,
            matchedBytesSHA256: matchedBytesSHA256,
            expiresAt: expiresAt
        )
        return matchRef
    }

    private func disclosureSessionKey(clientID: String, mcpSessionID: String?) -> String {
        "\(clientID)|\(mcpSessionID ?? "none")"
    }

    private func completenessString(_ status: ResponseBodyRevision.CompletenessStatus) -> String {
        switch status {
        case .complete: return "complete"
        case .captureTruncated: return "captureTruncated"
        case .decodeTruncated: return "decodeTruncated"
        case .unsupportedEncoding: return "unsupportedEncoding"
        case .invalidUTF8: return "invalidUTF8"
        case .decodeFailed: return "decodeFailed"
        case .bodyDeferred: return "bodyDeferred"
        case .bodyOmitted: return "bodyOmitted"
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
