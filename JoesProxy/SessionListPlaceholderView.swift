//
//  SessionListPlaceholderView.swift
//  JoesProxy
//
//  Empty-state view displayed in the session table when no sessions have been captured.
//  Includes a ghost skeleton row (PlaceholderSessionRow) used to suggest the table layout.
//

import SwiftUI

struct SessionListPlaceholderView: View {
    @Environment(\.appTextScale) private var appTextScale
    let proxyPort: UInt16

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("No Sessions Yet")
                    .appFont(.title2, scale: appTextScale, weight: .semibold)

                Text("Start the proxy and captured traffic will appear here.")
                    .foregroundStyle(.secondary)

                Text(verbatim: "Listening on port \(proxyPort)")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 10) {
                PlaceholderSessionRow(methodWidth: 84, domainWidth: 190, statusWidth: 72, durationWidth: 88)
                Divider().opacity(0.2)
                PlaceholderSessionRow(methodWidth: 84, domainWidth: 190, statusWidth: 72, durationWidth: 88)
                Divider().opacity(0.2)
                PlaceholderSessionRow(methodWidth: 84, domainWidth: 190, statusWidth: 72, durationWidth: 88)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sessions yet. Start the proxy and captured traffic will appear here.")
        .accessibilityIdentifier("sessionEmptyStatePlaceholder")
    }
}

struct PlaceholderSessionRow: View {
    let methodWidth: CGFloat
    let domainWidth: CGFloat
    let statusWidth: CGFloat
    let durationWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 36, height: 8)
                .frame(width: methodWidth, alignment: .leading)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 92, height: 8)
                .frame(width: domainWidth, alignment: .leading)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 28, height: 8)
                .frame(width: statusWidth, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 42, height: 8)
                .frame(width: durationWidth, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}


