import Foundation

/// Main-actor installer that resolves scopes then hops to ``DiagnosticRunObservationIndex``.
///
/// Concurrency: `@MainActor` — reads session store / effect resolvers on the main actor, then
/// awaits the observation actor. Partial failure is rolled back by the coordinator.
@MainActor
final class DiagnosticRunObservationWatchInstaller: DiagnosticRunWatchInstalling {
    private let index: DiagnosticRunObservationIndex
    private let sessionStore: (any SessionStore)?
    private let effectScopeResolver: (any DiagnosticRunEffectScopeResolving)?
    private let clock: () -> Date
    /// Set after MCP snapshot service exists so captured-session install can fail closed on epoch change.
    weak var snapshotService: MCPSessionSnapshotService?

    init(
        index: DiagnosticRunObservationIndex,
        sessionStore: (any SessionStore)? = nil,
        effectScopeResolver: (any DiagnosticRunEffectScopeResolving)? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.index = index
        self.sessionStore = sessionStore
        self.effectScopeResolver = effectScopeResolver
        self.clock = clock
    }

    func installWatches(
        runID: DiagnosticRunID,
        ownerID: String,
        scopes: [DiagnosticRunScope]
    ) async throws -> [UUID] {
        var resolved: [DiagnosticInstalledWatch] = []
        for scope in scopes {
            let watch = try await resolveWatch(
                runID: runID,
                ownerID: ownerID,
                scope: scope
            )
            resolved.append(watch)
        }
        return try await index.installWatches(resolved, watchingStartedAt: clock())
    }

    func removeWatches(_ watchIDs: [UUID]) async {
        await index.removeWatches(watchIDs)
    }

    private func resolveWatch(
        runID: DiagnosticRunID,
        ownerID: String,
        scope: DiagnosticRunScope
    ) async throws -> DiagnosticInstalledWatch {
        switch scope {
        case .http(let http):
            let normalized = try DiagnosticRunValidation.normalizedHTTPScope(http)
            return DiagnosticInstalledWatch(
                id: UUID(),
                runID: runID,
                ownerID: ownerID,
                scope: .http(normalized),
                resolvedHTTP: normalized,
                fingerprint: nil
            )
        case .capturedSession(let captured):
            if let sessionStore {
                guard let record = sessionStore.record(for: captured.sessionID) else {
                    throw DiagnosticRunError.staleTarget("Captured session is no longer retained.")
                }
                let currentEpoch = snapshotService?.captureEpoch ?? .initial
                guard currentEpoch == captured.captureEpoch else {
                    throw DiagnosticRunError.staleTarget("Capture epoch changed before watch install.")
                }
                let fingerprint = try DiagnosticRunValidation.requestFingerprint(
                    method: record.request.method,
                    scheme: record.request.scheme,
                    host: record.request.host,
                    port: BookmarkRequestMatcher.canonicalPort(
                        record.request.port,
                        scheme: record.request.scheme
                    ),
                    path: DiagnosticRunScopeMatcher.pathExcludingQuery(record.request.path)
                )
                guard fingerprint == captured.requestFingerprint else {
                    throw DiagnosticRunError.staleTarget("Captured-session fingerprint no longer matches.")
                }
            }
            return DiagnosticInstalledWatch(
                id: UUID(),
                runID: runID,
                ownerID: ownerID,
                scope: scope,
                resolvedHTTP: nil,
                fingerprint: captured.requestFingerprint
            )
        case .effect(let effect):
            guard let resolver = effectScopeResolver,
                  let http = await resolver.disclosedHTTPScope(kind: effect.kind, effectID: effect.effectID) else {
                throw DiagnosticRunError.staleTarget(
                    "Effect scope could not be resolved for observation."
                )
            }
            let normalized = try DiagnosticRunValidation.normalizedHTTPScope(http)
            return DiagnosticInstalledWatch(
                id: UUID(),
                runID: runID,
                ownerID: ownerID,
                scope: scope,
                resolvedHTTP: normalized,
                fingerprint: nil
            )
        }
    }
}
