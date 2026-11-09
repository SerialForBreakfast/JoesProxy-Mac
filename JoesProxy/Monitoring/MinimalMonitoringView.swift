import SwiftUI

/// Host-agnostic HUD content — ADR §2c. Pure SwiftUI: no window/frame assumptions, no
/// `GeometryReader`-driven full-bleed layout (`TimelinePerformance.md` documents that failure mode
/// for views that must work at several sizes) — the one background `GeometryReader` here only
/// *measures* the already-settled content size for `onSizeChange`, it never participates in
/// layout. This is the piece a future compact-mode host would reuse unmodified inside a different
/// window.
struct MinimalMonitoringView: View {
    @ObservedObject var viewModel: MinimalMonitoringViewModel
    @Environment(\.appTextScale) private var textScale
    /// Reports the view's actual rendered size so a host (e.g. `CompactModeController`) can size
    /// its window to fit exactly, rather than guessing a fixed size.
    var onSizeChange: ((CGSize) -> Void)?
    /// Requests the independent app-owned approvals window without mounting the Inspector.
    /// `nil` hides the button in hosts without app-level presentation.
    var onOpenApprovals: (() -> Void)?
    /// Option A: click an active-effects tile (`tile.id`, e.g. `"mapLocal"`) to jump straight to
    /// where that category is managed — exits compact mode when the destination lives on the main
    /// window, or opens Settings directly when it doesn't need to. `nil` disables the interaction
    /// (e.g. tests, or a host with nowhere to navigate to).
    var onOpenActiveEffect: ((String) -> Void)?
    /// Option B: right-click an active-effects tile for a quick "turn it off" without leaving
    /// compact mode. A blunt, category-wide action deliberately — see the ADR discussion on why
    /// per-rule control from this passive HUD isn't offered. `nil` disables the interaction.
    var onDisableAllActiveEffect: ((String) -> Void)?
    var onManageModifications: (() -> Void)?
    var captureAdmissionBudget: CaptureAdmissionBudget?
    var uploadSpoolService: UploadSpoolService?

