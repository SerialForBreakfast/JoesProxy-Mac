import Foundation

/// Best-effort, heuristic stall-risk detector based on rolling delivery-ratio thresholds (R3).
/// Every emitted `StallRiskEvent.recommendation` is prefixed "Heuristic: " — this signal must
/// never be presented as a guaranteed diagnosis.
actor StallRiskMonitor {
    private static let warningWindow = 10
    private static let sustainedCriticalWindow = 3
    private static let warningP75Threshold = 0.75
    private static let singleSegmentCriticalThreshold = 1.0
    private static let sustainedCriticalP75Threshold = 1.2

    /// Newest ratio last; capped at `warningWindow`.
    private var recentRatios: [Double] = []
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Records a segment's delivery ratio and returns a `StallRiskEvent` if any R3 threshold
    /// is crossed. Returns nil when delivery looks healthy.
    func record(ratio: Double) -> StallRiskEvent? {
        recentRatios.append(ratio)
        if recentRatios.count > Self.warningWindow {
            recentRatios.removeFirst(recentRatios.count - Self.warningWindow)
        }

        if ratio > Self.singleSegmentCriticalThreshold {
            return event(
                currentRatio: ratio,
                rollingP75: percentile75(of: recentRatios),
                severity: .critical,
                recommendation: "Heuristic: this segment took longer to download than to play; playback may stall."
            )
        }

        if recentRatios.count >= Self.sustainedCriticalWindow {
            let lastThree = Array(recentRatios.suffix(Self.sustainedCriticalWindow))
            let p75LastThree = percentile75(of: lastThree)
            if p75LastThree > Self.sustainedCriticalP75Threshold {
                return event(
                    currentRatio: ratio,
                    rollingP75: p75LastThree,
                    severity: .critical,
                    recommendation: "Heuristic: delivery has stayed above playback duration for the last 3 segments; a stall is likely."
                )
            }
        }

        if recentRatios.count >= Self.warningWindow {
            let p75 = percentile75(of: recentRatios)
            if p75 > Self.warningP75Threshold {
                return event(
                    currentRatio: ratio,
                    rollingP75: p75,
                    severity: .warning,
                    recommendation: "Heuristic: delivery margin is shrinking across recent segments; monitor for stalls."
                )
            }
        }

        return nil
    }

    /// Clears the rolling window. Call when a new playback session starts.
    func reset() {
        recentRatios = []
    }

    private func event(
        currentRatio: Double,
        rollingP75: Double,
        severity: StallRiskSeverity,
        recommendation: String
    ) -> StallRiskEvent {
        StallRiskEvent(
            timestamp: now(),
            currentDeliveryRatio: currentRatio,
            rollingP75DeliveryRatio: rollingP75,
            severity: severity,
            recommendation: recommendation
        )
    }

    private func percentile75(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((0.75 * Double(sorted.count)).rounded(.up)) - 1
        let clampedIndex = max(0, min(index, sorted.count - 1))
        return sorted[clampedIndex]
    }
}
