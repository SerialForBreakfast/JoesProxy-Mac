//
//  SemanticMockCardView.swift
//  JoesProxy
//
//  SwiftUI card view for managing semantic mock rules,
//  confidence thresholds, and interactive live query matching.
//

import SwiftUI

struct SemanticMockCardView: View {
    @State private var testQueryText: String = ""
    @State private var testMatchResult: SemanticMatchResult? = nil

    let rules: [SemanticMockRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Semantic Wire Mocking")
                        .font(.headline)
                    Text("Vector similarity matching for natural language & search endpoints")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(rules.count) Active Rules")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(.purple)
                    .cornerRadius(4)
            }

            // Interactive Query Tester
            VStack(alignment: .leading, spacing: 6) {
                Text("Test Natural Language Query")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("Enter test query (e.g. 'how to cancel plan')...", text: $testQueryText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 11))

                    Button("Test Match") {
                        testMatchResult = SemanticMockEngine.shared.evaluateQuery(query: testQueryText)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let res = testMatchResult {
                    HStack {
                        Circle()
                            .fill(res.isMatch ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        if res.isMatch {
                            Text("Matched Intent: [\(res.matchedIntent ?? "")] (\(res.matchedRuleName ?? "")) • Score: \(String(format: "%.1f%%", res.similarityScore * 100))")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        } else {
                            Text("No Rule Matched (Best Score: \(String(format: "%.1f%%", res.similarityScore * 100)))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(res.isMatch ? Color.green.opacity(0.08) : Color.primary.opacity(0.02))
                    .cornerRadius(4)
                }
            }

            // Configured Rules List
            VStack(alignment: .leading, spacing: 6) {
                Text("Semantic Mock Rules (\(rules.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func ruleRow(_ rule: SemanticMockRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name)
                    .font(.system(size: 11, weight: .bold))

                Text("[\(rule.intentLabel)]")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.purple)

                Spacer()

                Text("Threshold: \(String(format: "%.0f%%", rule.confidenceThreshold * 100))")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("Hits: \(rule.matchCount)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(3)
            }

            Text("Pattern: \(rule.urlPattern)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            // Example queries
            HStack(spacing: 4) {
                ForEach(rule.exampleQueries.prefix(3), id: \.self) { ex in
                    Text("\"\(ex)\"")
                        .font(.system(size: 8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(3)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(6)
    }
}
