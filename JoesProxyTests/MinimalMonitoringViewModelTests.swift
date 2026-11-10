import SwiftUI
import Combine
import XCTest
@testable import JoesProxy

/// Exercises `MinimalMonitoringViewModel` entirely through fakes — no window, no `NSPanel`, no
/// `ProxyViewModel` — proving the ADR's acceptance criterion that the HUD's behavior layer is
/// constructible and testable independent of any host.
@MainActor
final class MinimalMonitoringViewModelTests: XCTestCase {
    func testUnchangedRefreshDoesNotPublishOrDriveLayout() {
        let viewModel = makeViewModel()
        viewModel.refreshTick()
        var publications = 0
        let subscription = viewModel.objectWillChange.sink { publications += 1 }
        for _ in 0..<1_000 { viewModel.refreshTick() }
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testChangedStatusStillPublishesAfterQuietRefreshes() {
        var status = "Stopped"
        let viewModel = makeViewModel(proxyStatus: { (status, .safe) })
        viewModel.refreshTick()
        var publications = 0
        let subscription = viewModel.objectWillChange.sink { publications += 1 }
        status = "Capturing"
        viewModel.refreshTick()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(tile(viewModel, "proxy")?.value, "Capturing")
        viewModel.refreshTick()
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(subscription) {}
    }

    func testRefreshTickRequestsFreshAggregateEffectsWithoutInspectingCaptureRows() {
        var refreshRequests = 0
        let viewModel = MinimalMonitoringViewModel(
            captureHealthProvider: { .empty },
            transportSnapshotProvider: { .empty },
            proxyStatusProvider: { ("Stopped", .safe) },
            refreshActiveEffects: { refreshRequests += 1 },
            refreshInterval: 999
        )

        viewModel.refreshTick()
        viewModel.refreshTick()

        XCTAssertEqual(refreshRequests, 2)
    }

    private func makeViewModel(
        health: @escaping () -> CaptureHealthMetrics = { .empty },
        transport: @escaping () -> CaptureTransportDiagnosticsSnapshot = { .empty },
        proxyStatus: @escaping () -> (description: String, level: HealthLevel) = { ("Stopped", .safe) },
        pendingApprovals: @escaping () -> Int = { 0 },
        activeEffects: @escaping () -> MinimalMonitoringActiveEffectsSnapshot = { .empty },
        controlsState: @escaping () -> MinimalMonitoringControlsState = { .empty },
        startProxyAction: @escaping () -> Void = {},
        stopProxyAction: @escaping () -> Void = {},
        startMCPAction: @escaping () -> Void = {},
        stopMCPAction: @escaping () -> Void = {},
        colorDwellTicks: Int = 3
    ) -> MinimalMonitoringViewModel {
        MinimalMonitoringViewModel(
            captureHealthProvider: health,
            transportSnapshotProvider: transport,
            proxyStatusProvider: proxyStatus,
            pendingApprovalCountProvider: pendingApprovals,
            activeEffectsProvider: activeEffects,
            controlsStateProvider: controlsState,
            startProxyAction: startProxyAction,
            stopProxyAction: stopProxyAction,
            startMCPAction: startMCPAction,
            stopMCPAction: stopMCPAction,
            refreshInterval: 999, // never fires on its own during these tests
            colorDwellTicks: colorDwellTicks
        )
    }

    private func tile(_ viewModel: MinimalMonitoringViewModel, _ id: String) -> MonitoringTileDescriptor? {
        viewModel.tiles.first { $0.id == id }
    }

    private func activeEffectTile(_ viewModel: MinimalMonitoringViewModel, _ id: String) -> MonitoringTileDescriptor? {
        viewModel.activeEffectsTiles.first { $0.id == id }
    }

    private func resourceTile(_ viewModel: MinimalMonitoringViewModel, _ id: String) -> MonitoringTileDescriptor? {
        viewModel.resourceTiles.first { $0.id == id }
    }

    func testRefreshTickMapsAllEightFixedTilesFromProvidedData() {
        let health = CaptureHealthMetrics(
            sessionCount: 42,
            retainedBodyBytes: 0,
            droppedSessionCount: 1,
            captureStartedAt: Date().addingTimeInterval(-120),
            processMetrics: .empty
        )
        let transport = CaptureTransportDiagnosticsSnapshot(
            activeProxyChannels: 3,
            upstreamResponseBytesForwarded: 0,
            expectedClientDisconnectCount: 0,
            unexpectedChannelErrorCount: 2,
            expectedClientWriteFailureCount: 0,
            unexpectedClientWriteFailureCount: 1,
            leafCertCacheHits: 0,
            leafCertCacheMisses: 0
        )
        let viewModel = makeViewModel(
            health: { health },
            transport: { transport },
            proxyStatus: { ("Routing active", .safe) },
            pendingApprovals: { 2 }
        )
        viewModel.refreshTick()

        XCTAssertEqual(viewModel.tiles.count, 8)
        XCTAssertEqual(tile(viewModel, "proxy")?.value, "Routing active")
        XCTAssertEqual(tile(viewModel, "sessions")?.value, "42")
        XCTAssertEqual(tile(viewModel, "connections")?.value, "3")
        XCTAssertEqual(tile(viewModel, "errors")?.value, "3")
        XCTAssertEqual(tile(viewModel, "errors")?.level, .caution)
        XCTAssertEqual(tile(viewModel, "dropped")?.value, "Sessions: 1\nBodies: 0")
        XCTAssertEqual(tile(viewModel, "dropped")?.level, .caution)
        XCTAssertEqual(tile(viewModel, "approvals")?.value, "2")
        XCTAssertEqual(tile(viewModel, "approvals")?.level, .caution)
        XCTAssertNotEqual(tile(viewModel, "duration")?.value, "—")
        XCTAssertNotEqual(tile(viewModel, "throughput")?.value, "—")
    }

    func testUnavailableStatsRenderAsPlaceholderNotMissingTiles() {
        let viewModel = makeViewModel()
        viewModel.refreshTick()

        XCTAssertEqual(viewModel.tiles.count, 8, "the fixed tile count must never shrink based on data")
        XCTAssertEqual(tile(viewModel, "throughput")?.value, "—")
        XCTAssertEqual(tile(viewModel, "duration")?.value, "—")
    }

    func testColorDoesNotCommitUntilDwellTicksAgree() {
        var errorCount = 0
        let viewModel = makeViewModel(
            transport: {
                CaptureTransportDiagnosticsSnapshot(
                    activeProxyChannels: 0,
                    upstreamResponseBytesForwarded: 0,
                    expectedClientDisconnectCount: 0,
                    unexpectedChannelErrorCount: errorCount,
                    expectedClientWriteFailureCount: 0,
                    unexpectedClientWriteFailureCount: 0,
                    leafCertCacheHits: 0,
                    leafCertCacheMisses: 0
                )
            },
            colorDwellTicks: 3
        )
        viewModel.refreshTick()
        XCTAssertEqual(tile(viewModel, "errors")?.level, .safe, "starts safe with zero errors")

        errorCount = 5
        viewModel.refreshTick()
        XCTAssertEqual(tile(viewModel, "errors")?.level, .safe, "tick 1 of 3 — must not flip yet")
        viewModel.refreshTick()
        XCTAssertEqual(tile(viewModel, "errors")?.level, .safe, "tick 2 of 3 — must not flip yet")
        viewModel.refreshTick()
        XCTAssertEqual(tile(viewModel, "errors")?.level, .caution, "tick 3 of 3 — commits now")

        // The underlying value keeps updating on every tick even while color is debounced.
        XCTAssertEqual(tile(viewModel, "errors")?.value, "5")
    }

    func testFlickeringCandidateResetsTheDwellStreak() {
        var errorCount = 0
        let viewModel = makeViewModel(
            transport: {
                CaptureTransportDiagnosticsSnapshot(
                    activeProxyChannels: 0,
                    upstreamResponseBytesForwarded: 0,
                    expectedClientDisconnectCount: 0,
                    unexpectedChannelErrorCount: errorCount,
                    expectedClientWriteFailureCount: 0,
                    unexpectedClientWriteFailureCount: 0,
                    leafCertCacheHits: 0,
                    leafCertCacheMisses: 0
                )
            },
            colorDwellTicks: 3
        )
        viewModel.refreshTick() // establishes .safe as committed

        errorCount = 5
        viewModel.refreshTick() // candidate .caution, streak 1
        errorCount = 0
        viewModel.refreshTick() // back to committed .safe — streak resets
        errorCount = 5
        viewModel.refreshTick() // candidate .caution again, streak restarts at 1
        XCTAssertEqual(tile(viewModel, "errors")?.level, .safe, "an oscillating value must not commit early")
    }

    func testStopCancelsTheTimerSoAClosedHUDNeverKeepsPolling() async throws {
        var callCount = 0
        let viewModel = makeViewModel(
            health: {
                callCount += 1
                return .empty
            }
        )
        viewModel.start()
        try await Task.sleep(for: .milliseconds(50))
        let countAfterStart = callCount
        XCTAssertGreaterThan(countAfterStart, 0, "start() must perform an immediate tick")

        viewModel.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, countAfterStart, "no provider calls should occur after stop()")
    }

