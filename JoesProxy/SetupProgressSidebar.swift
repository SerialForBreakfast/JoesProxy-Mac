import SwiftUI

// MARK: - Model

enum SidebarStepState {
    case pending
    case inProgress(String)
    case done(Date?)
    case manual(confirmed: Bool)
    case attention(String)
}

struct SidebarStep: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let detail: String
    var state: SidebarStepState
    /// Non-nil for manual steps that have not yet been confirmed. Sidebar renders a "Mark done"
    /// button that calls this when tapped.
    var onConfirm: (() -> Void)?
}

// MARK: - View

/// Vertical timeline sidebar showing completion state for setup walkthroughs.
///
/// Each step has a circle icon, connector line, title, detail, and an optional
/// timestamp. Manual steps that haven't been confirmed show a "Mark done" button
/// so users can self-report completion of steps that can't be auto-detected.
struct SetupProgressSidebar: View {
    let title: String
    let steps: [SidebarStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, isLast: index == steps.count - 1)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Row

    @ViewBuilder
    private func stepRow(_ step: SidebarStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Left: circle + connector
            VStack(spacing: 0) {
                stepCircle(step)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2, height: 32)
                }
            }
            .frame(width: 28)

            // Right: title + detail + extras
            stepContent(step)
                .padding(.bottom, isLast ? 0 : 8)
        }
    }

    // MARK: - Circle

    @ViewBuilder
    private func stepCircle(_ step: SidebarStep) -> some View {
        ZStack {
            Circle()
                .fill(accentColor(step).opacity(0.12))
                .frame(width: 28, height: 28)

            switch step.state {
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            case .manual(let confirmed):
                Image(systemName: confirmed ? step.icon : "hand.tap")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor(step))
            default:
                Image(systemName: step.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor(step))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func stepContent(_ step: SidebarStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(step.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(titleColor(step))

            Text(step.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch step.state {
            case .done(let date):
                if let date {
                    Text(Self.timeFormatter.string(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .inProgress(let label):
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.blue)
            case .attention(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .manual(let confirmed):
                if !confirmed, let onConfirm = step.onConfirm {
                    Button("Mark done", action: onConfirm)
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .padding(.top, 2)
                }
            case .pending:
                EmptyView()
            }
        }
    }

    // MARK: - Colors

    private func accentColor(_ step: SidebarStep) -> Color {
        switch step.state {
        case .pending:             return .secondary
        case .inProgress:          return .blue
        case .done:                return .green
        case .manual(let confirmed): return confirmed ? .green : .secondary
        case .attention:           return .orange
        }
    }

    private func titleColor(_ step: SidebarStep) -> Color {
        switch step.state {
        case .pending:               return .secondary
        case .manual(false):         return .secondary
        default:                     return .primary
        }
    }

    // MARK: - Formatter

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
