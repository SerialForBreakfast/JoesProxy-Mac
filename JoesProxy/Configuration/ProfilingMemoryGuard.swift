import Darwin
import Foundation
import Network
import MachO
import AppKit

/// Only the isolated synthetic profiling launch may enable the self-sampler.
struct ProfilingMemoryGuardConfiguration: Equatable {
    static let ceiling: UInt64 = 1_610_612_736
    let port: UInt16
    let token: String
    let limit: UInt64

    init?(arguments: [String], environment: [String: String], isolated: Bool) {
        guard isolated, arguments.contains("--ui-test-memory-guard"),
              arguments.contains("--ui-test-suppress-launch-recovery"),
              let rawPort = environment["JOESPROXY_PROFILE_METRICS_PORT"],
              let port = UInt16(rawPort), port > 0,
              let token = environment["JOESPROXY_PROFILE_METRICS_TOKEN"],
              UUID(uuidString: token) != nil else { return nil }
        self.port = port
        self.token = token
        limit = arguments.contains("--ui-test-memory-cutoff-probe") ? 1 : Self.ceiling
    }

    func stopExitCode(footprint: UInt64?) -> Int32? {
        guard let footprint, footprint > 0 else { return 77 }
        return footprint >= limit ? 78 : nil
    }
}

/// Timer, connection and mutable state are confined to a dedicated serial queue. No UI work,
/// body data, disk writes, or unbounded send queue. Lifetime is the isolated test app's lifetime.
final class ProfilingMemoryGuard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "joesproxy.profiling.memory-guard")
    private let configuration: ProfilingMemoryGuardConfiguration
    private let connection: NWConnection
    private var timer: DispatchSourceTimer?
    private var sendPending = false
    private let instrumentationLoaded: Bool
    private let trackingProbeEnabled = ProcessInfo.processInfo.arguments.contains("--ui-test-tracking-probe")
    private var captureDiagnostics: CaptureTransportDiagnostics?
    private var mainProbeStarted: TimeInterval?
    private var lastMainProbe: TimeInterval = 0
    private var mainProbeSeconds: Double = 0
    private var trackingAreas = 0
    private var inspectedViews = 0
    private var trackingTruncated = false
    private var windowSizing: [String: Double] = [:]
    private var pressureSource: DispatchSourceMemoryPressure?

    func attachCaptureDiagnostics(_ diagnostics: CaptureTransportDiagnostics) {
        queue.async { [self] in captureDiagnostics = diagnostics }
    }

    init(configuration: ProfilingMemoryGuardConfiguration) {
        self.configuration = configuration
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuration.port)!, using: .udp)
        instrumentationLoaded = (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            let path = String(cString: name).lowercased()
            return ["libclang_rt.asan", "libclang_rt.tsan", "libclang_rt.ubsan", "libmainthreadchecker",
                    "libthreadperformancechecker"].contains { path.contains($0) }
        }
    }

    func start() {
        queue.async { [self] in
            connection.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
            if trackingProbeEnabled {
                let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
                pressure.setEventHandler { _exit(80) }
                pressureSource = pressure
                pressure.resume()
            }
        }
    }

    private func sample() {
        let uptime = ProcessInfo.processInfo.systemUptime
        if trackingProbeEnabled, captureDiagnostics != nil {
            if let started = mainProbeStarted, uptime - started > 5 { _exit(79) }
            if mainProbeStarted == nil, uptime - lastMainProbe >= 5 {
                mainProbeStarted = uptime
                lastMainProbe = uptime
                Task { @MainActor [weak self] in
                    let snapshot = Self.trackingSnapshot()
                    let sizing = Self.windowSizingSnapshot()
                    let elapsed = ProcessInfo.processInfo.systemUptime - uptime
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        mainProbeSeconds = elapsed
                        trackingAreas = snapshot.areas
                        inspectedViews = snapshot.views
                        trackingTruncated = snapshot.truncated
                        windowSizing = sizing
                        mainProbeStarted = nil
                    }
                }
            }
        }
        var usage = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &usage) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        let footprint = result == 0 ? usage.ri_phys_footprint : nil
        // Hard exit is intentional only for this disposable, non-persistent test process.
        // It remains effective when the main thread is hung. XCTest treats its loss as failure.
        if let exitCode = configuration.stopExitCode(footprint: footprint) {
            _exit(exitCode)
        }
        guard !sendPending else { return }
        var record: [String: Any] = [
            "token": configuration.token, "pid": getpid(),
            "instrumentationLoaded": instrumentationLoaded,
            "sampleUptime": ProcessInfo.processInfo.systemUptime,
            "physicalFootprintBytes": usage.ri_phys_footprint,
            "residentBytes": usage.ri_resident_size,
            "diskBytesRead": usage.ri_diskio_bytesread,
            "diskBytesWritten": usage.ri_diskio_byteswritten,
            "userCPUTimeNanoseconds": usage.ri_user_time,
            "systemCPUTimeNanoseconds": usage.ri_system_time
        ]
        record["interruptWakeups"] = usage.ri_interrupt_wkups
        record["idleWakeups"] = usage.ri_pkg_idle_wkups
        if trackingProbeEnabled {
            record["mainProbeSeconds"] = mainProbeSeconds
            record["trackingAreas"] = trackingAreas
            record["trackingViews"] = inspectedViews
            record["trackingTruncated"] = trackingTruncated
            record["windowSizing"] = windowSizing
            if let admission = captureDiagnostics?.snapshot().captureAdmission {
                record["captureReservedBytes"] = admission.reservedBytes
                record["capturePending"] = admission.pendingCaptures
                record["captureRejected"] = admission.rejectedCaptures
                record["captureMetadataOnly"] = admission.metadataOnlyCaptures
                record["capturePaused"] = admission.paused
                record["captureStoreDelivery"] = admission.storeDeliveryCount
            }
        }
        if let profile = AgentWorkspaceProfileMetrics.shared.snapshot(),
           let encoded = try? JSONEncoder().encode(profile),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            record["agentProfile"] = object
        }
        if let diagnostics = AgentWorkspaceDiagnostics.shared.currentSnapshot() {
            record["agentWorkspaceDiagnostics"] = [
                "inspectorModelConstructionCount": diagnostics.inspectorModelConstructionCount,
                "inspectorModelReleaseCount": diagnostics.inspectorModelReleaseCount,
                "inspectorSubscriptionCount": diagnostics.inspectorSubscriptionCount,
                "inspectorPresentationActivationCount": diagnostics.inspectorPresentationActivationCount,
                "inspectorPresentationDeactivationCount": diagnostics.inspectorPresentationDeactivationCount,
                "explicitAgentAnalysisCount": diagnostics.explicitAgentAnalysisCount
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record), data.count <= 2048 else { _exit(77) }
        sendPending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.sendPending = false
        })
    }

    /// Opt-in, metadata-only window constraints distinguish failed pointer targeting from a size lock.
    @MainActor
    private static func windowSizingSnapshot() -> [String: Double] {
        guard let window = MainWindowLookup.firstMainWindow() else { return [:] }
        return ["width": window.frame.width, "height": window.frame.height,
                "minWidth": window.minSize.width, "minHeight": window.minSize.height,
                "maxWidth": window.maxSize.width, "maxHeight": window.maxSize.height,
                "resizable": window.styleMask.contains(.resizable) ? 1 : 0]
    }

    /// Opt-in checkpoint only. Counts AppKit's public tracking areas, never private graph nodes.
    @MainActor
    private static func trackingSnapshot() -> (areas: Int, views: Int, truncated: Bool) {
        let maximum = 10_000
        var pending = Array(NSApp.windows.prefix(16).compactMap(\.contentView))
        var views = 0
        var areas = 0
        var truncated = NSApp.windows.count > 16
        while let view = pending.popLast() {
            views += 1
            areas += view.trackingAreas.count
            let available = max(0, maximum - views - pending.count)
            let children = view.subviews
            if children.count > available { truncated = true }
            pending.append(contentsOf: children.prefix(available))
        }
        return (areas, views, truncated)
    }
}
