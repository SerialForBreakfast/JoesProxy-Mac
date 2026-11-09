//
//  HypothesisGraphCardView.swift
//  JoesProxy
//
//  SwiftUI tree view for visualizing active hypothesis DAGs,
//  bisection progress, and isolated root causes.
//

import SwiftUI

struct HypothesisGraphCardView: View {
    let graph: HypothesisGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(graph.name)
                        .font(.headline)
                    Text("Target: \(graph.targetBugDescription)")
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
                    Text(String(format: "%.0f%%", graph.progressPercentage))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                ProgressView(value: graph.progressPercentage, total: 100.0)
                    .progressViewStyle(LinearProgressViewStyle())
            }

            // Hypothesis Nodes List
            VStack(alignment: .leading, spacing: 6) {
                Text("Hypothesis Tree (\(graph.nodes.count) Nodes)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(graph.nodes) { node in
                    nodeRow(node)
                }
            }

            // Proven Root Cause Banner
            if let proven = graph.provenNode {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Root Cause Isolated: [\(proven.id)] \(proven.title)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                    if let summary = proven.evidenceSummary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func nodeRow(_ node: HypothesisNode) -> some View {
        let isChild = node.parentID != nil
        return HStack(alignment: .top, spacing: 8) {
            if isChild {
                Text("↳")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("[\(node.id)]")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)

                    Text(node.title)
                        .font(.system(size: 10, weight: .semibold))
                        .strikethrough(node.status == .disproven || node.status == .pruned)
                        .foregroundColor(node.status == .pruned ? .secondary : .primary)

                    Spacer()

                    nodeStatusPill(node.status)
                }

                Text(node.mutation.description)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)

                if let evidence = node.evidenceSummary {
                    Text(evidence)
                        .font(.system(size: 9))
                        .foregroundColor(node.status == .proven ? .green : (node.status == .disproven ? .red : .secondary))
                }
            }
        }
        .padding(6)
        .background(node.status == .evaluating ? Color.yellow.opacity(0.08) : Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    private var statusBadge: some View {
        let title = graph.isCompleted ? (graph.provenNode != nil ? "Root Cause Proven" : "Bisection Complete") : "Evaluating"
        let color = graph.isCompleted ? (graph.provenNode != nil ? Color.green : Color.secondary) : Color.yellow
        return Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func nodeStatusPill(_ status: HypothesisNodeStatus) -> some View {
        let color: Color
        switch status {
        case .proven: color = .green
        case .disproven: color = .red
        case .evaluating: color = .yellow
        case .pruned: color = .secondary
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
