import Foundation
import CryptoKit

/// Validation and deterministic digest helpers for diagnostic runs (AN-2).
enum DiagnosticRunValidation {
    /// Normalizes and validates owner-authored hypothesis fields.
    static func validatedHypothesis(_ hypothesis: DiagnosticRunHypothesis) throws -> DiagnosticRunHypothesis {
        let summary = try normalizeOwnerText(
            hypothesis.summary,
            field: "summary",
            maxUTF8Bytes: DiagnosticRunBudget.maxHypothesisUTF8Bytes
        )
        let expected = try normalizeOwnerText(
            hypothesis.expectedObservation,
            field: "expectedObservation",
            maxUTF8Bytes: DiagnosticRunBudget.maxExpectedObservationUTF8Bytes
        )
        return DiagnosticRunHypothesis(summary: summary, expectedObservation: expected, source: hypothesis.source)
    }

    /// Validates conclusion summary length and returns a copy.
    static func validatedConclusion(_ conclusion: DiagnosticRunConclusion) throws -> DiagnosticRunConclusion {
        let summary = try normalizeOwnerText(
            conclusion.summary,
            field: "conclusion.summary",
            maxUTF8Bytes: DiagnosticRunBudget.maxConclusionUTF8Bytes
        )
        var copy = conclusion
        copy.summary = summary
        return copy
    }

    /// Validates scope count and each scope form.
    static func validateScopes(_ scopes: [DiagnosticRunScope], requireNonEmpty: Bool) throws {
        if requireNonEmpty && scopes.isEmpty {
            throw DiagnosticRunError.invalidScopes("At least one scope is required.")
        }
        guard scopes.count <= DiagnosticRunBudget.maxScopesPerRun else {
            throw DiagnosticRunError.quotaExceeded("A run may have at most \(DiagnosticRunBudget.maxScopesPerRun) scopes.")
        }
        for scope in scopes {
            try validateScope(scope)
        }
    }

    /// Validates one scope form without broadening it.
    static func validateScope(_ scope: DiagnosticRunScope) throws {
        switch scope {
        case .capturedSession(let captured):
            guard !captured.requestFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DiagnosticRunError.invalidScopes("capturedSession.requestFingerprint is required.")
            }
            guard !captured.captureEpoch.rawValue.isEmpty else {
                throw DiagnosticRunError.invalidScopes("capturedSession.captureEpoch is required.")
            }
        case .http(let http):
            try validateHTTPScope(http)
        case .effect(let effect):
            guard !effect.effectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DiagnosticRunError.invalidScopes("effect.effectID is required.")
            }
        }
    }

    /// Validates and normalizes an HTTP scope. Returns a canonicalized copy.
    static func normalizedHTTPScope(_ scope: DiagnosticHTTPScope) throws -> DiagnosticHTTPScope {
        try validateHTTPScope(scope)
        let method = scope.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let host = scope.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = try normalizePath(scope.path)
        return DiagnosticHTTPScope(
            method: method,
            scheme: scope.scheme,
            host: host,
            port: scope.port,
            path: path,
            pathMatch: scope.pathMatch
        )
    }

    /// Validates lifetime bounds and returns a concrete expires-at date.
    static func expiresAt(lifetime: TimeInterval?, now: Date) throws -> Date {
        let ttl = lifetime ?? DiagnosticRunBudget.defaultLifetime
        guard ttl >= DiagnosticRunBudget.minimumLifetime, ttl <= DiagnosticRunBudget.maximumLifetime else {
            throw DiagnosticRunError.invalidLifetime(
                "Lifetime must be between \(Int(DiagnosticRunBudget.minimumLifetime))s and \(Int(DiagnosticRunBudget.maximumLifetime))s."
            )
        }
        return now.addingTimeInterval(ttl)
    }

    /// Sorted-key SHA-256 hex digest over a JSON-encodable value.
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Query-insensitive request fingerprint for a captured session scope.
    static func requestFingerprint(
        method: String,
        scheme: SessionScheme,
        host: String,
        port: Int,
        path: String
    ) throws -> String {
        struct FingerprintPayload: Encodable {
            var host: String
            var method: String
            var path: String
            var port: Int
            var scheme: String
        }
        let payload = FingerprintPayload(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            method: method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            path: try normalizePath(path),
            port: port,
            scheme: scheme.rawValue
        )
        return try digest(payload)
    }

    // MARK: - Private

    private static func validateHTTPScope(_ scope: DiagnosticHTTPScope) throws {
        let method = scope.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !method.isEmpty, method != "*", !method.contains(",") else {
            throw DiagnosticRunError.invalidScopes("HTTP method must be one concrete method.")
        }
        let host = scope.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains("*"), !host.hasPrefix(".") else {
            throw DiagnosticRunError.invalidScopes("HTTP host must be one exact hostname or IP literal.")
        }
        guard (1...65_535).contains(scope.port) else {
            throw DiagnosticRunError.invalidScopes("HTTP port must be materialized in 1...65535.")
        }
        _ = try normalizePath(scope.path)
        if scope.pathMatch == .prefix {
            let path = try normalizePath(scope.path)
            if path == "/" {
                throw DiagnosticRunError.invalidScopes("Root path prefix '/' is rejected as an origin-wide wildcard.")
            }
        }
    }

    private static func normalizePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DiagnosticRunError.invalidScopes("HTTP path is required.")
        }
        guard trimmed.utf8.count <= DiagnosticRunBudget.maxHypothesisUTF8Bytes else {
            throw DiagnosticRunError.invalidScopes("HTTP path exceeds the UTF-8 byte budget.")
        }
        guard trimmed.hasPrefix("/") else {
            throw DiagnosticRunError.invalidScopes("HTTP path must be root-relative.")
        }
        guard !trimmed.contains("?"), !trimmed.contains("#") else {
            throw DiagnosticRunError.invalidScopes("HTTP path must exclude query and fragment.")
        }
        guard !trimmed.contains("\\") else {
            throw DiagnosticRunError.invalidScopes("HTTP path must not contain backslashes.")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw DiagnosticRunError.invalidScopes("HTTP path must not contain control characters.")
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // First element is empty because path starts with `/`.
        for segment in segments.dropFirst() {
            if segment == "." || segment == ".." {
                throw DiagnosticRunError.invalidScopes("HTTP path must not contain '.' or '..' segments.")
            }
            if segment.lowercased().contains("%2e") {
                throw DiagnosticRunError.invalidScopes("HTTP path must not contain encoded traversal.")
            }
        }
        if trimmed != "/" && trimmed.hasSuffix("/") {
            throw DiagnosticRunError.invalidScopes("HTTP path must not end with a trailing slash except for root.")
        }
        return trimmed
    }

    /// Validates editable human notes on an evidence record (AN-4).
    static func validatedEditableNotes(_ notes: String) throws -> String {
        try normalizeOwnerText(
            notes,
            field: "editableNotes",
            maxUTF8Bytes: DiagnosticRunBudget.maxConclusionUTF8Bytes
        )
    }

    private static func normalizeOwnerText(_ raw: String, field: String, maxUTF8Bytes: Int) throws -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\n"
                && scalar != "\t"
        }) {
            throw DiagnosticRunError.invalidHypothesis("\(field) contains unsupported control characters.")
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DiagnosticRunError.invalidHypothesis("\(field) is required.")
        }
        guard trimmed.utf8.count <= maxUTF8Bytes else {
            throw DiagnosticRunError.invalidHypothesis("\(field) exceeds \(maxUTF8Bytes) UTF-8 bytes.")
        }
        return trimmed
    }
}

