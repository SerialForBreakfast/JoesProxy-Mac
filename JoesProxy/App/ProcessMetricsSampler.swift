import Darwin
import Foundation

/// Process-level runtime health metrics for the current JoesProxy process.
struct AppProcessMetrics: Equatable, Sendable {
    /// CPU percentage where 100% represents one fully utilized core.
    let cpuPercent: Double?
    /// Instantaneous physical memory footprint in bytes (`phys_footprint`).
    let physicalFootprintBytes: UInt64
    /// Process lifetime peak resident set size in bytes (`ru_maxrss`).
    let peakResidentMemoryBytes: UInt64
    /// Resident memory footprint in bytes for telemetry. Uses physical footprint if available, otherwise peak RSS.
    var residentMemoryBytes: UInt64 { physicalFootprintBytes > 0 ? physicalFootprintBytes : peakResidentMemoryBytes }

    init(cpuPercent: Double?, physicalFootprintBytes: UInt64, peakResidentMemoryBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
    }

    init(cpuPercent: Double?, residentMemoryBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.physicalFootprintBytes = residentMemoryBytes
        self.peakResidentMemoryBytes = residentMemoryBytes
    }

    static let empty = AppProcessMetrics(cpuPercent: nil, physicalFootprintBytes: 0, peakResidentMemoryBytes: 0)
}

protocol ProcessMetricsSampling: AnyObject {
    func sample() -> AppProcessMetrics
}

/// Samples the current process metrics using `task_info` for instantaneous `phys_footprint`
/// and `getrusage` for CPU time and peak lifetime RSS.
final class CurrentProcessMetricsSampler: ProcessMetricsSampling {
    private var previousCPUTimeSeconds: Double?
    private var previousSampleUptime: TimeInterval?

    func sample() -> AppProcessMetrics {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return .empty
        }

        let peakResidentMemoryBytes = UInt64(max(0, usage.ru_maxrss))
        let physicalFootprintBytes = currentPhysicalFootprintBytes() ?? peakResidentMemoryBytes
        let now = ProcessInfo.processInfo.systemUptime
        let currentCPUTimeSeconds = seconds(from: usage.ru_utime) + seconds(from: usage.ru_stime)

        let cpuPercent: Double?
        if let previousCPUTimeSeconds,
           let previousSampleUptime {
            let elapsed = now - previousSampleUptime
            let cpuDelta = currentCPUTimeSeconds >= previousCPUTimeSeconds
                ? currentCPUTimeSeconds - previousCPUTimeSeconds
                : 0

            if elapsed > 0 {
                cpuPercent = max(0, (cpuDelta / elapsed) * 100)
            } else {
                cpuPercent = nil
            }
        } else {
            cpuPercent = nil
        }

        previousCPUTimeSeconds = currentCPUTimeSeconds
        previousSampleUptime = now

        return AppProcessMetrics(
            cpuPercent: cpuPercent,
            physicalFootprintBytes: physicalFootprintBytes,
            peakResidentMemoryBytes: peakResidentMemoryBytes
        )
    }

    private func currentPhysicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    private func seconds(from timeval: Darwin.timeval) -> Double {
        Double(timeval.tv_sec) + (Double(timeval.tv_usec) / 1_000_000)
    }
}
