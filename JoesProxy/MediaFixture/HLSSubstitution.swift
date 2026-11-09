import Foundation

struct HLSSubstitutionOrigin: Codable, Equatable, Hashable, Sendable {
    var scheme: SessionScheme
    var host: String
    var port: Int

    init(scheme: SessionScheme, host: String, port: Int? = nil) {
        self.scheme = scheme
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port ?? (scheme == .https ? 443 : 80)
    }

    var displayString: String {
        let canonicalPort = scheme == .https ? 443 : 80
        return port == canonicalPort ? "\(scheme.rawValue)://\(host)" : "\(scheme.rawValue)://\(host):\(port)"
    }
}

enum HLSSubstitutionScope: Codable, Equatable, Sendable {
    case selectedPlaylist(path: String)
    case host

    var displayName: String {
        switch self {
        case .selectedPlaylist: return "Selected playlist"
        case .host: return "All playlists on host"
        }
    }
}

enum HLSSubstitutionOwner: Codable, Equatable, Sendable {
    case localUser
    case mcpClient(id: String, displayName: String)

    var fixtureOwnerID: String {
        switch self {
        case .localUser: return "joesproxy-local-user"
        case .mcpClient(let id, _): return id
        }
    }

    var displayName: String {
        switch self {
        case .localUser: return "Local user"
        case .mcpClient(_, let displayName): return displayName
        }
    }
}

enum HLSSubstitutionState: String, Codable, Equatable, Sendable {
    case active
    case stopped
    case expired
}

/// TTL bounds for a substitution run's `expiresAt` — both the initial `start` duration and any
/// later `extend`. Mirrors `OpenAPIMockPackBudget`'s TTL policy shape (same default-absent-value /
/// hard-ceiling split) so the two features don't drift into inconsistent caps. The default (not the
/// ceiling) matches `HLSFixtureRunStore.maxRunDuration` exactly, preserving today's behavior for any
/// caller that omits `ttlSeconds` entirely.
enum HLSSubstitutionTTLPolicy {
    static let defaultTTL: TimeInterval = HLSFixtureRunStore.maxRunDuration
    static let maxTTL: TimeInterval = 86_400

    /// Rejects a TTL of zero/negative or greater than `maxTTL`.
    static func validate(_ ttl: TimeInterval) throws {
        guard ttl > 0, ttl <= maxTTL else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "ttlSeconds must be greater than 0 and at most \(Int(maxTTL))."
            )
        }
    }
}

struct HLSSubstitutionMetrics: Codable, Equatable, Sendable {
    var entryPlaylistHits = 0
    var childPlaylistHits = 0
    var segmentHits = 0
    var lastMatchedAt: Date?

    var totalHits: Int { entryPlaylistHits + childPlaylistHits + segmentHits }

    /// Below this many combined playlist hits, a skewed ratio isn't trustworthy yet — one or two
    /// legitimate startup requests (initial manifest fetch, one refresh) shouldn't be flagged before
    /// there's enough signal to distinguish that from a real stall.
    private static let minimumPlaylistHitsForStallSignal = 3
    /// A real, healthy player interleaves playlist refreshes with segment downloads at a low ratio;
    /// a ratio at or above this — playlist requests piling up with segments barely moving — is the
    /// same shape the field session described ("polled playlists ~24× while downloading almost no
    /// segments"). Not derived from a formal player-behavior study; a deliberately conservative
    /// starting threshold to revisit if it proves too sensitive or not sensitive enough in practice.
    private static let stallPlaylistToSegmentRatio: Double = 8.0

    /// Interpretation layer over these since-start counters (not a recent-activity window — see
    /// `HLSSubstitutionStallClass` doc comment) distinguishing three states the field session
    /// otherwise couldn't tell apart from the outside: the matcher never fired at all, requests are
    /// flowing and delivery looks healthy, or requests are flowing but the ratio suggests the player
    /// itself is rejecting/stalling on the stream — a different problem than the matcher, and not
    /// something re-tuning the rule can fix.
    var stallClass: HLSSubstitutionStallClass {
        guard totalHits > 0 else { return .matcherMiss }
        let playlistHits = entryPlaylistHits + childPlaylistHits
        guard playlistHits >= Self.minimumPlaylistHitsForStallSignal else { return .workingNormally }
        if segmentHits == 0 || Double(playlistHits) / Double(segmentHits) >= Self.stallPlaylistToSegmentRatio {
            return .likelyClientRejectOrStall
        }
        return .workingNormally
    }
}