/// Bounded AN-2 errors surfaced to callers and tests.
enum DiagnosticRunError: Error, Equatable, LocalizedError {
    case storeUnavailable(String)
    case runNotFound
    case notOwner
    case illegalTransition(from: DiagnosticRunStatus, to: DiagnosticRunStatus)
    case invalidScopes(String)
    case invalidHypothesis(String)
    case invalidLifetime(String)
    case quotaExceeded(String)
    case staleTarget(String)
    case attachRejected(String)
    case cleanupRequired(String)
    case conclusionRequired
    case cleanupNotVerified
    case observationUnavailable
    case cursorExpired
    case evidenceNotFound
    case evidenceQuotaExceeded(String)
    case evidenceTampered

    var errorDescription: String? {
        switch self {
        case .storeUnavailable(let reason):
            return reason
        case .runNotFound:
            return "Diagnostic run not found."
        case .notOwner:
            return "Diagnostic run is owned by a different client."
        case .illegalTransition(let from, let to):
            return "Illegal diagnostic-run transition from \(from.rawValue) to \(to.rawValue)."
        case .invalidScopes(let reason),
             .invalidHypothesis(let reason),
             .invalidLifetime(let reason),
             .quotaExceeded(let reason),
             .staleTarget(let reason),
             .attachRejected(let reason),
             .cleanupRequired(let reason):
            return reason
        case .conclusionRequired:
            return "A conclusion is required before this terminal transition."
        case .cleanupNotVerified:
            return "Cleanup is not verified; the run remains Cleanup Required."
        case .observationUnavailable:
            return "Diagnostic-run observation index is unavailable."
        case .cursorExpired:
            return "Observation cursor expired; capture epoch changed or the cursor does not match this run."
        case .evidenceNotFound:
            return "Diagnostic evidence record not found."
        case .evidenceQuotaExceeded(let reason):
            return reason
        case .evidenceTampered:
            return "Diagnostic evidence digest verification failed."
        }
    }
}
