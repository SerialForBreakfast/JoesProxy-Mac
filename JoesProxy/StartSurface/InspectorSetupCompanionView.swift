import SwiftUI

/// Non-blocking Inspector companion for human first capture (BA-3).
///
/// The session table stays visible. The toolbar remains the only Start Proxy control. Certificate
/// setup is not a milestone. Existing platform walkthroughs own device-specific routing depth.
struct InspectorSetupCompanionView: View {
    @Environment(\.appTextScale) private var appTextScale

    let isProxyRunning: Bool
    let selectedTargetID: String?
    let hasObservedSelectedTargetRequest: Bool
    let setupNetworkDriftSummary: String?
    let onSelectTarget: (String) -> Void
    let onOpenMacOSGuide: () -> Void
    let onOpenIOSGuide: () -> Void
    let onOpenTVOSGuide: () -> Void
    let onOpenSimulatorGuide: () -> Void
    let onDismiss: () -> Void

    private var selectedTarget: MCPSetupReadinessTarget? {
        FirstRunCompletionPolicy.target(fromStoredID: selectedTargetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First capture")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)

                    Text("Use Start Proxy in the toolbar, choose a target, then wait for a request. HTTPS inspection is optional later.")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Hide", action: onDismiss)
                    .buttonStyle(.borderless)
                    .appFont(.caption, scale: appTextScale)
                    .accessibilityIdentifier("inspectorSetupCompanionHideButton")
            }

            HStack(alignment: .top, spacing: 16) {
                milestoneColumn
                targetColumn
            }

            if let setupNetworkDriftSummary {
                staleHostBanner(summary: setupNetworkDriftSummary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspectorSetupCompanion")
    }

    private var milestoneColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            milestoneRow(
                title: "Proxy started",
                isComplete: isProxyRunning,
                identifier: "inspectorSetupCompanionMilestoneProxy"
            )
            milestoneRow(
                title: "Target chosen",
                isComplete: selectedTarget != nil,
                identifier: "inspectorSetupCompanionMilestoneTarget"
            )
            milestoneRow(
                title: "First request observed",
                isComplete: hasObservedSelectedTargetRequest,
                identifier: "inspectorSetupCompanionMilestoneRequest"
            )
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private var targetColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Capture target", selection: targetBinding) {
                Text("Choose a target").tag(Optional<MCPSetupReadinessTarget>.none)
                ForEach(MCPSetupReadinessTarget.allCases, id: \.self) { target in
                    Text(target.companionTitle).tag(Optional(target))
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("inspectorSetupCompanionTargetPicker")

            Text(routingHint)
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let walkthrough = selectedTarget.flatMap(walkthroughAction(for:)) {
                Button(walkthrough.title, action: walkthrough.action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier(walkthrough.identifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetBinding: Binding<MCPSetupReadinessTarget?> {
        Binding(
            get: { selectedTarget },
            set: { newValue in
                if let newValue {
                    onSelectTarget(newValue.rawValue)
                }
            }
        )
    }

    private var routingHint: String {
        switch selectedTarget {
        case .none:
            return "Choose where traffic will come from. First run completes on that target’s first request."
        case .macOS:
            return "Point Mac clients at this Mac’s proxy port. Open the macOS guide for routing detail."
        case .iOSiPadOS:
            return "Route the device through this Mac’s proxy. Open the iOS guide for Wi-Fi proxy steps."
        case .tvOS:
            return "Route the Apple TV through this Mac’s proxy. Open the tvOS guide for network steps."
        case .simulator:
            return "Route the simulator through this Mac’s proxy. Open the simulator guide for loopback routing."
        case .generic:
            return "Any captured request counts once this generic target is selected."
        }
    }

    private func walkthroughAction(
        for target: MCPSetupReadinessTarget
    ) -> (title: String, identifier: String, action: () -> Void)? {
        switch target {
        case .macOS:
            return ("macOS setup guide", "inspectorSetupCompanionMacOSGuide", onOpenMacOSGuide)
        case .iOSiPadOS:
            return ("iOS setup guide", "inspectorSetupCompanionIOSGuide", onOpenIOSGuide)
        case .tvOS:
            return ("tvOS setup guide", "inspectorSetupCompanionTVOSGuide", onOpenTVOSGuide)
        case .simulator:
            return ("Simulator setup guide", "inspectorSetupCompanionSimulatorGuide", onOpenSimulatorGuide)
        case .generic:
            return nil
        }
    }

    private func milestoneRow(title: String, isComplete: Bool, identifier: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
                .appFont(.caption, scale: appTextScale)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isComplete ? "Complete" : "Not yet")
        .accessibilityIdentifier(identifier)
    }

    private func staleHostBanner(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Host changed")
                .appFont(.caption, scale: appTextScale, weight: .semibold)
            Text(summary)
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("inspectorSetupCompanionStaleHost")
    }
}

extension MCPSetupReadinessTarget {
    /// Short picker label for the Inspector companion.
    var companionTitle: String {
        switch self {
        case .macOS:
            return "Mac"
        case .iOSiPadOS:
            return "iPhone or iPad"
        case .tvOS:
            return "Apple TV"
        case .simulator:
            return "Simulator"
        case .generic:
            return "Any client"
        }
    }
}
