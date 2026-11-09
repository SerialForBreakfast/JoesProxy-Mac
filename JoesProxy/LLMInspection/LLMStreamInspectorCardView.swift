//
//  LLMStreamInspectorCardView.swift
//  JoesProxy
//
//  SwiftUI card view for inspecting LLM SSE stream metrics,
//  token jitter, assembled text, tool calls, and canary prompt checks.
//

import SwiftUI

struct LLMStreamInspectorCardView: View {
    let report: LLMStreamReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM Streaming Wire Inspector")
                        .font(.headline)
                    Text("Protocol: \(report.format.rawValue) • Model: \(report.modelName ?? "Unknown")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                qualityScoreBadge
            }

            // Metrics Row
            HStack(spacing: 8) {
                metricPill(label: "TTFT", value: String(format: "%.0f ms", report.timeToFirstTokenMs))
                metricPill(label: "Throughput", value: String(format: "%.1f tok/s", report.tokensPerSecond))
                metricPill(label: "Jitter", value: String(format: "±%.1f ms", report.interTokenJitterMs))
                metricPill(label: "Tokens / Chunks", value: "\(report.totalTokens) / \(report.totalChunks)")
            }

            // Canary Violations Banner
            if !report.canaryViolations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Prompt Leakage Detected (\(report.canaryViolations.count))")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    ForEach(report.canaryViolations, id: \.self) { v in
                        Text(v)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }

            // Assembled Text Preview
            if !report.assembledText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assembled Response Stream")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(report.assembledText)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(6)
                }
            }

            // Tool Calls Section
            if !report.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Streamed Tool Calls (\(report.toolCalls.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.toolCalls) { tc in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(tc.name)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.purple)
                                Spacer()
                                Text(tc.isComplete ? "Complete" : "Partial")
                                    .font(.system(size: 9))
                                    .foregroundColor(tc.isComplete ? .green : .orange)
                            }
                            Text(tc.argumentsJSON)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        .padding(6)
                        .background(Color.purple.opacity(0.04))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var qualityScoreBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.qualityScore >= 80 ? Color.green : (report.qualityScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Score: %.0f/100", report.qualityScore))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.qualityScore >= 80 ? .green : (report.qualityScore >= 50 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.qualityScore >= 80 ? Color.green : (report.qualityScore >= 50 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func metricPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
