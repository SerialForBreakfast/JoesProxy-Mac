import Foundation

/// Wall time is descriptive; process-wide uptime aligns evidence despite wall-clock corrections.
struct CaptureObservationInstant: Codable, Equatable, Sendable {
    let date: Date
    let uptime: TimeInterval

    static func now() -> Self {
        .init(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }
}
