//
//  ResilienceMatrixCardView.swift
//  JoesProxy
//
//  SwiftUI card view for visualizing client resilience matrices,
//  isolated breaking points, and defensive decoding remediations.
//

import SwiftUI

struct ResilienceMatrixCardView: View {
    let plan: ResilienceBisectionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(.headline)
                    Text("Target: \(plan.targetURL) • \(plan.candidates.count) Mutations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusBadge
            }

            // Progress Bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bisection Progress")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", plan.progressPercentage))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                ProgressView(value: plan.progressPercentage, total: 100.0)
                    .progressViewStyle(LinearProgressViewStyle())
            }

            // Breaking Points Section
            let breaking = plan.candidates.filter { $0.status == .breakingPoint }
            if !breaking.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Breaking Points Isolated (\(breaking.count))")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }

                    ForEach(breaking) { b in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(b.keyPath)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                                Spacer()
                                Text(b.mutationType.rawValue)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            if let err = b.observedClientError {
                                Text("Error: \(err)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(6)
                        .background(Color.red.opacity(0.06))
                        .cornerRadius(4)
                    }
                }
            }

            // All Candidates List
            VStack(alignment: .leading, spacing: 6) {
                Text("Mutation Candidates (\(plan.candidates.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(plan.candidates.prefix(8)) { c in
                    candidateRow(c)
                }
                if plan.candidates.count > 8 {
                    Text("... and \(plan.candidates.count - 8) more mutation candidates")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func candidateRow(_ c: FieldMutationCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.keyPath)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(c.status == .breakingPoint ? .red : .primary)

                    Spacer()

                    statusPill(c.status)
                }

                Text("\(c.mutationType.rawValue): \(c.originalValueDescription) → \(c.mutatedValueDescription)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(4)
        .background(c.status == .evaluating ? Color.yellow.opacity(0.08) : Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    private var statusBadge: some View {
        let title = plan.isCompleted ? "Bisection Complete" : "Optimizing"
        let color = plan.isCompleted ? Color.green : Color.yellow
        return Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func statusPill(_ status: FieldResilienceStatus) -> some View {
        let color: Color
        switch status {
        case .safe: color = .green
        case .breakingPoint: color = .red
        case .evaluating: color = .yellow
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
