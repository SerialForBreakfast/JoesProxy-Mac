//
//  FaultBisectionSheet.swift
//  JoesProxy
//
//  Interactive sheet presenting the live AI Fault Bisection drawer, candidate tree, and finding.
//

import SwiftUI

struct FaultBisectionSheet: View {
    @ObservedObject var coordinator: FaultBisectionCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title Bar
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Fault Bisection & Root Cause Isolation")
                        .font(.headline)
                    Text("Autonomous binary search across upstream APIs and JSON payloads")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let report = coordinator.activeReport {
                        // Candidate Scope Summary
                        scopeSection(scope: report.candidateScope)

                        // If finding is ready, show Root Cause Card
                        if let finding = report.finding {
                            FaultBisectionCardView(finding: finding, onApplyMock: { _ in })
                        }

                        // Current Step / Action Prompter
                        if coordinator.isRunning, let action = coordinator.currentAction {
                            currentActionSection(action: action)
                        }

                        // Step History Ladder
                        if !report.steps.isEmpty {
                            stepHistorySection(steps: report.steps)
                        }
                    } else {
                        Text("No active bisection session.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .padding()
            }

            Divider()

            // Footer Controls
            HStack {
                if coordinator.isRunning {
                    Button(role: .destructive, action: {
                        coordinator.cancelBisection()
                    }) {
                        Label("Cancel Bisection", systemImage: "xmark.circle")
                    }
                }
                Spacer()
                Button(coordinator.isRunning ? "Running in Background..." : "Done", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Sections

    private func scopeSection(scope: FaultBisectionCandidateScope) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Candidate Window", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(scope.distinctEndpoints.count) Endpoints (\(scope.candidateSessionIDs.count) Requests)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scope.distinctEndpoints) { candidate in
                        HStack(spacing: 4) {
                            Text(candidate.method)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Text(candidate.path)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
    }

    private func currentActionSection(action: BisectionNextAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Step \(action.stepNumber): \(action.kind.rawValue.capitalized)", systemImage: "arrow.triangle.branch")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
            }

            Text(action.actionDescription)
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("Record Client Outcome:")
                .font(.caption)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                Button(action: {
                    coordinator.recordStepOutcome(outcome: .crashed)
                }) {
                    Label("Client Crashed", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: {
                    coordinator.recordStepOutcome(outcome: .failedAssertion)
                }) {
                    Label("Assertion Failed", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button(action: {
                    coordinator.recordStepOutcome(outcome: .succeeded)
                }) {
                    Label("Client Succeeded", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func stepHistorySection(steps: [BisectionStepResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bisection Trace")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(spacing: 6) {
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(step.clientOutcome == .succeeded ? Color.green : Color.red)
                            .frame(width: 8, height: 8)

                        Text("Step \(step.stepNumber)")
                            .font(.caption)
                            .fontWeight(.bold)

                        Text(step.mutationDescription)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(step.clientOutcome.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
    }
}
