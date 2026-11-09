import SwiftUI

// MARK: - HealthLevel

enum HealthLevel: Equatable {
    case safe
    case caution
    case critical

    init(fraction: Double) {
        if fraction > 1.0 { self = .critical }
        else if fraction >= 0.75 { self = .caution }
        else { self = .safe }
    }

    var color: Color {
        switch self {
        case .safe:     return .green
        case .caution:  return .yellow
        case .critical: return .red
        }
    }
}

// MARK: - HealthMetricIndicator

/// One small icon+value indicator, colored by `HealthLevel`. Internal (not `private`) so
/// `MinimalMonitoringView` can reuse the exact same compact look for its resource strip rather
/// than maintaining a second version of this styling.
struct HealthMetricIndicator: View {
    let systemImage: String
    let value: String
    let level: HealthLevel
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        Label(value, systemImage: systemImage)
            .foregroundStyle(level.color)
            .appFont(.caption, scale: textScale, design: .monospaced)
            .lineLimit(1)
    }
}

// MARK: - CaptureHealthStrip

enum CaptureHealthStripStyle {
    case standalone
    case inline
}

struct CaptureHealthStrip: View {
    let captureHealth: CaptureHealthMetrics
    var style: CaptureHealthStripStyle = .standalone

    private let thresholds = CaptureHealthThresholds.standard
    @State private var stripWidth: CGFloat = 800

    var body: some View {
        if captureHealth.hasCaptureSessionFootprint {
            Group {
                if style == .inline {
                    metricsRow(spacing: 10, includeSpacer: false)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .clipped()
                } else if stripWidth < CompactLayout.compactToolbarWidth {
                    ScrollView(.horizontal, showsIndicators: false) {
                        metricsRow(spacing: 10, includeSpacer: true)
                    }
                } else {
                    metricsRow(spacing: 14, includeSpacer: true)
                }
            }
            .reportViewWidth { stripWidth = $0 }
            .modifier(CaptureHealthStripContainerStyle(style: style))
        }
    }

    private func metricsRow(spacing: CGFloat, includeSpacer: Bool) -> some View {
        HStack(spacing: spacing) {
            if let duration = captureHealth.captureDuration {
                HealthMetricIndicator(
                    systemImage: "clock",
                    value: CaptureHealthFormatting.formattedDuration(duration),
                    level: HealthLevel(fraction: duration / thresholds.captureDuration)
                )
            }

            HealthMetricIndicator(
                systemImage: "list.bullet",
                value: captureHealth.sessionCount.formatted(),
                level: HealthLevel(fraction: Double(captureHealth.sessionCount) / Double(thresholds.sessionCount))
            )

            HealthMetricIndicator(
                systemImage: "internaldrive",
                value: ByteCountFormatter.string(fromByteCount: Int64(captureHealth.retainedBodyBytes), countStyle: .memory),
                level: HealthLevel(fraction: Double(captureHealth.retainedBodyBytes) / Double(thresholds.retainedBodyBytes))
            )

            HealthMetricIndicator(
                systemImage: "memorychip",
                value: ByteCountFormatter.string(fromByteCount: Int64(captureHealth.processMetrics.residentMemoryBytes), countStyle: .memory),
                level: HealthLevel(fraction: Double(captureHealth.processMetrics.residentMemoryBytes) / Double(thresholds.residentMemoryBytes))
            )

            if let cpu = captureHealth.processMetrics.cpuPercent {
                HealthMetricIndicator(
                    systemImage: "cpu",
                    value: String(format: "%.0f%%", cpu),
                    level: HealthLevel(fraction: cpu / thresholds.cpuPercent)
                )
            }

            if includeSpacer {
                Spacer(minLength: 0)
            }
        }
    }

}

/// Shared formatting helpers for capture-health values — used by `CaptureHealthStrip` and by
/// `MinimalMonitoringView` (Monitoring/) so both surfaces render duration identically rather than
/// maintaining two implementations that could drift.
enum CaptureHealthFormatting {
    static func formattedDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

private struct CaptureHealthStripContainerStyle: ViewModifier {
    let style: CaptureHealthStripStyle
    @Environment(\.appTextScale) private var textScale

    func body(content: Content) -> some View {
        switch style {
        case .standalone:
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxHeight: 28 * textScale)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) {
                    Divider()
                }
        case .inline:
            content
                .frame(maxHeight: 22 * textScale)
        }
    }
}
