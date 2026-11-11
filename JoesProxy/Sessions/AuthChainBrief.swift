import CryptoKit
import Foundation

/// Zero-secret credential and cookie continuity analyzer.
///
/// Raw `Authorization`, `Cookie`, `Set-Cookie`, and token-header values are fingerprinted in memory
/// with an ephemeral per-call `SymmetricKey` and mapped to sequential slot labels (`bearer#1`,
/// `cookie:sid#1`) in order of observation. Secret bytes and cryptographic digests never leave
/// this analyzer, while lifecycle transitions (rotations, 401/403 rejections, stale reuse, and
/// dropped cookies) remain 100% deterministic across the inspected session sequence.
enum AuthChainBrief {
    static let maximumInspectedSessions = 256
    static let maximumTokens = 32
    static let maximumAnomalies = 16

    struct TokenSummary: Codable, Equatable, Sendable {
        var label: String
        var kind: String
        var host: String
        var firstSeenSessionID: String
        var lastSeenSessionID: String
        var useCount: Int
        var issuedBySessionID: String?
        var rejectedStatusCodes: [Int]
    }

    struct Anomaly: Codable, Equatable, Sendable {
        var kind: String
        var sessionID: String
        var host: String
        var tokenLabel: String
        var relatedTokenLabel: String?
        var relatedSessionID: String?
        var statusCode: Int?
        var detail: String
    }

