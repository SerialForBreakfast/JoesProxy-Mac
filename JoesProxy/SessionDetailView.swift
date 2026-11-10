//
//  SessionDetailView.swift
//  JoesProxy
//
//  The request/response inspector panel shown in the main window split view when a
//  session is selected. Extracted from ContentView for independent compilation and
//  testability. All companion types (placeholder views, inspector section banners)
//  are colocated here.
//

import AppKit
import SwiftUI

struct SessionDetailView: View {
    private struct SummaryField: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    @Environment(\.appTextScale) private var appTextScale
    @AppStorage("isInspectorCopyRedactionEnabled") private var isInspectorCopyRedactionEnabled = true
    let session: SessionRecord?
    var contentRevision: UInt64 = 0
    var clientDisplayName: String? = nil
    /// When non-nil, the detail view will auto-switch the matching body pane's JSON view
    /// mode to Prettified so that find-result highlights can be applied to a flat string.
    /// Set by the caller when the user navigates to this session from a Find result.
    let activeFindResultLocation: SessionFindResult.MatchLocation?
    /// Active Find query to scroll/highlight in the matching JSON body pane.
    let findQuery: String?
    /// Unique token for the active Find navigation. Repeated result selections for the
    /// same query/body still produce a new token so native find pulse can replay.
    let findNavigationID: UUID?
    let requestFindMatchContext: SessionFindBodyMatchContext?
    let responseFindMatchContext: SessionFindBodyMatchContext?
    let findDebugLoggingEnabled: Bool
    let onAddBookmark: (SessionRecord) -> Void
    let onMapLocal: (SessionRecord) -> Void
    let onOpenMediaInfo: (SessionRecord) -> Void
    let onOpenHelpTopic: (MainWindowHelpTopic) -> Void
    var diagnosticInterlockCoordinator: MCPDiagnosticInterlockCoordinator? = nil
    var openAPISchemaStore: OpenAPISchemaStore? = nil
    @State private var isRequestHeadersExpanded = true
    @State private var isResponseHeadersExpanded = true
    @State private var isTimingExpanded = false
    @State private var isCachingExpanded = false
    @State private var isContractValidationExpanded = false
    @State private var validationReport: OpenAPIValidationReport? = nil
    @State private var isFailureExpanded = true
    @State private var requestJSONViewMode: JSONViewMode = .folder
    @State private var responseJSONViewMode: JSONViewMode = .folder
    /// Stable `JSONContentSource` for the request body of the currently displayed session.
    /// Cached so that parent re-renders caused by new sessions arriving do not regenerate
    /// the UUID inside the source, which would cancel `JSONContentView`'s derivation task
    /// and flash a loading spinner while the same JSON re-parses.
    @State private var bodyCache = InspectorBodyCache()
    private var cachedRequestBodySource: JSONContentSource? { bodyCache.requestSource }
    /// Stable `JSONContentSource` for the response body of the currently displayed session.
    private var cachedResponseBodySource: JSONContentSource? { bodyCache.responseSource }
    /// Decoded response body used for JSON/text inspection; raw bytes remain in the session record.
    private var cachedResponseBodyDecode: CapturedBodyDecodeResult? { bodyCache.responseDecode }
    /// Tracks which session the cached sources belong to.
    private var cachedSourcesSessionID: SessionRecord.ID? { bodyCache.sessionID }
    /// Indices of form-encoded param rows whose value has been expanded past the truncation threshold.
    @State private var expandedFormParamIndices: Set<Int> = []
    @State private var requestHeadersPaneHeight: CGFloat = 140
    @State private var responseHeadersPaneHeight: CGFloat = 140
    @State private var inspectorWidth: CGFloat = 420
    @State private var interlockEvaluation: MCPDiagnosticInterlockEvaluation?

    private static let headerPaneMinHeight: CGFloat = 88
    private static let headerPaneMaxHeight: CGFloat = 360
    private static let inspectorBodyPaneMinHeight: CGFloat = 120
    private static let inspectorMetadataPaneMinHeight: CGFloat = 72

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

    private var inspectorDisclosureTopPadding: CGFloat {
        if appTextScale <= 1.1 {
            return 4
        } else if appTextScale <= 1.25 {
            return 5
        } else if appTextScale <= 1.4 {
            return 6
        } else {
            return 8
        }
    }

    private var inspectorDisclosureContentSpacing: CGFloat {
        if appTextScale < 1 {
            return 6
        } else if appTextScale <= 1.1 {
            return 8
        } else if appTextScale <= 1.25 {
            return 9
        } else if appTextScale <= 1.4 {
            return 10
        } else {
            return 12
        }
    }

    private var isInspectorCompact: Bool {
        inspectorWidth / max(1, appTextScale) < 520
    }

