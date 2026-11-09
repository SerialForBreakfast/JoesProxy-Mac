import SwiftUI

enum MainTitleBarLayoutMode: Equatable {
    case full
    case compact
    case minimal

    init(width: CGFloat, textScale: CGFloat = 1) {
        let readableWidth = width / max(textScale, 1)
        if readableWidth < 760 {
            self = .minimal
        } else if readableWidth < 1_080 {
            self = .compact
        } else {
            self = .full
        }
    }

    var showsBadgeTitles: Bool {
        self == .full
    }

    var healthMetricsWidth: CGFloat {
        switch self {
        case .full:
            return 360
        case .compact:
            return 210
        case .minimal:
            return 120
        }
    }
}

/// One glanceable answer to "is the capture pipeline healthy, and if not, what do I click?"
/// Derived from the proxy runtime, certificate workflow, and HTTPS mode so the title bar
/// can show a single actionable status instead of three pills with independent vocabularies.
struct CapturePipelineStatus: Equatable {
    enum Tone: Equatable {
        case healthy
        case attention
        case problem
        case idle

        var color: Color {
            switch self {
            case .healthy: return .green
            case .attention: return .orange
            case .problem: return .red
            case .idle: return .secondary
            }
        }
    }

    enum ClickSurface: Equatable {
        case proxyHelp
        case certificateSetup
        case httpsRules
    }

    /// Short actionable label, e.g. "Capturing · HTTPS inspected".
    let label: String
    /// Longer explanation for tooltip/accessibility; carries failure messages.
    let detail: String?
    let systemImage: String
    let tone: Tone
    /// Which existing surface a click should open.
    let clickSurface: ClickSurface
    /// True only while the proxy is actively accepting traffic.
    let isCapturing: Bool
}

enum MainTitleBarFormatter {

    static func pipelineStatus(
        proxyState: ProxyRuntimeState,
        certificateWorkflowState: ProxyViewModel.CertificateWorkflowState,
        httpsProxyMode: HTTPSProxyMode
    ) -> CapturePipelineStatus {
        switch proxyState {
        case .starting:
            return CapturePipelineStatus(
                label: "Starting capture…",
                detail: "The proxy listener is starting.",
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tone: .idle,
                clickSurface: .proxyHelp,
                isCapturing: false
            )

        case .stopping:
            return CapturePipelineStatus(
                label: "Stopping…",
                detail: "The proxy listener is shutting down.",
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tone: .idle,
                clickSurface: .proxyHelp,
                isCapturing: false
            )

        case .failed(let message):
            return CapturePipelineStatus(
                label: "Capture failed",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                tone: .problem,
                clickSurface: .proxyHelp,
                isCapturing: false
            )

        case .stopped:
            switch certificateWorkflowState {
            case .ready:
                return CapturePipelineStatus(
                    label: "Ready to capture",
                    detail: "Press Start to begin capturing traffic.",
                    systemImage: "bolt.horizontal.circle",
                    tone: .idle,
                    clickSurface: .proxyHelp,
                    isCapturing: false
                )
            case .needsCleanup:
                return CapturePipelineStatus(
                    label: "Certificate needs repair",
                    detail: "The stored certificate is invalid. Open setup to repair it before capturing HTTPS.",
                    systemImage: "xmark.shield.fill",
                    tone: .problem,
                    clickSurface: .certificateSetup,
                    isCapturing: false
                )
            case .installedTrustRequired, .notSetUp:
                return CapturePipelineStatus(
                    label: "Set up HTTPS to capture",
                    detail: "HTTPS traffic can't be inspected until the JoesProxy certificate is installed and trusted.",
                    systemImage: "shield",
                    tone: .attention,
                    clickSurface: .certificateSetup,
                    isCapturing: false
                )
            }

        case .running:
            switch certificateWorkflowState {
            case .installedTrustRequired:
                return CapturePipelineStatus(
                    label: "Capturing · cert not trusted — HTTPS tunneled",
                    detail: "The certificate is installed but not trusted, so HTTPS is tunneled without inspection. Open certificate setup to fix trust.",
                    systemImage: "exclamationmark.shield.fill",
                    tone: .attention,
                    clickSurface: .certificateSetup,
                    isCapturing: true
                )
            case .needsCleanup:
                return CapturePipelineStatus(
                    label: "Capturing · certificate needs repair",
                    detail: "The stored certificate is invalid, so HTTPS is not inspected. Open certificate setup to repair it.",
                    systemImage: "xmark.shield.fill",
                    tone: .problem,
                    clickSurface: .certificateSetup,
                    isCapturing: true
                )
            case .notSetUp:
                return CapturePipelineStatus(
                    label: "Capturing · HTTP only — set up HTTPS",
                    detail: "No certificate is set up, so only plain HTTP is inspected. Open setup to enable HTTPS inspection.",
                    systemImage: "shield",
                    tone: .attention,
                    clickSurface: .certificateSetup,
                    isCapturing: true
                )
            case .ready:
                switch httpsProxyMode {
                case .intercepting:
                    return CapturePipelineStatus(
                        label: "Capturing · HTTPS inspected",
                        detail: "Traffic is being captured and HTTPS is decrypted for inspection.",
                        systemImage: "lock.shield.fill",
                        tone: .healthy,
                        clickSurface: .httpsRules,
                        isCapturing: true
                    )
                case .passThrough:
                    return CapturePipelineStatus(
                        label: "Capturing · HTTPS tunneled",
                        detail: "HTTPS is passed through without inspection. Open HTTPS rules to intercept it.",
                        systemImage: "lock.open.trianglebadge.exclamationmark",
                        tone: .attention,
                        clickSurface: .httpsRules,
                        isCapturing: true
                    )
                }
            }
        }
    }

