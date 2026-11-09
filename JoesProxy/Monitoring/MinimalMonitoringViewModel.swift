import Combine
import Foundation

/// Host-agnostic behavior for the Minimal Monitoring HUD — ADR §2b. Takes only narrow closures,
/// never a reference to `ProxyViewModel`/`AppCoordinator`/any session type, so it can be
/// constructed and unit-tested with fakes and reused by any future host unmodified.
///
/// One dedicated `Timer.publish` subscription drives everything (ADR §5) — this view model never
/// subscribes to `sessionStore.sessionChangesPublisher` or any other per-session publisher.
@MainActor
final class MinimalMonitoringViewModel: ObservableObject {
    @Published private(set) var tiles: [MonitoringTileDescriptor]
    /// Process-resource indicators (retained body bytes, resident memory, CPU) — rendered as a
    /// single-line strip rather than grid tiles (`CaptureHealthStrip`'s existing compact style) so
    /// this stays a several-`pt`-tall addition rather than three more 40pt tiles. Kept as its own
    /// array (not merged into `tiles`) precisely so the fixed 8-tile grid contract in ADR
    /// `Minimal-Monitoring-Mode` §6/§7 is untouched — this is an additive strip beside it, not a
    /// change to that array.
    @Published private(set) var resourceTiles: [MonitoringTileDescriptor] = []
    /// Map Local / Throttle / Tunneling indicators — see `MinimalMonitoringActiveEffectsSnapshot`.
    /// A third, separately-purposed strip: resource health (`resourceTiles`) asks "is JoesProxy
    /// itself healthy," this asks "is JoesProxy changing what the client sees."
    @Published private(set) var activeEffectsTiles: [MonitoringTileDescriptor] = []
    @Published private(set) var controlsState: MinimalMonitoringControlsState = .empty

    private let captureHealthProvider: () -> CaptureHealthMetrics
    private let transportSnapshotProvider: () -> CaptureTransportDiagnosticsSnapshot
    private let proxyStatusProvider: () -> (description: String, level: HealthLevel)
    private let pendingApprovalCountProvider: () -> Int
    private let activeEffectsProvider: () -> MinimalMonitoringActiveEffectsSnapshot
    private let refreshActiveEffects: () -> Void
    private let controlsStateProvider: () -> MinimalMonitoringControlsState
    let startProxyAction: () -> Void
    let stopProxyAction: () -> Void
    let startMCPAction: () -> Void
    let stopMCPAction: () -> Void
    private let refreshInterval: TimeInterval
    private let colorDwellTicks: Int

    private var timerCancellable: AnyCancellable?
    private var timerConnection: Cancellable?
    private var isRunning = false
    private var dwellState: [String: DwellState] = [:]

    private struct DwellState {
        var committed: HealthLevel
        var candidate: HealthLevel
        var streak: Int
    }

    init(
        captureHealthProvider: @escaping () -> CaptureHealthMetrics,
        transportSnapshotProvider: @escaping () -> CaptureTransportDiagnosticsSnapshot,
        proxyStatusProvider: @escaping () -> (description: String, level: HealthLevel),
        pendingApprovalCountProvider: @escaping () -> Int = { 0 },
        activeEffectsProvider: @escaping () -> MinimalMonitoringActiveEffectsSnapshot = { .empty },
        refreshActiveEffects: @escaping () -> Void = {},
        controlsStateProvider: @escaping () -> MinimalMonitoringControlsState = { .empty },
        startProxyAction: @escaping () -> Void = {},
        stopProxyAction: @escaping () -> Void = {},
        startMCPAction: @escaping () -> Void = {},
        stopMCPAction: @escaping () -> Void = {},
        refreshInterval: TimeInterval = 2.0,
        colorDwellTicks: Int = 3
    ) {
        self.captureHealthProvider = captureHealthProvider
        self.transportSnapshotProvider = transportSnapshotProvider
        self.proxyStatusProvider = proxyStatusProvider
        self.pendingApprovalCountProvider = pendingApprovalCountProvider
        self.activeEffectsProvider = activeEffectsProvider
        self.refreshActiveEffects = refreshActiveEffects
        self.controlsStateProvider = controlsStateProvider
        self.startProxyAction = startProxyAction
        self.stopProxyAction = stopProxyAction
        self.startMCPAction = startMCPAction
        self.stopMCPAction = stopMCPAction
        self.refreshInterval = refreshInterval
        self.colorDwellTicks = max(1, colorDwellTicks)
        self.tiles = Self.rawTileDescriptors(for: .empty, proxyStatusLevel: .safe)
        self.resourceTiles = Self.rawResourceDescriptors(for: .empty)
    }

