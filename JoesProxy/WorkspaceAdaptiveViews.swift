import SwiftUI

struct SessionFilterPill: Identifiable {
    let id: String
    let label: String
    let remove: () -> Void
}

struct WorkspaceToastView: View {
    let toast: WorkspaceToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(toast.message)
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
        .accessibilityIdentifier("workspaceToast")
    }
}

struct WorkspacePersistentNoticeView: View {
    let notice: WorkspacePersistentNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.severity == .blocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.severity == .blocking ? Color.orange : Color.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).fontWeight(.semibold)
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if notice.isDismissible {
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((notice.severity == .blocking ? Color.orange : Color.blue).opacity(0.10))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspacePersistentNotice")
    }
}

struct WorkspaceNoticeRegion: View {
    @Environment(\.appTextScale) private var textScale
    let notices: [WorkspacePersistentNotice]
    let constrained: Bool
    let perform: (String) -> Void
    let dismiss: (String) -> Void

    static func ordered(_ notices: [WorkspacePersistentNotice]) -> [WorkspacePersistentNotice] {
        notices.sorted { $0.severity == $1.severity ? $0.id < $1.id : $0.severity > $1.severity }
    }

    var body: some View {
        if let first = Self.ordered(notices).first {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(first.title, systemImage: "exclamationmark.circle")
                        .appFont(.caption, scale: textScale, weight: .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !constrained, let action = first.actionID {
                        Button(first.actionTitle ?? "Resolve") { perform(action) }
                    }
                    Button(notices.count > 1 ? "\(notices.count - 1) more issues" : "Details") {
                        perform(first.actionID ?? "all")
                    }
                    .accessibilityLabel("Show all \(notices.count) workspace issues")
                    .accessibilityIdentifier("workspaceNoticeDetails")
                }
                if !constrained {
                    Text(first.message).appFont(.caption, scale: textScale).lineLimit(2)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspaceNoticeRegion")
        }
    }
}
