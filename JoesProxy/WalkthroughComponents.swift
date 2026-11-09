import SwiftUI

// Shared step-card building blocks used by all device-setup walkthroughs.

enum WalkthroughStepStatus {
    case todo
    case inProgress(String)
    case done(String)
    case attention(String)
    case manual
}

@ViewBuilder
func walkthroughStepCard<Content: View>(
    _ number: Int,
    _ title: String,
    status: WalkthroughStepStatus,
    @ViewBuilder content: () -> Content
) -> some View {
    GroupBox {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    } label: {
        HStack(spacing: 8) {
            walkthroughStepIcon(number: number, status: status)
            Text(title)
                .fontWeight(.semibold)
            Spacer()
            walkthroughStepBadge(status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title), \(walkthroughStepAccessibilityText(status))")
    }
}

@ViewBuilder
func walkthroughStepIcon(number: Int, status: WalkthroughStepStatus) -> some View {
    switch status {
    case .todo:
        Image(systemName: "\(number).circle")
            .foregroundStyle(.secondary)
    case .inProgress:
        ProgressView()
            .controlSize(.small)
    case .done:
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
    case .attention:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    case .manual:
        Image(systemName: "hand.tap.fill")
            .foregroundStyle(.secondary)
    }
}

@ViewBuilder
func walkthroughStepBadge(_ status: WalkthroughStepStatus) -> some View {
    switch status {
    case .todo:
        EmptyView()
    case .inProgress(let text):
        Text(text).font(.caption).foregroundStyle(.secondary)
    case .done(let text):
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.green)
    case .attention(let text):
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.orange)
    case .manual:
        Text("Manual").font(.caption).foregroundStyle(.secondary)
    }
}

func walkthroughStepAccessibilityText(_ status: WalkthroughStepStatus) -> String {
    switch status {
    case .todo: return "to do"
    case .inProgress(let text): return text
    case .done(let text): return text
    case .attention(let text): return text
    case .manual: return "manual"
    }
}