    var body: some View {
        VStack(spacing: 10) {
            // Grid and strip share a tighter 4pt gap than the standard 10pt used elsewhere — the
            // strip reads as a compact footer on the grid, not a third independent row, so it
            // shouldn't claim the same breathing room as the grid/controls boundary.
            VStack(spacing: 4) {
                MonitoringTileGrid(tiles: viewModel.tiles)
                resourceStrip
                activeEffectsStrip
            }
            controlsRow
            if let uploadSpoolService {
                UploadStorageNotice(service: uploadSpoolService).frame(width: 270 * textScale)
            }
            if let captureAdmissionBudget {
                CaptureAdmissionNotice(budget: captureAdmissionBudget)
                    .frame(width: 270 * textScale)
            }
            if let onManageModifications {
                Button("Manage Modifications…", action: onManageModifications)
                    .appFont(.body, scale: textScale)
                    .accessibilityIdentifier("compactManageModifications")
                    .help("Open Traffic Modifications in a separate window without leaving Compact mode.")
            }
        }
        .padding(12)
        .appFont(.caption, scale: textScale)
        .fixedSize()
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compactMonitorRoot")
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onSizeChange?(geometry.size) }
                    .onChange(of: geometry.size) { _, size in onSizeChange?(size) }
            }
        )
        .onAppear { viewModel.start() }
    }

    /// Retained bytes / resident memory / CPU as one compact row — `CaptureHealthStrip`'s own
    /// single-line indicator style, reused as-is rather than three more 40pt grid tiles, so this
    /// adds roughly one line of height to the panel instead of another grid row.
    private var resourceStrip: some View {
        HStack(spacing: 10) {
            ForEach(["retainedBytes", "memory", "cpu"], id: \.self) { id in
                let tile = viewModel.resourceTiles.first { $0.id == id }
                HealthMetricIndicator(systemImage: tile?.systemImage ?? "cpu", value: tile?.value ?? "—", level: tile?.level ?? .safe)
                    .frame(width: (id == "cpu" ? 54 : 96) * textScale, alignment: .leading)
                    .help("\(tile?.label ?? "CPU"): \(tile?.value ?? "Unavailable")")
                    .accessibilityLabel(tile?.label ?? "CPU")
                    .accessibilityValue(tile?.value ?? "Unavailable")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16 * textScale, alignment: .leading)
        .padding(.leading, 8) // aligns under the grid's own tile padding, not the outer edge
    }

    /// All ten currently-applied traffic modifications — answers "is JoesProxy changing what the
    /// client sees right now, and specifically how" at a glance, without opening the full UI or
    /// hunting through several separate surfaces. A 2-column grid (matching the tile grid's own
    /// 130pt columns, so this doesn't widen the panel) rather than one line, since ten labeled
    /// entries don't fit on a single row — this deliberately trades a taller panel for a complete,
    /// legible list instead of a terser one a person has to decode from icons alone.
    private var activeEffectsStrip: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(0..<((viewModel.activeEffectsTiles.count + 1) / 2), id: \.self) { row in
                GridRow {
                    ForEach(Array(viewModel.activeEffectsTiles.dropFirst(row * 2).prefix(2))) { tile in
                        activeEffectTile(tile)
                    }
                }
            }
        }
        .padding(.leading, 8)
    }

    private func activeEffectTile(_ tile: MonitoringTileDescriptor) -> some View {
        HStack(spacing: 4) {
            Image(systemName: tile.systemImage)
                .foregroundStyle(tile.level.color)
                .appFont(.caption2, scale: textScale)
                .frame(width: 12 * textScale)
            Text("\(Self.shortLabel(for: tile.id)) \(tile.value)")
                .foregroundStyle(tile.level.color)
                .appFont(.caption2, scale: textScale, design: .monospaced)
                .lineLimit(1)
        }
        .frame(width: 130 * textScale, height: 14 * textScale, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpenActiveEffect?(tile.id) }
        .contextMenu {
            Button(Self.disableActionTitle(for: tile.id)) {
                onDisableAllActiveEffect?(tile.id)
            }
            .disabled(tile.level != .caution) // nothing active to turn off
            Button("Open in JoesProxy…") { onOpenActiveEffect?(tile.id) }
        }
        .help("\(tile.label): \(tile.value) — click to open, right-click for quick actions")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.label)
        .accessibilityValue(tile.value)
        .accessibilityAction(named: "Open in JoesProxy") { onOpenActiveEffect?(tile.id) }
        .accessibilityAction(named: Text(Self.disableActionTitle(for: tile.id))) {
            onDisableAllActiveEffect?(tile.id)
        }
    }

    private static let toggleActiveEffectIDs: Set<String> = ["throttle", "tunnel"]

    private static func disableActionTitle(for tileID: String) -> String {
        toggleActiveEffectIDs.contains(tileID) ? "Turn off \(shortLabel(for: tileID))" : "Disable all \(shortLabel(for: tileID))"
    }

    /// Short enough to sit next to a 1-2 character value inside a 130pt column; the full name
    /// stays available via `.help()` and VoiceOver (`accessibilityLabel` above uses `tile.label`,
    /// not this).
    private static func shortLabel(for tileID: String) -> String {
        switch tileID {
        case "mapLocal": return "Local"
        case "mapRemote": return "Remote"
        case "block": return "Block"
        case "bookmarkRewrite": return "BM Rewrite"
        case "liveRewrite": return "Live RW"
        case "throttle": return "Throttle"
        case "hlsSubstitution": return "HLS Sub"
        case "openAPIMock": return "OpenAPI"
        case "syntheticInjection": return "Inject"
        case "tunnel": return "Tunnel"
        default: return tileID
        }
    }

    /// Mirrors the full toolbar's proxy toggle button exactly (`MainStatusTitleBar.swift`):
    /// `Label` icon+text, `.buttonStyle(.borderedProminent)`, `.controlSize(.small)`, tinted by
    /// run state. Title/icon/tint come pre-computed from `controlsState` so this view has no
    /// dependency on the underlying state types — see `MinimalMonitoringControlsState`.
    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.toggleProxy()
            } label: {
                Label {
                    Text(viewModel.controlsState.proxyButtonTitle)
                } icon: {
                    if viewModel.controlsState.isProxyTransitioning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: viewModel.controlsState.proxyButtonIcon)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.controlsState.proxyButtonTint)
            .disabled(
                viewModel.controlsState.isProxyTransitioning
                    || (!viewModel.controlsState.canStartProxy && !viewModel.controlsState.canStopProxy)
            )
            .accessibilityIdentifier("proxyToggleButton")
            .accessibilityValue(viewModel.controlsState.isProxyTransitioning ? "transitioning" : (viewModel.controlsState.isProxyRunning ? "running" : "stopped"))

            Button {
                viewModel.toggleMCP()
            } label: {
                Label(viewModel.controlsState.mcpButtonTitle, systemImage: viewModel.controlsState.mcpButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.controlsState.mcpButtonTint)
            .disabled(!viewModel.controlsState.canStartMCP && !viewModel.controlsState.canStopMCP)
            .accessibilityIdentifier("compactMCPToggleButton")
            .accessibilityValue(viewModel.controlsState.mcpButtonTitle)
            .accessibilityHint("Starts MCP when stopped, or stops the current MCP service before retrying.")

            if let onOpenApprovals {
                Button(action: onOpenApprovals) {
                    Label("Approvals", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens the pending MCP approvals window without leaving compact mode")
                .accessibilityIdentifier("compactApprovalsButton")
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }
}