    func testControlsStateRefreshesEachTick() {
        var state = MinimalMonitoringControlsState(
            isProxyRunning: false, canStartProxy: true, canStopProxy: false,
            proxyButtonTitle: "Start", proxyButtonIcon: "play.fill", proxyButtonTint: .secondary,
            isMCPRunning: false, canStartMCP: true, canStopMCP: false,
            mcpButtonTitle: "Start", mcpButtonIcon: "play.fill", mcpButtonTint: .secondary
        )
        let viewModel = makeViewModel(controlsState: { state })
        viewModel.refreshTick()
        XCTAssertEqual(viewModel.controlsState.isProxyRunning, false)
        XCTAssertEqual(viewModel.controlsState.canStartProxy, true)

        state = MinimalMonitoringControlsState(
            isProxyRunning: true, canStartProxy: false, canStopProxy: true,
            proxyButtonTitle: "Stop", proxyButtonIcon: "stop.fill", proxyButtonTint: .red,
            isMCPRunning: true, canStartMCP: false, canStopMCP: true,
            mcpButtonTitle: "Stop", mcpButtonIcon: "stop.fill", mcpButtonTint: .green
        )
        viewModel.refreshTick()
        XCTAssertEqual(viewModel.controlsState.isProxyRunning, true)
        XCTAssertEqual(viewModel.controlsState.isMCPRunning, true)
        XCTAssertEqual(viewModel.controlsState.proxyButtonTint, .red)
    }