    /// Use fresh controller capabilities, not the last timer snapshot, to choose the action.
    func toggleMCP() {
        let current = controlsStateProvider()
        controlsState = current
        if current.canStartMCP {
            startMCPAction()
        } else if current.canStopMCP {
            stopMCPAction()
        }
    }

    func toggleProxy() {
        let current = controlsStateProvider()
        guard !current.isProxyTransitioning else {
            controlsState = current
            return
        }
        if current.canStartProxy {
            startProxyAction()
        } else if current.canStopProxy {
            stopProxyAction()
        }
        controlsState = controlsStateProvider()
    }

    /// Begins the dedicated refresh timer. Idempotent — calling it while already running is a
    /// no-op, so a view's `onAppear` can call this freely.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTick()
        let timer = Timer.publish(every: refreshInterval, on: .main, in: .common)
        timerCancellable = timer.sink { [weak self] _ in
            self?.refreshTick()
        }
        timerConnection = timer.connect()
    }

    /// Cancels the refresh timer so a closed HUD never keeps polling while nobody is looking.
    func stop() {
        isRunning = false
        timerConnection?.cancel()
        timerConnection = nil
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    /// Reads all providers synchronously, builds a `MinimalMonitoringSnapshot`, maps it to tiles,
    /// and applies the color-dwell debounce. Not private — tests call this directly instead of
    /// waiting on a real `Timer`.
    func refreshTick() {
        refreshActiveEffects()
        let health = captureHealthProvider()
        let transport = transportSnapshotProvider()
        let proxyStatus = proxyStatusProvider()
        let snapshot = MinimalMonitoringSnapshot(
            proxyStatusDescription: proxyStatus.description,
            sessionCount: health.sessionCount,
            throughputPerMinute: health.sessionThroughputPerMinute,
            activeConnections: transport.activeProxyChannels,
            errorCount: transport.unexpectedChannelErrorCount + transport.unexpectedClientWriteFailureCount,
            droppedSessionCount: health.droppedSessionCount,
            captureDuration: health.captureDuration,
            pendingApprovalCount: max(0, pendingApprovalCountProvider())
        )
        let candidates = Self.rawTileDescriptors(for: snapshot, proxyStatusLevel: proxyStatus.level)
        let nextTiles = candidates.map(applyDwell)
        let nextResources = Self.rawResourceDescriptors(for: health).map(applyDwell)
        let nextEffects = Self.rawActiveEffectsDescriptors(for: activeEffectsProvider()).map(applyDwell)
        let nextControls = controlsStateProvider()
        if tiles != nextTiles { tiles = nextTiles }
        if resourceTiles != nextResources { resourceTiles = nextResources }
        if activeEffectsTiles != nextEffects { activeEffectsTiles = nextEffects }
        if controlsState != nextControls { controlsState = nextControls }
    }

    /// Commits a tile's candidate health level only after it has been observed on
    /// `colorDwellTicks` consecutive calls, so a value oscillating at a threshold boundary does
    /// not flicker (ADR §6). A tile's very first observed level commits immediately — only
    /// subsequent changes are debounced.
    private func applyDwell(to descriptor: MonitoringTileDescriptor) -> MonitoringTileDescriptor {
        var state = dwellState[descriptor.id]
            ?? DwellState(committed: descriptor.level, candidate: descriptor.level, streak: 0)
        if descriptor.level == state.committed {
            state.candidate = descriptor.level
            state.streak = 0
        } else if descriptor.level == state.candidate {
            state.streak += 1
            if state.streak >= colorDwellTicks {
                state.committed = descriptor.level
                state.streak = 0
            }
        } else {
            state.candidate = descriptor.level
            state.streak = 1
        }
        dwellState[descriptor.id] = state
        return MonitoringTileDescriptor(
            id: descriptor.id,
            label: descriptor.label,
            systemImage: descriptor.systemImage,
            value: descriptor.value,
            level: state.committed
        )
    }

    /// The fixed tile set and order — always all eight tiles (seven ADR §7 HUD tiles plus AO
    /// pending-approvals aggregate), never conditionally added or removed based on data.
    /// Unavailable values render as "—".
    private static func rawTileDescriptors(
        for snapshot: MinimalMonitoringSnapshot,
        proxyStatusLevel: HealthLevel
    ) -> [MonitoringTileDescriptor] {
        let thresholds = CaptureHealthThresholds.standard
        return [
            MonitoringTileDescriptor(
                id: "proxy",
                label: "Proxy",
                systemImage: "network",
                value: snapshot.proxyStatusDescription,
                level: proxyStatusLevel
            ),
            MonitoringTileDescriptor(
                id: "sessions",
                label: "Sessions",
                systemImage: "list.bullet",
                value: snapshot.sessionCount.formatted(),
                level: HealthLevel(fraction: Double(snapshot.sessionCount) / Double(thresholds.sessionCount))
            ),
            MonitoringTileDescriptor(
                id: "throughput",
                label: "Throughput",
                systemImage: "gauge.with.dots.needle.50percent",
                value: snapshot.throughputPerMinute.map { String(format: "%.1f/min", $0) } ?? "—",
                level: .safe
            ),
            MonitoringTileDescriptor(
                id: "connections",
                label: "Connections",
                systemImage: "cable.connector",
                value: snapshot.activeConnections.formatted(),
                level: .safe
            ),
            MonitoringTileDescriptor(
                id: "errors",
                label: "Errors",
                systemImage: "exclamationmark.triangle",
                value: snapshot.errorCount.formatted(),
                level: snapshot.errorCount > 0 ? .caution : .safe
            ),
            MonitoringTileDescriptor(
                id: "dropped",
                label: "Dropped",
                systemImage: "tray.and.arrow.down",
                // Reads as "data may be missing," not a scored health metric — everything else on
                // this HUD is a health summary; this one is a completeness signal (ADR §7).
                value: snapshot.droppedSessionCount.formatted(),
                level: snapshot.droppedSessionCount > 0 ? .caution : .safe
            ),
            MonitoringTileDescriptor(
                id: "duration",
                label: "Duration",
                systemImage: "clock",
                value: snapshot.captureDuration.map(CaptureHealthFormatting.formattedDuration) ?? "—",
                level: snapshot.captureDuration.map { HealthLevel(fraction: $0 / thresholds.captureDuration) } ?? .safe
            ),
            MonitoringTileDescriptor(
                id: "approvals",
                label: "Approvals",
                systemImage: "checkmark.shield",
                value: snapshot.pendingApprovalCount.formatted(),
                level: snapshot.pendingApprovalCount > 0 ? .caution : .safe
            )
        ]
    }

    /// Retained body bytes, resident memory, and CPU — the three `CaptureHealthStrip` metrics the
    /// fixed tile set above doesn't cover. Same field/threshold/formatting choices as
    /// `CaptureHealthStrip.metricsRow` on purpose: this is the same health data rendered in the
    /// HUD's compact strip layout rather than a second, independently-tuned computation.
    private static func rawResourceDescriptors(for health: CaptureHealthMetrics) -> [MonitoringTileDescriptor] {
        let thresholds = CaptureHealthThresholds.standard
        var descriptors = [
            MonitoringTileDescriptor(
                id: "retainedBytes",
                label: "Retained",
                systemImage: "internaldrive",
                value: ByteCountFormatter.string(fromByteCount: Int64(health.retainedBodyBytes), countStyle: .memory),
                level: HealthLevel(fraction: Double(health.retainedBodyBytes) / Double(thresholds.retainedBodyBytes))
            ),
            MonitoringTileDescriptor(
                id: "memory",
                label: "Memory",
                systemImage: "memorychip",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(health.processMetrics.residentMemoryBytes),
                    countStyle: .memory
                ),
                level: HealthLevel(
                    fraction: Double(health.processMetrics.residentMemoryBytes) / Double(thresholds.residentMemoryBytes)
                )
            )
        ]
        if let cpu = health.processMetrics.cpuPercent {
            descriptors.append(
                MonitoringTileDescriptor(
                    id: "cpu",
                    label: "CPU",
                    systemImage: "cpu",
                    value: String(format: "%.0f%%", cpu),
                    level: HealthLevel(fraction: cpu / thresholds.cpuPercent)
                )
            )
        }
        return descriptors
    }

    /// Every currently-applied traffic modification — always all ten, in this order, matching the
    /// fixed-set philosophy of `rawTileDescriptors` above (nothing appears/disappears based on
    /// data; an inactive mechanism still shows its "0"/"Off" entry). `.caution` (not `.critical`)
    /// marks "active" — these are deliberate states, not problems, but they're exactly the kind of
    /// "traffic isn't behaving normally" fact this HUD exists to surface without digging through
    /// the full UI or the MCP-only effect journal.
    private static func rawActiveEffectsDescriptors(
        for effects: MinimalMonitoringActiveEffectsSnapshot
    ) -> [MonitoringTileDescriptor] {
        func countTile(id: String, label: String, systemImage: String, count: Int) -> MonitoringTileDescriptor {
            MonitoringTileDescriptor(
                id: id,
                label: label,
                systemImage: systemImage,
                value: count.formatted(),
                level: count > 0 ? .caution : .safe
            )
        }
        func toggleTile(id: String, label: String, systemImage: String, isOn: Bool) -> MonitoringTileDescriptor {
            MonitoringTileDescriptor(
                id: id,
                label: label,
                systemImage: systemImage,
                value: isOn ? "On" : "Off",
                level: isOn ? .caution : .safe
            )
        }
        return [
            countTile(id: "mapLocal", label: "Map Local", systemImage: "arrow.triangle.branch", count: effects.activeMapLocalCount),
            countTile(id: "mapRemote", label: "Map Remote", systemImage: "arrow.triangle.swap", count: effects.activeMapRemoteCount),
            countTile(id: "block", label: "Block", systemImage: "slash.circle", count: effects.activeBlockCount),
            countTile(id: "bookmarkRewrite", label: "Bookmark Rewrite", systemImage: "bookmark.fill", count: effects.activeBookmarkRewriteCount),
            countTile(id: "liveRewrite", label: "Live Rewrite", systemImage: "arrow.triangle.2.circlepath", count: effects.activeLiveRewriteCount),
            toggleTile(id: "throttle", label: "Throttle", systemImage: "speedometer", isOn: effects.isThrottlingEnabled),
            countTile(id: "hlsSubstitution", label: "HLS Substitution", systemImage: "play.rectangle.on.rectangle.fill", count: effects.activeHLSSubstitutionCount),
            countTile(id: "openAPIMock", label: "OpenAPI Mock", systemImage: "shippingbox.fill", count: effects.activeOpenAPIMockPackCount),
            countTile(id: "syntheticInjection", label: "Synthetic Injection", systemImage: "syringe.fill", count: effects.activeSyntheticInjectionCount),
            toggleTile(id: "tunnel", label: "Tunneling", systemImage: "network.badge.shield.half.filled", isOn: effects.isSystemProxyTunnelingActive)
        ]
    }
}
