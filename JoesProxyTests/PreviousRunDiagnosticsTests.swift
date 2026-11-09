import AppKit
import XCTest
@testable import JoesProxy

private final class StubMetricsSampler: ProcessMetricsSampling {
    var metrics = AppProcessMetrics(cpuPercent: 12, physicalFootprintBytes: 64 << 20, peakResidentMemoryBytes: 80 << 20)
    func sample() -> AppProcessMetrics { metrics }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_780_000_000)
    private var uptime: TimeInterval = 1_000

    var now: Date { lock.withLock { date } }
    var systemUptime: TimeInterval { lock.withLock { uptime } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(seconds)
            uptime += seconds
        }
    }
}

/// Business policy for previous-run evidence: finalization, association, bounds, privacy and
/// the frozen report. Every store writes only inside a per-test repository build directory.
@MainActor
final class PreviousRunDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var runDirectory: URL { root.appendingPathComponent("PreviousRun", isDirectory: true) }
    private let clock = TestClock()

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/DiagnosticsTests/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func makeStore(runID: String, limits: PreviousRunDiagnosticsStore.Limits = .init()) -> PreviousRunDiagnosticsStore {
        let clock = clock
        return PreviousRunDiagnosticsStore(
            directory: runDirectory, incidentDirectory: root, runID: runID,
            producerVersion: "9.9.9", producerBuild: "999", metricsSampler: StubMetricsSampler(),
            transport: CaptureTransportDiagnostics(), limits: limits,
            now: { clock.now }, uptime: { clock.systemUptime })
    }

    /// Runs one complete earlier process whose lock is released when the store is deallocated.
    private func completeRun(_ runID: String, clean: Bool, context: PreviousRunOperatingContext? = nil,
                             extraSamples: Int = 0) {
        var store: PreviousRunDiagnosticsStore? = makeStore(runID: runID)
        _ = store?.preparePreviousRunNow()
        if let context { store?.updateContext(context) }
        store?.startRecording()
        for _ in 0..<extraSamples {
            clock.advance(30)
            store?.recordHealthNow()
        }
        clock.advance(30)
        if clean { store?.recordCleanShutdown() } else { store?.recordHealthNow() }
        store = nil
    }

    private func previousEnvelope(_ result: PreviousRunDiagnosticsStore.PreviousRun,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> PreviousRunDiagnosticEnvelope {
        guard case .envelope(let envelope) = result else {
            XCTFail("Expected a finalized envelope, got \(result)", file: file, line: line)
            throw CocoaError(.fileReadCorruptFile)
        }
        return envelope
    }

    private func writeIncident(runID: String?) throws {
        let incident = ResponsivenessIncident(
            schemaVersion: 1, appVersion: "9.9.9", detectedAt: clock.now, recoveredAt: nil,
            onsetSamples: [.init(at: clock.now, pendingSeconds: 7.5, physicalFootprintBytes: 1, cpuPercent: nil,
                                 activeChannels: 0, capturePending: 0, captureRejected: 0, progress: [])],
            runID: runID)
        try ResponsivenessIncidentStore(directory: root).save(incident)
    }

    private func files(prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: runDirectory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Finalization

    func testCleanShutdownIsFinalizedForTheNextLaunch() throws {
        completeRun("run-a", clean: true)
        let next = makeStore(runID: "run-b")
        let envelope = try previousEnvelope(next.preparePreviousRunNow())

        XCTAssertEqual(envelope.runID, "run-a")
        XCTAssertTrue(envelope.cleanShutdownRecorded)
        XCTAssertEqual(envelope.incidentAssociation, PreviousRunIncidentAssociation.none)
        XCTAssertEqual(envelope.producerBuild, "999")
        XCTAssertEqual(files(prefix: "run-run-a"), [], "Finalized run files are removed")
        XCTAssertEqual(files(prefix: "previous-"), ["previous-run-a.json"])
    }

    func testMissingCleanShutdownIsReportedAsUnknownCause() throws {
        completeRun("run-a", clean: false)
        let envelope = try previousEnvelope(makeStore(runID: "run-b").preparePreviousRunNow())
        let report = PreviousRunReport(envelope: envelope, readerVersion: "1", readerBuild: "1", reportID: "r")

        XCTAssertFalse(envelope.cleanShutdownRecorded)
        XCTAssertTrue(report.text.contains("clean shutdown was not recorded; cause unknown"))
        XCTAssertTrue(report.text.contains("evidence after the last saved health sample is unavailable"))
    }

    func testConcurrentLiveRunIsNeverFinalized() throws {
        let live = makeStore(runID: "run-live")
        _ = live.preparePreviousRunNow()
        live.startRecording()
        live.recordHealthNow()

        XCTAssertEqual(makeStore(runID: "run-other").preparePreviousRunNow(), .none)
        XCTAssertEqual(files(prefix: "run-run-live.json"), ["run-run-live.json"])
        XCTAssertEqual(files(prefix: "previous-"), [])
    }

    func testMalformedOversizedAndUnsupportedEnvelopesAreUnreadableNotGuessed() throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let cases: [(Data, PreviousRunUnreadableReason)] = [
            (Data("{not json".utf8), .malformed),
            (Data(repeating: 0x20, count: 300 * 1024), .oversized),
            (Data(#"{"schemaVersion":1,"runID":"x"}"#.utf8), .unsupportedSchema),
        ]
        for (index, (data, reason)) in cases.enumerated() {
            let file = runDirectory.appendingPathComponent("run-bad\(index).json")
            try data.write(to: file)
            XCTAssertEqual(makeStore(runID: "reader-\(index)").preparePreviousRunNow(), .unreadable(reason))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testSymlinkedEnvelopeIsIgnored() throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: runDirectory.appendingPathComponent("run-link.json"), withDestinationURL: outside)

        XCTAssertEqual(makeStore(runID: "reader").preparePreviousRunNow(), .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - Incident association

    func testIncidentIsAttributedOnlyToItsOwnRun() throws {
        completeRun("run-a", clean: false)
        try writeIncident(runID: "run-a")
        let correlated = try previousEnvelope(makeStore(runID: "run-b").preparePreviousRunNow())
        XCTAssertEqual(correlated.incidentAssociation, .correlated)
        XCTAssertEqual(correlated.incident?.maximumAcknowledgementDelaySeconds, 7.5)

        completeRun("run-c", clean: false)
        try writeIncident(runID: nil)
        let legacy = try previousEnvelope(makeStore(runID: "run-d").preparePreviousRunNow())
        XCTAssertEqual(legacy.incidentAssociation, .uncorrelatedLegacy)
        XCTAssertNil(legacy.incident)

        completeRun("run-e", clean: false)
        try writeIncident(runID: "run-z")
        let other = try previousEnvelope(makeStore(runID: "run-f").preparePreviousRunNow())
        XCTAssertEqual(other.incidentAssociation, .otherRun)
        XCTAssertNil(other.incident)
        let text = PreviousRunReport(envelope: other, readerVersion: "1", readerBuild: "1").text
        XCTAssertTrue(text.contains("belongs to another run; not attributed"))
        XCTAssertFalse(text.contains("7.5s"))
    }

    // MARK: - Bounds and retention

    func testRetentionKeepsThreeOwnHistoryFilesAndNeverTouchesOtherFiles() throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let foreign = runDirectory.appendingPathComponent("notes.txt")
        let sharedIncident = root.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: foreign)
        try Data("keep".utf8).write(to: sharedIncident)

        for index in 0..<6 {
            completeRun("run-\(index)", clean: true)
            clock.advance(60)
        }
        let newest = try previousEnvelope(makeStore(runID: "reader").preparePreviousRunNow())

        XCTAssertEqual(newest.runID, "run-5")
        XCTAssertEqual(files(prefix: "previous-").count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedIncident.path))
    }

    func testExpiredHistoryIsRemovedButTheOfferedReportIsPinned() throws {
        completeRun("run-old", clean: true)
        _ = makeStore(runID: "run-mid").preparePreviousRunNow()
        let oldFile = runDirectory.appendingPathComponent("previous-run-old.json")
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: oldFile.path)
        clock.advance(1)
        completeRun("run-new", clean: true)

        let offered = try previousEnvelope(makeStore(runID: "reader").preparePreviousRunNow())
        XCTAssertEqual(offered.runID, "run-new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
    }

    func testRecentSamplesAreCappedWithAnOmissionCount() throws {
        completeRun("run-a", clean: true, extraSamples: 70)
        let envelope = try previousEnvelope(makeStore(runID: "run-b").preparePreviousRunNow())

        XCTAssertEqual(envelope.recentSamples.count, PreviousRunDiagnosticEnvelope.maximumRecentSamples)
        XCTAssertEqual(envelope.omittedSampleCount, 72 - PreviousRunDiagnosticEnvelope.maximumRecentSamples)
        XCTAssertTrue(PreviousRunReport(envelope: envelope, readerVersion: "1", readerBuild: "1").text
            .contains("12 older health samples not retained"))
    }

    func testFailedWritesAreCountedAndReported() throws {
        var store: PreviousRunDiagnosticsStore? = makeStore(runID: "run-a")
        _ = store?.preparePreviousRunNow()
        store?.startRecording()
        store?.recordHealthNow()
        let runFile = runDirectory.appendingPathComponent("run-run-a.json")
        try FileManager.default.removeItem(at: runFile)
        try FileManager.default.createDirectory(at: runFile, withIntermediateDirectories: false)
        store?.recordHealthNow()
        store?.recordHealthNow()
        try FileManager.default.removeItem(at: runFile)
        store?.recordCleanShutdown()
        store = nil

        let envelope = try previousEnvelope(makeStore(runID: "run-b").preparePreviousRunNow())
        XCTAssertEqual(envelope.failedWriteCount, 2)
        XCTAssertTrue(PreviousRunReport(envelope: envelope, readerVersion: "1", readerBuild: "1").text
            .contains("2 diagnostic writes failed"))
    }

    // MARK: - Privacy and report truthfulness

    func testPrivacyCanariesNeverReachStorageOrReport() throws {
        let canaryError = "/Users/canary-user/Secret-File.jproxy host canary.example.test token=canary-token"
        let status = RollingCaptureStatus(isEnabled: true, isAvailable: true, savedAt: clock.now.addingTimeInterval(-60),
                                          sessionCount: 4, fileURL: URL(fileURLWithPath: "/Users/canary-user/capture.jproxy"),
                                          persistenceError: canaryError)
        let context = PreviousRunOperatingContext(observedAt: clock.now, workspace: "agent", retainedRequestCount: 4,
                                                  mcpRunning: true, pendingApprovalCount: 1, checkpoint: status)
        completeRun("run-a", clean: false, context: context)
        let active = try String(contentsOf: runDirectory.appendingPathComponent("run-run-a.json"), encoding: .utf8)
        let envelope = try previousEnvelope(makeStore(runID: "run-b").preparePreviousRunNow())
        let stored = active + (try String(contentsOf: runDirectory.appendingPathComponent("previous-run-a.json"), encoding: .utf8))
        let text = PreviousRunReport(envelope: envelope, readerVersion: "1", readerBuild: "1").text

        for canary in ["canary-user", "Secret-File", "canary.example.test", "canary-token", ".jproxy"] {
            XCTAssertFalse(stored.contains(canary), "Stored envelope leaked \(canary)")
            XCTAssertFalse(text.contains(canary), "Report leaked \(canary)")
        }
        XCTAssertTrue(text.contains("storage error checkpoint-write-failed"))
        XCTAssertTrue(text.contains("(predates this run)"))
    }

    func testMissingMeasurementsReadUnavailableNeverZero() {
        let envelope = PreviousRunDiagnosticEnvelope(
            runID: "r", producerVersion: "1", producerBuild: "1", osVersion: "x", architecture: "arm64",
            physicalMemoryBytes: 8 << 30, startedAt: clock.now, lastSavedHealthAt: clock.now,
            startUptime: 0, lastSampleUptime: 0, healthCadenceSeconds: 30)
        let text = PreviousRunDiagnosticsFormatter.text(envelope: envelope, reportID: "id", readerVersion: "1", readerBuild: "1")

        XCTAssertTrue(text.contains("physical footprint last unavailable"))
        XCTAssertTrue(text.contains("CPU at last sample: unavailable"))
        XCTAssertTrue(text.contains("Admission: unavailable"))
        XCTAssertTrue(text.contains("responsiveness incident not examined"))
        XCTAssertFalse(text.contains("Zero KB"))
        XCTAssertLessThanOrEqual(text.utf8.count, PreviousRunDiagnosticsFormatter.maximumBytes)
    }

    // MARK: - Presenter: frozen report, disable, clear and save

    private func startedCoordinator(runID: String, enabled: Bool = true) async -> PreviousRunDiagnosticsCoordinator {
        let coordinator = PreviousRunDiagnosticsCoordinator(
            store: makeStore(runID: runID), isEnabled: { enabled }, readerVersion: "2.0", readerBuild: "20")
        await withCheckedContinuation { continuation in
            coordinator.start { continuation.resume() }
        }
        return coordinator
    }

    func testRepeatedCopiesUseTheSameFrozenReport() async throws {
        completeRun("run-a", clean: true)
        let coordinator = await startedCoordinator(runID: "run-b")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviousRunDiagnosticsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(coordinator.copy(to: pasteboard))
        let first = pasteboard.string(forType: .string)
        clock.advance(120)
        XCTAssertTrue(coordinator.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), first)
        XCTAssertEqual(first, coordinator.reportText)
        XCTAssertTrue(first?.contains("reader: 2.0 (20)") == true)
        coordinator.setRecordingEnabled(false)
    }

    func testInterruptedRunIsFrozenBeforeNewMonitorCanReplaceIncident() async throws {
        completeRun("interrupted", clean: false)
        try writeIncident(runID: "interrupted")
        let store = makeStore(runID: "reader")
        let coordinator = PreviousRunDiagnosticsCoordinator(store: store, isEnabled: { true })
        await withCheckedContinuation { continuation in
            coordinator.start {
                XCTAssertTrue(coordinator.isExportable, "Preservation must precede monitor startup")
                XCTAssertTrue(coordinator.reportText?.contains("clean shutdown was not recorded; cause unknown") == true)
                continuation.resume()
            }
        }
        defer { coordinator.setRecordingEnabled(false) }
        let original = try XCTUnwrap(coordinator.reportText)
        try writeIncident(runID: "reader")
        clock.advance(90)
        store.recordHealthNow()
        let destination = root.appendingPathComponent("interrupted-report.txt")
        try coordinator.save(to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), original)
        XCTAssertEqual(coordinator.reportText, original, "New-run incidents must not rewrite the offered report")
    }

    func testClearedReportCannotBeCopiedOrExportedAgain() async throws {
        completeRun("run-a", clean: true)
        let coordinator = await startedCoordinator(runID: "run-b")
        defer { coordinator.setRecordingEnabled(false) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviousRunDiagnosticsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(coordinator.copy(to: pasteboard))
        let earlierCopy = pasteboard.string(forType: .string)
        coordinator.clearHistory()
        XCTAssertFalse(coordinator.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), earlierCopy,
                       "An unavailable copy must not erase clipboard contents")
        let destination = root.appendingPathComponent("must-not-exist.txt")
        XCTAssertThrowsError(try coordinator.save(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNoPreviousRunIsUnavailableAndCopyReportsFailure() async {
        let coordinator = await startedCoordinator(runID: "run-first")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PreviousRunDiagnosticsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertEqual(coordinator.availability, .noPreviousRun)
        XCTAssertFalse(coordinator.copy(to: pasteboard))
        XCTAssertEqual(coordinator.unavailableDescription, "No previous-run diagnostics were saved")
        coordinator.setRecordingEnabled(false)
    }

    func testDisablingStopsRecordingAndRetainsNoNewHistory() async {
        let store = makeStore(runID: "run-a")
        let coordinator = PreviousRunDiagnosticsCoordinator(store: store, isEnabled: { true })
        await withCheckedContinuation { continuation in coordinator.start { continuation.resume() } }
        store.recordHealthNow()
        XCTAssertEqual(files(prefix: "run-run-a.json"), ["run-run-a.json"])

        coordinator.setRecordingEnabled(false)
        store.recordHealthNow()
        XCTAssertEqual(files(prefix: "run-run-a.json"), [])
        store.recordCleanShutdown()
        XCTAssertEqual(files(prefix: "run-run-a.json"), [], "Shutdown after disabling writes nothing")
    }

    func testDisabledLaunchDoesNotRecord() async {
        let coordinator = await startedCoordinator(runID: "run-off", enabled: false)
        XCTAssertEqual(coordinator.availability, .noPreviousRun)
        XCTAssertEqual(files(prefix: "run-run-off.json"), [])
    }

    func testClearHistoryRemovesSavedReportsOnly() async {
        completeRun("run-a", clean: true)
        let store = makeStore(runID: "run-b")
        let coordinator = PreviousRunDiagnosticsCoordinator(store: store, isEnabled: { true })
        await withCheckedContinuation { continuation in coordinator.start { continuation.resume() } }
        XCTAssertTrue(coordinator.isExportable)

        coordinator.clearHistory()
        store.recordHealthNow()
        XCTAssertEqual(coordinator.availability, .noPreviousRun)
        XCTAssertEqual(files(prefix: "previous-"), [])
        XCTAssertEqual(files(prefix: "run-run-b.json"), ["run-run-b.json"], "This run keeps recording")
        coordinator.setRecordingEnabled(false)
    }

    func testSaveFlowWritesTheFrozenReportAndTreatsCancelAsNotAnError() async throws {
        completeRun("run-a", clean: true)
        let coordinator = await startedCoordinator(runID: "run-b")
        let destination = root.appendingPathComponent("saved.txt")

        XCTAssertEqual(PreviousRunDiagnosticsSaveFlow.run(coordinator: coordinator, chooseDestination: { _ in nil }), .cancelled)
        XCTAssertEqual(PreviousRunDiagnosticsSaveFlow.run(coordinator: coordinator, chooseDestination: { name in
            XCTAssertTrue(name.hasSuffix(".txt"))
            return destination
        }), .saved)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), coordinator.reportText)

        let unwritable = root.appendingPathComponent("missing/dir/saved.txt")
        guard case .failed = PreviousRunDiagnosticsSaveFlow.run(coordinator: coordinator, chooseDestination: { _ in unwritable }) else {
            return XCTFail("Expected a visible save failure")
        }
        coordinator.setRecordingEnabled(false)
    }

    func testStoreLessCoordinatorIsOffAndNeverTouchesDisk() {
        final class Flag { var value = false }
        let coordinator = PreviousRunDiagnosticsCoordinator(store: nil, isEnabled: { true })
        let preserved = Flag()
        coordinator.start { preserved.value = true }

        XCTAssertTrue(preserved.value)
        XCTAssertEqual(coordinator.availability, .off)
        XCTAssertFalse(coordinator.isExportable)
        coordinator.installUITestReport()
        XCTAssertTrue(coordinator.reportText?.contains("JoesProxy previous-run diagnostics") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
    }
}