    static func runtimeTitle(for state: ProxyRuntimeState) -> String {
        switch state {
        case .running:
            return "Running"
        case .starting:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Failed"
        case .stopped:
            return "Stopped"
        }
    }

    static func runtimeButtonTitle(canStartProxy: Bool) -> String {
        canStartProxy ? "Start" : "Stop"
    }

    static func runtimeButtonTitle(state: ProxyRuntimeState, canStartProxy: Bool) -> String {
        switch state {
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        default: return runtimeButtonTitle(canStartProxy: canStartProxy)
        }
    }

    static func runtimeButtonIcon(canStartProxy: Bool) -> String {
        canStartProxy ? "play.fill" : "stop.fill"
    }

    static func runtimeStatusValue(state: ProxyRuntimeState, port: UInt16) -> String {
        "\(runtimeTitle(for: state)) · \(port)"
    }

    static func runtimeIconName(for state: ProxyRuntimeState) -> String {
        switch state {
        case .running:
            return "bolt.horizontal.circle.fill"
        case .starting, .stopping:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "bolt.horizontal.circle"
        }
    }

    static func runtimeTint(for state: ProxyRuntimeState) -> Color {
        switch state {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    static func certificateTitle(for state: ProxyViewModel.CertificateWorkflowState) -> String {
        switch state {
        case .ready:
            // "Trusted" describes the certificate itself; "Inspecting" clashed with the
            // HTTPS pill's vocabulary and read as contradictory next to "HTTPS Inactive".
            return "Trusted"
        case .installedTrustRequired:
            return "Trust"
        case .needsCleanup:
            return "Repair"
        case .notSetUp:
            return "Setup"
        }
    }

    static func certificateIconName(for state: ProxyViewModel.CertificateWorkflowState) -> String {
        switch state {
        case .ready:
            return "checkmark.shield.fill"
        case .installedTrustRequired:
            return "exclamationmark.shield.fill"
        case .needsCleanup:
            return "xmark.shield.fill"
        case .notSetUp:
            return "shield"
        }
    }

    static func certificateTint(for state: ProxyViewModel.CertificateWorkflowState) -> Color {
        switch state {
        case .ready:
            return .green
        case .installedTrustRequired:
            return .orange
        case .needsCleanup:
            return .red
        case .notSetUp:
            return .secondary
        }
    }

    static func httpsTitle(proxyState: ProxyRuntimeState, mode: HTTPSProxyMode) -> String {
        switch proxyState {
        case .stopped:
            return "Off"
        case .starting:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Unavailable"
        case .running:
            // Matches SetupVerificationState vocabulary ("inspected"/"tunneled").
            switch mode {
            case .intercepting:
                return "Inspected"
            case .passThrough:
                return "Tunneled"
            }
        }
    }

    static func httpsIconName(proxyState: ProxyRuntimeState, mode: HTTPSProxyMode) -> String {
        switch proxyState {
        case .running:
            return mode == .intercepting ? "lock.shield.fill" : "lock.open.trianglebadge.exclamationmark"
        case .starting, .stopping:
            return "arrow.triangle.2.circlepath.circle"
        case .failed:
            return "wifi.exclamationmark"
        case .stopped:
            return "lock.slash"
        }
    }

    static func httpsTint(proxyState: ProxyRuntimeState, mode: HTTPSProxyMode) -> Color {
        switch proxyState {
        case .running:
            return mode == .intercepting ? .green : .orange
        case .starting, .stopping:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }
}

struct MainStatusTitleBar: View {
    let proxyState: ProxyRuntimeState
    let canStartProxy: Bool
    let canStopProxy: Bool
    let proxyPort: UInt16
    let certificateWorkflowState: ProxyViewModel.CertificateWorkflowState
    let certificateStatusGuidance: String
    let httpsProxyMode: HTTPSProxyMode
    let hasCustomHTTPSRules: Bool
    let captureHealth: CaptureHealthMetrics
    let lastErrorMessage: String?
    let suggestedHelpTopicTitle: String
    let textScale: CGFloat
    let systemProxyIndicator: AnyView
    let toggleProxy: () -> Void
    let openProxyHelp: () -> Void
    let openCertificateSetup: () -> Void
    let openHTTPSRules: () -> Void
    let openContextualHelp: () -> Void
    var openFindInBodies: () -> Void = {}
    var mcpPipelineStatus: MCPPipelineStatus = .hidden
    var openMCPManagement: (MCPPipelineStatus.ManagementDestination) -> Void = { _ in }
    /// Quiet BA-3 Setup chip while first capture or expert bypass is still in progress.
    var showsSetupChip: Bool = false
    var openSetupCompanion: () -> Void = {}

    @State private var titleBarWidth: CGFloat = 1_400

    private var layoutMode: MainTitleBarLayoutMode {
        MainTitleBarLayoutMode(width: titleBarWidth, textScale: textScale)
    }

    private var pipelineStatus: CapturePipelineStatus {
        MainTitleBarFormatter.pipelineStatus(
            proxyState: proxyState,
            certificateWorkflowState: certificateWorkflowState,
            httpsProxyMode: httpsProxyMode
        )
    }

    private func openPipelineSurface(_ surface: CapturePipelineStatus.ClickSurface) {
        switch surface {
        case .proxyHelp: openProxyHelp()
        case .certificateSetup: openCertificateSetup()
        case .httpsRules: openHTTPSRules()
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggleProxy()
            } label: {
                Label {
                    Text(MainTitleBarFormatter.runtimeButtonTitle(state: proxyState, canStartProxy: canStartProxy))
                } icon: {
                    if proxyState.isTransitioning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: MainTitleBarFormatter.runtimeButtonIcon(canStartProxy: canStartProxy))
                    }
                }
                .appFont(.caption, scale: textScale, weight: .semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            // Record semantics: the stop control is red while capturing so the "recording"
            // state is unmistakable; the start control keeps the state-derived tint.
            .tint(pipelineStatus.isCapturing ? .red : MainTitleBarFormatter.runtimeTint(for: proxyState))
            .disabled(proxyState.isTransitioning || (!canStartProxy && !canStopProxy))
            .help(canStartProxy ? "Start the local proxy listener." : "Stop the running proxy listener.")
            .accessibilityLabel("\(MainTitleBarFormatter.runtimeButtonTitle(state: proxyState, canStartProxy: canStartProxy)) proxy")
            .accessibilityValue(proxyState.accessibilityRuntimeValue)
            .accessibilityIdentifier("proxyToggleButton")
            .layoutPriority(4)

            CapturePipelinePill(
                status: pipelineStatus,
                port: proxyPort,
                showsPort: layoutMode.showsBadgeTitles,
                textScale: textScale,
                action: { openPipelineSurface(pipelineStatus.clickSurface) }
            )
            .accessibilityIdentifier("capturePipelinePill")
            .layoutPriority(4)

            MCPStatusPill(
                status: mcpPipelineStatus,
                textScale: textScale,
                action: {
                    openMCPManagement(mcpPipelineStatus.managementDestination)
                }
            )
            .layoutPriority(3)
            .help(mcpPipelineStatus.detail ?? "Open MCP Management.")

            if showsSetupChip {
                Button(action: openSetupCompanion) {
                    Label("Setup", systemImage: "checklist")
                        .appFont(.caption, scale: textScale, weight: .semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("First-run setup is still in progress. Capture a request from the selected target to finish.")
                .accessibilityLabel("Setup in progress")
                .accessibilityIdentifier("firstRunSetupChip")
                .layoutPriority(3)
            }

            // The three per-component pills stay available for detail, but only in the
            // full-width layout — the unified pill above carries the at-a-glance answer.
            if layoutMode == .full {
                StatusBadgeButton(
                    title: "Proxy",
                    value: MainTitleBarFormatter.runtimeStatusValue(state: proxyState, port: proxyPort),
                    systemImage: MainTitleBarFormatter.runtimeIconName(for: proxyState),
                    tint: MainTitleBarFormatter.runtimeTint(for: proxyState),
                    showsTitle: layoutMode.showsBadgeTitles,
                    textScale: textScale,
                    monospacedValue: true,
                    accessibilityHint: "Shows the proxy runtime state and listening port.",
                    action: openProxyHelp
                )
                .accessibilityIdentifier("proxyStatusPill")
                .layoutPriority(3)

                StatusBadgeButton(
                    title: "Cert",
                    value: MainTitleBarFormatter.certificateTitle(for: certificateWorkflowState),
                    systemImage: MainTitleBarFormatter.certificateIconName(for: certificateWorkflowState),
                    tint: MainTitleBarFormatter.certificateTint(for: certificateWorkflowState),
                    showsTitle: layoutMode.showsBadgeTitles,
                    textScale: textScale,
                    accessibilityHint: "Opens certificate setup, trust status, and reset actions.",
                    action: openCertificateSetup
                )
                .help(certificateStatusGuidance)
                .accessibilityIdentifier("certificateStatusPill")
                .layoutPriority(3)

                StatusBadgeButton(
                    title: "HTTPS",
                    value: MainTitleBarFormatter.httpsTitle(proxyState: proxyState, mode: httpsProxyMode),
                    systemImage: MainTitleBarFormatter.httpsIconName(proxyState: proxyState, mode: httpsProxyMode),
                    tint: MainTitleBarFormatter.httpsTint(proxyState: proxyState, mode: httpsProxyMode),
                    showsTitle: layoutMode.showsBadgeTitles,
                    textScale: textScale,
                    accessibilityHint: "Opens HTTPS rules for bypass and intercept domains.",
                    action: openHTTPSRules
                )
                .help("Shows whether JoesProxy is inspecting HTTPS traffic or tunneling it for compatibility.")
                .accessibilityIdentifier("httpsStatusPill")
                .layoutPriority(3)
            }

            if hasCustomHTTPSRules {
                StatusBadgeButton(
                    title: "Rules",
                    value: "Custom",
                    systemImage: "list.bullet.rectangle",
                    tint: .secondary,
                    showsTitle: layoutMode == .full,
                    textScale: textScale,
                    accessibilityHint: "Opens custom HTTPS bypass and intercept rules.",
                    action: openHTTPSRules
                )
                .help("Custom HTTPS bypass or intercept rules are active.")
            }

            if certificateWorkflowState != .ready {
                Button {
                    openCertificateSetup()
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open certificate setup, trust status, and reset actions.")
                .accessibilityLabel("Open HTTPS setup")
                .layoutPriority(2)
            }

            Button(action: openFindInBodies) {
                Image(systemName: "doc.text.magnifyingglass")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Find in retained request and response bodies.")
            .accessibilityLabel("Find in captured bodies")
            .accessibilityIdentifier("globalBodyFindButton")
            .layoutPriority(2)

            SettingsLink {
                Image(systemName: "gearshape")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)
            .help("Open JoesProxy settings.")
            .accessibilityLabel("Open settings")
            .accessibilityIdentifier("globalSettingsButton")
            .layoutPriority(2)

            Spacer(minLength: 8)

            MainTitleBarHealthMetrics(captureHealth: captureHealth, layoutMode: layoutMode, textScale: textScale)
                .layoutPriority(-1)
                .frame(maxWidth: layoutMode.healthMetricsWidth * textScale, alignment: .trailing)
                .accessibilityIdentifier("captureHealthMetricsInline")

            systemProxyIndicator
                .layoutPriority(1)

            if let lastErrorMessage, !lastErrorMessage.isEmpty {
                Label("Attention", systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(lastErrorMessage)
                    .accessibilityHint(lastErrorMessage)
                    .layoutPriority(1)
            }

            Button {
                openContextualHelp()
            } label: {
                Image(systemName: "questionmark.circle")
                    .appFont(.caption, scale: textScale)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open a contextual help window for the current screen state.")
            .accessibilityLabel("Show contextual help")
            .accessibilityValue(suggestedHelpTopicTitle)
            .accessibilityIdentifier("mainHelpDrawerToggle")
            .layoutPriority(2)
        }
        .reportViewWidth { titleBarWidth = $0 }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mainStatusTitleBar")
    }
}

/// The unified capture-pipeline pill: the primary status control in the title bar.
/// A pulsing red dot marks the recording state; the tinted label + symbol summarize
/// pipeline health; a click opens whichever surface resolves the current problem.
private struct CapturePipelinePill: View {
    let status: CapturePipelineStatus
    let port: UInt16
    let showsPort: Bool
    let textScale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if status.isCapturing {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 7))
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityHidden(true)
                }

                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tone.color)
                    .accessibilityHidden(true)

                Text(status.label)
                    .appFont(.caption, scale: textScale, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if showsPort {
                    Text(verbatim: "· \(port)")
                        .appFont(.caption, scale: textScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(status.tone.color.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(status.detail ?? status.label)
        .accessibilityLabel(status.label)
        .accessibilityValue(status.detail ?? "")
        .accessibilityHint("Opens the setup surface for the current capture state.")
    }
}

private struct StatusBadgeButton: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    let showsTitle: Bool
    let textScale: CGFloat
    var monospacedValue = false
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                if showsTitle {
                    Text(title)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(verbatim: value)
                    .appFont(.caption, scale: textScale, weight: .semibold, design: monospacedValue ? .monospaced : .default)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(title): \(value)")
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint(accessibilityHint)
    }
}

private struct MainTitleBarHealthMetrics: View {
    let captureHealth: CaptureHealthMetrics
    let layoutMode: MainTitleBarLayoutMode
    let textScale: CGFloat

    var body: some View {
        if captureHealth.captureStartedAt != nil || captureHealth.hasCaptureSessionFootprint {
            if layoutMode == .full {
                metricRow
            } else {
                Menu {
                    ForEach(MainTitleBarHealthMetric.metrics(for: captureHealth, layoutMode: .full)) { metric in
                        Label(metric.accessibilityLabel, systemImage: metric.systemImage)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .accessibilityHidden(true)
                        Text(verbatim: compactSummary)
                            .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .help("Open capture health details.")
                .accessibilityLabel("Capture health: \(compactSummary)")
                .accessibilityIdentifier("captureHealthSummaryMenu")
            }
        }
    }

    private var metricRow: some View {
        HStack(spacing: spacing) {
            ForEach(MainTitleBarHealthMetric.metrics(for: captureHealth, layoutMode: layoutMode)) { metric in
                Label(metric.value, systemImage: metric.systemImage)
                    .foregroundStyle(metric.level.color)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .lineLimit(1)
                    .accessibilityLabel(metric.accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }

    private var compactSummary: String {
        let retained = ByteCountFormatter.string(
            fromByteCount: Int64(captureHealth.retainedBodyBytes),
            countStyle: .memory
        )
        return "\(captureHealth.sessionCount) reqs · \(retained)"
    }

    private var spacing: CGFloat {
        switch layoutMode {
        case .full:
            return 14
        case .compact:
            return 10
        case .minimal:
            return 8
        }
    }
}

struct MainTitleBarHealthMetric: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let value: String
    let level: HealthLevel
    let accessibilityLabel: String

    private static let thresholds = CaptureHealthThresholds.standard

    static func metrics(
        for captureHealth: CaptureHealthMetrics,
        layoutMode: MainTitleBarLayoutMode
    ) -> [MainTitleBarHealthMetric] {
        var metrics: [MainTitleBarHealthMetric] = [
            MainTitleBarHealthMetric(
                id: "sessions",
                systemImage: "list.bullet",
                value: captureHealth.sessionCount.formatted(),
                level: HealthLevel(fraction: Double(captureHealth.sessionCount) / Double(thresholds.sessionCount)),
                accessibilityLabel: "\(captureHealth.sessionCount) sessions"
            ),
            MainTitleBarHealthMetric(
                id: "retained-body",
                systemImage: "internaldrive",
                value: ByteCountFormatter.string(fromByteCount: Int64(captureHealth.retainedBodyBytes), countStyle: .memory),
                level: HealthLevel(fraction: Double(captureHealth.retainedBodyBytes) / Double(thresholds.retainedBodyBytes)),
                accessibilityLabel: "Retained body data \(ByteCountFormatter.string(fromByteCount: Int64(captureHealth.retainedBodyBytes), countStyle: .memory))"
            ),
            MainTitleBarHealthMetric(
                id: "memory",
                systemImage: "memorychip",
                value: ByteCountFormatter.string(fromByteCount: Int64(captureHealth.processMetrics.residentMemoryBytes), countStyle: .memory),
                level: HealthLevel(fraction: Double(captureHealth.processMetrics.residentMemoryBytes) / Double(thresholds.residentMemoryBytes)),
                accessibilityLabel: "Memory \(ByteCountFormatter.string(fromByteCount: Int64(captureHealth.processMetrics.residentMemoryBytes), countStyle: .memory))"
            )
        ]

        if let cpu = captureHealth.processMetrics.cpuPercent {
            metrics.append(
                MainTitleBarHealthMetric(
                    id: "cpu",
                    systemImage: "cpu",
                    value: String(format: "%.0f%%", cpu),
                    level: HealthLevel(fraction: cpu / thresholds.cpuPercent),
                    accessibilityLabel: String(format: "CPU %.0f%%", cpu)
                )
            )
        }

        if let duration = captureHealth.captureDuration {
            metrics.append(
                MainTitleBarHealthMetric(
                    id: "duration",
                    systemImage: "clock",
                    value: formattedDuration(duration),
                    level: HealthLevel(fraction: duration / thresholds.captureDuration),
                    accessibilityLabel: "Capture duration \(formattedDuration(duration))"
                )
            )
        }

        switch layoutMode {
        case .full:
            return metrics
        case .compact:
            return Array(metrics.prefix(3))
        case .minimal:
            return Array(metrics.prefix(2))
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
