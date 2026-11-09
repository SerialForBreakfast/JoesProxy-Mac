import AppKit
import CoreGraphics
import Network
import XCTest

/// Opt-in only; use the serial profiling wrapper after approval for desktop interaction.
@MainActor
final class CaptureStabilityProfilingUITests: XCTestCase {
    func testTrackingPilot1500() async throws {
        try await run(mode: "pilot", count: 1_500, durations: [10, 15, 10, 15, 10])
    }

    func testStabilityHour20000() async throws {
        try await run(mode: "full", count: 20_000, durations: [600, 900, 600, 900, 600])
    }

    private func run(mode: String, count: Int, durations: [Double]) async throws {
        guard ProcessInfo.processInfo.environment["JOESPROXY_STABILITY_PROFILE"] == mode else {
            throw XCTSkip("Requires explicitly selected stability profiling scope")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.ShowBlender.JoesProxy").isEmpty else {
            throw Failure.existingUserApp
        }
        continueAfterFailure = false
        executionTimeAllowance = mode == "full" ? 3_900 : 240
        let metrics = try SoakAppMetricsReceiver()
        let metricsPort = try await metrics.start()
        defer { metrics.stop() }
        let body = Data(repeating: 42, count: 256 * 1_024)
        let origin = try SoakBinaryOrigin(body: body)
        let originPort = try await origin.start()
        defer { origin.stop() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let reservation = try NWListener(using: parameters)
        reservation.newConnectionHandler = { $0.cancel() }
        let proxyPort = try await SoakBinaryOrigin.startListener(reservation)
        reservation.cancel()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--ui-test-session-count=\(count)",
            "--ui-test-browser-mode=table", "--ui-test-proxy-port=\(proxyPort)",
            "--ui-test-memory-guard", "--ui-test-tracking-probe"]
        app.launchEnvironment = ["JOESPROXY_PROFILE_METRICS_PORT": String(metricsPort),
            "JOESPROXY_PROFILE_METRICS_TOKEN": metrics.token, "DYLD_INSERT_LIBRARIES": ""]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.ShowBlender.JoesProxy")
            .first { $0.bundleURL?.path.contains("/Build/Products/Release/JoesProxy.app") == true })
        let toggle = app.identifiedElement("proxyToggleButton")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        app.waitUntilProxyRuntimeIsRunning()
        var evidence = Data()
        var evidenceBytes = 0
        defer {
            let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.plain-text")
            attachment.name = "capture-stability-\(mode)-\(count).jsonl"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let names = ["stationary", "interaction", "idle", "resumed-interaction", "drain"]
        var completed = 0
        var compact = false
        var step = 0
        var verifiedResizes = 0
        var verifiedSelections = 0
        for (phase, duration) in durations.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            var nextInteraction = started
            var nextSample = started + 2
            while ProcessInfo.processInfo.systemUptime - started < duration {
                guard !running.isTerminated else { throw Failure.safetyStop }
                if phase == 0 || phase == 1 || phase == 3 {
                    // Explicit, repeatable burst; each response is checked byte-for-byte.
                    for _ in 0..<(phase == 3 ? 4 : 1) {
                        try await SoakBinaryClient.request(proxyPort: proxyPort, originPort: originPort, expectedBody: body)
                        completed += 1
                    }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if (phase == 1 || phase == 3), now >= nextInteraction {
                    // Persist the last completed observations before an XCTest interaction can
                    // abort the runner. Target the menu bar, not a full application AX snapshot.
                    let checkpoint = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.plain-text")
                    checkpoint.name = "capture-stability-before-interaction-\(step).jsonl"
                    checkpoint.lifetime = .keepAlways
                    add(checkpoint)
                    evidence.removeAll(keepingCapacity: true)
                    guard !running.isTerminated else { throw Failure.safetyStop }
                    app.activate()
                    app.menuBars.firstMatch.typeKey("0", modifierFlags: .command)
                    compact.toggle()
                    if compact {
                        let hud = app.identifiedElement("compactMonitorRoot")
                        XCTAssertTrue(hud.waitForExistence(timeout: 5))
                        hud.hover()
                        app.menuBars.firstMatch.typeKey("l", modifierFlags: [.command, .option])
                        let utility = app.windows["Traffic Modifications"]
                        XCTAssertTrue(utility.waitForExistence(timeout: 5))
                        utility.hover()
                        utility.buttons["trafficModificationsClose"].click()
                    } else {
                        let table = app.windows["main"].descendants(matching: .any)
                            .matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                "sessionTable", "Captured sessions")).firstMatch
                        XCTAssertTrue(table.waitForExistence(timeout: 5))
                        let originalFrame = try mainWindowFrame(pid: running.processIdentifier)
                        let visibleTable = table.frame.intersection(originalFrame)
                        XCTAssertGreaterThan(visibleTable.height, 200)
                        XCTAssertGreaterThan(visibleTable.width, 200)
                        // Element hover/scroll asks XCTest to reveal the entire virtualized outline.
                        // Send pointer events into its visible viewport instead, without AX scrolling.
                        let menuBar = app.menuBars.firstMatch
                        let anchorFrame = menuBar.frame
                        let anchor = menuBar.coordinate(withNormalizedOffset: .zero)
                        let viewport = anchor.withOffset(CGVector(dx: visibleTable.midX - anchorFrame.minX,
                                                                 dy: visibleTable.midY - anchorFrame.minY))
                        viewport.hover()
                        // Expand first so a window initially at its minimum can still participate.
                        let shrink = !verifiedResizes.isMultiple(of: 2)
                        viewport.scroll(byDeltaX: 0, deltaY: shrink ? -80 : 80)
                        XCTAssertGreaterThan(table.frame.height, 200)
                        // A global first matching cell may be virtualized/offscreen after scrolling.
                        // Select at the visible pointer location and verify the published selection.
                        viewport.click()
                        let selected = XCTNSPredicateExpectation(
                            predicate: NSPredicate(format: "value BEGINSWITH 'Selected: GET '"), object: table)
                        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
                        verifiedSelections += 1
                        guard !running.isTerminated else { throw Failure.safetyStop }
                        app.activate()
                        // Native resize tracking extends outside the frame; an inset hits content.
                        let edge = anchor.withOffset(CGVector(dx: originalFrame.maxX - anchorFrame.minX + 2,
                                                             dy: originalFrame.midY - anchorFrame.minY))
                        // Enter AppKit's resize tracking region before sending mouse-down.
                        edge.hover()
                        let pointerBefore = try XCTUnwrap(CGEvent(source: nil)).location
                        edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: shrink ? -20 : 20, dy: 0)))
                        let pointerAfter = try XCTUnwrap(CGEvent(source: nil)).location
                        let resizeDeadline = ProcessInfo.processInfo.systemUptime + 3
                        var widthChange = try mainWindowFrame(pid: running.processIdentifier).width - originalFrame.width
                        while (shrink ? widthChange > -5 : widthChange < 5),
                              ProcessInfo.processInfo.systemUptime < resizeDeadline {
                            guard !running.isTerminated else { throw Failure.safetyStop }
                            try await Task.sleep(for: .milliseconds(100))
                            widthChange = try mainWindowFrame(pid: running.processIdentifier).width - originalFrame.width
                        }
                        guard shrink ? widthChange <= -5 : widthChange >= 5 else {
                            let bounds = XCTAttachment(string: "Before: \(originalFrame); after: \(try mainWindowFrame(pid: running.processIdentifier)); expected shrink: \(shrink); pointer before: \(pointerBefore); pointer after: \(pointerAfter)")
                            bounds.name = "stability-resize-bounds"
                            bounds.lifetime = .keepAlways
                            add(bounds)
                            let diagnostics = XCTAttachment(data: try JSONSerialization.data(
                                withJSONObject: metrics.latest(pid: running.processIdentifier), options: [.sortedKeys]),
                                uniformTypeIdentifier: "public.json")
                            diagnostics.name = "stability-resize-diagnostics"
                            diagnostics.lifetime = .keepAlways
                            add(diagnostics)
                            throw Failure.resizeNotObserved
                        }
                        verifiedResizes += 1
                    }
                    step += 1
                    nextInteraction = now + 10
                }
                let sampleTime = ProcessInfo.processInfo.systemUptime
                if sampleTime >= nextSample {
                    var record = try metrics.latest(pid: running.processIdentifier)
                    XCTAssertEqual(record["instrumentationLoaded"] as? Bool, false)
                    XCTAssertEqual(record["trackingTruncated"] as? Bool, false, "Incomplete tracking counts cannot establish stability")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(record["captureReservedBytes"] as? Int), 128 * 1_024 * 1_024)
                    XCTAssertLessThanOrEqual(try XCTUnwrap(record["capturePending"] as? Int), 512)
                    if phase == 2 || phase == 4, sampleTime - started > 5 {
                        XCTAssertEqual(record["capturePaused"] as? Bool, false)
                        XCTAssertEqual(record["capturePending"] as? Int, 0)
                        XCTAssertEqual(record["captureReservedBytes"] as? Int, 0)
                    }
                    record["phase"] = names[phase]
                    record["seedCount"] = count
                    record["completedRequests"] = completed
                    record["interactionProbe"] = true
                    record["verifiedResizes"] = verifiedResizes
                    record["verifiedSelections"] = verifiedSelections
                    record["requiresAllocationReview"] = true
                    let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    guard evidenceBytes + line.count + 1 < 2 * 1_024 * 1_024 else { throw Failure.evidenceBound }
                    evidenceBytes += line.count + 1
                    evidence.append(line)
                    evidence.append(10)
                    nextSample = sampleTime + 5
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        XCTAssertGreaterThan(verifiedResizes, 0, "Resize coverage must not silently be skipped")
        XCTAssertGreaterThan(verifiedSelections, 0, "Inspector selection must actually occur")
        app.menuBars.firstMatch.typeKey(".", modifierFlags: [.command, .option])
    }

    // Window-server bounds avoid XCTest's whole-window accessibility snapshot and cell realization.
    // Reject ambiguous windows rather than targeting another presentation or another process.
    private func mainWindowFrame(pid: pid_t) throws -> CGRect {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        let frames = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 200, frame.height > 200 else { return nil }
            return frame
        }
        guard frames.count == 1, let frame = frames.first else { throw Failure.ambiguousWindow }
        return frame
    }

    private enum Failure: Error { case existingUserApp, safetyStop, evidenceBound, resizeNotObserved, ambiguousWindow }
}
