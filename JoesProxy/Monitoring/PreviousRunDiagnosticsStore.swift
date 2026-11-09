//
//  PreviousRunDiagnosticsStore.swift
//  JoesProxy
//
//  File-backed previous-run evidence for startup recovery (ADR-Startup-Recovery-Diagnostics).
//

import Darwin
import Foundation

/// Persists this run's content-free health envelope and finalizes earlier runs at launch.
///
/// Concurrency: every file operation runs on one serial utility queue. Main-actor callers push
/// context through a lock and never wait for disk, except the single bounded final write in
/// ``recordCleanShutdown()``. The store only reads, writes or deletes its own fixed-prefix files
/// inside its own directory; the shared Diagnostics directory is read solely for the latest
/// responsiveness incident, which is never modified here.
final class PreviousRunDiagnosticsStore: @unchecked Sendable {
    struct Limits: Sendable {
        var maximumEnvelopeBytes = 256 * 1024
        var maximumIncidentBytes = ResponsivenessIncidentStore.maximumBytes
        var maximumHistoryFiles = 3
        var maximumTotalBytes = 2 * 1024 * 1024
        var maximumAge: TimeInterval = 7 * 86_400
        var healthCadence: TimeInterval = 30
        var transitionMinimumInterval: TimeInterval = 5
        var tickInterval: TimeInterval = 5
    }

    /// Outcome of finalizing earlier runs, delivered once per launch.
    enum PreviousRun: Equatable, Sendable {
        case none
        case envelope(PreviousRunDiagnosticEnvelope)
        case unreadable(PreviousRunUnreadableReason)
    }

    static let incidentFileName = "latest-responsiveness-incident.json"

    let runID: String
    private let directory: URL
    private let incidentDirectory: URL
    private let limits: Limits
    private let producerVersion: String
    private let producerBuild: String
    private let metricsSampler: ProcessMetricsSampling
    private let transport: CaptureTransportDiagnostics
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let startedAt: Date
    private let startUptime: TimeInterval
    private let queue = DispatchQueue(label: "com.joesproxyapp.previous-run-diagnostics", qos: .utility)

    private let contextLock = NSLock()
    private var cachedContext: PreviousRunOperatingContext?

    // Queue-confined state.
    private var lockDescriptor: Int32 = -1
    private var recording = false
    private var timer: DispatchSourceTimer?
    private var envelope: PreviousRunDiagnosticEnvelope?
    private var lastWriteUptime: TimeInterval?
    private var lastWrittenAdmissionPaused: Bool?
    private var lastWrittenErrorCode: String?

    init(
        directory: URL,
        incidentDirectory: URL,
        runID: String = UUID().uuidString,
        producerVersion: String = Bundle.main.marketingVersionOrDev,
        producerBuild: String = Bundle.main.buildNumber,
        metricsSampler: ProcessMetricsSampling = CurrentProcessMetricsSampler(),
        transport: CaptureTransportDiagnostics,
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.directory = directory
        self.incidentDirectory = incidentDirectory
        self.runID = runID
        self.producerVersion = producerVersion
        self.producerBuild = producerBuild
        self.metricsSampler = metricsSampler
        self.transport = transport
        self.limits = limits
        self.now = now
        self.uptime = uptime
        startedAt = now()
        startUptime = uptime()
    }