/// See `HLSSubstitutionMetrics.stallClass`. Computed since experiment start, not over a recent
/// window — a true recent-window ratio would need either re-deriving playlist/segment
/// classification from `SessionStore` history per request, or new timestamped per-hit storage in
/// `HLSSubstitutionRouteStore`; both are a larger, separate follow-up if since-start proves too
/// coarse in practice (e.g. a long-running experiment that stalled only recently).
enum HLSSubstitutionStallClass: String, Codable, Equatable, Sendable {
    /// No hits at all — the rule/matcher itself was never exercised. A distinct, already-diagnosable
    /// failure mode (check the matcher, not the player) — kept separate from the two states below.
    case matcherMiss
    /// Hits are occurring and the playlist:segment ratio is in a normal range (or there isn't yet
    /// enough playlist volume to say otherwise).
    case workingNormally
    /// Hits are occurring, but the playlist:segment ratio is skewed — the player keeps re-polling
    /// the manifest without downloading segments. Likely a player-side rejection or buffer stall,
    /// not a matcher problem; stop re-tuning the rule and pivot to player-side logs.
    case likelyClientRejectOrStall
}

struct HLSSubstitutionExperiment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var owner: HLSSubstitutionOwner
    var profileID: String
    /// Managed external profile directory for a portable effect bundle. `nil` uses the bundled
    /// profile catalog. Persisted-active experiments are stopped on launch before this path is used.
    var profileDirectoryPath: String? = nil
    var origin: HLSSubstitutionOrigin
    var scope: HLSSubstitutionScope
    var mountPath: String
    var fixtureRunID: UUID?
    var state: HLSSubstitutionState
    var startedAt: Date?
    var expiresAt: Date?
    var stoppedAt: Date?
    var metrics: HLSSubstitutionMetrics
    var playbackConfiguration: HLSPlaybackConfiguration? = nil
    var mcpProvenance: MCPProvenance? = nil

    var requestPolicy: HLSRequestPolicy? = nil

    var isActive: Bool { state == .active }
    var effectivePlaybackConfiguration: HLSPlaybackConfiguration {
        playbackConfiguration ?? .legacyCompatible
    }
}

enum HLSSubstitutionConflictStrategy: String, Codable, Equatable, Sendable {
    case cancel
    case replaceExisting
}

struct HLSSubstitutionConflictSummary: Equatable, Sendable {
    var experimentCount: Int
    var responseRuleCount: Int

    var totalCount: Int { experimentCount + responseRuleCount }
}

enum HLSSubstitutionError: LocalizedError, Equatable {
    case profileNotFound
    case invalidPlaylistPath
    case conflictingExperiment
    case experimentNotFound
    case notOwner
    case inactiveExperiment
    case invalidRequestPolicy

    var errorDescription: String? {
        switch self {
        case .profileNotFound: return "The selected HLS test profile is unavailable."
        case .invalidPlaylistPath: return "Selected-playlist scope requires a valid .m3u8 path."
        case .conflictingExperiment: return "Another active local override overlaps this target."
        case .experimentNotFound: return "The HLS test stream could not be found."
        case .notOwner: return "This HLS test stream belongs to another client."
        case .inactiveExperiment: return "The HLS test stream is not active."
        case .invalidRequestPolicy: return "Scoped HLS requires a client address, a selected playlist with a valid query, and a known text-track fault if requested."
        }
    }
}

enum HLSSubstitutionRouteKind: Sendable {
    case entryPlaylist
    case childPlaylist
    case segment
}

struct HLSSubstitutionRouteDecision: Sendable {
    var observation: EffectBundleObservation.Identity? = nil
    var experimentID: UUID
    var fixtureRunID: UUID
    var fixturePath: String
    var mountPath: String
    var kind: HLSSubstitutionRouteKind
    var playbackConfiguration: HLSPlaybackConfiguration
    var mcpProvenance: MCPProvenance?
    var missingTextTrackID: String? = nil
}

