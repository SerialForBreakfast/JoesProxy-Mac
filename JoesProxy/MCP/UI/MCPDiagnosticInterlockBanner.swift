import SwiftUI

/// Inline interlock warning for diagnostic views when MCP effects may skew measurements (AJ-4).
struct MCPDiagnosticInterlockBanner: View {
    @ObservedObject var coordinator: MCPDiagnosticInterlockCoordinator
    let diagnostic: MCPDiagnosticKind
    let evaluation: MCPDiagnosticInterlockEvaluation
    let textScale: CGFloat
    let onAcknowledge: () -> Void

    var body: some View {
        if coordinator.shouldShowWarning(for: diagnostic, evaluation: evaluation) || coordinator.isMeasurementActive {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(bannerTitle)
                        .appFont(.body, scale: textScale, weight: .semibold)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let summary = evaluation.summaryMessage {
                    Text(summary)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                if coordinator.isMeasurementActive, coordinator.activeDiagnostic == diagnostic {
                    Text("Measured with MCP effects suspended.")
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if evaluation.requiresScenarioStop, let scenarioID = evaluation.activeScenarioIDs.first {
                        Button("Stop Scenario And Measure Clean") {
                            Task {
                                await coordinator.stopScenarioAndMeasureClean(
                                    scenarioID: MCPScenarioID(rawValue: scenarioID),
                                    diagnostic: diagnostic
                                )
                            }
                        }
                        .accessibilityIdentifier("mcpStopScenarioMeasureCleanButton")
                    } else if !evaluation.relevantItems.isEmpty {
                        Button("Measure without MCP effects") {
                            Task {
                                _ = await coordinator.beginCleanMeasurement(for: diagnostic)
                            }
                        }
                        .accessibilityIdentifier("mcpMeasureWithoutEffectsButton")
                    }
                    if coordinator.isMeasurementActive {
                        Button("End Clean Measurement") {
                            Task { await coordinator.endCleanMeasurement() }
                        }
                        .accessibilityIdentifier("mcpEndCleanMeasurementButton")
                    }
                    if coordinator.shouldShowWarning(for: diagnostic, evaluation: evaluation) {
                        Button("Acknowledge") {
                            coordinator.acknowledgeWarning(for: diagnostic)
                            onAcknowledge()
                        }
                        .accessibilityIdentifier("mcpInterlockAcknowledgeButton")
                    }
                }
                if let conflict = coordinator.lastRestoreConflictMessage {
                    Text(conflict)
                        .foregroundStyle(.orange)
                        .appFont(.caption, scale: textScale)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mcpDiagnosticInterlockBanner")
        }
    }

    private var bannerTitle: String {
        if coordinator.isMeasurementActive {
            return "Clean measurement active"
        }
        return "MCP effects may affect this view"
    }
}
