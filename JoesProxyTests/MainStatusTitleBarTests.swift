import XCTest
@testable import JoesProxy

final class MainStatusTitleBarTests: XCTestCase {
    func testLargerReadingTextChoosesAHeaderLayoutWithRoomForItsMetrics() {
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_200), .full)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_200, textScale: AppTextSize.accessibility.fontScale), .compact)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_000), .compact)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_000, textScale: AppTextSize.accessibility.fontScale), .minimal)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_200, textScale: AppTextSize.small.fontScale), .full)
    }

    func testCertificateWorkflowStatesUseCompactTitles() {
        XCTAssertEqual(MainTitleBarFormatter.certificateTitle(for: .ready), "Trusted")
        XCTAssertEqual(MainTitleBarFormatter.certificateTitle(for: .installedTrustRequired), "Trust")
        XCTAssertEqual(MainTitleBarFormatter.certificateTitle(for: .needsCleanup), "Repair")
        XCTAssertEqual(MainTitleBarFormatter.certificateTitle(for: .notSetUp), "Setup")
    }

    func testRuntimeStatusUsesUngroupedPortFormatting() {
        XCTAssertEqual(
            MainTitleBarFormatter.runtimeStatusValue(state: .stopped, port: 9090),
            "Stopped · 9090"
        )
        XCTAssertEqual(
            MainTitleBarFormatter.runtimeStatusValue(state: .running(port: 9090), port: 9090),
            "Running · 9090"
        )
    }

    func testHTTPSTitleUsesShortStatusText() {
        XCTAssertEqual(
            MainTitleBarFormatter.httpsTitle(proxyState: .running(port: 9090), mode: .intercepting),
            "Inspected"
        )
        XCTAssertEqual(
            MainTitleBarFormatter.httpsTitle(proxyState: .running(port: 9090), mode: .passThrough),
            "Tunneled"
        )
        XCTAssertEqual(
            MainTitleBarFormatter.httpsTitle(proxyState: .stopped, mode: .intercepting),
            "Off"
        )
    }

    // MARK: - Capture pipeline status matrix

    func testPipelineStatusHealthyOnlyWhenRunningReadyAndIntercepting() {
        let status = MainTitleBarFormatter.pipelineStatus(
            proxyState: .running(port: 9090),
            certificateWorkflowState: .ready,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(status.label, "Capturing · HTTPS inspected")
        XCTAssertEqual(status.tone, .healthy)
        XCTAssertEqual(status.clickSurface, .httpsRules)
        XCTAssertTrue(status.isCapturing)
    }

    func testPipelineStatusRunningVariantsRouteToTheRightSurface() {
        let tunneled = MainTitleBarFormatter.pipelineStatus(
            proxyState: .running(port: 9090),
            certificateWorkflowState: .ready,
            httpsProxyMode: .passThrough
        )
        XCTAssertEqual(tunneled.label, "Capturing · HTTPS tunneled")
        XCTAssertEqual(tunneled.tone, .attention)
        XCTAssertEqual(tunneled.clickSurface, .httpsRules)
        XCTAssertTrue(tunneled.isCapturing)

        let untrusted = MainTitleBarFormatter.pipelineStatus(
            proxyState: .running(port: 9090),
            certificateWorkflowState: .installedTrustRequired,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(untrusted.label, "Capturing · cert not trusted — HTTPS tunneled")
        XCTAssertEqual(untrusted.tone, .attention)
        XCTAssertEqual(untrusted.clickSurface, .certificateSetup)

        let repair = MainTitleBarFormatter.pipelineStatus(
            proxyState: .running(port: 9090),
            certificateWorkflowState: .needsCleanup,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(repair.label, "Capturing · certificate needs repair")
        XCTAssertEqual(repair.tone, .problem)
        XCTAssertEqual(repair.clickSurface, .certificateSetup)

        let httpOnly = MainTitleBarFormatter.pipelineStatus(
            proxyState: .running(port: 9090),
            certificateWorkflowState: .notSetUp,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(httpOnly.label, "Capturing · HTTP only — set up HTTPS")
        XCTAssertEqual(httpOnly.clickSurface, .certificateSetup)
    }

    func testPipelineStatusStoppedVariants() {
        let ready = MainTitleBarFormatter.pipelineStatus(
            proxyState: .stopped,
            certificateWorkflowState: .ready,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(ready.label, "Ready to capture")
        XCTAssertEqual(ready.tone, .idle)
        XCTAssertEqual(ready.clickSurface, .proxyHelp)
        XCTAssertFalse(ready.isCapturing)

        let needsSetup = MainTitleBarFormatter.pipelineStatus(
            proxyState: .stopped,
            certificateWorkflowState: .notSetUp,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(needsSetup.label, "Set up HTTPS to capture")
        XCTAssertEqual(needsSetup.tone, .attention)
        XCTAssertEqual(needsSetup.clickSurface, .certificateSetup)

        let repair = MainTitleBarFormatter.pipelineStatus(
            proxyState: .stopped,
            certificateWorkflowState: .needsCleanup,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(repair.tone, .problem)
        XCTAssertEqual(repair.clickSurface, .certificateSetup)
    }

    func testPipelineStatusFailureCarriesMessageInDetail() {
        let failed = MainTitleBarFormatter.pipelineStatus(
            proxyState: .failed(message: "Port 9090 is already in use."),
            certificateWorkflowState: .ready,
            httpsProxyMode: .intercepting
        )
        XCTAssertEqual(failed.label, "Capture failed")
        XCTAssertEqual(failed.detail, "Port 9090 is already in use.")
        XCTAssertEqual(failed.tone, .problem)
        XCTAssertFalse(failed.isCapturing)
    }

    func testPipelineStatusEveryCombinationHasNonEmptyLabelAndDetail() {
        let proxyStates: [ProxyRuntimeState] = [
            .stopped, .starting(port: 9090), .running(port: 9090), .stopping,
            .failed(message: "boom")
        ]
        let certStates: [ProxyViewModel.CertificateWorkflowState] = [
            .ready, .installedTrustRequired, .needsCleanup, .notSetUp
        ]
        let modes: [HTTPSProxyMode] = [.intercepting, .passThrough]

        for proxyState in proxyStates {
            for certState in certStates {
                for mode in modes {
                    let status = MainTitleBarFormatter.pipelineStatus(
                        proxyState: proxyState,
                        certificateWorkflowState: certState,
                        httpsProxyMode: mode
                    )
                    XCTAssertFalse(status.label.isEmpty, "\(proxyState)/\(certState)/\(mode)")
                    XCTAssertFalse((status.detail ?? "").isEmpty, "\(proxyState)/\(certState)/\(mode)")
                    if case .running = proxyState {
                        XCTAssertTrue(status.isCapturing, "\(certState)/\(mode)")
                    } else {
                        XCTAssertFalse(status.isCapturing, "\(proxyState)/\(certState)/\(mode)")
                    }
                }
            }
        }
    }

    func testTimelineMethodColumnFitsConnectVerb() {
        // Must exceed the rendered width of "CONNECT" in caption monospaced at 1x so the
        // widest HTTP verb never wraps or truncates in the timeline event rows.
        let width = TimelineLayoutMetrics.methodColumnWidth(scale: 1)
        XCTAssertGreaterThanOrEqual(width, 56)

        // Scales up with accessibility text size, never below the 1x width.
        XCTAssertGreaterThan(
            TimelineLayoutMetrics.methodColumnWidth(scale: 1.4),
            width
        )
        XCTAssertEqual(TimelineLayoutMetrics.methodColumnWidth(scale: 0.5), width,
                       "Sub-1 scales clamp to the 1x width")
    }

    // MARK: - Timeline content width clamp
    //
    // Regression coverage for a bug found via a 44-minute Instruments capture
    // (memlog/Instruments-Results/JoesProxyNotRendering): zooming the timeline produced a
    // `contentWidth` wider than CALayer/Metal's real backing-store limit. AppKit didn't clip it —
    // it silently dropped the layer ("Ignoring bogus layer size (247401.0, 14192.0)..."), so the
    // pane rendered blank at that zoom level, immediately preceded in the log by three
    // back-to-back "Publishing changes from within view updates is not allowed" warnings from the
    // ruler cache's `.onChange` reacting to the same runaway width during the live pinch gesture.

    func testTimelineContentWidthNeverExceedsRenderableMaximum() {
        // The un-clamped math (viewport up to 8,000pt × zoom up to 50x) reaches 400,000pt — the
        // exact combination that produced the bogus-layer warning in the capture.
        let width = TimelineLayoutMetrics.contentWidth(viewportWidth: 8_000, zoomScale: 50)
        XCTAssertLessThanOrEqual(width, TimelineLayoutMetrics.maxRenderableTimelineContentWidth)
    }

    func testTimelineContentWidthExceedsSafeLimitOnAnOrdinaryWindowAtMaxZoom() {
        // This is not an edge case: an ordinary ~1,200pt-wide window already exceeds the safe
        // render limit before reaching max zoom (1,200 × 50 = 60,000pt). Confirms the clamp is
        // actually engaging for realistic window sizes, not just the 8,000pt guard-rail case.
        let unclamped: CGFloat = 1_200 * 50
        XCTAssertGreaterThan(unclamped, TimelineLayoutMetrics.maxRenderableTimelineContentWidth)
        let width = TimelineLayoutMetrics.contentWidth(viewportWidth: 1_200, zoomScale: 50)
        XCTAssertLessThanOrEqual(width, TimelineLayoutMetrics.maxRenderableTimelineContentWidth)
    }

    func testTimelineContentWidthUnaffectedByClampBelowTheLimit() {
        // At ordinary zoom levels the clamp must be inert — this is a ceiling, not a rescale.
        XCTAssertEqual(
            TimelineLayoutMetrics.contentWidth(viewportWidth: 800, zoomScale: 2),
            1_600
        )
        XCTAssertEqual(
            TimelineLayoutMetrics.contentWidth(viewportWidth: 800, zoomScale: 1),
            800,
            "Content width never shrinks below the viewport, even below 1x zoom math"
        )
    }

    func testLayoutModeBreakpointsPrioritizeCompaction() {
        XCTAssertEqual(MainTitleBarLayoutMode(width: 1_200), .full)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 900), .compact)
        XCTAssertEqual(MainTitleBarLayoutMode(width: 700), .minimal)
    }

    func testHealthMetricsDropLowerPriorityItemsWhenCompact() {
        let metrics = CaptureHealthMetrics(
            sessionCount: 226,
            retainedBodyBytes: 2_900_000,
            droppedSessionCount: 0,
            captureStartedAt: Date(timeIntervalSinceNow: -6_120),
            processMetrics: AppProcessMetrics(cpuPercent: 10, residentMemoryBytes: 133_400_000)
        )

        let fullIDs = MainTitleBarHealthMetric.metrics(for: metrics, layoutMode: .full).map(\.id)
        let compactIDs = MainTitleBarHealthMetric.metrics(for: metrics, layoutMode: .compact).map(\.id)
        let minimalIDs = MainTitleBarHealthMetric.metrics(for: metrics, layoutMode: .minimal).map(\.id)

        XCTAssertEqual(fullIDs, ["sessions", "retained-body", "memory", "cpu", "duration"])
        XCTAssertEqual(compactIDs, ["sessions", "retained-body", "memory"])
        XCTAssertEqual(minimalIDs, ["sessions", "retained-body"])
    }
}