/// In-memory hot-path route table consulted by the proxy before ordinary response overrides.
actor HLSSubstitutionRouteStore {
    private struct Route: Sendable {
        var experimentID: UUID
        var fixtureRunID: UUID
        var origin: HLSSubstitutionOrigin
        var scope: HLSSubstitutionScope
        var mountPath: String
        var playbackConfiguration: HLSPlaybackConfiguration
        var mcpProvenance: MCPProvenance?
        var requestPolicy: HLSRequestPolicy?
    }

    private var routesByExperimentID: [UUID: Route] = [:]
    private var metricsByExperimentID: [UUID: HLSSubstitutionMetrics] = [:]
    private let effectBundleGate: EffectBundleActivationGate

    init(effectBundleGate: EffectBundleActivationGate = .shared) {
        self.effectBundleGate = effectBundleGate
    }

    func install(_ experiment: HLSSubstitutionExperiment) throws {
        try experiment.requestPolicy?.validate(scope: experiment.scope)
        guard let fixtureRunID = experiment.fixtureRunID, experiment.isActive else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        routesByExperimentID[experiment.id] = Route(
            experimentID: experiment.id,
            fixtureRunID: fixtureRunID,
            origin: experiment.origin,
            scope: experiment.scope,
            mountPath: experiment.mountPath,
            playbackConfiguration: experiment.effectivePlaybackConfiguration,
            mcpProvenance: experiment.mcpProvenance,
            requestPolicy: experiment.requestPolicy
        )
        metricsByExperimentID[experiment.id] = experiment.metrics
    }

    func install(_ experiment: HLSSubstitutionExperiment, replacing experimentIDs: Set<UUID>) throws {
        try experiment.requestPolicy?.validate(scope: experiment.scope)
        guard let fixtureRunID = experiment.fixtureRunID, experiment.isActive else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        for id in experimentIDs {
            routesByExperimentID.removeValue(forKey: id)
        }
        routesByExperimentID[experiment.id] = Route(
            experimentID: experiment.id,
            fixtureRunID: fixtureRunID,
            origin: experiment.origin,
            scope: experiment.scope,
            mountPath: experiment.mountPath,
            playbackConfiguration: experiment.effectivePlaybackConfiguration,
            mcpProvenance: experiment.mcpProvenance,
            requestPolicy: experiment.requestPolicy
        )
        metricsByExperimentID[experiment.id] = experiment.metrics
    }

    func remove(experimentID: UUID) {
        routesByExperimentID.removeValue(forKey: experimentID)
    }

    func metrics(experimentID: UUID) -> HLSSubstitutionMetrics {
        metricsByExperimentID[experimentID] ?? HLSSubstitutionMetrics()
    }

    func activeExperimentIDs() -> [UUID] {
        routesByExperimentID.keys.filter { effectBundleGate.allows(hlsExperimentID: $0) }
    }

    func decision(for request: CapturedRequest, now: Date = Date()) -> HLSSubstitutionRouteDecision? {
        guard request.method.caseInsensitiveCompare("GET") == .orderedSame ||
                request.method.caseInsensitiveCompare("HEAD") == .orderedSame else {
            return nil
        }
        let requestOrigin = HLSSubstitutionOrigin(
            scheme: request.scheme,
            host: request.host,
            port: request.port
        )
        let requestPath = Self.pathWithoutQuery(request.path)

        for route in routesByExperimentID.values where route.origin == requestOrigin {
            guard route.requestPolicy?.permits(request) ?? true else { continue }
            let admission = effectBundleGate.hlsAdmission(experimentID: route.experimentID)
            guard admission.allowed else { continue }
            if requestPath == String(route.mountPath.dropLast()) || requestPath.hasPrefix(route.mountPath) {
                let relativePath = requestPath == String(route.mountPath.dropLast())
                    ? "master.m3u8"
                    : String(requestPath.dropFirst(route.mountPath.count))
                let kind: HLSSubstitutionRouteKind = relativePath.lowercased().hasSuffix(".m3u8")
                    ? .childPlaylist
                    : .segment
                recordHit(experimentID: route.experimentID, kind: kind, now: now)
                return HLSSubstitutionRouteDecision(
                    observation: admission.observation,
                    experimentID: route.experimentID,
                    fixtureRunID: route.fixtureRunID,
                    fixturePath: relativePath + (request.path.firstIndex(of: "?").map { String(request.path[$0...]) } ?? ""),
                    mountPath: route.mountPath,
                    kind: kind,
                    playbackConfiguration: route.playbackConfiguration,
                    mcpProvenance: route.mcpProvenance,
                    missingTextTrackID: route.requestPolicy?.missingTextTrackID
                )
            }
        }

        for route in routesByExperimentID.values where route.origin == requestOrigin {
            guard route.requestPolicy?.permits(request) ?? true else { continue }
            let admission = effectBundleGate.hlsAdmission(experimentID: route.experimentID)
            guard admission.allowed else { continue }
            let isEntry = HLSRequestPolicy.entryMatches(request.path, scope: route.scope, policy: route.requestPolicy)
            guard isEntry else { continue }
            recordHit(experimentID: route.experimentID, kind: .entryPlaylist, now: now)
            return HLSSubstitutionRouteDecision(
                observation: admission.observation,
                experimentID: route.experimentID,
                fixtureRunID: route.fixtureRunID,
                fixturePath: "master.m3u8",
                mountPath: route.mountPath,
                kind: .entryPlaylist,
                playbackConfiguration: route.playbackConfiguration,
                mcpProvenance: route.mcpProvenance
            )
        }
        return nil
    }

    func conflictingExperimentIDs(origin: HLSSubstitutionOrigin, scope: HLSSubstitutionScope,
                                  requestPolicy: HLSRequestPolicy? = nil) -> [UUID] {
        routesByExperimentID.values.compactMap { route in
            if let existing = route.requestPolicy, let proposed = requestPolicy,
               existing.clientAddress != proposed.clientAddress { return nil }
            guard route.origin == origin,
                  effectBundleGate.allows(hlsExperimentID: route.experimentID) else { return nil }
            switch (route.scope, scope) {
            case (.host, _), (_, .host):
                return route.experimentID
            case (.selectedPlaylist(let existing), .selectedPlaylist(let proposed)):
                return Self.pathWithoutQuery(existing) == Self.pathWithoutQuery(proposed)
                    ? route.experimentID
                    : nil
            }
        }
    }

    private func recordHit(experimentID: UUID, kind: HLSSubstitutionRouteKind, now: Date) {
        var metrics = metricsByExperimentID[experimentID] ?? HLSSubstitutionMetrics()
        switch kind {
        case .entryPlaylist: metrics.entryPlaylistHits += 1
        case .childPlaylist: metrics.childPlaylistHits += 1
        case .segment: metrics.segmentHits += 1
        }
        metrics.lastMatchedAt = now
        metricsByExperimentID[experimentID] = metrics
    }

    private static func pathWithoutQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
    }
}

