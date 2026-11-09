//
//  PreviousRunDiagnosticsCoordinator.swift
//  JoesProxy
//
//  Main-actor presentation of the frozen previous-run report (ADR-Startup-Recovery-Diagnostics).
//

import AppKit
import Combine
import Foundation

/// Owns the one frozen previous-run report shown by every recovery surface.
///
/// Disk work happens in ``PreviousRunDiagnosticsStore`` on its own queue; this type only
/// publishes availability, writes the prepared text to the pasteboard and pushes last-known
/// main-actor context to the store. Copy and save never start collection, restore or capture.
@MainActor
final class PreviousRunDiagnosticsCoordinator: ObservableObject {
    enum Availability: Equatable {
        case preparing
        case ready(PreviousRunReport)
        case unreadable(reportID: String, text: String)
        case noPreviousRun
        case off
    }

    enum SaveError: LocalizedError {
        case unavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: "Previous-run diagnostics are not available."
            case .writeFailed: "The diagnostics file could not be saved."
            }
        }
    }

    static let contextInterval: TimeInterval = 15

    @Published private(set) var availability: Availability

    nonisolated let runID: String
    /// Supplies last-known workspace, capture and MCP facts. Must be cheap and content-free.
    var contextProvider: (@MainActor () -> PreviousRunOperatingContext)?

    private let store: PreviousRunDiagnosticsStore?
    private let isEnabled: () -> Bool
    private let readerVersion: String
    private let readerBuild: String
    private var contextTimer: Timer?
    private var hasStarted = false

    /// - Parameter store: `nil` keeps the coordinator memory-only (tests, UI tests, screenshots).
    init(
        store: PreviousRunDiagnosticsStore?,
        isEnabled: @escaping () -> Bool,
        readerVersion: String = Bundle.main.marketingVersionOrDev,
        readerBuild: String = Bundle.main.buildNumber
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.readerVersion = readerVersion
        self.readerBuild = readerBuild
        self.runID = store?.runID ?? UUID().uuidString
        self.availability = .off
    }

    var reportText: String? {
        switch availability {
        case .ready(let report): report.text
        case .unreadable(_, let text): text
        case .preparing, .noPreviousRun, .off: nil
        }
    }

    var isExportable: Bool { reportText != nil }

    /// Short state for disabled controls; `nil` when a report is available.
    var unavailableDescription: String? {
        switch availability {
        case .ready, .unreadable: nil
        case .preparing: "Preparing previous-run diagnostics"
        case .noPreviousRun: "No previous-run diagnostics were saved"
        case .off: "Previous-run diagnostics are off"
        }
    }

    var suggestedFileName: String {
        let id: String = switch availability {
        case .ready(let report): report.reportID
        case .unreadable(let reportID, _): reportID
        default: "unavailable"
        }
        return "JoesProxy-previous-run-diagnostics-\(id.prefix(8)).txt"
    }

    /// Preserves earlier runs, then begins this run's recording when enabled. `onPreserved`
    /// runs on the main actor after preservation so the responsiveness monitor cannot overwrite
    /// the previous run's incident first. It is called even when no store exists.
    func start(onPreserved: @escaping @MainActor () -> Void = {}) {
        guard !hasStarted else { return }
        hasStarted = true
        guard let store else {
            onPreserved()
            return
        }
        availability = .preparing
        let readerVersion = readerVersion, readerBuild = readerBuild
        store.preparePreviousRun { [weak self] previous in
            let availability: Availability = switch previous {
            case .none:
                .noPreviousRun
            case .envelope(let envelope):
                .ready(PreviousRunReport(envelope: envelope, readerVersion: readerVersion, readerBuild: readerBuild))
            case .unreadable(let reason):
                PreviousRunDiagnosticsCoordinator.unreadable(reason, readerVersion: readerVersion, readerBuild: readerBuild)
            }
            Task { @MainActor in
                self?.finishPreparation(availability)
                onPreserved()
            }
        }
    }

    private func finishPreparation(_ prepared: Availability) {
        availability = prepared
        guard isEnabled() else { return }
        beginRecording()
    }

    /// Applies the Settings toggle. Disabling stops recording and removes this run's envelope;
    /// the already-prepared report remains until the person clears it.
    func setRecordingEnabled(_ enabled: Bool) {
        guard let store, hasStarted else { return }
        if enabled {
            beginRecording()
        } else {
            contextTimer?.invalidate()
            contextTimer = nil
            store.stopRecording()
        }
    }

    private func beginRecording() {
        guard let store, contextTimer == nil else { return }
        pushContext()
        store.startRecording()
        contextTimer = Timer.scheduledTimer(withTimeInterval: Self.contextInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushContext() }
        }
    }

    func pushContext() {
        guard let store, let contextProvider else { return }
        store.updateContext(contextProvider())
    }

    /// Writes the frozen report to the pasteboard. Returns `false` when nothing is available or
    /// the pasteboard rejects the write; never claims success otherwise.
    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = reportText else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func save(to destination: URL) throws {
        guard let text = reportText else { throw SaveError.unavailable }
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            throw SaveError.writeFailed
        }
    }

    /// Deletes saved history and the offered report. Capture checkpoints are unaffected.
    func clearHistory() {
        availability = store == nil ? .off : .noPreviousRun
        store?.clearHistory {}
    }

    /// Bounded final write; call from `applicationWillTerminate` after other shutdown work.
    func recordCleanShutdown() {
        contextTimer?.invalidate()
        contextTimer = nil
        guard isEnabled() else { return }
        pushContext()
        store?.recordCleanShutdown()
    }

    /// Memory-only synthetic report for deterministic UI tests. Never touches disk.
    func installUITestReport() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let envelope = PreviousRunDiagnosticEnvelope(
            runID: "00000000-0000-4000-8000-000000000001", producerVersion: readerVersion,
            producerBuild: readerBuild, osVersion: "synthetic", architecture: "arm64",
            physicalMemoryBytes: 16 * 1_073_741_824, startedAt: start,
            lastSavedHealthAt: start.addingTimeInterval(600), startUptime: 100, lastSampleUptime: 700,
            healthCadenceSeconds: 30, incidentAssociation: PreviousRunIncidentAssociation.none)
        availability = .ready(PreviousRunReport(envelope: envelope, readerVersion: readerVersion,
                                                readerBuild: readerBuild,
                                                reportID: "00000000-0000-4000-8000-0000000000aa"))
    }

    private nonisolated static func unreadable(_ reason: PreviousRunUnreadableReason, readerVersion: String,
                                   readerBuild: String) -> Availability {
        let reportID = UUID().uuidString
        return .unreadable(reportID: reportID, text: PreviousRunDiagnosticsFormatter.unreadableText(
            reason: reason, reportID: reportID, readerVersion: readerVersion, readerBuild: readerBuild))
    }
}

extension PreviousRunOperatingContext {
    /// Maps checkpoint status to allowlisted fields. The free-form error message is reduced to a
    /// fixed code because it can contain file names or paths.
    init(observedAt: Date, workspace: String?, retainedRequestCount: Int?, mcpRunning: Bool?,
         pendingApprovalCount: Int?, checkpoint: RollingCaptureStatus?) {
        self.init(observedAt: observedAt, workspace: workspace, retainedRequestCount: retainedRequestCount,
                  mcpRunning: mcpRunning, pendingApprovalCount: pendingApprovalCount,
                  checkpointSavedAt: checkpoint?.savedAt,
                  checkpointSessionCount: checkpoint?.isAvailable == true ? checkpoint?.sessionCount : nil,
                  checkpointErrorCode: checkpoint?.persistenceError == nil ? nil : "checkpoint-write-failed")
    }
}
