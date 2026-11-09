import Foundation

/// Reads canonical mutation owners for Agent supervision without constructing Inspector state.
@MainActor
final class AgentEffectsMonitor {
    private let configuration: any AppConfiguration
    private let responseOverrideStore: ResponseOverrideStore
    private let bookmarkStore: any BookmarkStore
    private let hlsSubstitutionCoordinator: HLSSubstitutionCoordinator
    private let openAPIMockPackCoordinator: OpenAPIMockPackCoordinator
    private let systemProxyController: SystemProxyController

    private(set) var snapshot: MinimalMonitoringActiveEffectsSnapshot = .empty
    private var refreshTask: Task<Void, Never>?

    init(
        configuration: any AppConfiguration,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: any BookmarkStore,
        hlsSubstitutionCoordinator: HLSSubstitutionCoordinator,
        openAPIMockPackCoordinator: OpenAPIMockPackCoordinator,
        systemProxyController: SystemProxyController
    ) {
        self.configuration = configuration
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkStore = bookmarkStore
        self.hlsSubstitutionCoordinator = hlsSubstitutionCoordinator
        self.openAPIMockPackCoordinator = openAPIMockPackCoordinator
        self.systemProxyController = systemProxyController
    }

    func refresh() async {
        await hlsSubstitutionCoordinator.synchronizeMetricsAndExpiry()
        await openAPIMockPackCoordinator.synchronizeMetricsAndExpiry()
        let rules = await responseOverrideStore.rules()

        func count(_ kind: MCPEffectKind) -> Int {
            rules.filter {
                $0.isEnabled && MCPEffectInventoryBuilder.effectKind(for: $0.sourceKind) == kind
            }.count
        }

        let bookmarkRewriteCount = bookmarkStore.loadBookmarks().reduce(0) { total, bookmark in
            total + bookmark.responseRewrites.filter(\.isRuleEnabled).count
        }
        let tunnelActive: Bool
        if case .active = systemProxyController.status {
            tunnelActive = true
        } else {
            tunnelActive = false
        }

        snapshot = MinimalMonitoringActiveEffectsSnapshot(
            activeMapLocalCount: count(.mapLocal),
            activeMapRemoteCount: count(.mapRemote),
            activeBlockCount: count(.block),
            activeBookmarkRewriteCount: bookmarkRewriteCount,
            activeLiveRewriteCount: count(.liveResponseRewrite),
            isThrottlingEnabled: configuration.networkThrottleConfiguration.isEnabled,
            activeHLSSubstitutionCount: hlsSubstitutionCoordinator.experiments.filter(\.isActive).count,
            activeOpenAPIMockPackCount: openAPIMockPackCoordinator.packs.filter(\.isServing).count,
            activeSyntheticInjectionCount: SyntheticCollectionInjectionEngine.shared.allPlans().filter(\.isEnabled).count,
            isSystemProxyTunnelingActive: tunnelActive
        )
    }

    /// Coalesces HUD refresh requests so a slow coordinator read cannot turn a periodic display
    /// tick into an unbounded queue of effect scans.
    func requestRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.refreshTask = nil
        }
    }

    /// Stops one whole effect category from the Agent HUD. This uses the same canonical owners as
    /// MCP and the Inspector; it never synthesizes an approval or bypasses owner checks.
    func disableAll(in tileID: String) async throws {
        switch tileID {
        case "mapLocal":
            try await disableResponseOverrides(matching: .mapLocal)
        case "mapRemote":
            try await disableResponseOverrides(matching: .mapRemote)
        case "block":
            try await disableResponseOverrides(matching: .block)
        case "liveRewrite":
            try await disableResponseOverrides(matching: .liveResponseRewrite)
        case "bookmarkRewrite":
            try disableBookmarkRewrites()
        case "throttle":
            var throttle = configuration.networkThrottleConfiguration
            throttle.isEnabled = false
            configuration.networkThrottleConfiguration = throttle
        case "hlsSubstitution":
            for experiment in hlsSubstitutionCoordinator.experiments where experiment.isActive {
                _ = try await hlsSubstitutionCoordinator.stop(
                    id: experiment.id,
                    requestingOwnerID: HLSSubstitutionCoordinator.localUserOwnerID
                )
            }
        case "openAPIMock":
            for pack in openAPIMockPackCoordinator.packs where pack.isServing {
                _ = try await openAPIMockPackCoordinator.stop(
                    id: pack.id,
                    requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID
                )
            }
        case "syntheticInjection":
            SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        case "tunnel":
            break
        default:
            return
        }
        await refresh()
    }

    private func disableResponseOverrides(matching kind: MCPEffectKind) async throws {
        let matchingRules = await responseOverrideStore.rules().filter {
            $0.isEnabled && MCPEffectInventoryBuilder.effectKind(for: $0.sourceKind) == kind
        }
        for rule in matchingRules {
            try await responseOverrideStore.setEnabled(false, for: rule.id)
        }
        configuration.responseOverridesData = try await responseOverrideStore.persistedData()
    }

    private func disableBookmarkRewrites() throws {
        let updated = bookmarkStore.loadBookmarks().map { bookmark -> Bookmark in
            var bookmark = bookmark
            bookmark.responseRewrites = bookmark.responseRewrites.map { rewrite in
                var rewrite = rewrite
                rewrite.isRuleEnabled = false
                return rewrite
            }
            return bookmark
        }
        try bookmarkStore.saveBookmarks(updated)
    }
}