    private var summaryGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 160), spacing: 12, alignment: .topLeading),
            GridItem(.flexible(minimum: 160), spacing: 12, alignment: .topLeading)
        ]
    }

    /// Two-column grid for URL-encoded form bodies: narrow key column, wide value column.
    private var formParamGridColumns: [GridItem] {
        [
            GridItem(.fixed(140), spacing: 16, alignment: .topLeading),
            GridItem(.flexible(minimum: 160), alignment: .topLeading)
        ]
    }

    private let findExcerptBuilder = SessionFindExcerptBuilder()

    var body: some View {
        if let session {
            let freshness = session.cacheFreshness
            VSplitView {
                // ── Top pane: status, banners, and request body ──────────────
                VStack(alignment: .leading, spacing: inspectorSectionSpacing) {
                    compactStatusStrip(session: session)

                    if let coordinator = diagnosticInterlockCoordinator,
                       let evaluation = interlockEvaluation {
                        MCPDiagnosticInterlockBanner(
                            coordinator: coordinator,
                            diagnostic: .responseComparison,
                            evaluation: evaluation,
                            textScale: appTextScale,
                            onAcknowledge: {}
                        )
                    }

                    if let src = session.response?.source, src != .upstream {
                        overrideBanner(session: session, source: src)
                    }

                    if session.request.inspectionKind == .tunneledTLS {
                        tunnelInfoBanner(session: session)
                    }

                    if sessionHasNoCachingApplied(session) {
                        noCachingBanner(session: session)
                    }

                    if let failure = session.failure {
                        disclosureSection(
                            title: failureSectionTitle(for: failure),
                            badge: nil,
                            isExpanded: $isFailureExpanded,
                            content: failure.message
                        )
                    }

                    requestBodySection(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: Self.inspectorBodyPaneMinHeight)

                // ── Middle pane: response body and media info ────────────────
                VStack(alignment: .leading, spacing: inspectorSectionSpacing) {
                    responseBodySection(session: session)

                    if MediaDetector.mediaType(for: session) != .none {
                        mediaInfoSection(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: Self.inspectorBodyPaneMinHeight)

                // ── Bottom pane: headers and timing (scroll when space is tight) ─
                ScrollView {
                    VStack(alignment: .leading, spacing: inspectorSectionSpacing) {
                        headerDisclosureSection(
                            title: "Request Headers",
                            headers: session.request.headers,
                            isExpanded: $isRequestHeadersExpanded,
                            paneHeight: $requestHeadersPaneHeight
                        )

                        headerDisclosureSection(
                            title: "Response Headers",
                            headers: session.response?.headers ?? [],
                            isExpanded: $isResponseHeadersExpanded,
                            paneHeight: $responseHeadersPaneHeight
                        )

                        compactSection(
                            title: "Timing",
                            badge: session.timing.duration.map { "\($0.formatted(.number.precision(.fractionLength(3))))s" },
                            isExpanded: $isTimingExpanded,
                            actions: {
                                inspectorCopyButton("Copy Timing") {
                                    copyTextToPasteboard(timingText(for: session))
                                }
                            }
                        ) {
                            VStack(alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                                WireWaterfallInspectorView(session: session)
                                Divider()
                                LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                                    ForEach(timingFields(for: session)) { field in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(field.label)
                                                .appFont(.caption, scale: appTextScale, weight: .semibold)
                                                .foregroundStyle(.secondary)
                                            Text(verbatim: field.value)
                                                .appFont(.body, scale: appTextScale, design: .monospaced)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .lineLimit(nil)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }

                        compactSection(
                            title: "Caching & Freshness",
                            badge: freshness.displayBadgeText,
                            isExpanded: $isCachingExpanded,
                            actions: {
                                inspectorCopyButton("Copy Caching") {
                                    copyTextToPasteboard(cachingText(for: session))
                                }
                            }
                        ) {
                            VStack(alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                                if !freshness.conflictingDirectives.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(freshness.conflictingDirectives, id: \.self) { conflict in
                                            HStack(spacing: 4) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundStyle(.orange)
                                                    .font(.caption)
                                                Text(conflict)
                                                    .appFont(.caption, scale: appTextScale)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                    .padding(.bottom, 4)
                                }
                                LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                                    ForEach(cachingFields(freshness)) { field in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(field.label)
                                                .appFont(.caption, scale: appTextScale, weight: .semibold)
                                                .foregroundStyle(.secondary)
                                            Text(verbatim: field.value)
                                                .appFont(.body, scale: appTextScale, design: .monospaced)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .lineLimit(nil)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }

                        if let report = validationReport, report.status != .undocumentedEndpoint {
                            compactSection(
                                title: "Contract Validation",
                                badge: report.badgeText,
                                isExpanded: $isContractValidationExpanded,
                                actions: {
                                    inspectorCopyButton("Copy Validation") {
                                        copyTextToPasteboard(contractValidationText(for: report))
                                    }
                                }
                            ) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let opID = report.operationID {
                                        HStack(spacing: 4) {
                                            Text("Operation:")
                                                .appFont(.caption, scale: appTextScale, weight: .semibold)
                                                .foregroundStyle(.secondary)
                                            Text(opID)
                                                .appFont(.caption, scale: appTextScale, design: .monospaced)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    if report.violations.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.seal.fill")
                                                .foregroundStyle(.green)
                                            Text("Matches OpenAPI specification.")
                                                .appFont(.caption, scale: appTextScale)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(report.violations, id: \.self) { v in
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "exclamationmark.circle.fill")
                                                            .foregroundStyle(.red)
                                                            .font(.caption2)
                                                        Text(v.keyPath)
                                                            .appFont(.caption, scale: appTextScale, weight: .semibold, design: .monospaced)
                                                    }
                                                    Text(v.reason)
                                                        .appFont(.caption2, scale: appTextScale)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.vertical, 2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: Self.inspectorMetadataPaneMinHeight)
            }
            .accessibilityLabel("Selected session details")
            .reportViewWidth { inspectorWidth = $0 }
            .task {
                guard let coordinator = diagnosticInterlockCoordinator else {
                    interlockEvaluation = nil
                    return
                }
                interlockEvaluation = await coordinator.evaluate(diagnostic: .responseComparison)
            }
            .onAppear {
                refreshCachedSources(for: session)
                resetHeaderPaneHeights(for: session)
                applyFindResultModeSwitch(for: session)
                logFind("Detail appeared session=\(session.id.uuidString) activeLocation=\(activeFindResultLocation?.rawValue ?? "nil") query='\(findQuery ?? "")' token=\(findNavigationID?.uuidString ?? "nil")")
            }
            .onChange(of: session.id) { _, _ in
                refreshCachedSources(for: session)
                resetHeaderPaneHeights(for: session)
                applyFindResultModeSwitch(for: session)
                logFind("Detail session changed to \(session.id.uuidString); activeLocation=\(activeFindResultLocation?.rawValue ?? "nil") query='\(findQuery ?? "")'")
            }
            .onChange(of: findNavigationID) { _, _ in
                applyFindResultModeSwitch(for: session)
                logFind("Find navigation token changed session=\(session.id.uuidString) activeLocation=\(activeFindResultLocation?.rawValue ?? "nil") query='\(findQuery ?? "")' token=\(findNavigationID?.uuidString ?? "nil")")
            }
            .onChange(of: contentRevision) { _, _ in
                refreshCachedSources(for: session)
                applyFindResultModeSwitch(for: session)
            }
            .onDisappear { clearBodyCache() }
            .task(id: session.id) {
                if let openAPISchemaStore {
                    let report = await OpenAPIContractValidator.validate(session: session, schemaStore: openAPISchemaStore)
                    guard !Task.isCancelled else { return }
                    validationReport = report
                } else {
                    validationReport = nil
                }
            }
        } else {
            SessionDetailPlaceholderView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { clearBodyCache() }
        }
    }

    /// Compact status strip replacing the old title header + Request Summary + Response Summary.
    /// Shows method/status badges, URL, byte sizes, scheme, duration, and action buttons in two rows.
    @ViewBuilder
    private func compactStatusStrip(session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RequestMethodBadge(method: session.request.method, scale: appTextScale)

                statusBadgeView(session: session)

                Text(verbatim: "\(session.request.host)\(session.request.path)")
                    .appFont(.body, scale: appTextScale, design: .monospaced)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(session.request.scheme.rawValue.uppercased())
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)

                    if let clientDisplayName {
                        Label(clientDisplayName, systemImage: "network")
                            .appFont(.caption, scale: appTextScale, weight: .semibold, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Source device: \(clientDisplayName)")
                    }

                    if let reqSize = session.request.bodySize {
                        Label(formatBytes(reqSize), systemImage: "arrow.up")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }

                    if let respSize = session.response?.bodySize {
                        Label(formatBytes(respSize), systemImage: "arrow.down")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }

                    if let duration = session.timing.duration {
                        Text("\(duration.formatted(.number.precision(.fractionLength(3))))s")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                ContextHelpButton(
                    accessibilityLabel: "Request Inspector help",
                    accessibilityHint: "Explains what the inspector shows and why some tunneled sessions have limited details.",
                    accessibilityIdentifier: "requestInspectorHelpButton"
                ) {
                    inspectorHelpPopoverContent
                }

                inspectorCopyButton("Copy Summary") {
                    copyTextToPasteboard(summaryText(for: session))
                }
                .help("Copy a summary of the selected captured session.")
                .accessibilityLabel("Copy session summary")

                Button {
                    onMapLocal(session)
                } label: {
                    inspectorActionLabel("Map Local", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(session.response == nil || session.request.inspectionKind == .tunneledTLS)
                .help("Serve matching requests from a local override instead of going upstream.")
                .accessibilityLabel("Map Local")

                Button {
                    onAddBookmark(session)
                } label: {
                    inspectorActionLabel("Add to Bookmarks", systemImage: "bookmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Save the selected captured request as a bookmark.")
                .accessibilityLabel("Add to Bookmarks")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusBadgeView(session: SessionRecord) -> some View {
        if let statusCode = session.response?.statusCode {
            Text(String(statusCode))
                .appFont(.caption, scale: appTextScale, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusBadgeColor(statusCode), in: RoundedRectangle(cornerRadius: 4))
        } else if session.failure != nil {
            Text("ERR")
                .appFont(.caption, scale: appTextScale, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text("…")
                .appFont(.caption, scale: appTextScale, weight: .medium)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func statusBadgeColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...: return .red
        default: return .gray
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes == 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Lightweight expandable section replacing the old `GroupBox { DisclosureGroup }` double-chrome.
    @ViewBuilder
    private func compactSection<Content: View, Actions: View>(
        title: String,
        badge: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text(title)
                        .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if let badge {
                        Text(badge)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    actions()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")

            Divider()

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, inspectorDisclosureTopPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func bodyHeaderBar<Actions: View>(
        title: String,
        badge: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .appFont(.subheadline, scale: appTextScale, weight: .semibold)

                Spacer(minLength: 8)

                if let badge {
                    Text(badge)
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }

                actions()
            }
            .padding(.vertical, 6)

            Divider()
        }
    }

    @ViewBuilder
    private func findExcerptStrip(
        bodyData: Data?,
        context: SessionFindBodyMatchContext?,
        accessibilityIdentifier: String
    ) -> some View {
        if let context,
           let result = findExcerptBuilder.build(bodyData: bodyData, query: context.query) {
            VStack(alignment: .leading, spacing: 6) {
                Text(matchCountLabel(context.matchCount))
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.secondary)

                switch result {
                case .excerpts(let excerpts):
                    ForEach(Array(excerpts.enumerated()), id: \.offset) { _, excerpt in
                        Text(excerpt.attributedText)
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                case .tooLarge(_, let limitBytes):
                    Text("Body too large to preview. Limit \(byteCountLabel(limitBytes)).")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(findExcerptAccessibilityLabel(context: context, result: result))
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    @ViewBuilder
    private func summarySection(title: String, isExpanded: Binding<Bool>, fields: [SummaryField]) -> some View {
        compactSection(title: title, isExpanded: isExpanded) {
            LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.label)
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .foregroundStyle(.secondary)

                        Text(verbatim: field.value)
                            .appFont(.body, scale: appTextScale, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func overrideBanner(session: SessionRecord, source: CapturedResponseSource) -> some View {
        switch source {
        case .localOverride:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Served From Local Override", systemImage: "arrow.triangle.branch")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.purple)

                    Text("JoesProxy served this response from a temporary local override instead of sending the request upstream.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let sourceDescription = session.response?.sourceDescription {
                        Text(verbatim: "Source: \(sourceDescription)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .blocked:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Blocked by Rule", systemImage: "slash.circle")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.red)

                    Text("JoesProxy dropped this request and returned a synthetic error response. No upstream server was contacted.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let statusCode = session.response?.statusCode {
                        Text(verbatim: "Status: \(statusCode)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .mapRemote:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Remapped to Different Host", systemImage: "arrow.triangle.swap")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.indigo)

                    Text("JoesProxy forwarded this request to a different upstream host instead of the original destination.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let sourceDescription = session.response?.sourceDescription {
                        Text(verbatim: "Destination: \(sourceDescription)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .bookmarkRewrite:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Rewritten From Bookmark", systemImage: "bookmark.fill")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.blue)

                    Text("JoesProxy replaced this request with a saved bookmark request before contacting upstream.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let sourceDescription = session.response?.sourceDescription {
                        Text(verbatim: "Rewrite: \(sourceDescription)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .bookmarkResponseRewrite:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Bookmark Response Rewrite", systemImage: "pencil.and.outline")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.teal)

                    Text("JoesProxy served this response from a bookmark saved snapshot with configured field overrides instead of contacting upstream.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let sourceDescription = session.response?.sourceDescription {
                        Text(verbatim: "Source: \(sourceDescription)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)

                        ForEach(bookmarkResponseRewriteDetailLines(from: sourceDescription), id: \.self) { line in
                            Text(verbatim: line)
                                .appFont(.caption, scale: appTextScale, design: .monospaced)
                                .foregroundStyle(line.hasPrefix("Skipped:") ? Color.orange : Color.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .liveResponseRewrite:
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Live Response Rewrite", systemImage: "arrow.triangle.2.circlepath")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.teal)

                    Text("JoesProxy forwarded this request to the real upstream server and patched JSON fields in the response on the way back to the client.")
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Match: \(session.request.method) \(session.request.host)\(session.request.path)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)

                    if let sourceDescription = session.response?.sourceDescription {
                        Text(verbatim: "Rewrites: \(sourceDescription)")
                            .appFont(.caption, scale: appTextScale, design: .monospaced)
                            .foregroundStyle(.tertiary)

                        ForEach(bookmarkResponseRewriteDetailLines(from: sourceDescription), id: \.self) { line in
                            Text(verbatim: line)
                                .appFont(.caption, scale: appTextScale, design: .monospaced)
                                .foregroundStyle(line.hasPrefix("Skipped:") ? Color.orange : Color.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

        case .upstream:
            EmptyView()
        }
    }

    // MARK: - No Caching Banner

    /// Extracts applied/skipped path lines from an enriched bookmark response rewrite source description.
    private func bookmarkResponseRewriteDetailLines(from sourceDescription: String) -> [String] {
        var lines: [String] = []
        if let appliedRange = sourceDescription.range(of: "applied:") {
            let appliedSegment = sourceDescription[appliedRange.upperBound...]
                .split(separator: "·", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !appliedSegment.isEmpty {
                lines.append("Applied: \(appliedSegment)")
            }
        }
        if let skippedRange = sourceDescription.range(of: "skipped:") {
            let skippedSegment = sourceDescription[skippedRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !skippedSegment.isEmpty {
                lines.append("Skipped: \(skippedSegment)")
            }
        }
        return lines
    }

    /// Returns `true` when the recorded request headers indicate that
    private func failureSectionTitle(for failure: SessionFailure) -> String {
        guard let bucketRaw = failure.bucket,
              let bucket = NetworkFailureBucket(rawValue: bucketRaw) else {
            return "Failure"
        }

        return bucket.displayTitle
    }

    /// `NoCachingPolicy` was applied to this session.
    ///
    /// Detection is derived from recorded headers — no schema change is needed:
    /// - `Cache-Control: no-cache` present in request headers
    /// - `Pragma: no-cache` present in request headers
    /// - `If-None-Match` absent (the proxy stripped it)
    ///
    /// The combination is unique to proxy intervention and does not occur in
    /// typical organic browser traffic. Tunneled sessions are always excluded.
    private func sessionHasNoCachingApplied(_ session: SessionRecord) -> Bool {
        guard session.request.inspectionKind != .tunneledTLS else { return false }
        let headers = session.request.headers
        let hasCacheControl = headers.contains {
            $0.name.caseInsensitiveCompare("Cache-Control") == .orderedSame
            && $0.value.localizedCaseInsensitiveContains("no-cache")
        }
        let hasPragma = headers.contains {
            $0.name.caseInsensitiveCompare("Pragma") == .orderedSame
            && $0.value.localizedCaseInsensitiveContains("no-cache")
        }
        let hasIfNoneMatch = headers.contains {
            $0.name.caseInsensitiveCompare("If-None-Match") == .orderedSame
        }
        return hasCacheControl && hasPragma && !hasIfNoneMatch
    }

    @ViewBuilder
    private func noCachingBanner(session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("No Caching Applied", systemImage: "xmark.circle")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.teal)

                Text("JoesProxy stripped caching headers and forced revalidation for this request.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func tunnelInfoBanner(session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("HTTPS Tunneled", systemImage: "lock.slash")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.orange)

                Text("JoesProxy proxied this CONNECT tunnel without TLS interception for compatibility. Request and response contents were not decrypted.")
                    .foregroundStyle(.secondary)

                Text("If you expected readable bodies here, review the inspection reason below and check HTTPS Rules and certificate trust. Some pinned or compatibility-sensitive traffic must remain tunneled.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)

                Text("Host: \(session.request.host)")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .foregroundStyle(.tertiary)

                if let inspectionReason = session.request.inspectionReason {
                    Text("Reason: \(inspectionReason)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.tertiary)
                }

                Button("Learn More") {
                    onOpenHelpTopic(.requestInspector)
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private var inspectorHelpPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Request Inspector")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            Text("The inspector shows bodies, headers, timing, and inspection metadata for the selected session when that data is available.")
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Label("Request and response bodies appear only when JoesProxy could inspect the traffic.", systemImage: "circle.fill")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                Label("HTTPS Tunneled sessions stay encrypted end-to-end, so the inspector can show only metadata.", systemImage: "circle.fill")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
            }

            Divider()

            Button("Open Current Screen Help") {
                onOpenHelpTopic(.requestInspector)
            }
            .buttonStyle(.link)
            .accessibilityHint("Opens the contextual help window for the request inspector.")
        }
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }

    @ViewBuilder
    private func requestBodySection(session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            bodyHeaderBar(
                title: "Request Body",
                badge: requestBodyBadge(for: session),
                actions: {
                    inspectorCopyButton("Copy Body") {
                        copyTextToPasteboard(bodyText(for: session.request.bodyData, headers: session.request.headers))
                    }
                }
            )

            if let omissionReason = session.request.recordingBodyOmissionReason {
                BodyOmissionWarningBanner(message: omissionReason.userFacingMessage)
            } else if session.request.bodyData == nil, !session.request.bodyDeferred, (session.request.bodySize ?? 0) > 0 {
                BodyOmissionWarningBanner(message: "Request body unavailable. The reason was not recorded.")
            }
            if session.request.bodyTruncated {
                TruncationWarningBanner()
            }

            findExcerptStrip(
                bodyData: session.request.bodyData,
                context: requestFindMatchContext,
                accessibilityIdentifier: "requestFindExcerptStrip"
            )

            if session.request.bodyDeferred {
                BodyLoadingBanner()
            } else if let source = cachedRequestBodySource {
                jsonBodyContent(
                    source: source,
                    viewMode: $requestJSONViewMode,
                    findQuery: activeFindResultLocation == .requestBody ? findQuery : nil,
                    findNavigationID: activeFindResultLocation == .requestBody ? findNavigationID : nil
                )
            } else if isFormEncoded(headers: session.request.headers),
                      let params = parseFormParams(from: session.request.bodyData ?? Data()),
                      !params.isEmpty {
                formEncodedBodyContent(
                    params: params,
                    findQuery: activeFindResultLocation == .requestBody ? findQuery : nil,
                    findNavigationID: activeFindResultLocation == .requestBody ? findNavigationID : nil,
                    bodyLabel: "request"
                )
            } else if isLikelyXML(headers: session.request.headers),
                      let xmlString = prettifiedXML(from: session.request.bodyData ?? Data()) {
                scrollableBodyText(xmlString)
            } else {
                InspectorBodyTextView(
                    data: session.request.bodyData,
                    binary: CapturedBodyDecoder.isKnownBinaryContentType(headers: session.request.headers),
                    textScale: appTextScale
                )
                .id(session.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func mediaInfoSection(session: SessionRecord) -> some View {
        GroupBox {
            HStack {
                Label("Media Info", systemImage: "photo.on.rectangle.angled")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                Spacer()
                Button("View Media Info") {
                    onOpenMediaInfo(session)
                }
                .accessibilityIdentifier("openMediaInfoButton")
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func responseBodySection(session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            bodyHeaderBar(
                title: "Response Body",
                badge: responseBodyBadge(for: session),
                actions: {
                    inspectorCopyButton("Copy Body") {
                        copyTextToPasteboard(responseBodyDisplayText(for: session))
                    }
                }
            )

            if let omissionReason = session.response?.recordingBodyOmissionReason {
                BodyOmissionWarningBanner(message: omissionReason.userFacingMessage)
            } else if let response = session.response, response.bodyData == nil, !response.bodyDeferred,
                      (response.bodySize ?? 0) > 0, session.responseCaptureLimitedByPressure != true {
                BodyOmissionWarningBanner(message: "Response body unavailable. The reason was not recorded.")
            }
            if session.responseCaptureLimitedByPressure == true {
                BodyOmissionWarningBanner(message: "Response body skipped to keep capture memory bounded. Request details, status and timing remain available. New requests capture bodies again automatically when capacity recovers.")
            } else if session.response?.bodyTruncated == true {
                TruncationWarningBanner()
            }
            if let decodeMessage = responseBodyDecodeBannerMessage(for: session) {
                BodyDecodeStatusBanner(message: decodeMessage)
            }

            findExcerptStrip(
                bodyData: responseAnalysisData(for: session),
                context: responseFindMatchContext,
                accessibilityIdentifier: "responseFindExcerptStrip"
            )

            if session.response?.bodyDeferred == true {
                BodyLoadingBanner()
            } else if case .image(let mimeType) = MediaDetector.mediaType(for: session),
               let bodyData = session.response?.bodyData,
               !bodyData.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
                        ImageViewer(bodyData: bodyData, contentType: mimeType,
                            sessionID: session.id, contentRevision: contentRevision)
                        Button("View Full Media Info") {
                            onOpenMediaInfo(session)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let source = cachedResponseBodySource {
                jsonBodyContent(
                    source: source,
                    viewMode: $responseJSONViewMode,
                    findQuery: activeFindResultLocation == .responseBody ? findQuery : nil,
                    findNavigationID: activeFindResultLocation == .responseBody ? findNavigationID : nil
                )
            } else if let responseHeaders = session.response?.headers,
                      isFormEncoded(headers: responseHeaders),
                      let params = parseFormParams(from: responseAnalysisData(for: session) ?? Data()),
                      !params.isEmpty {
                formEncodedBodyContent(
                    params: params,
                    findQuery: activeFindResultLocation == .responseBody ? findQuery : nil,
                    findNavigationID: activeFindResultLocation == .responseBody ? findNavigationID : nil,
                    bodyLabel: "response"
                )
            } else if let responseHeaders = session.response?.headers,
                      isLikelyXML(headers: responseHeaders),
                      let xmlString = prettifiedXML(from: responseAnalysisData(for: session) ?? Data()) {
                scrollableBodyText(xmlString)
            } else {
                InspectorBodyTextView(
                    data: responseTextPageData(for: session),
                    binary: CapturedBodyDecoder.isKnownBinaryContentType(headers: session.response?.headers ?? []),
                    textScale: appTextScale
                )
                .id(session.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func disclosureSection(
        title: String,
        badge: String? = nil,
        isExpanded: Binding<Bool>,
        allowsRedaction: Bool = false,
        copyContent: String? = nil,
        content: String
    ) -> some View {
        compactSection(
            title: title,
            badge: badge,
            isExpanded: isExpanded,
            actions: {
                inspectorCopyButton(allowsRedaction ? "Copy Redacted" : "Copy") {
                    copyTextToPasteboard(copyContent ?? content)
                }
            }
        ) {
            scrollableInspectorText(content)
        }
    }

    /// Headers use a resizable scrollable pane inside the metadata split so they stay readable
    /// when request/response bodies are expanded.
    @ViewBuilder
    private func headerDisclosureSection(
        title: String,
        headers: [HTTPHeaderField],
        isExpanded: Binding<Bool>,
        paneHeight: Binding<CGFloat>
    ) -> some View {
        let fieldCount = headers.count
        compactSection(
            title: title,
            badge: fieldCount == 1 ? "1 field" : "\(fieldCount) fields",
            isExpanded: isExpanded,
            actions: {
                headerCopyActions(headers: headers)
            }
        ) {
            VStack(spacing: 0) {
                ScrollView {
                    scrollableInspectorText(headerText(headers))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                headerPaneResizeHandle(height: paneHeight)
            }
            .frame(
                height: clampedHeaderPaneHeight(paneHeight.wrappedValue, fieldCount: fieldCount),
                alignment: .topLeading
            )
            .accessibilityIdentifier("\(title.replacingOccurrences(of: " ", with: ""))Pane")
        }
    }

    @ViewBuilder
    private func scrollableInspectorText(_ content: String) -> some View {
        Text(content)
            .appFont(.body, scale: appTextScale, design: .monospaced)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func headerCopyActions(headers: [HTTPHeaderField]) -> some View {
        let rawText = headerText(headers, redactSensitive: false)
        if isInspectorCopyRedactionEnabled {
            Menu {
                Button("Copy Headers") {
                    copyTextToPasteboard(rawText)
                }
                Button("Copy Redacted Headers") {
                    copyTextToPasteboard(headerText(headers, redactSensitive: true))
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel("Copy header actions")
        } else {
            inspectorCopyButton("Copy") {
                copyTextToPasteboard(rawText)
            }
        }
    }

    private func headerPaneResizeHandle(height: Binding<CGFloat>) -> some View {
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
                if isHovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let proposed = height.wrappedValue + value.translation.height
                        height.wrappedValue = min(
                            max(proposed, Self.headerPaneMinHeight),
                            Self.headerPaneMaxHeight
                        )
                    }
            )
            .accessibilityLabel("Resize headers pane")
            .accessibilityHint("Drag to change how many header lines are visible.")
        }
    }

    private func defaultHeaderPaneHeight(fieldCount: Int) -> CGFloat {
        let lineHeight = 20 * max(appTextScale, 1)
        let automatic = CGFloat(max(fieldCount, 4)) * lineHeight + 28
        return min(max(automatic, Self.headerPaneMinHeight), Self.headerPaneMaxHeight)
    }

    private func clampedHeaderPaneHeight(_ storedHeight: CGFloat, fieldCount: Int) -> CGFloat {
        let fallback = defaultHeaderPaneHeight(fieldCount: fieldCount)
        return min(max(storedHeight > 0 ? storedHeight : fallback, Self.headerPaneMinHeight), Self.headerPaneMaxHeight)
    }

    private func resetHeaderPaneHeights(for session: SessionRecord) {
        requestHeadersPaneHeight = defaultHeaderPaneHeight(fieldCount: session.request.headers.count)
        responseHeadersPaneHeight = defaultHeaderPaneHeight(
            fieldCount: session.response?.headers.count ?? 0
        )
    }

    @ViewBuilder
    private func jsonBodyContent(
        source: JSONContentSource,
        viewMode: Binding<JSONViewMode>,
        findQuery: String?,
        findNavigationID: UUID?
    ) -> some View {
        VStack(alignment: .leading, spacing: inspectorDisclosureContentSpacing) {
            jsonModePicker(selection: viewMode)
            JSONContentView(
                source: source,
                viewMode: viewMode,
                findQuery: findQuery,
                findNavigationID: findNavigationID,
                findDebugLoggingEnabled: findDebugLoggingEnabled
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func scrollableBodyText(_ content: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .appFont(.body, scale: appTextScale, design: .monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, inspectorDisclosureTopPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func requestBodyBadge(for session: SessionRecord) -> String? {
        guard isFormEncoded(headers: session.request.headers),
              let params = parseFormParams(from: session.request.bodyData ?? Data()),
              !params.isEmpty else {
            return session.request.bodySize.map(formatBytes)
        }
        if let size = session.request.bodySize.map(formatBytes) {
            return "\(params.count) params · \(size)"
        }
        return "\(params.count) params"
    }

    private func responseBodyBadge(for session: SessionRecord) -> String? {
        guard let responseHeaders = session.response?.headers,
              isFormEncoded(headers: responseHeaders),
              let params = parseFormParams(from: responseAnalysisData(for: session) ?? Data()),
              !params.isEmpty else {
            return session.response?.bodySize.map(formatBytes)
        }
        if let size = session.response?.bodySize.map(formatBytes) {
            return "\(params.count) params · \(size)"
        }
        return "\(params.count) params"
    }

    private func requestSummaryFields(for session: SessionRecord) -> [SummaryField] {
        [
            SummaryField(label: "Method", value: session.request.method),
            SummaryField(label: "Path", value: session.request.path),
            SummaryField(label: "Host", value: session.request.host),
            SummaryField(label: "Scheme", value: session.request.scheme.rawValue.uppercased()),
            SummaryField(label: "Inspection", value: inspectionLabel(for: session.request.inspectionKind)),
            SummaryField(label: "Reason", value: session.request.inspectionReason ?? "Not specified"),
            SummaryField(label: "Port", value: session.request.port.map(String.init) ?? "-"),
            SummaryField(label: "Body Bytes", value: session.request.bodySize.map(String.init) ?? "0")
        ]
    }

    private func responseSummaryFields(for session: SessionRecord) -> [SummaryField] {
        if session.request.inspectionKind == .tunneledTLS {
            return [
                SummaryField(label: "Status", value: "Tunnel established"),
                SummaryField(label: "TLS Contents", value: "Not decrypted"),
                SummaryField(label: "Reason", value: session.request.inspectionReason ?? "Compatibility pass-through")
            ]
        }

        return [
            SummaryField(label: "Status", value: session.response.map { String($0.statusCode) } ?? "Pending"),
            SummaryField(label: "Source", value: session.response?.sourceDescription ?? "Upstream"),
            SummaryField(label: "Body Bytes", value: session.response?.bodySize.map(String.init) ?? "0")
        ]
    }

    private func timingFields(for session: SessionRecord) -> [SummaryField] {
        [
            SummaryField(label: "Started", value: session.timing.startedAt.formatted(date: .abbreviated, time: .standard)),
            SummaryField(label: "Completed", value: session.timing.completedAt?.formatted(date: .abbreviated, time: .standard) ?? "Pending"),
            SummaryField(label: "Duration", value: session.timing.duration.map { $0.formatted(.number.precision(.fractionLength(3))) + "s" } ?? "Pending"),
            SummaryField(label: "State", value: session.state.rawValue.capitalized)
        ]
    }

    private func summaryText(for session: SessionRecord) -> String {
        [
            "Method: \(session.request.method)",
            "Status: \(session.response.map { String($0.statusCode) } ?? (session.failure == nil ? "Pending" : "Error"))",
            "URL: \(session.request.scheme.rawValue)://\(session.request.host)\(session.request.path)",
            "Inspection: \(inspectionLabel(for: session.request.inspectionKind))",
            "Request Bytes: \(session.request.bodySize.map(formatBytes) ?? "0 B")",
            "Response Bytes: \(session.response?.bodySize.map(formatBytes) ?? "0 B")",
            "Duration: \(session.timing.duration.map { $0.formatted(.number.precision(.fractionLength(3))) + "s" } ?? "Pending")"
        ]
        .joined(separator: "\n")
    }

    private func timingText(for session: SessionRecord) -> String {
        timingFields(for: session)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
    }

    private func cachingFields(_ f: CacheFreshnessSummary) -> [SummaryField] {
        var fields = [
            SummaryField(label: "Freshness", value: f.displayBadgeText),
            SummaryField(label: "Revalidation", value: f.revalidationRequired ? "Required" : "Optional"),
            SummaryField(label: "Effective TTL", value: f.effectiveTTLSeconds.map { "\($0)s" } ?? "None"),
            SummaryField(label: "Age", value: f.ageSeconds.map { "\($0)s" } ?? "0s"),
            SummaryField(label: "ETag", value: f.etag ?? "None"),
            SummaryField(label: "Last-Modified", value: f.lastModified ?? "None"),
            SummaryField(label: "CDN Status", value: f.cdnStatus ?? "Direct / Origin")
        ]
        if let swr = f.staleWhileRevalidateSeconds {
            fields.append(SummaryField(label: "Stale-While-Revalidate", value: "\(swr)s"))
        }
        return fields
    }

    private func cachingText(for session: SessionRecord) -> String {
        let f = session.cacheFreshness
        var lines = cachingFields(f).map { "\($0.label): \($0.value)" }
        if !f.conflictingDirectives.isEmpty {
            lines.append("Conflicts: " + f.conflictingDirectives.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func contractValidationText(for report: OpenAPIValidationReport) -> String {
        var lines: [String] = []
        if let opID = report.operationID {
            lines.append("Operation: \(opID)")
        }
        lines.append("Status: \(report.badgeText)")
        if !report.violations.isEmpty {
            lines.append("Violations:")
            for v in report.violations {
                lines.append("  - \(v.keyPath): \(v.reason) (expected: \(v.expected), actual: \(v.actual))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func headerText(_ headers: [HTTPHeaderField], redactSensitive: Bool = false) -> String {
        if headers.isEmpty {
            return "No headers"
        }

        return headers
            .map {
                let value = redactSensitive ? redactedHeaderValue(for: $0.name, value: $0.value) : $0.value
                return "\($0.name): \(value)"
            }
            .joined(separator: "\n")
    }

    private func bodyText(for bodyData: Data?, headers: [HTTPHeaderField]) -> String {
        guard let bodyData else {
            return "No body"
        }

        if bodyData.isEmpty {
            return "Empty body"
        }

        if !CapturedBodyDecoder.isKnownBinaryContentType(headers: headers),
           let utf8Text = String(data: bodyData, encoding: .utf8) {
            return utf8Text
        }

        return """
        Binary body (\(bodyData.count) bytes)

        Base64:
        \(bodyData.base64EncodedString())
        """
    }

    private func matchCountLabel(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count) matches"
    }

    private func byteCountLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func findExcerptAccessibilityLabel(
        context: SessionFindBodyMatchContext,
        result: SessionFindExcerptResult
    ) -> String {
        switch result {
        case .excerpts(let excerpts):
            let preview = excerpts.map(\.plainText).joined(separator: " ")
            return "\(matchCountLabel(context.matchCount)) for \(context.query). \(preview)"
        case .tooLarge:
            return "\(matchCountLabel(context.matchCount)) for \(context.query). Body too large to preview."
        }
    }

    private func inspectorCopyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            inspectorActionLabel(title, systemImage: "document.on.document")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func inspectorActionLabel(_ title: String, systemImage: String) -> some View {
        if isInspectorCompact {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func copyTextToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func redactedHeaderValue(for name: String, value: String) -> String {
        if SensitiveDataRedaction.isSensitiveHeaderName(name) {
            return "<redacted>"
        }
        return value
    }

    /// Refreshes on selection/content revision, never on unrelated capture publications.
    private func refreshCachedSources(for session: SessionRecord) {
        if session.id != cachedSourcesSessionID { expandedFormParamIndices = [] }
        bodyCache.update(session: session, revision: contentRevision)
    }

    private func clearBodyCache() {
        bodyCache.clear()
        validationReport = nil
        expandedFormParamIndices = []
    }

    private func responseAnalysisData(for session: SessionRecord) -> Data? {
        if session.id == cachedSourcesSessionID, let cachedResponseBodyDecode {
            return cachedResponseBodyDecode.analysisData
        }
        guard let response = session.response else {
            return nil
        }
        return responseAnalysisData(response: response, decode: CapturedBodyDecoder.decode(response: response))
    }

    private func responseBodyDisplayText(for session: SessionRecord) -> String {
        if let decodedText = cachedResponseBodyDecode?.analysisUTF8Text() {
            return decodedText
        }
        if session.id != cachedSourcesSessionID,
           let decoded = session.response.flatMap({ CapturedBodyDecoder.decode(response: $0) }),
           let text = decoded.analysisUTF8Text() {
            return text
        }
        return bodyText(for: session.response?.bodyData, headers: session.response?.headers ?? [])
    }

    private func responseTextPageData(for session: SessionRecord) -> Data? {
        if CapturedBodyDecoder.isKnownBinaryContentType(headers: session.response?.headers ?? []) {
            return session.response?.bodyData
        }
        return responseAnalysisData(for: session) ?? session.response?.bodyData
    }

    private func responseAnalysisData(response: CapturedResponse, decode: CapturedBodyDecodeResult?) -> Data? {
        if let decode {
            return decode.canUseAnalysisDataForInspection ? decode.analysisData : nil
        }
        return response.bodyData
    }

    private func responseBodyDecodeBannerMessage(for session: SessionRecord) -> String? {
        let decode = session.id == cachedSourcesSessionID
            ? cachedResponseBodyDecode
            : session.response.flatMap { CapturedBodyDecoder.decode(response: $0) }

        guard let decode else {
            return nil
        }

        switch decode.status {
        case .decoded(let appliedCodings):
            let codingLabel = appliedCodings.joined(separator: ", ")
            return "Decoded \(codingLabel): \(formatBytes(decode.rawByteCount)) → \(formatBytes(decode.analysisByteCount))"
        case .unsupported(let coding):
            return "Unsupported response body encoding (\(coding)). Showing captured bytes."
        case .failed(let reason):
            return "Could not decode response body (\(reason)). Showing captured bytes."
        case .limitExceeded(let maxBytes):
            return "Decoded body would exceed \(formatBytes(maxBytes)). Find and JSON preview are unavailable for this response."
        case .unchanged:
            return nil
        }
    }

    /// When the user navigated here from a Find result, switch the matched body pane's JSON
    /// view mode to Prettified so the body renders as a flat string suitable for highlighting.
    /// Only fires when the body is actually JSON (source is non-nil). Does nothing for
    /// non-JSON bodies (plain text, form-encoded, XML) since those already render as flat text.
    private func applyFindResultModeSwitch(for session: SessionRecord) {
        guard let location = activeFindResultLocation else { return }

        let renderSignpost = SessionFindPerformanceSignposts.beginDetailRender()
        defer { SessionFindPerformanceSignposts.endDetailRender(renderSignpost) }

        switch location {
        case .requestBody:
            if cachedRequestBodySource != nil {
                requestJSONViewMode = .prettified
            }
        case .responseBody:
            if cachedResponseBodySource != nil {
                responseJSONViewMode = .prettified
            }
        }
    }

    private func isFormEncoded(headers: [HTTPHeaderField]) -> Bool {
        guard let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() else { return false }
        let mimeType = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? contentType
        return mimeType == "application/x-www-form-urlencoded"
    }

    /// Parses a `application/x-www-form-urlencoded` body into ordered (name, value) pairs.
    /// Returns nil if the data cannot be decoded as UTF-8 or produces no items.
    private func parseFormParams(from data: Data) -> [(name: String, value: String)]? {
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else { return nil }
        // Prefix "?" so URLComponents treats the whole string as a query.
        guard let components = URLComponents(string: "?\(string)"),
              let items = components.queryItems, !items.isEmpty else { return nil }
        return items.map { (name: $0.name, value: $0.value ?? "") }
    }

    private func isLikelyXML(headers: [HTTPHeaderField]) -> Bool {
        guard let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() else { return false }
        let mimeType = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? contentType
        return mimeType == "text/xml"
            || mimeType == "application/xml"
            || mimeType == "application/soap+xml"
            || mimeType.hasSuffix("+xml")
    }

    /// Returns an indented XML string, or nil if the data cannot be parsed as XML.
    private func prettifiedXML(from data: Data) -> String? {
        guard let doc = try? XMLDocument(data: data, options: .nodePrettyPrint) else { return nil }
        let prettyData = doc.xmlData(options: .nodePrettyPrint)
        return String(data: prettyData, encoding: .utf8)
    }

    // MARK: - Form-encoded body table

    @ViewBuilder
    private func formEncodedBodyContent(
        params: [(name: String, value: String)],
        findQuery: String?,
        findNavigationID: UUID?,
        bodyLabel: String
    ) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: formParamGridColumns,
                    alignment: .leading,
                    spacing: inspectorDisclosureContentSpacing
                ) {
                    // Column headers
                    Text("Key")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text("Value")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)

                    ForEach(Array(params.enumerated()), id: \.offset) { index, param in
                        // Key cell
                        highlightedBodyText(param.name, query: findQuery)
                            .appFont(.body, scale: appTextScale, design: .monospaced)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(formParamRowID(index))

                        // Value cell — truncated if long
                        formParamValueCell(index: index, value: param.value, findQuery: findQuery)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.top, inspectorDisclosureTopPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                scrollToFormMatch(
                    params: params,
                    findQuery: findQuery,
                    bodyLabel: bodyLabel,
                    scrollProxy: scrollProxy
                )
            }
            .onChange(of: findNavigationID) { _, _ in
                scrollToFormMatch(
                    params: params,
                    findQuery: findQuery,
                    bodyLabel: bodyLabel,
                    scrollProxy: scrollProxy
                )
            }
        }
    }

    private func formParamValueCell(index: Int, value: String, findQuery: String?) -> some View {
        let isLong = value.count > 120
        let expanded = expandedFormParamIndices.contains(index)
        let trimmedQuery = findQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryMatchesFullValue = !trimmedQuery.isEmpty && value.range(
            of: trimmedQuery,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let shouldTruncate = isLong && !expanded && !queryMatchesFullValue
        let displayValue = shouldTruncate ? String(value.prefix(120)) + "…" : value
        return VStack(alignment: .leading, spacing: 2) {
            highlightedBodyText(displayValue, query: findQuery)
                .appFont(.body, scale: appTextScale, design: .monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if isLong && (!queryMatchesFullValue || expanded) {
                Button(expanded ? "Show less" : "Show more") {
                    if expanded {
                        expandedFormParamIndices.remove(index)
                    } else {
                        expandedFormParamIndices.insert(index)
                    }
                }
                .buttonStyle(.borderless)
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func highlightedBodyText(_ content: String, query: String?) -> Text {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty,
              let range = content.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) else {
            return Text(verbatim: content)
        }

        var attributed = AttributedString(content)
        if let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].backgroundColor = Color.accentColor.opacity(0.32)
            attributed[attributedRange].foregroundColor = Color.primary
        }
        return Text(attributed)
    }

    private func scrollToFormMatch(
        params: [(name: String, value: String)],
        findQuery: String?,
        bodyLabel: String,
        scrollProxy: ScrollViewProxy
    ) {
        guard let index = firstMatchingFormParamIndex(params: params, findQuery: findQuery) else {
            logFind("Form \(bodyLabel) body has no row match for query '\(findQuery ?? "")'")
            return
        }

        logFind("Form \(bodyLabel) body scrolling to row \(index) for query '\(findQuery ?? "")'")
        withAnimation(.easeInOut(duration: 0.18)) {
            scrollProxy.scrollTo(formParamRowID(index), anchor: .center)
        }
    }

    private func firstMatchingFormParamIndex(params: [(name: String, value: String)], findQuery: String?) -> Int? {
        let trimmedQuery = findQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else { return nil }

        return params.firstIndex { param in
            param.name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || param.value.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func formParamRowID(_ index: Int) -> String {
        "form-param-\(index)"
    }

    private func logFind(_ message: String) {
        guard findDebugLoggingEnabled else { return }
        debugPrint("Find debug: \(message)")
    }

    @ViewBuilder
    private func jsonModePicker(selection: Binding<JSONViewMode>) -> some View {
        Picker("JSON View", selection: selection) {
            ForEach(JSONViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.iconName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280 * appTextScale)
    }

    private func inspectionLabel(for inspectionKind: SessionInspectionKind) -> String {
        switch inspectionKind {
        case .plain:
            return "HTTP"
        case .interceptedTLS:
            return "HTTPS Inspected"
        case .tunneledTLS:
            return "HTTPS Tunneled"
        }
    }
}

struct SessionDetailPlaceholderView: View {
    @Environment(\.appTextScale) private var appTextScale
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .appFont(.title2, scale: appTextScale)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("No Session Selected")
                        .appFont(.title2, scale: appTextScale, weight: .semibold)

                    Text("Select a captured request to inspect headers, timing, and bodies.")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No session selected. Select a captured request to inspect its details.")
    }
}

struct InspectorPlaceholderSection: View {
    @Environment(\.appTextScale) private var appTextScale
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 160, height: 10)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
    }
}

// MARK: - Recording UI

/// An inline banner shown below request or response body sections when that body was truncated
/// at recording save time.
struct TruncationWarningBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .foregroundStyle(.orange)
            Text("Body truncated during recording save.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Body was truncated during recording save.")
    }
}

/// Inline banner when stored response bytes were decoded for inspection (for example gzip JSON).
struct BodyDecodeStatusBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(.teal)
            Text(verbatim: message)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(message)
    }
}

/// An inline banner shown when a saved recording intentionally omitted a body based on the chosen
/// recording fidelity mode.
struct BodyOmissionWarningBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.minus")
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(message)
    }
}

/// An inline banner shown in the request or response body section while phase-2 body decode is
/// pending after a large-file recording open. Replaced by the actual body content once
/// `RecordingLoadCoordinator` calls `SessionStore.update(_:)` with the fully decoded session.
struct BodyLoadingBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading body…")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Body is loading.")
    }
}