    struct Report: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var status: String
        var inspectedSessionCount: Int
        var omittedSessionCount: Int
        var tokens: [TokenSummary]
        var omittedTokenCount: Int
        var anomalies: [Anomaly]
        var omittedAnomalyCount: Int
        var contentTrust = "captured_untrusted_names_zero_secret_values"
        var scope = "Ephemeral in-memory correlation across the selected sessions only. Labels (e.g. bearer#1) are sequential within this report and never disclose secret values or reusable hashes."
    }

    private static let trackedAuthHeaders: Set<String> = [
        "x-api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-session-id"
    ]

    static func analyze(
        records: [SessionRecord],
        disclosure: MCPDisclosureSerializer? = nil
    ) -> Report {
        let key = SymmetricKey(size: .bits256)
        let boundedRecords = Array(records.prefix(maximumInspectedSessions))
        let omittedSessions = max(0, records.count - boundedRecords.count)

        struct SlotKey: Hashable {
            let host: String
            let slot: String
        }

        struct TokenState {
            var label: String
            var ordinal: Int
            var kind: String
            var host: String
            var firstSeenSessionID: String
            var lastSeenSessionID: String
            var useCount: Int
            var issuedBySessionID: String?
            var rejectedStatusCodes: Set<Int> = []
        }

        var hmacToLabel: [SlotKey: [Data: String]] = [:]
        var nextOrdinalBySlot: [SlotKey: Int] = [:]
        var tokenStates: [String: TokenState] = [:]
        var tokenOrder: [String] = []

        // Tracks latest active credential per (host, slot) to detect stale reuse after rotation.
        var latestActiveBySlot: [SlotKey: (label: String, ordinal: Int, sessionID: String)] = [:]
        // Tracks latest Set-Cookie issued per (host, cookieSlot) to detect un-echoed Set-Cookie.
        var latestIssuedCookieBySlot: [SlotKey: (label: String, ordinal: Int, sessionID: String)] = [:]
        // Tracks hosts that have used an Authorization header at least once.
        var hostsWithAuthHeader: [String: (label: String, sessionID: String)] = [:]

        var anomalies: [Anomaly] = []
        var totalAnomalies = 0

        func recordAnomaly(_ anomaly: Anomaly) {
            totalAnomalies += 1
            if anomalies.count < maximumAnomalies {
                anomalies.append(anomaly)
            }
        }

        func resolveToken(
            slotKey: SlotKey,
            kind: String,
            rawSecret: String,
            sessionID: String,
            isIssuance: Bool
        ) -> (label: String, ordinal: Int) {
            let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(rawSecret.utf8), using: key))
            if let existingLabel = hmacToLabel[slotKey]?[mac],
               var state = tokenStates[existingLabel] {
                if !isIssuance {
                    state.useCount += 1
                    state.lastSeenSessionID = sessionID
                } else if state.issuedBySessionID == nil {
                    state.issuedBySessionID = sessionID
                }
                tokenStates[existingLabel] = state
                return (existingLabel, state.ordinal)
            }

            let ordinal = (nextOrdinalBySlot[slotKey] ?? 0) + 1
            nextOrdinalBySlot[slotKey] = ordinal
            let label = "\(slotKey.slot)#\(ordinal)"
            hmacToLabel[slotKey, default: [:]][mac] = label
            let state = TokenState(
                label: label,
                ordinal: ordinal,
                kind: kind,
                host: slotKey.host,
                firstSeenSessionID: sessionID,
                lastSeenSessionID: sessionID,
                useCount: isIssuance ? 0 : 1,
                issuedBySessionID: isIssuance ? sessionID : nil
            )
            tokenStates[label] = state
            tokenOrder.append(label)
            return (label, ordinal)
        }

        for record in boundedRecords {
            guard !CaptureMarkerConstants.isMarkerRecord(record) else { continue }
            let sessionID = record.id.uuidString
            let rawHost = record.request.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let host = disclosure?.sanitizedHost(rawHost) ?? rawHost
            let statusCode = record.response?.statusCode
            let method = record.request.method.uppercased()

            var sawAuthorizationOnRequest = false
            var requestCookiesSeen: Set<SlotKey> = []

            for header in record.request.headers {
                let headerName = header.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let rawValue = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawValue.isEmpty else { continue }

                if headerName == "authorization" || headerName == "proxy-authorization" {
                    sawAuthorizationOnRequest = true
                    let (schemeSlot, secretPart) = parseAuthorizationHeader(rawValue)
                    let slotKey = SlotKey(host: host, slot: schemeSlot)
                    let resolved = resolveToken(
                        slotKey: slotKey,
                        kind: "authorization",
                        rawSecret: secretPart,
                        sessionID: sessionID,
                        isIssuance: false
                    )
                    hostsWithAuthHeader[host] = (resolved.label, sessionID)

                    if let prior = latestActiveBySlot[slotKey], resolved.ordinal < prior.ordinal {
                        recordAnomaly(Anomaly(
                            kind: "stale_credential_reused_after_rotation",
                            sessionID: sessionID,
                            host: host,
                            tokenLabel: resolved.label,
                            relatedTokenLabel: prior.label,
                            relatedSessionID: prior.sessionID,
                            statusCode: statusCode,
                            detail: "Request sent older \(resolved.label) after \(prior.label) was already active on session \(prior.sessionID)."
                        ))
                    } else if let prior = latestActiveBySlot[slotKey] {
                        if resolved.ordinal > prior.ordinal {
                            latestActiveBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                        }
                    } else {
                        latestActiveBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                    }

                    if let status = statusCode, status == 401 || status == 403 {
                        tokenStates[resolved.label]?.rejectedStatusCodes.insert(status)
                        recordAnomaly(Anomaly(
                            kind: "credential_rejected",
                            sessionID: sessionID,
                            host: host,
                            tokenLabel: resolved.label,
                            relatedTokenLabel: nil,
                            relatedSessionID: nil,
                            statusCode: status,
                            detail: "Server returned HTTP \(status) for request carrying \(resolved.label)."
                        ))
                    }
                } else if trackedAuthHeaders.contains(headerName) {
                    let slot = "header:\(headerName)"
                    let slotKey = SlotKey(host: host, slot: slot)
                    let resolved = resolveToken(
                        slotKey: slotKey,
                        kind: "auth_header",
                        rawSecret: rawValue,
                        sessionID: sessionID,
                        isIssuance: false
                    )
                    if let prior = latestActiveBySlot[slotKey], resolved.ordinal < prior.ordinal {
                        recordAnomaly(Anomaly(
                            kind: "stale_credential_reused_after_rotation",
                            sessionID: sessionID,
                            host: host,
                            tokenLabel: resolved.label,
                            relatedTokenLabel: prior.label,
                            relatedSessionID: prior.sessionID,
                            statusCode: statusCode,
                            detail: "Request sent older \(resolved.label) after \(prior.label) was already active on session \(prior.sessionID)."
                        ))
                    } else if resolved.ordinal > (latestActiveBySlot[slotKey]?.ordinal ?? 0) {
                        latestActiveBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                    }
                    if let status = statusCode, status == 401 || status == 403 {
                        tokenStates[resolved.label]?.rejectedStatusCodes.insert(status)
                        recordAnomaly(Anomaly(
                            kind: "credential_rejected",
                            sessionID: sessionID,
                            host: host,
                            tokenLabel: resolved.label,
                            relatedTokenLabel: nil,
                            relatedSessionID: nil,
                            statusCode: status,
                            detail: "Server returned HTTP \(status) for request carrying \(resolved.label)."
                        ))
                    }
                } else if headerName == "cookie" {
                    for (cookieName, cookieValue) in parseCookieHeader(rawValue) {
                        let safeName = sanitizeCookieName(cookieName)
                        let slot = "cookie:\(safeName)"
                        let slotKey = SlotKey(host: host, slot: slot)
                        requestCookiesSeen.insert(slotKey)
                        let resolved = resolveToken(
                            slotKey: slotKey,
                            kind: "cookie",
                            rawSecret: cookieValue,
                            sessionID: sessionID,
                            isIssuance: false
                        )
                        if let issued = latestIssuedCookieBySlot[slotKey], resolved.ordinal < issued.ordinal {
                            recordAnomaly(Anomaly(
                                kind: "set_cookie_not_echoed",
                                sessionID: sessionID,
                                host: host,
                                tokenLabel: resolved.label,
                                relatedTokenLabel: issued.label,
                                relatedSessionID: issued.sessionID,
                                statusCode: statusCode,
                                detail: "Request sent older \(resolved.label) after Set-Cookie issued \(issued.label) in session \(issued.sessionID)."
                            ))
                        }
                        if resolved.ordinal > (latestActiveBySlot[slotKey]?.ordinal ?? 0) {
                            latestActiveBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                        }
                    }
                }
            }

            if !sawAuthorizationOnRequest, method != "OPTIONS",
               let priorAuth = hostsWithAuthHeader[host],
               statusCode == 401 || statusCode == 403 {
                recordAnomaly(Anomaly(
                    kind: "unauthenticated_request_to_authenticated_host",
                    sessionID: sessionID,
                    host: host,
                    tokenLabel: "missing_authorization",
                    relatedTokenLabel: priorAuth.label,
                    relatedSessionID: priorAuth.sessionID,
                    statusCode: statusCode,
                    detail: "Request omitted Authorization to \(host) (which previously used \(priorAuth.label)) and failed with HTTP \(statusCode ?? 0)."
                ))
            }

            for (slotKey, issued) in latestIssuedCookieBySlot where slotKey.host == host && method != "OPTIONS" {
                if !requestCookiesSeen.contains(slotKey) {
                    recordAnomaly(Anomaly(
                        kind: "set_cookie_not_echoed",
                        sessionID: sessionID,
                        host: host,
                        tokenLabel: "missing_\(slotKey.slot)",
                        relatedTokenLabel: issued.label,
                        relatedSessionID: issued.sessionID,
                        statusCode: statusCode,
                        detail: "Request to \(host) omitted \(slotKey.slot) after Set-Cookie issued \(issued.label) in session \(issued.sessionID)."
                    ))
                }
            }

            // Inspect Set-Cookie on responses after evaluating the request so same-session issuance
            // is compared against subsequent requests.
            for header in record.response?.headers ?? [] {
                let headerName = header.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard headerName == "set-cookie" else { continue }
                if let (cookieName, cookieValue) = parseSetCookieHeader(header.value) {
                    let safeName = sanitizeCookieName(cookieName)
                    let slot = "cookie:\(safeName)"
                    let slotKey = SlotKey(host: host, slot: slot)
                    let resolved = resolveToken(
                        slotKey: slotKey,
                        kind: "cookie",
                        rawSecret: cookieValue,
                        sessionID: sessionID,
                        isIssuance: true
                    )
                    latestIssuedCookieBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                    if resolved.ordinal > (latestActiveBySlot[slotKey]?.ordinal ?? 0) {
                        latestActiveBySlot[slotKey] = (resolved.label, resolved.ordinal, sessionID)
                    }
                }
            }
        }

        let allTokens: [TokenSummary] = tokenOrder.compactMap { label in
            guard let state = tokenStates[label] else { return nil }
            return TokenSummary(
                label: state.label,
                kind: state.kind,
                host: state.host,
                firstSeenSessionID: state.firstSeenSessionID,
                lastSeenSessionID: state.lastSeenSessionID,
                useCount: state.useCount,
                issuedBySessionID: state.issuedBySessionID,
                rejectedStatusCodes: state.rejectedStatusCodes.sorted()
            )
        }
        let emittedTokens = Array(allTokens.prefix(maximumTokens))
        let omittedTokens = max(0, allTokens.count - emittedTokens.count)
        let omittedAnomalies = max(0, totalAnomalies - anomalies.count)
        let complete = omittedSessions == 0 && omittedTokens == 0 && omittedAnomalies == 0

        return Report(
            status: complete ? "complete" : "bounded",
            inspectedSessionCount: boundedRecords.count,
            omittedSessionCount: omittedSessions,
            tokens: emittedTokens,
            omittedTokenCount: omittedTokens,
            anomalies: anomalies,
            omittedAnomalyCount: omittedAnomalies
        )
    }

    private static func parseAuthorizationHeader(_ value: String) -> (slot: String, secret: String) {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return ("auth", value)
        }
        let scheme = parts[0].lowercased()
        let allowedScheme: String
        switch scheme {
        case "bearer", "basic", "digest", "dpop", "aws4-hmac-sha256":
            allowedScheme = scheme
        default:
            allowedScheme = "custom_auth"
        }
        return (allowedScheme, String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseCookieHeader(_ value: String) -> [(name: String, value: String)] {
        value.split(separator: ";").compactMap { pair in
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !val.isEmpty else { return nil }
            return (name, val)
        }
    }

    private static func parseSetCookieHeader(_ value: String) -> (name: String, value: String)? {
        guard let firstSegment = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let trimmed = firstSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !val.isEmpty else { return nil }
        return (name, val)
    }

    private static func sanitizeCookieName(_ name: String) -> String {
        let cleaned = name.prefix(48).map { char -> Character in
            if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." {
                return char
            }
            return "_"
        }
        return String(cleaned)
    }
}