    deinit {
        timer?.cancel()
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    // MARK: - Launch

    /// Claims this run's lock, finalizes runs whose owners have exited, applies retention and
    /// reports the newest retained previous run. Call before this launch's responsiveness monitor
    /// may write, so an earlier run's incident is preserved first.
    func preparePreviousRun(completion: @escaping @Sendable (PreviousRun) -> Void) {
        queue.async { [self] in
            completion(prepareOnQueue())
        }
    }

    /// Synchronous variant for tests.
    func preparePreviousRunNow() -> PreviousRun {
        queue.sync { prepareOnQueue() }
    }

    private func prepareOnQueue() -> PreviousRun {
        guard ensureOwnedDirectory(), claimLock() else { return .none }
        let incident = readIncident()
        var newest: PreviousRun = .none
        var newestSavedAt = Date.distantPast
        for runFile in ownFiles(prefix: "run-", suffix: ".json") {
            let otherID = String(runFile.lastPathComponent.dropFirst(4).dropLast(5))
            guard otherID != runID, acquireLockIfOwnerExited(runID: otherID) else { continue }
            switch decodeEnvelope(at: runFile, expectedRunID: otherID) {
            case .success(var decoded):
                attach(incident, to: &decoded)
                if write(decoded, to: historyURL(for: otherID)), decoded.lastSavedHealthAt >= newestSavedAt {
                    newestSavedAt = decoded.lastSavedHealthAt
                    newest = .envelope(decoded)
                }
            case .failure(let reason):
                if case .none = newest { newest = .unreadable(reason) }
            }
            try? FileManager.default.removeItem(at: runFile)
            try? FileManager.default.removeItem(at: lockURL(for: otherID))
        }
        // Runs that never recorded (diagnostics off, early exit) leave only an unlocked lock file.
        for lockFile in ownFiles(prefix: "run-", suffix: ".lock") {
            let otherID = String(lockFile.lastPathComponent.dropFirst(4).dropLast(5))
            guard otherID != runID, acquireLockIfOwnerExited(runID: otherID) else { continue }
            try? FileManager.default.removeItem(at: lockFile)
        }
        let pinned: String? = if case .envelope(let envelope) = newest { envelope.runID } else { nil }
        applyRetention(pinnedRunID: pinned)
        if case .envelope = newest { return newest }
        if let retained = newestRetainedHistory() { return .envelope(retained) }
        return newest
    }

    // MARK: - Recording

    /// Starts periodic health checkpoints for this run if the lock was claimed.
    func startRecording() {
        queue.async { [self] in
            guard lockDescriptor >= 0, !recording else { return }
            recording = true
            writeHealth(cleanShutdown: false)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + limits.tickInterval, repeating: limits.tickInterval,
                           leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops recording and removes this run's envelope, so disabled diagnostics retain no new history.
    func stopRecording() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            recording = false
            envelope = nil
            try? FileManager.default.removeItem(at: runURL(for: runID))
        }
    }

    /// Replaces the last-known main-actor context. Never blocks on disk.
    func updateContext(_ context: PreviousRunOperatingContext) {
        contextLock.withLock { cachedContext = context }
    }

    /// Bounded final write marking a clean shutdown. A failed write leaves the run "not recorded".
    func recordCleanShutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            guard recording else { return }
            writeHealth(cleanShutdown: true)
            recording = false
        }
    }

    /// Forces a health write; used by tests and never needed by production callers.
    func recordHealthNow() {
        queue.sync { if recording { writeHealth(cleanShutdown: false) } }
    }

    /// Deletes finalized previous-run history. This run's active envelope is unaffected.
    func clearHistory(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            for file in ownFiles(prefix: "previous-", suffix: ".json") {
                try? FileManager.default.removeItem(at: file)
            }
            completion()
        }
    }

    private func tick() {
        guard recording else { return }
        let current = uptime()
        let elapsed = lastWriteUptime.map { current - $0 } ?? .infinity
        let admissionPaused = transport.snapshot().captureAdmission?.paused
        let errorCode = contextLock.withLock { cachedContext?.checkpointErrorCode }
        let transitioned = admissionPaused != lastWrittenAdmissionPaused || errorCode != lastWrittenErrorCode
        if elapsed >= limits.healthCadence || (transitioned && elapsed >= limits.transitionMinimumInterval) {
            writeHealth(cleanShutdown: false)
        }
    }

    private func writeHealth(cleanShutdown: Bool) {
        let date = now()
        let currentUptime = uptime()
        let metrics = metricsSampler.sample()
        let snapshot = transport.snapshot()
        let context = contextLock.withLock { cachedContext }
        var next = envelope ?? PreviousRunDiagnosticEnvelope(
            runID: runID, producerVersion: producerVersion, producerBuild: producerBuild,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            startedAt: startedAt, lastSavedHealthAt: date, startUptime: startUptime,
            lastSampleUptime: currentUptime, healthCadenceSeconds: limits.healthCadence)
        let footprint = metrics.physicalFootprintBytes > 0 ? metrics.physicalFootprintBytes : nil
        next.lastSavedHealthAt = date
        next.lastSampleUptime = currentUptime
        next.cleanShutdownRecorded = cleanShutdown
        next.lastPhysicalFootprintBytes = footprint
        if let footprint {
            next.sampledPeakPhysicalFootprintBytes = max(next.sampledPeakPhysicalFootprintBytes ?? 0, footprint)
        }
        next.processPeakResidentBytes = metrics.peakResidentMemoryBytes > 0 ? metrics.peakResidentMemoryBytes : nil
        next.lastCPUPercent = metrics.cpuPercent
        next.completedResponsesCumulative = snapshot.requestProgress[.responseComplete]?.count
        next.failedResponsesCumulative = snapshot.requestProgress[.responseFailed]?.count
        next.activeProxyChannels = snapshot.activeProxyChannels
        next.admission = snapshot.captureAdmission.map { admission in
            .init(paused: admission.paused, lastRejectionReasonCode: admission.lastRejectionReason?.rawValue,
                  reservedBytes: admission.reservedBytes, peakReservedBytes: admission.peakReservedBytes,
                  reservedLimitBytes: admission.byteLimit > 0 ? admission.byteLimit : nil,
                  collectingCount: admission.collectingCount, storeDeliveryCount: admission.storeDeliveryCount,
                  oldestPendingAgeSeconds: admission.oldestReservationAge, rejectedCaptures: admission.rejectedCaptures,
                  gapCount: admission.gaps.count, lastStoreDeliveryAt: admission.lastStoreDeliveryAt,
                  metadataOnlyCaptures: admission.metadataOnlyCaptures)
        }
        next.context = context
        next.recentSamples.append(.init(at: date, physicalFootprintBytes: footprint, cpuPercent: metrics.cpuPercent,
                                        admissionPaused: snapshot.captureAdmission?.paused))
        let overflow = next.recentSamples.count - PreviousRunDiagnosticEnvelope.maximumRecentSamples
        if overflow > 0 {
            next.recentSamples.removeFirst(overflow)
            next.omittedSampleCount += overflow
        }
        // Failed attempts also count toward the cadence so a full disk is not retried every tick.
        lastWriteUptime = currentUptime
        if write(next, to: runURL(for: runID)) {
            lastWrittenAdmissionPaused = snapshot.captureAdmission?.paused
            lastWrittenErrorCode = context?.checkpointErrorCode
        } else {
            next.failedWriteCount += 1
        }
        envelope = next
    }

    // MARK: - Files

    private func runURL(for id: String) -> URL { directory.appendingPathComponent("run-\(id).json") }
    private func lockURL(for id: String) -> URL { directory.appendingPathComponent("run-\(id).lock") }
    private func historyURL(for id: String) -> URL { directory.appendingPathComponent("previous-\(id).json") }

    private func ensureOwnedDirectory() -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        } catch {
            return false
        }
    }

    private func claimLock() -> Bool {
        if lockDescriptor >= 0 { return true }
        let descriptor = open(lockURL(for: runID).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    /// A run is finalized only when no live process holds its lock (PID reuse cannot fool this).
    private func acquireLockIfOwnerExited(runID other: String) -> Bool {
        let descriptor = open(lockURL(for: other).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    private func ownFiles(prefix: String, suffix: String) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private func readBounded(_ url: URL, limit: Int) -> Result<Data, PreviousRunUnreadableReason>? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        guard (values.fileSize ?? .max) <= limit else { return .failure(.oversized) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.malformed) }
        return .success(data)
    }

    private func decodeEnvelope(at url: URL, expectedRunID: String?) -> Result<PreviousRunDiagnosticEnvelope, PreviousRunUnreadableReason> {
        guard let read = readBounded(url, limit: limits.maximumEnvelopeBytes) else { return .failure(.malformed) }
        let data: Data
        switch read {
        case .success(let bytes): data = bytes
        case .failure(let reason): return .failure(reason)
        }
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? Self.decoder.decode(Version.self, from: data) else { return .failure(.malformed) }
        guard version.schemaVersion == PreviousRunDiagnosticEnvelope.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        guard let envelope = try? Self.decoder.decode(PreviousRunDiagnosticEnvelope.self, from: data),
              expectedRunID == nil || envelope.runID == expectedRunID else { return .failure(.malformed) }
        return .success(envelope)
    }

    private func readIncident() -> Result<ResponsivenessIncident, PreviousRunUnreadableReason>? {
        let url = incidentDirectory.appendingPathComponent(Self.incidentFileName)
        guard let read = readBounded(url, limit: limits.maximumIncidentBytes) else { return nil }
        switch read {
        case .success(let data):
            guard let incident = try? JSONDecoder().decode(ResponsivenessIncident.self, from: data) else {
                return .failure(.malformed)
            }
            return .success(incident)
        case .failure(let reason):
            return .failure(reason)
        }
    }

    private func attach(_ incident: Result<ResponsivenessIncident, PreviousRunUnreadableReason>?,
                        to envelope: inout PreviousRunDiagnosticEnvelope) {
        switch incident {
        case nil:
            envelope.incidentAssociation = PreviousRunIncidentAssociation.none
        case .failure?:
            envelope.incidentAssociation = .unreadable
        case .success(let value)?:
            if value.runID == envelope.runID {
                envelope.incidentAssociation = .correlated
                envelope.incident = .init(detectedAt: value.detectedAt, recoveredAt: value.recoveredAt,
                    maximumAcknowledgementDelaySeconds: value.onsetSamples.map(\.pendingSeconds).max())
            } else {
                envelope.incidentAssociation = value.runID == nil ? .uncorrelatedLegacy : .otherRun
            }
        }
    }

    private func write(_ envelope: PreviousRunDiagnosticEnvelope, to url: URL) -> Bool {
        var bounded = envelope
        guard var data = try? Self.encoder.encode(bounded) else { return false }
        while data.count > limits.maximumEnvelopeBytes, !bounded.recentSamples.isEmpty {
            let drop = max(1, bounded.recentSamples.count / 4)
            bounded.recentSamples.removeFirst(drop)
            bounded.omittedSampleCount += drop
            guard let smaller = try? Self.encoder.encode(bounded) else { return false }
            data = smaller
        }
        guard data.count <= limits.maximumEnvelopeBytes else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func newestRetainedHistory() -> PreviousRunDiagnosticEnvelope? {
        ownFiles(prefix: "previous-", suffix: ".json")
            .compactMap { try? decodeEnvelope(at: $0, expectedRunID: nil).get() }
            .max { $0.lastSavedHealthAt < $1.lastSavedHealthAt }
    }

    /// Age, count and byte limits over this store's own history files only. The pinned report
    /// survives rotation; it is deleted only if it alone exceeds the byte budget.
    private func applyRetention(pinnedRunID: String?) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let current = now()
        var history = ownFiles(prefix: "previous-", suffix: ".json").map { url -> (URL, Date, Int) in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        let pinnedName = pinnedRunID.map { "previous-\($0).json" }
        func isPinned(_ url: URL) -> Bool { url.lastPathComponent == pinnedName }

        history.removeAll { entry in
            guard !isPinned(entry.0), current.timeIntervalSince(entry.1) > limits.maximumAge else { return false }
            try? fileManager.removeItem(at: entry.0)
            return true
        }
        var kept = 0
        history.removeAll { entry in
            if isPinned(entry.0) { return false }
            kept += 1
            guard kept > limits.maximumHistoryFiles - (pinnedName == nil ? 0 : 1) else { return false }
            try? fileManager.removeItem(at: entry.0)
            return true
        }
        var total = history.reduce(0) { $0 + $1.2 } + ownActiveBytes()
        for entry in history.reversed() where total > limits.maximumTotalBytes && !isPinned(entry.0) {
            try? fileManager.removeItem(at: entry.0)
            total -= entry.2
        }
    }

    private func ownActiveBytes() -> Int {
        ownFiles(prefix: "run-", suffix: ".json").reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
