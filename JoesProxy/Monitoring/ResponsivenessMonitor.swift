import Foundation
import os

/// Pure monotonic-clock detector. A monitor scheduling gap is not evidence of a UI stall.
struct ResponsivenessDetector {
    enum Event: Equatable { case delayed, delayRecovered, stalled, recovered }
    private(set) var pendingSince: TimeInterval?
    private(set) var isStalled = false
    private var delayReported = false
    private var previousTick: TimeInterval?

    mutating func tick(at now: TimeInterval) -> (event: Event?, shouldPing: Bool, invalidated: Bool) {
        let gap = previousTick.map { now < $0 || now - $0 > 3 } ?? false
        previousTick = now
        if gap {
            pendingSince = nil
            isStalled = false
            delayReported = false
        }
        if pendingSince == nil {
            pendingSince = now
            return (nil, true, gap)
        }
        if !isStalled, now - (pendingSince ?? now) >= 5 {
            isStalled = true
            return (.stalled, false, gap)
        }
        if !delayReported, now - (pendingSince ?? now) >= 1 {
            delayReported = true
            return (.delayed, false, gap)
        }
        return (nil, false, gap)
    }

    mutating func acknowledge() -> Event? {
        let event: Event? = isStalled ? .recovered : (delayReported ? .delayRecovered : nil)
        pendingSince = nil
        isStalled = false
        delayReported = false
        return event
    }
}

struct ResponsivenessSample: Codable, Equatable, Sendable {
    struct Progress: Codable, Equatable, Sendable {
        let stage: String
        let count: UInt64
        let lastObservedAt: Date?
    }
    let at: Date
    let pendingSeconds: TimeInterval
    let physicalFootprintBytes: UInt64
    let cpuPercent: Double?
    let activeChannels: Int
    let capturePending: Int
    let captureRejected: Int
    let progress: [Progress]
    var captureReservedBytes: Int? = nil
    var captureStoreDelivery: Int? = nil
    var captureAdmissionPaused: Bool? = nil
}

struct ResponsivenessIncident: Codable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let detectedAt: Date
    var recoveredAt: Date?
    let onsetSamples: [ResponsivenessSample]
    var runID: String? = nil
}

/// One latest local incident; no append-only history, request content, or automatic upload.
struct ResponsivenessIncidentStore: Sendable {
    let directory: URL
    static let maximumBytes = 128 * 1_024

    func save(_ incident: ResponsivenessIncident) throws {
        let data = try JSONEncoder().encode(incident)
        guard data.count <= Self.maximumBytes, incident.onsetSamples.count <= 30 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("latest-responsiveness-incident.json"), options: .atomic)
    }

    func loadLatest() -> ResponsivenessIncident? {
        let fileURL = directory.appendingPathComponent("latest-responsiveness-incident.json")
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumBytes,
              let incident = try? JSONDecoder().decode(ResponsivenessIncident.self, from: data) else {
            return nil
        }
        return incident
    }
}

/// All mutable state and the dedicated metrics sampler are confined to queue. The only main-queue
/// operation is an acknowledgement. Weak callbacks avoid keeping the app-owned monitor alive.
final class ResponsivenessMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.joesproxyapp.responsiveness", qos: .utility)
    private let diagnostics: CaptureTransportDiagnostics
    private let store: ResponsivenessIncidentStore
    private let appVersion: String
    private let runID: String?
    private let sampler = CurrentProcessMetricsSampler()
    private let logger = Logger(subsystem: "com.joesproxyapp", category: "Responsiveness")
    private var timer: DispatchSourceTimer?
    private var detector = ResponsivenessDetector()
    private var samples: [ResponsivenessSample] = []
    private var incident: ResponsivenessIncident?
    private var pingGeneration: UInt64 = 0
    // Remains set through scheduling gaps so repeated gaps cannot queue unlimited main callbacks.
    private var pingOutstanding = false
    private var lastShortIncidentPersisted: TimeInterval = -.infinity

    init(diagnostics: CaptureTransportDiagnostics, store: ResponsivenessIncidentStore, appVersion: String, runID: String? = nil) {
        self.diagnostics = diagnostics
        self.store = store
        self.appVersion = appVersion
        self.runID = runID
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    deinit { timer?.cancel() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let result = detector.tick(at: now)
        if result.invalidated {
            samples.removeAll(keepingCapacity: true)
            incident = nil
            pingGeneration &+= 1
        }
        let metrics = sampler.sample()
        let transport = diagnostics.snapshot()
        samples.append(.init(at: Date(), pendingSeconds: max(0, now - (detector.pendingSince ?? now)),
            physicalFootprintBytes: metrics.physicalFootprintBytes, cpuPercent: metrics.cpuPercent,
            activeChannels: transport.activeProxyChannels,
            capturePending: transport.captureAdmission?.pendingCaptures ?? 0,
            captureRejected: transport.captureAdmission?.rejectedCaptures ?? 0,
            progress: CaptureRequestProgressStage.allCases.map { stage in
                let value = transport.requestProgress[stage, default: CaptureRequestProgress()]
                return .init(stage: stage.rawValue, count: value.count, lastObservedAt: value.lastObservedAt)
            }, captureReservedBytes: transport.captureAdmission?.reservedBytes,
            captureStoreDelivery: transport.captureAdmission?.storeDeliveryCount,
            captureAdmissionPaused: transport.captureAdmission?.paused))
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
        if result.event == .delayed || result.event == .stalled {
            incident = .init(schemaVersion: 1, appVersion: appVersion, detectedAt: Date(),
                recoveredAt: nil, onsetSamples: samples, runID: runID)
            if result.event == .stalled { persistIncident() }
        }
        if result.shouldPing, !pingOutstanding {
            pingOutstanding = true
            let generation = pingGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.pingOutstanding = false
                    let event = self.detector.acknowledge()
                    let recovered = event == .recovered || event == .delayRecovered
                    if generation != self.pingGeneration {
                        self.detector = ResponsivenessDetector()
                    }
                    if recovered, generation == self.pingGeneration {
                        self.incident?.recoveredAt = Date()
                        let now = ProcessInfo.processInfo.systemUptime
                        if event == .recovered || now - self.lastShortIncidentPersisted >= 10 {
                            self.persistIncident()
                            self.lastShortIncidentPersisted = now
                        }
                    }
                }
            }
        }
    }

    private func persistIncident() {
        guard let incident else { return }
        do { try store.save(incident) }
        catch { logger.error("Responsiveness incident could not be saved; capture and routing are unchanged.") }
    }
}
