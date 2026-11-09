//
//  SessionExplorerFolderDetailView.swift
//  JoesProxy
//
//  The detail panel shown in the main window when a folder node is selected in
//  Explorer view. Displays aggregate stats and a session list for the folder.
//  Extracted from ContentView for independent compilation and testability.
//

import SwiftUI

struct ExplorerFolderDetailView: View {
    @Environment(\.appTextScale) private var appTextScale
    let node: SessionExplorerNode
    let sessionSummaries: [SessionSummary]
    let grouping: SessionExplorerGrouping
    let onSelectSession: (SessionRecord.ID) -> Void
    let onAddBookmark: (SessionRecord.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(node.title, systemImage: explorerFolderIconName)
                        .appFont(.title3, scale: appTextScale, weight: .semibold)

                    if !node.breadcrumbs.isEmpty {
                        Text(node.breadcrumbs.joined(separator: " > "))
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 12) {
                        summaryPill(title: "Requests", value: "\(node.aggregateCount)", tint: .secondary)

                        if node.failedCount > 0 {
                            summaryPill(title: "Failed", value: "\(node.failedCount)", tint: .orange)
                        }

                        if let latestActivity = node.latestActivity {
                            summaryPill(
                                title: "Latest",
                                value: latestActivity.formatted(date: .omitted, time: .shortened),
                                tint: .secondary
                            )
                        }
                    }
                }

                Divider()

                if sessionSummaries.isEmpty {
                    ContentUnavailableView {
                        Label("No Requests In Group", systemImage: "folder")
                    } description: {
                        Text("This explorer node does not have any visible requests after the current filters were applied.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Requests")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)

                        ForEach(sessionSummaries) { summary in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    onSelectSession(summary.id)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: sessionIconName(for: summary))
                                            .appFont(.caption, scale: appTextScale)
                                            .foregroundStyle(sessionIconTint(for: summary))
                                            .frame(width: 14, alignment: .center)

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                Text(summary.method)
                                                    .appFont(.subheadline, scale: appTextScale, weight: .semibold, design: .monospaced)

                                                Text(statusText(for: summary))
                                                    .appFont(.caption, scale: appTextScale, weight: .semibold, design: .monospaced)
                                                    .foregroundStyle(statusColor(for: summary))

                                                Text(durationText(for: summary))
                                                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(lineText(for: summary))
                                                .appFont(.caption, scale: appTextScale, design: .monospaced)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .truncationMode(.middle)
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    onAddBookmark(summary.id)
                                } label: {
                                    Image(systemName: "bookmark")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                }
                                .buttonStyle(.borderless)
                                .help("Add this request to bookmarks.")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func lineText(for summary: SessionSummary) -> String {
        switch grouping {
        case .byHost:
            return summary.path
        case .byEndpoint:
            return "\(summary.host)\(summary.path)"
        case .bySource:
            return "\(summary.host)\(summary.path)"
        }
    }

    private func summaryPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.caption, scale: appTextScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func statusText(for summary: SessionSummary) -> String {
        switch summary.responseSource {
        case .localOverride:
            return "Local"
        case .blocked:
            return "Blocked"
        case .mapRemote:
            return "Remapped"
        case .bookmarkRewrite:
            return "Rewrite"
        case .bookmarkResponseRewrite:
            return "Bk Response"
        case .liveResponseRewrite:
            return "Live Rewrite"
        case .upstream, nil:
            break
        }
        if summary.inspectionKind == .tunneledTLS {
            return "Tunnel"
        }
        if let statusCode = summary.statusCode {
            return String(statusCode)
        }
        switch summary.state {
        case .pending:
            return "Pending"
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func statusColor(for summary: SessionSummary) -> Color {
        switch summary.responseSource {
        case .localOverride:
            return .teal
        case .blocked:
            return .red
        case .mapRemote:
            return .indigo
        case .bookmarkRewrite:
            return .blue
        case .bookmarkResponseRewrite:
            return .teal
        case .liveResponseRewrite:
            return .teal
        case .upstream, nil:
            break
        }
        if summary.inspectionKind == .tunneledTLS {
            return .orange
        }
        guard let statusCode = summary.statusCode else {
            switch summary.state {
            case .failed:
                return .red
            case .cancelled:
                return .orange
            default:
                return .secondary
            }
        }

        switch statusCode {
        case 200..<400:
            return .green
        case 400..<500:
            return .orange
        case 500...599:
            return .red
        default:
            return .secondary
        }
    }

    private func durationText(for summary: SessionSummary) -> String {
        guard let duration = summary.duration else {
            return lifecycleText(for: summary.state)
        }

        return duration.formatted(.number.precision(.fractionLength(3))) + "s"
    }

    private func sessionIconName(for summary: SessionSummary) -> String {
        switch summary.inspectionKind {
        case .plain:
            return "globe"
        case .interceptedTLS:
            return "lock.fill"
        case .tunneledTLS:
            return "lock.slash"
        }
    }

    private func sessionIconTint(for summary: SessionSummary) -> Color {
        switch summary.responseSource {
        case .localOverride:
            return .teal
        case .blocked:
            return .red
        case .mapRemote:
            return .indigo
        case .bookmarkRewrite:
            return .blue
        case .bookmarkResponseRewrite:
            return .teal
        case .liveResponseRewrite:
            return .teal
        case .upstream, nil:
            break
        }

        switch summary.inspectionKind {
        case .plain:
            return .secondary
        case .interceptedTLS:
            return .green
        case .tunneledTLS:
            return .orange
        }
    }

    private func lifecycleText(for state: SessionLifecycleState) -> String {
        switch state {
        case .pending:
            return "Pending"
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var explorerFolderIconName: String {
        switch node.role {
        case .domainFamily:
            return "square.stack.3d.up.fill"
        case .host:
            return "globe"
        case .path:
            return "folder"
        case .request:
            return "circle.fill"
        }
    }
}
