//
//  FaultBisectionCardView.swift
//  JoesProxy
//
//  Renders the executive Root Cause finding card with 1-click actionable resolutions.
//

import SwiftUI
import AppKit

struct FaultBisectionCardView: View {
    let finding: FaultBisectionFinding
    let onApplyMock: (String) -> Void

    @State private var copiedTicket: Bool = false
    @State private var copiedCurl: Bool = false
    @State private var appliedMock: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Root Cause Isolated")
                        .font(.headline)
                    Text("Confidence: \(Int(finding.confidenceScore * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Culprit Details Grid
            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: "Culprit Endpoint", value: finding.culpritEndpoint.displayTitle)
                if let key = finding.culpritKeyPath {
                    detailRow(label: "Breaking Field", value: key)
                }
                detailRow(label: "Exact Wire Fault", value: finding.exactWireFault)
                if let err = finding.observedClientError {
                    detailRow(label: "Client Symptom", value: err)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // Action Buttons
            VStack(alignment: .leading, spacing: 10) {
                Text("Actionable Resolutions")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 12) {
                    if let mockJSON = finding.proposedMockJSON {
                        Button(action: {
                            onApplyMock(mockJSON)
                            appliedMock = true
                        }) {
                            Label(appliedMock ? "Local Mock Active" : "Apply Temporary Local Mock", systemImage: appliedMock ? "checkmark" : "shield.lefthalf.filled")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appliedMock ? .gray : .blue)
                        .disabled(appliedMock)
                    }

                    Button(action: {
                        copyBugTicket()
                    }) {
                        Label(copiedTicket ? "Copied Ticket!" : "Copy Bug Ticket", systemImage: copiedTicket ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        copyCurl()
                    }) {
                        Label(copiedCurl ? "Copied curl!" : "Copy curl", systemImage: copiedCurl ? "checkmark" : "terminal")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func copyBugTicket() {
        let markdown = """
        ### Bug Report: Root Cause Isolated via JoesProxy AI Fault Bisection

        - **Culprit Endpoint**: `\(finding.culpritEndpoint.displayTitle)`
        - **Breaking Field**: `\(finding.culpritKeyPath ?? "N/A")`
        - **Wire Fault**: \(finding.exactWireFault)
        - **Observed Client Error**: `\(finding.observedClientError ?? "Unknown")`

        #### Reproducer:
        ```bash
        \(finding.curlReproducer)
        ```
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedTicket = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedTicket = false
        }
    }

    private func copyCurl() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finding.curlReproducer, forType: .string)
        copiedCurl = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedCurl = false
        }
    }
}