enum HLSSubstitutionManifestRouter {
    static func rewriteMaster(
        _ response: HLSFixtureResponse,
        mountPath: String,
        method: String,
        cacheControlHeader: String = "no-store"
    ) -> HLSFixtureResponse {
        guard response.status == 200,
              let source = String(data: response.body, encoding: .utf8) else {
            return response
        }
        let normalizedMount = mountPath.hasSuffix("/") ? mountPath : "\(mountPath)/"
        let rewritten = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rewriteMasterLine(String($0), mountPath: normalizedMount) }
            .joined(separator: "\n")
        let body = method.caseInsensitiveCompare("HEAD") == .orderedSame ? Data() : Data(rewritten.utf8)
        var headers = response.headers
        headers["Content-Length"] = "\(rewritten.utf8.count)"
        headers["Cache-Control"] = cacheControlHeader
        return HLSFixtureResponse(status: response.status, headers: headers, body: body)
    }

    private static func rewriteMasterLine(_ line: String, mountPath: String) -> String {
        if !line.isEmpty, !line.hasPrefix("#") {
            return rootedURI(line, mountPath: mountPath)
        }
        guard let uriRange = line.range(of: "URI=\"") else { return line }
        let valueStart = uriRange.upperBound
        guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else { return line }
        let uri = String(line[valueStart..<valueEnd])
        return line.replacingCharacters(in: valueStart..<valueEnd, with: rootedURI(uri, mountPath: mountPath))
    }

    private static func rootedURI(_ uri: String, mountPath: String) -> String {
        guard !uri.hasPrefix("/"), URL(string: uri)?.scheme == nil else { return uri }
        return "\(mountPath)\(uri)"
    }
}
