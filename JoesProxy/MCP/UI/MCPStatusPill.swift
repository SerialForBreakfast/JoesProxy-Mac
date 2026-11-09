import SwiftUI

/// MCP title-bar pill driven by ``MCPPipelineStatus`` (AJ-1).
struct MCPStatusPill: View {
    let status: MCPPipelineStatus
    let textScale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if status.shouldPulse {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(status.tone.color)
                        .font(.system(size: 7))
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityHidden(true)
                }

                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tone.color)
                    .accessibilityHidden(true)

                HStack(spacing: 4) {
                    Text(verbatim: status.label)
                    if status.badgeCount > 0 {
                        Text(verbatim: "\(status.badgeCount)")
                            .appFont(.caption2, scale: textScale, weight: .bold)
                    }
                }
                .appFont(.caption, scale: textScale, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(status.tone.color.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mcpStatusPill")
        .accessibilityLabel(status.label)
        .accessibilityValue(status.detail ?? "")
        .help(status.detail ?? status.label)
    }
}

private extension MCPPipelineStatus.Tone {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .attention: return .orange
        case .problem: return .red
        case .idle: return .secondary
        }
    }
}
