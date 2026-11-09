//
//  BookmarkPanelView.swift
//  JoesProxy
//
//  The bookmark inspector panel and its companion merge/update sheet. Extracted from
//  ContentView for independent compilation and testability.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BookmarkDetailView: View {
    @Environment(\.appTextScale) private var appTextScale
    let bookmark: Bookmark?
    let canExecute: Bool
    let executionMessage: String?
    let executionState: ProxyViewModel.BookmarkExecutionState
    let isProxyRunning: Bool
    let isResponseRewriteEnabled: Bool
    let canEnableResponseRewrite: Bool
    let onExecute: (Bookmark.ID) async -> Void
    let onRename: (Bookmark.ID, String) -> Void
    let onUpdateRequest: (Bookmark.ID, CapturedRequest) -> Void
    let onDelete: (Bookmark.ID) -> Void
    let onEnableResponseRewrite: (Bookmark.ID) -> Void
    let onDisableResponseRewrite: (Bookmark.ID) -> Void
    let onUpdateResponseMatchMode: (Bookmark.ID, ResponseOverrideMatchMode) -> Void
    let onAddResponseRewrite: (Bookmark.ID, String, String, JSONMutationOperation, BookmarkResponseRewriteValueInputMode) -> Void
    let onRemoveResponseRewrite: (Bookmark.ID, UUID) -> Void
    let onSetResponseRewriteEnabled: (Bookmark.ID, UUID, Bool) -> Void
    let onUpdateResponseRewriteOverride: (Bookmark.ID, UUID, String, BookmarkResponseRewriteValueInputMode) -> Void
    let onUpdateResponseRewritePath: (Bookmark.ID, UUID, String) -> Void
    let onSetResponseRewriteOperation: (Bookmark.ID, UUID, JSONMutationOperation) -> Void
    let responseRewriteApplicability: (applicable: Int, enabled: Int)?
    let responseRewriteActivity: BookmarkResponseRewriteActivity?
    let trafficHints: [String]
    let savedResponseRefreshCandidate: BookmarkSavedResponseRefreshCandidate?
    let onRefreshSavedResponse: (Bookmark.ID) -> BookmarkSavedResponseRefreshResult
    let onClearSavedResponse: (Bookmark.ID) -> Void
    let onOpenResponseRewriteHelp: () -> Void

    @State private var responseJSONViewMode: JSONViewMode = .folder
    @State private var newRewritePath = ""
    @State private var newRewriteValue = ""
    @State private var newRewriteOperation: JSONMutationOperation = .set
    @State private var newRewriteValueInputMode: BookmarkResponseRewriteValueInputMode = .auto
    @State private var rewriteValueInputModes: [UUID: BookmarkResponseRewriteValueInputMode] = [:]
    @State private var savedResponsePaneHeight: CGFloat = 240
    @State private var showPatchedResponsePreview = false
    @State private var cachedSavedResponseSource: JSONContentSource?
    @State private var cachedSavedResponseKey: String?
    @State private var refreshSavedResponseConfirmationPresented = false
    @State private var refreshSavedResponseFeedback: String?
    @State private var savedResponseTreeExpandedIDs: Set<String> = ["root"]
    @State private var savedResponseScrollAnchorPath: String?

    private static let savedResponsePaneMinHeight: CGFloat = 120
    private static let savedResponsePaneMaxHeight: CGFloat = 560

    private var inspectorSectionSpacing: CGFloat {
        if appTextScale < 1 {
            return 10
        } else if appTextScale <= 1.1 {
            return 12
        } else if appTextScale <= 1.25 {
            return 14
        } else if appTextScale <= 1.4 {
            return 16
        } else {
            return 18
        }
    }

    var body: some View {
        if let bookmark {
            ScrollView {
                VStack(alignment: .leading, spacing: inspectorSectionSpacing) {
                    HStack {
                        Label("Bookmark Inspector", systemImage: "bookmark")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)

                        Spacer()

                        Button {
                            Task {
                                await onExecute(bookmark.id)
                            }
                        } label: {
                            if case .executing(let bookmarkID) = executionState,
                               bookmarkID == bookmark.id {
                                Label("Running…", systemImage: "hourglass")
                            } else {
                                Label("Run", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canExecute)
                        .help(executionMessage ?? "Run this bookmark through JoesProxy.")

                        Button(role: .destructive) {
                            onDelete(bookmark.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    GroupBox("Bookmark") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(
                                "Bookmark Name",
                                text: Binding(
                                    get: { bookmark.name },
                                    set: { onRename(bookmark.id, $0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            metadataRow("Created", value: bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                            metadataRow(
                                "Last Executed",
                                value: bookmark.lastExecutedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
                            )

                            if let executionMessage {
                                Text(executionMessage)
                                    .appFont(.caption, scale: appTextScale)
                                    .foregroundStyle(executionStateTint(for: bookmark.id))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    }

                    responseRewriteBanner(for: bookmark)

                    savedResponseSection(for: bookmark)

                    responseRewritesSection(for: bookmark)

                    GroupBox("Request Summary") {
                        Text(requestSummary(bookmark))
                            .appFont(.body, scale: appTextScale, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }

                    GroupBox("Request Target") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Scheme")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)

                                    Picker(
                                        "Scheme",
                                        selection: Binding(
                                            get: { bookmark.request.scheme },
                                            set: { newScheme in
                                                onUpdateRequest(
                                                    bookmark.id,
                                                    updatedRequest(
                                                        bookmark.request,
                                                        scheme: newScheme
                                                    )
                                                )
                                            }
                                        )
                                    ) {
                                        Text("HTTPS").tag(SessionScheme.https)
                                        Text("HTTP").tag(SessionScheme.http)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 120)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Method")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)

                                    Text(bookmark.request.method)
                                        .appFont(.body, scale: appTextScale, design: .monospaced)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Host")
                                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                                    .foregroundStyle(.secondary)

                                TextField(
                                    "api.example.com",
                                    text: Binding(
                                        get: { bookmark.request.host },
                                        set: { newHost in
                                            onUpdateRequest(
                                                bookmark.id,
                                                updatedRequest(
                                                    bookmark.request,
                                                    host: newHost
                                                )
                                            )
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Path And Query")
                                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                                    .foregroundStyle(.secondary)

                                TextField(
                                    "/events?sessionToken=updated",
                                    text: Binding(
                                        get: { bookmark.request.path },
                                        set: { newPath in
                                            onUpdateRequest(
                                                bookmark.id,
                                                updatedRequest(
                                                    bookmark.request,
                                                    path: newPath
                                                )
                                            )
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            metadataRow("Port", value: bookmark.request.port.map(String.init) ?? "Default")
                        }
                        .padding(.top, 6)
                    }

                    GroupBox("Request Headers") {
                        VStack(alignment: .leading, spacing: 10) {
                            if bookmark.request.headers.isEmpty {
                                Text("No request headers captured.")
                                    .appFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(bookmark.request.headers.enumerated()), id: \.offset) { index, header in
                                    HStack(alignment: .center, spacing: 8) {
                                        TextField(
                                            "Header Name",
                                            text: Binding(
                                                get: { header.name },
                                                set: { newName in
                                                    onUpdateRequest(
                                                        bookmark.id,
                                                        updatedRequest(
                                                            bookmark.request,
                                                            headers: updatingHeader(
                                                                at: index,
                                                                in: bookmark.request.headers,
                                                                name: newName,
                                                                value: header.value
                                                            )
                                                        )
                                                    )
                                                }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minWidth: 180)

                                        TextField(
                                            "Header Value",
                                            text: Binding(
                                                get: { header.value },
                                                set: { newValue in
                                                    onUpdateRequest(
                                                        bookmark.id,
                                                        updatedRequest(
                                                            bookmark.request,
                                                            headers: updatingHeader(
                                                                at: index,
                                                                in: bookmark.request.headers,
                                                                name: header.name,
                                                                value: newValue
                                                            )
                                                        )
                                                    )
                                                }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)

                                        Button(role: .destructive) {
                                            onUpdateRequest(
                                                bookmark.id,
                                                updatedRequest(
                                                    bookmark.request,
                                                    headers: removingHeader(
                                                        at: index,
                                                        from: bookmark.request.headers
                                                    )
                                                )
                                            )
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Remove header")
                                    }
                                }
                            }

                            Button {
                                var headers = bookmark.request.headers
                                headers.append(HTTPHeaderField(name: "", value: ""))
                                onUpdateRequest(
                                    bookmark.id,
                                    updatedRequest(bookmark.request, headers: headers)
                                )
                            } label: {
                                Label("Add Header", systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .padding(.top, 6)
                    }

                    GroupBox("Request Body") {
                        VStack(alignment: .leading, spacing: 10) {
                            if BookmarkRequestEditing.supportsTextBodyEditing(for: bookmark.request) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text("Format")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)

                                    Text(BookmarkRequestEditing.bodyFormatLabel(for: bookmark.request))
                                        .appFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    if let prettyPrintedJSON = BookmarkRequestEditing.prettyPrintedJSONText(for: bookmark.request) {
                                        Button("Format JSON") {
                                            onUpdateRequest(
                                                bookmark.id,
                                                updatedRequest(
                                                    bookmark.request,
                                                    bodyData: BookmarkRequestEditing.bodyData(from: prettyPrintedJSON)
                                                )
                                            )
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                    }
                                }

                                TextEditor(
                                    text: Binding(
                                        get: { BookmarkRequestEditing.bodyEditorText(for: bookmark.request) },
                                        set: { newBodyText in
                                            onUpdateRequest(
                                                bookmark.id,
                                                updatedRequest(
                                                    bookmark.request,
                                                    bodyData: BookmarkRequestEditing.bodyData(from: newBodyText)
                                                )
                                            )
                                        }
                                    )
                                )
                                .appFont(.body, scale: appTextScale, design: .monospaced)
                                .frame(minHeight: 160)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.secondary.opacity(0.15))
                                )

                                if let bodyValidationMessage = BookmarkRequestEditing.bodyValidationMessage(for: bookmark.request) {
                                    Text(bodyValidationMessage)
                                        .appFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.orange)
                                }

                                Text("Body bytes: \(bookmark.request.bodyData?.count ?? 0)")
                                    .appFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Binary request bodies are shown read-only right now.")
                                    .appFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)

                                Text(bodyText(for: bookmark.request))
                                    .appFont(.body, scale: appTextScale, design: .monospaced)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Selected bookmark details")
        } else {
            ContentUnavailableView {
                Label("No Bookmark Selected", systemImage: "bookmark")
            } description: {
                Text("Select a saved bookmark to inspect its request details.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .appFont(.caption, scale: appTextScale, design: .monospaced)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func responseRewriteBanner(for bookmark: Bookmark) -> some View {
        if bookmark.savedResponse == nil {
            GroupBox {
                Label("No saved response — bookmark request only", systemImage: "info.circle")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        } else if bookmark.enabledResponseRewriteCount == 0 {
            GroupBox {
                Text("Saved response attached. Add field rewrites below to configure intercept behavior.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        } else if isResponseRewriteEnabled {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            "Response rewrites active · intercepting matching traffic",
                            systemImage: "checkmark.circle.fill"
                        )
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.green)

                        Spacer()

                        Button("Disable") {
                            onDisableResponseRewrite(bookmark.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("Matches \(bookmark.request.method) \(bookmark.request.host)\(normalizedMatchPath(for: bookmark))")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let activity = responseRewriteActivity {
                        if activity.hasIntercepted, let lastInterceptAt = activity.lastInterceptAt {
                            Text(
                                "Last intercept: \(lastInterceptAt.formatted(.relative(presentation: .named))) · \(activity.lastAppliedCount) applied, \(activity.lastSkippedCount) skipped"
                            )
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)

                            if !activity.lastAppliedPaths.isEmpty {
                                Text(verbatim: "Applied: \(activity.lastAppliedPaths.joined(separator: ", "))")
                                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                            }
                            if !activity.lastSkippedPaths.isEmpty {
                                Text(verbatim: "Skipped: \(activity.lastSkippedPaths.joined(separator: ", "))")
                                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Waiting for matching traffic… Re-trigger the request in your client.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)

                            Text("If the app shows unchanged data, it may be using a cached response — force refresh or navigate away and back.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !trafficHints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recent traffic used different paths:")
                                .appFont(.caption, scale: appTextScale, weight: .semibold)
                                .foregroundStyle(.orange)
                            ForEach(trafficHints, id: \.self) { path in
                                Text(verbatim: path)
                                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if let responseRewriteApplicability {
                        rewriteApplicabilityText(
                            applicable: responseRewriteApplicability.applicable,
                            enabled: responseRewriteApplicability.enabled
                        )
                    }

                    Text("Stopping the proxy clears session enablement.")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else {
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "\(bookmark.enabledResponseRewriteCount) response rewrite\(bookmark.enabledResponseRewriteCount == 1 ? "" : "s") configured",
                            systemImage: "pencil.and.outline"
                        )
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.orange)

                        Text(isProxyRunning
                            ? "Not active this session. Enable to intercept matching traffic."
                            : "Start the proxy, then enable response rewrites for this session.")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Enable for Session") {
                        onEnableResponseRewrite(bookmark.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canEnableResponseRewrite)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func savedResponseSection(for bookmark: Bookmark) -> some View {
        let showsRefreshBanner = shouldShowSavedResponseRefreshBanner(for: bookmark)

        GroupBox("Saved Response") {
            VStack(alignment: .leading, spacing: 10) {
                if showsRefreshBanner {
                    savedResponseRefreshBanner(for: bookmark)
                }

                if let refreshSavedResponseFeedback {
                    Text(refreshSavedResponseFeedback)
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(refreshFeedbackColor(refreshSavedResponseFeedback))
                }

                savedResponseToolbar(for: bookmark, showsRefreshBanner: showsRefreshBanner)

                if let source = cachedSavedResponseSource {
                    Picker("View", selection: $responseJSONViewMode) {
                        ForEach(JSONViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    VStack(spacing: 0) {
                        JSONContentView(
                            source: source,
                            viewMode: $responseJSONViewMode,
                            findQuery: nil,
                            findNavigationID: nil,
                            findDebugLoggingEnabled: false,
                            onAddFieldRewrite: { path, value in
                                prefillFieldRewrite(path: path, value: value)
                            },
                            treeExpandedIDs: $savedResponseTreeExpandedIDs,
                            treeScrollAnchorPath: savedResponseScrollAnchorPath,
                            preservesScrollPositionOnContentChange: usesFullBodyPreview(for: bookmark),
                            previewOverridesByPath: surgicalPreviewOverrides(for: bookmark)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()

                        savedResponsePaneResizeHandle
                    }
                    .frame(
                        height: min(
                            max(savedResponsePaneHeight, Self.savedResponsePaneMinHeight),
                            Self.savedResponsePaneMaxHeight
                        ),
                        alignment: .topLeading
                    )
                } else if bookmark.savedResponse?.bodyData != nil {
                    ProgressView("Loading saved response…")
                        .frame(maxWidth: .infinity, minHeight: Self.savedResponsePaneMinHeight)
                } else if bookmark.savedResponse != nil {
                    Text("Saved response body is empty or not JSON.")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
        .confirmationDialog(
            "Replace saved response?",
            isPresented: $refreshSavedResponseConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Refresh Saved Response", role: .destructive) {
                performSavedResponseRefresh(for: bookmark)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(refreshSavedResponseConfirmationMessage)
        }
        .onAppear {
            refreshCachedSavedResponseSource(for: bookmark)
        }
        .onChange(of: bookmark.id) { _, _ in
            savedResponseTreeExpandedIDs = ["root"]
            savedResponseScrollAnchorPath = nil
            refreshCachedSavedResponseSource(for: bookmark)
        }
        .onChange(of: showPatchedResponsePreview) { _, _ in
            if usesFullBodyPreview(for: bookmark) {
                refreshCachedSavedResponseSource(for: bookmark)
            }
        }
        .onChange(of: bookmark.savedResponse?.savedAt) { _, _ in
            refreshCachedSavedResponseSource(for: bookmark)
        }
        .onChange(of: bookmark.responseRewrites) { _, _ in
            if usesFullBodyPreview(for: bookmark) {
                refreshCachedSavedResponseSource(for: bookmark)
            }
        }
    }

    private var refreshSavedResponseConfirmationMessage: String {
        guard let candidate = savedResponseRefreshCandidate else {
            return "No matching captured session was found for this bookmark URL."
        }

        let capturedAt = candidate.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "Replace the saved body from \(candidate.method) \(candidate.host)\(candidate.path) captured \(capturedAt)?"
    }

    private func refreshFeedbackColor(_ message: String) -> Color {
        message.contains("Refreshed") ? .green : .orange
    }

    @ViewBuilder
    private func savedResponseToolbar(for bookmark: Bookmark, showsRefreshBanner: Bool) -> some View {
        HStack {
            if let savedResponse = bookmark.savedResponse {
                Text("Status \(savedResponse.statusCode) · saved \(savedResponse.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            } else {
                Text("No saved response on this bookmark.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            Spacer()

                    if bookmark.enabledResponseRewriteCount > 0 {
                        Toggle(isOn: $showPatchedResponsePreview) {
                            Text("Preview Patches")
                                .appFont(.caption, scale: appTextScale)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(previewPatchesHelpText(for: bookmark))
                    }

            Group {
                if showsRefreshBanner {
                    Button("Update Saved Response") {
                        refreshSavedResponseConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Update Saved Response") {
                        refreshSavedResponseConfirmationPresented = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            .controlSize(.small)
            .disabled(bookmark.savedResponse == nil)
            .accessibilityIdentifier("bookmarkUpdateSavedResponseButton")

            Button("Clear Saved Response") {
                onClearSavedResponse(bookmark.id)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(bookmark.savedResponse == nil)
        }
    }

    @ViewBuilder
    private func responseRewritesSection(for bookmark: Bookmark) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Response Rewrites")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)

                    ContextHelpButton(
                        accessibilityLabel: "Bookmark response rewrite help",
                        accessibilityHint: "Explains saved response rewrites, JSON paths, preview, and session enablement.",
                        accessibilityIdentifier: "bookmarkResponseRewriteHelpButton"
                    ) {
                        BookmarkResponseRewritesQuickHelp(onOpenHelpTopic: onOpenResponseRewriteHelp)
                    }

                    Spacer()
                }

                Picker(
                    "Match Mode",
                    selection: Binding(
                        get: { bookmark.responseMatchMode },
                        set: { onUpdateResponseMatchMode(bookmark.id, $0) }
                    )
                ) {
                    ForEach(ResponseOverrideMatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                if bookmark.responseRewrites.isEmpty {
                    Text("No field rewrites configured.")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bookmark.responseRewrites) { rewrite in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { rewrite.isRuleEnabled },
                                set: { onSetResponseRewriteEnabled(bookmark.id, rewrite.id, $0) }
                            ))
                            .labelsHidden()
                            .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    if rewritePathIsValid(rewrite, bodyData: bookmark.savedResponse?.bodyData) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .help(rewritePathValidationHelp(for: rewrite.operation))
                                    } else {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .help(rewritePathValidationHelp(for: rewrite.operation))
                                    }

                                    Picker(
                                        "Operation",
                                        selection: Binding(
                                            get: { rewrite.operation },
                                            set: { onSetResponseRewriteOperation(bookmark.id, rewrite.id, $0) }
                                        )
                                    ) {
                                        ForEach(JSONMutationOperation.allCases, id: \.self) { operation in
                                            Text(operation.title).tag(operation)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .accessibilityLabel("Rewrite operation")
                                    .accessibilityValue(rewrite.operation.title)

                                    BookmarkRewritePathField(
                                        value: rewrite.jsonPath,
                                        onCommit: { updatedPath in
                                            onUpdateResponseRewritePath(bookmark.id, rewrite.id, updatedPath)
                                        }
                                    )
                                }

                                Picker(
                                    "Value type",
                                    selection: Binding(
                                        get: { rewriteValueInputModes[rewrite.id] ?? valueInputMode(for: rewrite.overrideValue) },
                                        set: { rewriteValueInputModes[rewrite.id] = $0 }
                                    )
                                ) {
                                    ForEach(BookmarkResponseRewriteValueInputMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()

                                BookmarkRewriteOverrideField(
                                    value: rewrite.overrideValue.displayString,
                                    onCommit: { updatedValue in
                                        let mode = rewriteValueInputModes[rewrite.id] ?? valueInputMode(for: rewrite.overrideValue)
                                        onUpdateResponseRewriteOverride(bookmark.id, rewrite.id, updatedValue, mode)
                                    }
                                )

                                if let mismatch = rewriteValueKindMismatchMessage(
                                    path: rewrite.jsonPath,
                                    overrideValue: rewrite.overrideValue,
                                    bodyData: bookmark.savedResponse?.bodyData
                                ) {
                                    Text(mismatch)
                                        .appFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.orange)
                                }

                                if let original = rewrite.originalValueSnapshot {
                                    Text("Original: \(original)")
                                        .appFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 0)

                            Button(role: .destructive) {
                                onRemoveResponseRewrite(bookmark.id, rewrite.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Field Rewrite")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)

                    TextField("JSON path (e.g. movie.title or castNames[1])", text: $newRewritePath)
                        .textFieldStyle(.roundedBorder)

                    Picker("Operation", selection: $newRewriteOperation) {
                        ForEach(JSONMutationOperation.allCases, id: \.self) { operation in
                            Text(operation.title).tag(operation)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Rewrite operation")
                    .accessibilityValue(newRewriteOperation.title)

                    Picker("Value type", selection: $newRewriteValueInputMode) {
                        ForEach(BookmarkResponseRewriteValueInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Override value", text: $newRewriteValue)
                        .textFieldStyle(.roundedBorder)

                    Text("Tip: right-click a field in Folder or Prettified view to fill these automatically. Set overwrites an existing value; Insert adds to an array at index 0 through count (append at count).")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)

                    Button("Add Rewrite") {
                        onAddResponseRewrite(
                            bookmark.id,
                            newRewritePath,
                            newRewriteValue,
                            newRewriteOperation,
                            newRewriteValueInputMode
                        )
                        newRewritePath = ""
                        newRewriteValue = ""
                        newRewriteOperation = .set
                        newRewriteValueInputMode = .auto
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newRewritePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newRewriteValue.isEmpty || bookmark.savedResponse == nil)
                }
            }
            .padding(.top, 6)
        }
    }

    private func savedResponseJSONSource(for bodyData: Data, bookmarkID: Bookmark.ID) -> JSONContentSource? {
        try? JSONContentSource.makeLoaded(from: bodyData, stableID: bookmarkID)
    }

    /// Refreshes the cached JSON source when the saved response body changes or full-body preview is required.
    private func refreshCachedSavedResponseSource(for bookmark: Bookmark) {
        guard let bodyData = displaySavedResponseBodyData(for: bookmark) else {
            cachedSavedResponseSource = nil
            cachedSavedResponseKey = nil
            return
        }

        let cacheKey = savedResponseCacheKey(for: bookmark, bodyData: bodyData)
        guard cacheKey != cachedSavedResponseKey else {
            return
        }

        cachedSavedResponseKey = cacheKey
        cachedSavedResponseSource = savedResponseJSONSource(for: bodyData, bookmarkID: bookmark.id)
    }

    private func savedResponseCacheKey(for bookmark: Bookmark, bodyData: Data) -> String {
        let bodyFingerprint = JSONContentSource.contentDigest(for: bodyData)
        let savedAt = bookmark.savedResponse?.savedAt.timeIntervalSince1970 ?? 0
        return "\(bookmark.id.uuidString)|\(savedAt)|\(bodyFingerprint)"
    }

    private func savedResponseBodyData(for bookmark: Bookmark) -> Data? {
        bookmark.savedResponse?.bodyData
    }

    private func usesFullBodyPreview(for bookmark: Bookmark) -> Bool {
        showPatchedResponsePreview &&
            bookmark.enabledResponseRewriteCount > 0 &&
            BookmarkJSONPreviewOverlay.shouldUseEngineBackedPreview(for: bookmark.responseRewrites)
    }

    private func surgicalPreviewOverrides(for bookmark: Bookmark) -> [String: BookmarkJSONValue] {
        guard showPatchedResponsePreview, !usesFullBodyPreview(for: bookmark) else {
            return [:]
        }
        return BookmarkJSONPreviewOverlay.overrides(from: bookmark.responseRewrites)
    }

    private func previewPatchesHelpText(for bookmark: Bookmark) -> String {
        if usesFullBodyPreview(for: bookmark) {
            return "Applies all enabled rewrites to the full saved response (large rewrite set)."
        }
        return "Overlays enabled field rewrites in Folder and Prettified views without reloading the full JSON body."
    }

    private func prefillFieldRewrite(path: String, value: String) {
        savedResponseScrollAnchorPath = path
        newRewritePath = path
        newRewriteValue = value
    }

    /// Body bytes shown in the saved-response viewer; uses full apply for insert rules or large rewrite sets.
    private func displaySavedResponseBodyData(for bookmark: Bookmark) -> Data? {
        guard let bodyData = savedResponseBodyData(for: bookmark) else {
            return nil
        }

        guard showPatchedResponsePreview, bookmark.enabledResponseRewriteCount > 0 else {
            return bodyData
        }

        if let preview = BookmarkJSONPreviewOverlay.previewBodyData(base: bodyData, rewrites: bookmark.responseRewrites) {
            return preview
        }

        return bodyData
    }

    private func rewritePathIsValid(_ rewrite: BookmarkResponseFieldRewrite, bodyData: Data?) -> Bool {
        BookmarkJSONRewriteEngine.rewritePathIsValid(
            operation: rewrite.operation,
            path: rewrite.jsonPath,
            overrideValue: rewrite.overrideValue,
            in: bodyData
        )
    }

    private func rewritePathValidationHelp(for operation: JSONMutationOperation) -> String {
        switch operation {
        case .set:
            return "Path exists in saved response."
        case .insert:
            return "Insert path targets an array index from 0 through count (append at count)."
        case .appendString:
            return "Append path targets an existing string value."
        case .prependString:
            return "Prepend path targets an existing string value."
        case .removeProperty:
            return "Remove path targets an existing object key."
        case .removeIndex:
            return "Remove Index path targets an existing array index from 0 through count minus 1."
        case .move:
            return "Move path targets an existing array index; the override value is the destination index, also from 0 through count minus 1."
        }
    }

    private func shouldShowSavedResponseRefreshBanner(for bookmark: Bookmark) -> Bool {
        guard bookmark.savedResponse != nil else {
            return false
        }

        let hasInvalidPath = bookmark.responseRewrites.contains {
            !rewritePathIsValid($0, bodyData: bookmark.savedResponse?.bodyData)
        }
        if hasInvalidPath {
            return true
        }

        if let applicability = responseRewriteApplicability,
           applicability.enabled > 0,
           applicability.applicable < applicability.enabled {
            return true
        }

        return false
    }

    private var savedResponsePaneResizeHandle: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 40, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { isHovering in
                #if canImport(AppKit)
                if isHovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let proposed = savedResponsePaneHeight + value.translation.height
                        savedResponsePaneHeight = min(
                            max(proposed, Self.savedResponsePaneMinHeight),
                            Self.savedResponsePaneMaxHeight
                        )
                    }
            )
            .accessibilityLabel("Resize saved response viewer")
            .accessibilityHint("Drag to change the height of the saved response JSON viewer.")
        }
    }

    @ViewBuilder
    private func savedResponseRefreshBanner(for bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Some rewrite paths do not match the saved response. Refresh from the latest matching captured session.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.orange)

            if let candidate = savedResponseRefreshCandidate {
                Text(verbatim: "Latest: \(candidate.method) \(candidate.host)\(candidate.path)")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Saved Response") {
                refreshSavedResponseConfirmationPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("bookmarkRefreshSavedResponseBannerButton")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func performSavedResponseRefresh(for bookmark: Bookmark) {
        let result = onRefreshSavedResponse(bookmark.id)
        switch result {
        case .refreshed:
            refreshSavedResponseFeedback = "Refreshed saved response from latest matching session."
        case .noMatchingSession:
            refreshSavedResponseFeedback = "No matching captured session found for this bookmark URL."
        case .noSavableBody:
            refreshSavedResponseFeedback = "Matching session found but response body could not be saved."
        }
    }

    private func valueInputMode(for value: BookmarkJSONValue) -> BookmarkResponseRewriteValueInputMode {
        switch value.kind {
        case .string:
            return .string
        case .number:
            return .number
        case .bool:
            return .bool
        case .null:
            return .null
        case .array, .object:
            return .json
        }
    }

    private func rewriteValueKindMismatchMessage(
        path: String,
        overrideValue: BookmarkJSONValue,
        bodyData: Data?
    ) -> String? {
        guard let savedKind = BookmarkJSONValue.kind(at: path, in: bodyData) else {
            return nil
        }
        guard savedKind != overrideValue.kind else {
            return nil
        }

        switch savedKind {
        case .array:
            return "Saved value is an array; use JSON mode or enter a JSON array (e.g. [\"a\",\"b\"])."
        case .object:
            return "Saved value is an object; use JSON mode or enter a JSON object."
        case .bool:
            return "Saved value is a boolean; switch value type to Bool."
        case .number:
            return "Saved value is a number; switch value type to Number."
        case .null:
            return "Saved value is null; switch value type to Null."
        case .string:
            return "Saved value is a string; switch value type to String."
        }
    }

    private func normalizedMatchPath(for bookmark: Bookmark) -> String {
        let path = bookmark.request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        switch bookmark.responseMatchMode {
        case .exactPath:
            return path.isEmpty ? "/" : path
        case .ignoreQuery, .pathPrefix, .pathSuffix, .filename:
            let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
            return withoutQuery.isEmpty ? "/" : withoutQuery
        }
    }

    @ViewBuilder
    private func rewriteApplicabilityText(applicable: Int, enabled: Int) -> some View {
        if applicable == enabled {
            Text("\(applicable) of \(enabled) enabled rewrite\(enabled == 1 ? "" : "s") apply to the saved response.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
        } else {
            Text("Only \(applicable) of \(enabled) enabled rewrite\(enabled == 1 ? "" : "s") apply to the saved response. Fix paths or update the saved response.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.orange)
        }
    }

    private func requestSummary(_ bookmark: Bookmark) -> String {
        [
            "\(bookmark.request.method) \(bookmark.request.path)",
            "Scheme: \(bookmark.request.scheme.rawValue.uppercased())",
            "Host: \(bookmark.request.host)",
            "Port: \(bookmark.request.port.map(String.init) ?? "default")",
            "Inspection: \(inspectionText(for: bookmark.request.inspectionKind))",
            "Body bytes: \(bookmark.request.bodySize ?? bookmark.request.bodyData?.count ?? 0)"
        ].joined(separator: "\n")
    }

    private func headersText(_ headers: [HTTPHeaderField]) -> String {
        guard !headers.isEmpty else {
            return "No request headers captured."
        }

        return headers
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")
    }

    private func bodyText(for request: CapturedRequest) -> String {
        guard let bodyData = request.bodyData, !bodyData.isEmpty else {
            return "No request body captured."
        }

        if !CapturedBodyDecoder.isKnownBinaryContentType(headers: request.headers),
           let text = String(data: bodyData, encoding: .utf8) {
            return text
        }

        return bodyData.base64EncodedString()
    }

    private func inspectionText(for inspectionKind: SessionInspectionKind) -> String {
        switch inspectionKind {
        case .plain:
            return "HTTP"
        case .interceptedTLS:
            return "HTTPS inspected"
        case .tunneledTLS:
            return "HTTPS tunneled"
        }
    }

    private func executionStateTint(for bookmarkID: Bookmark.ID) -> Color {
        switch executionState {
        case .idle:
            return .secondary
        case .executing(let executingBookmarkID) where executingBookmarkID == bookmarkID:
            return .secondary
        case .failed(let failedBookmarkID, _) where failedBookmarkID == bookmarkID:
            return .orange
        case .executing, .failed:
            return .secondary
        }
    }

    private func updatedRequest(
        _ request: CapturedRequest,
        scheme: SessionScheme? = nil,
        host: String? = nil,
        path: String? = nil,
        headers: [HTTPHeaderField]? = nil,
        bodyData: Data?? = nil
    ) -> CapturedRequest {
        let resolvedBodyData = bodyData ?? request.bodyData
        let bodyByteCount = resolvedBodyData?.count

        return CapturedRequest(
            method: request.method,
            scheme: scheme ?? request.scheme,
            inspectionKind: request.inspectionKind,
            inspectionReason: request.inspectionReason,
            host: host ?? request.host,
            port: request.port,
            path: path ?? request.path,
            headers: headers ?? request.headers,
            bodyData: resolvedBodyData,
            bodySize: bodyByteCount
        )
    }

    private func updatingHeader(
        at index: Int,
        in headers: [HTTPHeaderField],
        name: String,
        value: String
    ) -> [HTTPHeaderField] {
        guard headers.indices.contains(index) else {
            return headers
        }

        var updatedHeaders = headers
        updatedHeaders[index] = HTTPHeaderField(name: name, value: value)
        return updatedHeaders
    }

    private func removingHeader(at index: Int, from headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        guard headers.indices.contains(index) else {
            return headers
        }

        var updatedHeaders = headers
        updatedHeaders.remove(at: index)
        return updatedHeaders
    }
}

struct BookmarkMergeSheetContext: Identifiable {
    let bookmark: Bookmark
    let sourceSession: SessionRecord

    var id: String {
        "\(bookmark.id.uuidString)-\(sourceSession.id.uuidString)"
    }

}

struct BookmarkMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var appTextScale

    let bookmark: Bookmark
    let sourceSession: SessionRecord
    let initialPreset: BookmarkUpdatePreset
    let onApply: (BookmarkUpdatePreset, BookmarkCustomMergeOptions?) -> Void
    let onCancel: () -> Void

    @State private var selectedPreset: BookmarkUpdatePreset
    @State private var customOptions: BookmarkCustomMergeOptions

    init(
        bookmark: Bookmark,
        sourceSession: SessionRecord,
        initialPreset: BookmarkUpdatePreset,
        onApply: @escaping (BookmarkUpdatePreset, BookmarkCustomMergeOptions?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.bookmark = bookmark
        self.sourceSession = sourceSession
        self.initialPreset = initialPreset
        self.onApply = onApply
        self.onCancel = onCancel
        _selectedPreset = State(initialValue: initialPreset)
        _customOptions = State(
            initialValue: BookmarkRequestEditing.suggestedCustomMergeOptions(
                bookmarkRequest: bookmark.request,
                sourceRequest: sourceSession.request
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update Bookmark From Session")
                        .appFont(.title3, scale: appTextScale, weight: .semibold)
                    Text("Merge newer auth, headers, or query values from the selected captured request.")
                        .appFont(.body, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            HStack(alignment: .top, spacing: 16) {
                requestSummaryCard(
                    title: "Bookmark",
                    systemImage: "bookmark.fill",
                    request: bookmark.request
                )

                requestSummaryCard(
                    title: "Captured Session",
                    systemImage: "tray.full.fill",
                    request: sourceSession.request
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Merge Preset")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)

                Picker("Merge Preset", selection: $selectedPreset) {
                    ForEach(BookmarkUpdatePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Label(selectedPreset.summary, systemImage: selectedPreset.systemImage)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            if selectedPreset == .custom {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        customSelectionSection(
                            title: "Headers",
                            items: BookmarkRequestEditing.availableHeaderNames(for: sourceSession.request),
                            selectedItems: Binding(
                                get: { customOptions.headerNames },
                                set: { customOptions.headerNames = $0 }
                            )
                        )

                        customSelectionSection(
                            title: "Query Items",
                            items: BookmarkRequestEditing.availableQueryItemNames(for: sourceSession.request),
                            selectedItems: Binding(
                                get: { customOptions.queryItemNames },
                                set: { customOptions.queryItemNames = $0 }
                            )
                        )

                        customSelectionSection(
                            title: "JSON Body Fields",
                            items: BookmarkRequestEditing.availableJSONBodyKeys(for: sourceSession.request),
                            selectedItems: Binding(
                                get: { customOptions.jsonBodyKeys },
                                set: { customOptions.jsonBodyKeys = $0 }
                            )
                        )
                    }
                }
                .frame(minHeight: 180, maxHeight: 280)
            }

            Text("Transport headers like Host, Content-Length, Connection, and Proxy-Connection are never copied from the session.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()

                Button("Apply Update") {
                    onApply(selectedPreset, selectedPreset == .custom ? customOptions : nil)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 860, minHeight: 420)
    }

    private func customSelectionSection(
        title: String,
        items: [String],
        selectedItems: Binding<Set<String>>
    ) -> some View {
        GroupBox(title) {
            if items.isEmpty {
                Text("No mergeable \(title.lowercased()) were detected in the captured session.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Toggle(
                            isOn: Binding(
                                get: { selectedItems.wrappedValue.contains(item) },
                                set: { isSelected in
                                    var updatedSelection = selectedItems.wrappedValue
                                    if isSelected {
                                        updatedSelection.insert(item)
                                    } else {
                                        updatedSelection.remove(item)
                                    }
                                    selectedItems.wrappedValue = updatedSelection
                                }
                            )
                        ) {
                            Text(item)
                                .appFont(.body, scale: appTextScale, design: .monospaced)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func requestSummaryCard(title: String, systemImage: String, request: CapturedRequest) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .appFont(.headline, scale: appTextScale, weight: .semibold)

                Text("\(request.method) \(request.scheme == .https ? "https" : "http")://\(request.host)\(request.path)")
                    .appFont(.body, scale: appTextScale, design: .monospaced)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Headers")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)

                    Text(request.headers.prefix(5).map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if request.headers.count > 5 {
                        Text("+\(request.headers.count - 5) more")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }
}

/// Defers bookmark rewrite path persistence until editing finishes to avoid list refreshes on every keystroke.
private struct BookmarkRewritePathField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var draftValue: String
    @FocusState private var isFocused: Bool

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _draftValue = State(initialValue: value)
    }

    var body: some View {
        TextField("JSON path", text: $draftValue)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .focused($isFocused)
            .onSubmit {
                commitIfNeeded()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitIfNeeded()
                }
            }
            .onChange(of: value) { _, updatedValue in
                guard !isFocused else { return }
                draftValue = updatedValue
            }
    }

    private func commitIfNeeded() {
        guard draftValue != value else { return }
        onCommit(draftValue)
    }
}

/// Defers bookmark rewrite override persistence until editing finishes to avoid JSON viewer flashes.
private struct BookmarkRewriteOverrideField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var draftValue: String
    @FocusState private var isFocused: Bool

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _draftValue = State(initialValue: value)
    }

    var body: some View {
        TextField("Override value", text: $draftValue)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit {
                commitIfNeeded()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitIfNeeded()
                }
            }
            .onChange(of: value) { _, updatedValue in
                guard !isFocused else { return }
                draftValue = updatedValue
            }
    }

    private func commitIfNeeded() {
        guard draftValue != value else { return }
        onCommit(draftValue)
    }
}
