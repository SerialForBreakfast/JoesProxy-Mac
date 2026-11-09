import SwiftUI

/// One tile's rendered content — label, icon, formatted value, and health color. Reuses
/// `HealthLevel` from `CaptureHealthStrip.swift` rather than a second color scheme.
///
/// `id` is stable per logical stat (not per value) so `MinimalMonitoringViewModel` can key its
/// color-dwell debounce state by it, and so `MonitoringTileGrid` never treats a value change as a
/// different tile.
struct MonitoringTileDescriptor: Identifiable, Equatable {
    let id: String
    let label: String
    let systemImage: String
    let value: String
    let level: HealthLevel
}

/// Fixed, data-driven tile grid — see ADR §2c/§6. The tile *count* and *position* never change
/// based on data: callers always pass the full fixed set, using "—" as a tile's `value` when a
/// stat is unavailable, so the grid never reflows. This is the one renderer any future host
/// (compact mode or otherwise) reuses rather than re-implementing tile layout.
struct MonitoringTileGrid: View {
    let tiles: [MonitoringTileDescriptor]
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        // All eight tiles are visible. Eager rows avoid lazy height estimates during refresh.
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<((tiles.count + 1) / 2), id: \.self) { row in
                GridRow {
                    ForEach(Array(tiles.dropFirst(row * 2).prefix(2))) { tile in
                        MonitoringTileView(tile: tile).frame(width: 130 * textScale)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct MonitoringTileView: View {
    let tile: MonitoringTileDescriptor
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(tile.label, systemImage: tile.systemImage)
                .accessibilityIdentifier("monitoringTileLabel-\(tile.id)")
                .appFont(.caption2, scale: textScale)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14 * textScale, alignment: .leading)
            Text(tile.value)
                .accessibilityIdentifier("monitoringTileValue-\(tile.id)")
                .font(.system(size: 15 * textScale, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tile.level.color)
                .lineLimit(1)
                .frame(height: 20 * textScale, alignment: .leading)
                // No `.animation()` here — a value replaces the prior value at the refresh tick,
                // never counts up or cross-fades (ADR §6: no motion).
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40 * textScale, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
