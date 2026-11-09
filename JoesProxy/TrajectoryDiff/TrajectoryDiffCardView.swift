//
//  TrajectoryDiffCardView.swift
//  JoesProxy
//
//  SwiftUI card view for visualizing multi-session trajectory sequence alignment,
//  divergence point callouts, and behavioral branching graphs.
//

import SwiftUI

struct TrajectoryDiffCardView: View {
    let report: TrajectoryDiffReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behavioral Trajectory Diff")
                        .font(.headline)
                    Text("\(report.baselineRunName) (\(report.totalBaselineRequests) reqs) vs \(report.candidateRunName) (\(report.totalCandidateRequests) reqs)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                similarityBadge
            }

            // Divergence Alert Banner
            if let divSummary = report.divergencePointSummary {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Behavioral Divergence Detected")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    Text(divSummary)
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            } else {
                HStack {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Zero Divergence: Trajectories executed identically")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            }

            // Aligned Steps List
            VStack(alignment: .leading, spacing: 6) {
                Text("Aligned Trajectory Steps (\(report.alignedSteps.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(report.alignedSteps) { step in
                    stepRow(step)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func stepRow(_ step: TrajectoryAlignedStep) -> some View {
        let isDivergent = step.stepType != .matched
        return HStack(alignment: .top, spacing: 8) {
            Text("#\(step.id)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(step.requestSignature)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(isDivergent ? .red : .primary)

                    Spacer()

                    stepTypePill(step.stepType)
                }

                HStack(spacing: 8) {
                    if let bStatus = step.baselineStatusCode {
                        Text("Base: \(bStatus)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if let cStatus = step.candidateStatusCode {
                        Text("Cand: \(cStatus)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if step.relativeTimestampDeltaMs != 0 {
                        Text(String(format: "Δ %.0fms", step.relativeTimestampDeltaMs))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                if let div = step.divergenceSummary {
                    Text(div)
                        .font(.system(size: 9))
                        .foregroundColor(isDivergent ? .red : .secondary)
                }
            }
        }
        .padding(6)
        .background(isDivergent ? Color.red.opacity(0.04) : Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    private var similarityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.similarityScore >= 80 ? Color.green : (report.similarityScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Similarity: %.0f%%", report.similarityScore))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.similarityScore >= 80 ? .green : (report.similarityScore >= 50 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.similarityScore >= 80 ? Color.green : (report.similarityScore >= 50 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func stepTypePill(_ type: TrajectoryStepType) -> some View {
        let color: Color
        switch type {
        case .matched: color = .green
        case .payloadDiverged: color = .yellow
        case .statusCodeMismatch: color = .red
        case .missingInCandidate: color = .orange
        case .unexpectedInCandidate: color = .purple
        }
        return Text(type.rawValue)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(3)
    }
}