    func testMCPToggleUsesCapabilitiesAndFreshStateInsteadOfRunningFlag() {
        var state = MinimalMonitoringControlsState.empty
        state.canStartMCP = true
        var starts = 0
        var stops = 0
        let model = makeViewModel(controlsState: { state },
                                  startMCPAction: { starts += 1 }, stopMCPAction: { stops += 1 })
        model.refreshTick()
        model.toggleMCP()
        XCTAssertEqual(starts, 1)

        // Starting, failed and degraded services are stoppable even when not running.
        state.canStartMCP = false
        state.canStopMCP = true
        state.isMCPRunning = false
        model.toggleMCP()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(model.controlsState, state)

        state.canStopMCP = false
        model.toggleMCP()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)

        state.canStartMCP = true
        model.toggleMCP()
        XCTAssertEqual(starts, 2)
    }

    func testProxyTapImmediatelyProjectsStartupAndIgnoresAdditionalTaps() {
        var state = MinimalMonitoringControlsState.empty
        state.canStartProxy = true
        var starts = 0
        var stops = 0
        let model = makeViewModel(controlsState: { state }, startProxyAction: {
            starts += 1
            state.canStartProxy = false
            state.isProxyTransitioning = true
            state.proxyButtonTitle = "Starting… Proxy"
        }, stopProxyAction: { stops += 1 })
        model.toggleProxy()
        XCTAssertTrue(model.controlsState.isProxyTransitioning)
        XCTAssertEqual(model.controlsState.proxyButtonTitle, "Starting… Proxy")
        model.toggleProxy()
        model.toggleProxy()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        state.isProxyTransitioning = false
        state.canStopProxy = true
        state.isProxyRunning = true
        model.toggleProxy()
        XCTAssertEqual(stops, 1)
    }

    func testResourceStripCoversTheMetricsTheFixedTileSetDoesNot() {
        let health = CaptureHealthMetrics(
            sessionCount: 1,
            retainedBodyBytes: 10 * 1024 * 1024,
            droppedSessionCount: 0,
            captureStartedAt: Date(),
            processMetrics: AppProcessMetrics(cpuPercent: 12.4, residentMemoryBytes: 256 * 1024 * 1024)
        )
        let viewModel = makeViewModel(health: { health })
        viewModel.refreshTick()

        XCTAssertNil(tile(viewModel, "retainedBytes"), "retained bytes belongs to the resource strip, not the fixed grid")
        XCTAssertEqual(resourceTile(viewModel, "retainedBytes")?.value, "10 MB")
        XCTAssertEqual(resourceTile(viewModel, "memory")?.value, "256 MB")
        XCTAssertEqual(resourceTile(viewModel, "cpu")?.value, "12%")
    }

    func testResourceStripOmitsCPUWhenUnavailableRatherThanShowingAPlaceholder() {
        let health = CaptureHealthMetrics(
            sessionCount: 0,
            retainedBodyBytes: 0,
            droppedSessionCount: 0,
            captureStartedAt: nil,
            processMetrics: .empty // cpuPercent == nil
        )
        let viewModel = makeViewModel(health: { health })
        viewModel.refreshTick()

        XCTAssertEqual(viewModel.resourceTiles.count, 2, "retained bytes and memory are always known; cpu is omitted, not shown as —")
        XCTAssertNil(resourceTile(viewModel, "cpu"))
    }

    func testResourceStripColorAlsoDebouncesAcrossDwellTicks() {
        var residentMemoryBytes: UInt64 = 0
        let viewModel = makeViewModel(
            health: {
                CaptureHealthMetrics(
                    sessionCount: 0,
                    retainedBodyBytes: 0,
                    droppedSessionCount: 0,
                    captureStartedAt: nil,
                    processMetrics: AppProcessMetrics(cpuPercent: nil, residentMemoryBytes: residentMemoryBytes)
                )
            },
            colorDwellTicks: 3
        )
        viewModel.refreshTick()
        XCTAssertEqual(resourceTile(viewModel, "memory")?.level, .safe)

        residentMemoryBytes = UInt64(CaptureHealthThresholds.standard.residentMemoryBytes) * 2 // well past critical
        viewModel.refreshTick()
        XCTAssertEqual(resourceTile(viewModel, "memory")?.level, .safe, "tick 1 of 3 — must not flip yet")
        viewModel.refreshTick()
        XCTAssertEqual(resourceTile(viewModel, "memory")?.level, .safe, "tick 2 of 3 — must not flip yet")
        viewModel.refreshTick()
        XCTAssertEqual(resourceTile(viewModel, "memory")?.level, .critical, "tick 3 of 3 — commits now")
    }

    func testActiveEffectsStripAlwaysShowsAllTenIndicatorsRegardlessOfState() {
        let viewModel = makeViewModel(
            activeEffects: {
                MinimalMonitoringActiveEffectsSnapshot(
                    activeMapLocalCount: 2,
                    activeMapRemoteCount: 1,
                    activeBlockCount: 3,
                    activeBookmarkRewriteCount: 4,
                    activeLiveRewriteCount: 1,
                    isThrottlingEnabled: true,
                    activeHLSSubstitutionCount: 1,
                    activeOpenAPIMockPackCount: 2,
                    activeSyntheticInjectionCount: 1,
                    isSystemProxyTunnelingActive: false
                )
            }
        )
        viewModel.refreshTick()

        XCTAssertEqual(viewModel.activeEffectsTiles.count, 10, "fixed set — every traffic modification always present")
        XCTAssertEqual(activeEffectTile(viewModel, "mapLocal")?.value, "2")
        XCTAssertEqual(activeEffectTile(viewModel, "mapLocal")?.level, .caution, "active traffic mutation should draw attention")
        XCTAssertEqual(activeEffectTile(viewModel, "mapRemote")?.value, "1")
        XCTAssertEqual(activeEffectTile(viewModel, "block")?.value, "3")
        XCTAssertEqual(activeEffectTile(viewModel, "bookmarkRewrite")?.value, "4")
        XCTAssertEqual(activeEffectTile(viewModel, "liveRewrite")?.value, "1")
        XCTAssertEqual(activeEffectTile(viewModel, "throttle")?.value, "On")
        XCTAssertEqual(activeEffectTile(viewModel, "throttle")?.level, .caution)
        XCTAssertEqual(activeEffectTile(viewModel, "hlsSubstitution")?.value, "1")
        XCTAssertEqual(activeEffectTile(viewModel, "openAPIMock")?.value, "2")
        XCTAssertEqual(activeEffectTile(viewModel, "syntheticInjection")?.value, "1")
        XCTAssertEqual(activeEffectTile(viewModel, "tunnel")?.value, "Off")
        XCTAssertEqual(activeEffectTile(viewModel, "tunnel")?.level, .safe, "inactive tunneling is the normal/expected state")
    }

    func testActiveEffectsStripReflectsAllInactiveAsSafe() {
        let viewModel = makeViewModel(activeEffects: { .empty })
        viewModel.refreshTick()

        XCTAssertTrue(viewModel.activeEffectsTiles.allSatisfy { $0.level == .safe })
        XCTAssertEqual(activeEffectTile(viewModel, "mapLocal")?.value, "0")
        XCTAssertEqual(activeEffectTile(viewModel, "throttle")?.value, "Off")
        XCTAssertEqual(activeEffectTile(viewModel, "tunnel")?.value, "Off")
    }

    func testStartStopActionsAreInvokedDirectly() {
        var startProxyCalled = false
        var stopMCPCalled = false
        let viewModel = makeViewModel(
            startProxyAction: { startProxyCalled = true },
            stopMCPAction: { stopMCPCalled = true }
        )
        viewModel.startProxyAction()
        viewModel.stopMCPAction()
        XCTAssertTrue(startProxyCalled)
        XCTAssertTrue(stopMCPCalled)
    }
}
