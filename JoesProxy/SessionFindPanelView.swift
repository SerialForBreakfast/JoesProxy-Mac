import SwiftUI

struct SessionFindPanelView: View {
    @ObservedObject var viewModel: ProxyViewModel
    let onSelectResult: (SessionFindResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    /// Local draft text. Only committed to the view model when Find is submitted,
    /// preventing per-keystroke objectWillChange broadcasts to the full view tree.
    @State private var queryDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchControls
            statusRow
            resultsList
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 660, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 560, minHeight: 420)
        .accessibilityIdentifier("sessionFindPanel")
        .onAppear {
            SessionFindPerformanceSignposts.emitPanelOpen()
            queryDraft = viewModel.sessionFindQuery
        }
    }

    // MARK: - Actions

    private func submitFind() {
        viewModel.sessionFindQuery = queryDraft
        viewModel.runSessionFind()
    }

    private var canSubmit: Bool {
        viewModel.hasSessions && !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Find in Bodies")
                .appFont(.title3, scale: textScale, weight: .semibold)

            Text("Search retained UTF-8 request and response bodies across all sessions.")
                .appFont(.subheadline, scale: textScale)
                .foregroundStyle(.secondary)
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            TextField("Search body text", text: $queryDraft)
                .textFieldStyle(.roundedBorder)
                .appFont(.body, scale: textScale)
                .onSubmit { submitFind() }
                .accessibilityIdentifier("sessionFindQueryField")

            Button { submitFind() } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!canSubmit || viewModel.sessionFindState == .searching)
            .accessibilityIdentifier("sessionFindRunButton")

            Button {
                queryDraft = ""
                viewModel.clearSessionFind()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(queryDraft.isEmpty && viewModel.sessionFindResults.isEmpty)
            .accessibilityIdentifier("sessionFindClearButton")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if viewModel.sessionFindState == .searching {
                ProgressView()
                    .controlSize(.small)
            }

            Text(statusText)
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sessionFindStatusText")

            Spacer()
        }
        .frame(minHeight: 18)
    }

    private var resultsList: some View {
        VStack(spacing: 8) {
            List(viewModel.sessionFindDisplayedResults) { result in
                Button {
                    viewModel.selectSessionFindResult(result)
                    onSelectResult(result)
                    dismiss()
                } label: {
                    SessionFindResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("sessionFindResultsList")

            if viewModel.sessionFindHiddenResultCount > 0 {
                Button {
                    viewModel.showMoreSessionFindResults()
                } label: {
                    Text("Show \(viewModel.sessionFindHiddenResultCount) more…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessionFindShowMoreButton")
            }
        }
    }

    private var statusText: String {
        switch viewModel.sessionFindState {
        case .idle:
            return viewModel.hasSessions ? "Enter text and press Find." : "No captured sessions."
        case .searching:
            return "Searching..."
        case .emptyQuery:
            return "Enter text to search."
        case .bodyUnavailable:
            return "Body unavailable"
        case .noMatches:
            return "No matches"
        case .results(let matchCount, _):
            if viewModel.sessionFindHiddenResultCount > 0 {
                return "Showing \(viewModel.sessionFindDisplayedResults.count) of \(matchCount) matches"
            }
            return matchCount == 1 ? "1 match" : "\(matchCount) matches"
        }
    }
}

private struct SessionFindResultRow: View {
    let result: SessionFindResult

    @Environment(\.appTextScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(result.method)
                .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(result.host)\(result.path)")
                        .appFont(.body, scale: textScale, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let statusCode = result.statusCode {
                        Text(verbatim: "\(statusCode)")
                            .appFont(.caption, scale: textScale, design: .monospaced)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(result.location.title) - \(matchCountText)")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var matchCountText: String {
        result.matchCount == 1 ? "1 occurrence" : "\(result.matchCount) occurrences"
    }
}
