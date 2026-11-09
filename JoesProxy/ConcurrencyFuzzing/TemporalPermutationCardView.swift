//
//  TemporalPermutationCardView.swift
//  JoesProxy
//
//  SwiftUI card view for visualizing temporal request permutation matrices,
//  arrival order schedules, and detected async race conditions.
//

import SwiftUI

struct TemporalPermutationCardView: View {
    let plan: TemporalPermutationPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(.headline)
                    Text("Target: \(plan.targetBatchDescription) • \(plan.endpoints.count) Endpoints")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusBadge
            }

            // Progress Bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Permutation Fuzzing Progress")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", plan.progressPercentage))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                ProgressView(value: plan.progressPercentage, total: 100.0)
                    .progressViewStyle(LinearProgressViewStyle())
            }

            // Sequences Matrix
            VStack(alignment: .leading, spacing: 6) {
                Text("Permutation Schedule (\(plan.sequences.count) Sequences)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(plan.sequences) { seq in
                    sequenceRow(seq)
                }
            }

            // Race Condition Warning Banner
            let failing = plan.sequences.filter(\.errorDetected)
            if !failing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Race Conditions Detected in \(failing.count) Permutation(s)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    if let firstFail = failing.first {
                        Text("Failing Order: \(firstFail.order.joined(separator: " -> "))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.red)
                        if let outcome = firstFail.clientOutcomeSummary {
                            Text(outcome)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func sequenceRow(_ seq: PermutationSequence) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("#\(seq.id)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(seq.order.joined(separator: " → "))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(seq.errorDetected ? .red : .primary)

                    Spacer()

                    outcomePill(seq.status)
                }

                let delaysSummary = seq.order.map { "\($0): +\(seq.delaysMs[$0] ?? 0)ms" }.joined(separator: " | ")
                Text(delaysSummary)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)

                if let outcome = seq.clientOutcomeSummary {
                    Text(outcome)
                        .font(.system(size: 9))
                        .foregroundColor(seq.errorDetected ? .red : .secondary)
                }
            }
        }
        .padding(6)
        .background(seq.status == .evaluating ? Color.yellow.opacity(0.08) : Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    private var statusBadge: some View {
        let title = plan.isCompleted ? (plan.sequences.contains(where: \.errorDetected) ? "Fuzzing Complete (Race Found)" : "Fuzzing Complete (Safe)") : "Fuzzing"
        let color = plan.isCompleted ? (plan.sequences.contains(where: \.errorDetected) ? Color.red : Color.green) : Color.yellow
        return Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func outcomePill(_ status: PermutationOutcomeStatus) -> some View {
        let color: Color
        switch status {
        case .passed: color = .green
        case .raceConditionDetected: color = .red
        case .evaluating: color = .yellow
        case .clientTimeout: color = .orange
        case .untested: color = .blue
        }
        return Text(status.rawValue)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(3)
    }
}
