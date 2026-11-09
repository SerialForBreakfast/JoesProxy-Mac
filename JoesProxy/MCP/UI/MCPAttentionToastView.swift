import SwiftUI

/// Transient noticed-tier toast for sensitive MCP reads (AJ-5).
struct MCPAttentionToastView: View {
    let message: MCPAttentionToastMessage
    let textScale: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.message)
                    .appFont(.caption, scale: textScale, weight: .semibold)
                Text("Client \(message.clientLabel)")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            }
            Button("Dismiss") { onDismiss() }
                .appFont(.caption, scale: textScale)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mcpAttentionToast")
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                onDismiss()
            }
        }
    }
}
