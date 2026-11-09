//
//  LocalizationMockSheet.swift
//  JoesProxy
//
//  Native SwiftUI drawer for inspecting and generating localized response mocks.
//

import SwiftUI
import AppKit

struct LocalizationMockSheet: View {
    let originalData: Data
    let onClose: () -> Void
    var onSaveAsMock: ((Data) -> Void)?

    @State private var selectedPreset: LocalizationPresetKind = .pseudoAccentedExpansion
    @State private var preserveURLs: Bool = true
    @State private var preserveIDs: Bool = true
    @State private var copied: Bool = false

    private var transformResult: LocalizationTransformResult {
        var options = LocalizationTransformOptions()
        options.preset = selectedPreset
        options.preserveURLs = preserveURLs
        options.preserveIDs = preserveIDs
        return LocalizationMockEngine.transform(jsonData: originalData, options: options)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "globe.americas.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Localization & Pseudo-Loc Mock Generator")
                        .font(.headline)
                    Text("Simulate text expansion, RTL mirroring, and CJK line-height on live responses")
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

            // Controls & Preset Bar
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(LocalizationPresetKind.allCases) { preset in
                        Button(action: { selectedPreset = preset }) {
                            Text(preset.title)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selectedPreset == preset ? Color.accentColor : Color.primary.opacity(0.06))
                                .foregroundColor(selectedPreset == preset ? .white : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Preserve URLs", isOn: $preserveURLs)
                        .font(.caption)
                    Toggle("Preserve IDs & UUIDs", isOn: $preserveIDs)
                        .font(.caption)

                    Spacer()

                    // Metric Pills
                    metricBadge(
                        label: "Mutated Strings",
                        value: "\(transformResult.mutatedStringCount)"
                    )
                    metricBadge(
                        label: "Expansion",
                        value: String(format: "+%.0f%%", max(0, transformResult.expansionPercentage))
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Comparison View
            HSplitView {
                // Left: Original JSON
                VStack(alignment: .leading, spacing: 6) {
                    Text("Original Wire Response")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    ScrollView {
                        Text(String(data: originalData, encoding: .utf8) ?? "Empty")
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .frame(minWidth: 280)

                // Right: Transformed Localized Mock
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Transformed Mock Response")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: copyToClipboard) {
                            Label(copied ? "Copied!" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ScrollView {
                        Text(transformResult.transformedString)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .frame(minWidth: 280)
            }

            Divider()

            // Footer Actions
            HStack {
                Text(selectedPreset.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                if let onSave = onSaveAsMock {
                    Button(action: {
                        onSave(transformResult.transformedData)
                        onClose()
                    }) {
                        Label("Apply as Active Mock", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private func metricBadge(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transformResult.transformedString, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
