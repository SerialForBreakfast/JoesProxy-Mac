import Foundation

/// Exact, segment-aware prefix, and component-bounded suffix matching for diagnostic-run scopes.
enum DiagnosticRunScopeMatcher {
    enum Decision: Equatable, Sendable {
        case hit
        case matcherMiss
        case ignore
    }

    /// Classifies `event` against one frozen watch. Markers are handled by the index, not here.
    static func decision(for event: DiagnosticRunCaptureEvent, watch: DiagnosticInstalledWatch) -> Decision {
        if let http = watch.resolvedHTTP {
            return httpDecision(event: event, scope: http)
        }
        if let fingerprint = watch.fingerprint {
            let actual = (try? DiagnosticRunValidation.requestFingerprint(
                method: event.method,
                scheme: event.scheme,
                host: event.host,
                port: event.port,
                path: event.path
            )) ?? ""
            return actual == fingerprint ? .hit : .ignore
        }
        return .ignore
    }

    /// Status family key such as `2xx`. Returns nil when no status is present.
    static func statusFamily(for statusCode: Int?) -> String? {
        guard let statusCode, (100...599).contains(statusCode) else { return nil }
        return "\(statusCode / 100)xx"
    }

    /// Strips query and fragment from a captured path without broadening it.
    static func pathExcludingQuery(_ raw: String) -> String {
        let withoutFragment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? raw
        return String(
            withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
                ?? Substring(withoutFragment)
        )
    }

    /// Bounded attribution tokens copied from capture provenance. Never includes bodies or URLs.
    static func attributionIDs(from attribution: MCPCaptureAttribution?) -> [String] {
        guard let attribution else { return [] }
        var ids: [String] = attribution.effectKinds.map(\.rawValue)
        if let scenarioID = attribution.scenarioID { ids.append("scenario:\(scenarioID)") }
        if let packID = attribution.openAPIMockPackID { ids.append("openapi:\(packID)") }
        ids.append("operation:\(attribution.provenance.operationID)")
        return Array(ids.prefix(DiagnosticRunBudget.maxAttributionIDsPerObservation)).map { id in
            if id.utf8.count <= DiagnosticRunBudget.maxAttributionIDUTF8Bytes { return id }
            return String(decoding: Array(id.utf8.prefix(DiagnosticRunBudget.maxAttributionIDUTF8Bytes)), as: UTF8.self)
        }
    }

    // MARK: - Private

    private static func httpDecision(
        event: DiagnosticRunCaptureEvent,
        scope: DiagnosticHTTPScope
    ) -> Decision {
        guard event.method.caseInsensitiveCompare(scope.method) == .orderedSame else { return .ignore }
        guard event.scheme == scope.scheme else { return .ignore }
        guard event.host.lowercased() == scope.host.lowercased() else { return .ignore }
        guard event.port == scope.port else { return .ignore }
        return pathMatches(scopePath: scope.path, requestPath: event.path, match: scope.pathMatch)
            ? .hit
            : .matcherMiss
    }

    private static func pathMatches(
        scopePath: String,
        requestPath: String,
        match: DiagnosticPathMatch
    ) -> Bool {
        switch match {
        case .exact:
            return requestPath == scopePath
        case .prefix:
            if requestPath == scopePath { return true }
            let prefix = scopePath.hasSuffix("/") ? scopePath : "\(scopePath)/"
            return requestPath.hasPrefix(prefix)
        case .suffix:
            let scopeComponents = pathComponents(scopePath)
            let requestComponents = pathComponents(requestPath)
            guard !scopeComponents.isEmpty, requestComponents.count >= scopeComponents.count else {
                return false
            }
            return Array(requestComponents.suffix(scopeComponents.count)) == scopeComponents
        case .filename:
            return pathComponents(requestPath).last == pathComponents(scopePath).last
        }
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
