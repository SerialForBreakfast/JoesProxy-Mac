//
//  JSONViewerSheet.swift
//  JoesProxy
//
//  Displays a JSON file in tree or raw view. Opened via File > Open JSON as a normal window.
//

import AppKit
import CryptoKit
import SwiftUI

// MARK: - NSAttributedString + HighlightSpan

extension NSMutableAttributedString {
    /// Applies an array of `HighlightSpan` values produced by `JSONSyntaxHighlighter`.
    ///
    /// Call on the main actor after receiving spans from a background task.
    func applyHighlightSpans(_ spans: [HighlightSpan]) {
        for span in spans {
            addAttribute(.foregroundColor, value: span.color.nsColor, range: span.range)
        }
    }
}

private extension HighlightColor {
    /// Resolves to the corresponding `NSColor`. Must be called on the main thread.
    var nsColor: NSColor {
        switch self {
        case .key:         return .systemBlue
        case .string:      return .systemGreen
        case .number:      return .systemOrange
        case .boolean:     return .systemPurple
        case .null:        return .secondaryLabelColor
        case .bracket:     return .systemPurple
        case .punctuation: return .secondaryLabelColor
        }
    }
}

/// View mode for the JSON viewer: folder-style tree, original raw text, or prettified text.
enum JSONViewMode: String, CaseIterable, Sendable, Hashable {
    case folder = "Folder"
    case raw = "Raw"
    case prettified = "Prettified"
}

/// Displays JSON from a file URL in tree or raw view.
///
/// Loads the file from disk, parses it as JSON, and renders in an expandable tree or as raw text.
struct JSONViewerSheet: View {
    let fileURL: URL
    @State private var source: JSONContentSource?
    @State private var viewMode: JSONViewMode = .folder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            JSONContentView(
                source: source,
                viewMode: $viewMode,
                findQuery: nil,
                findNavigationID: nil,
                findDebugLoggingEnabled: false
            )
        }
        .frame(minWidth: 480, minHeight: 400)
        .navigationTitle(fileURL.lastPathComponent)
        .task {
            await loadFile()
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL.lastPathComponent)
                    .font(.headline)
                Text(fileURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if source?.isLoaded == true {
                viewModeTabs
            }

            Button("Close") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var viewModeTabs: some View {
        Picker("View", selection: $viewMode) {
            ForEach(JSONViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.iconName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
    }

    /// Loads the file from disk asynchronously to avoid blocking the main thread.
    /// Concurrency: runs file I/O off the main actor, then updates @State on MainActor.
    private func loadFile() async {
        source = .loading

        let url = fileURL
        let result: Result<JSONContentSource, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                return .success(try JSONContentSource.makeLoaded(from: data))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let loadedSource):
            source = loadedSource
        case .failure(let error):
            source = .failed(message: error.localizedDescription)
        }
    }
}

// MARK: - View mode icons

extension JSONViewMode {
    var iconName: String {
        switch self {
        case .folder: return "folder.fill"
        case .raw: return "curlybraces"
        case .prettified: return "text.alignleft"
        }
    }
}

/// Character count above which syntax highlighting is disabled by default to avoid
/// main-thread blocking and memory pressure when rendering large JSON.
let rawViewHighlightingThreshold = 500_000

enum JSONContentSource {
    case loading
    case loaded(id: UUID, revision: UUID, rawJSON: String, data: Data)
    case failed(message: String)

    var isLoaded: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }

    var loadedID: UUID? {
        guard case .loaded(let id, _, _, _) = self else {
            return nil
        }
        return id
    }

    static func makeLoaded(from data: Data) throws -> JSONContentSource {
        try makeLoaded(from: data, stableID: UUID())
    }

    /// Retain this immutable source across renders. Logical identity stays stable, while each
    /// newly constructed source has its own revision without scanning bytes during rendering.
    static func makeLoaded(from data: Data, stableID: UUID) throws -> JSONContentSource {
        let rawJSON = try originalJSONString(from: data)
        return .loaded(id: stableID, revision: UUID(), rawJSON: rawJSON, data: data)
    }

    /// Derives a deterministic UUID from body bytes for stable viewer caching.
    static func stableID(for data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress!) as UUID
        }
        return uuid
    }

    /// Use only at source-refresh boundaries, never as a computed view/task identity.
    static func contentDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func originalJSONString(from data: Data) throws -> String {
        if let string = String(data: data, encoding: .utf8) {
            return normalizeStreamingJSONSeparators(string)
        }

        if let string = String(data: data, encoding: .utf16LittleEndian) {
            return string
        }

        if let string = String(data: data, encoding: .utf16BigEndian) {
            return string
        }

        throw JSONTreeParserError.invalidUTF8
    }

    /// Replaces Konductor-style null record separators with newlines for raw display.
    private static func normalizeStreamingJSONSeparators(_ text: String) -> String {
        guard text.contains("\0") else {
            return text
        }

        return text
            .replacingOccurrences(of: "\0", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prettyPrintedJSONString(from data: Data) throws -> String {
        let jsonObject = try JSONTreeParser.parseJSONObject(from: data)
        let prettyPrintedData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        guard let string = String(data: prettyPrintedData, encoding: .utf8) else {
            throw JSONTreeParserError.invalidUTF8
        }

        return string
    }
}

struct JSONContentView: View {
    let source: JSONContentSource?
    @Binding var viewMode: JSONViewMode
    let findQuery: String?
    let findNavigationID: UUID?
    let findDebugLoggingEnabled: Bool
    /// When set, folder and prettified views offer a context menu to prefill bookmark rewrite fields.
    var onAddFieldRewrite: ((String, String) -> Void)? = nil
    /// Optional shared expansion state so toggling preview patches does not collapse the tree.
    var treeExpandedIDs: Binding<Set<String>>? = nil
    /// When set, folder view scrolls to this dot path after the tree reloads (e.g. preview toggle).
    var treeScrollAnchorPath: String? = nil
    /// Preserves NSScrollView position when prettified/raw text changes without a find navigation.
    var preservesScrollPositionOnContentChange: Bool = false
    /// Surgical bookmark preview overrides; toggling does not re-parse the saved response body.
    var previewOverridesByPath: [String: BookmarkJSONValue] = [:]
    @State private var derivation = JSONDerivationModel()
    private var cachedRoot: JSONTreeNode? { derivation.root }
    private var cachedPrettifiedJSON: String? { derivation.prettified }
    private var derivationErrorMessage: String? { derivation.errorMessage }
    @State private var showTypeLegend = false

    var body: some View {
        Group {
            switch source {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(_, _, let rawJSON, let data):
                switch viewMode {
                case .folder:
                    if let cachedRoot {
                        JSONTreeView(
                            root: cachedRoot,
                            expandedIDs: treeExpandedIDs,
                            scrollAnchorPath: treeScrollAnchorPath,
                            previewOverridesByPath: previewOverridesByPath,
                            onAddFieldRewrite: onAddFieldRewrite
                        )
                    } else if let derivationErrorMessage {
                        errorView(message: derivationErrorMessage)
                    } else {
                        ProgressView("Loading folder view…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .raw:
                    RawJSONView(
                        content: rawJSON,
                        jsonData: data,
                        findQuery: findQuery,
                        findNavigationID: findNavigationID,
                        findDebugLoggingEnabled: findDebugLoggingEnabled,
                        preservesScrollPositionOnContentChange: preservesScrollPositionOnContentChange,
                        onAddFieldRewrite: onAddFieldRewrite
                    )
                case .prettified:
                    if let displayedPrettifiedJSON {
                        RawJSONView(
                            content: displayedPrettifiedJSON,
                            jsonData: data,
                            findQuery: findQuery,
                            findNavigationID: findNavigationID,
                            findDebugLoggingEnabled: findDebugLoggingEnabled,
                            preservesScrollPositionOnContentChange: preservesScrollPositionOnContentChange,
                            onAddFieldRewrite: onAddFieldRewrite
                        )
                    } else if let derivationErrorMessage {
                        errorView(message: derivationErrorMessage)
                    } else {
                        ProgressView("Loading prettified JSON…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .failed(let message):
                errorView(message: message)
            case .none:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsFolderTypeLegendButton {
                Button {
                    showTypeLegend = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(8)
                .accessibilityLabel("Show JSON type legend")
                .popover(isPresented: $showTypeLegend) {
                    JSONTypeLegendView()
                        .padding(4)
                }
            }
        }
        .task(id: derivationTaskID) {
            loadDerivedContentIfNeeded()
        }
        .onDisappear {
            derivation.cancelAndClear()
        }
    }

    /// Folder mode shows a `?` control for the on-demand JSON type legend (Workstream AC-1).
    private var showsFolderTypeLegendButton: Bool {
        guard viewMode == .folder else { return false }
        if case .loaded = source, cachedRoot != nil {
            return true
        }
        return false
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Could not load JSON")
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var derivationTaskID: String {
        guard let source else {
            return "none"
        }

        switch source {
        case .loading:
            return "loading"
        case .failed(let message):
            return "failed:\(message)"
        case .loaded(let id, let revision, _, _):
            return "\(id.uuidString)-\(viewMode.rawValue)-\(revision.uuidString)"
        }
    }

    /// Base prettified text with surgical preview overrides applied when present.
    private var displayedPrettifiedJSON: String? {
        guard let cachedPrettifiedJSON, case .loaded(_, _, _, let data) = source else {
            return nil
        }

        guard !previewOverridesByPath.isEmpty else {
            return cachedPrettifiedJSON
        }

        return BookmarkJSONPreviewOverlay.patchedPrettifiedText(
            base: cachedPrettifiedJSON,
            bodyData: data,
            overrides: previewOverridesByPath
        )
    }

    /// Submits the latest immutable input; the model owns one worker and one pending request.
    private func loadDerivedContentIfNeeded() {
        derivation.request(source: source, mode: viewMode)
    }
}

/// Displays raw JSON text with optional syntax highlighting.
///
/// Includes a toggle to enable or disable highlighting for legibility and accessibility.
/// For content exceeding `rawViewHighlightingThreshold` characters, highlighting is off
/// by default and the toggle is disabled.
///
/// Syntax highlighting is computed asynchronously off the main thread using
/// `JSONSyntaxHighlighter`. Plain text is shown immediately; the highlighted
/// `NSAttributedString` is swapped in once the background task completes.
struct RawJSONView: View {
    let content: String
    let jsonData: Data?
    let findQuery: String?
    let findNavigationID: UUID?
    let findDebugLoggingEnabled: Bool
    var onAddFieldRewrite: ((String, String) -> Void)? = nil
    var preservesScrollPositionOnContentChange: Bool = false
    @State private var syntaxHighlightingEnabled: Bool
    /// Pre-computed highlighted content. `nil` while computing or when highlighting is off.
    @State private var highlightedContent: NSAttributedString?
    /// `true` while a background highlighting task is running.
    @State private var isComputingHighlighting = false
    /// Bumped per `computeHighlighting()` call; guards against a superseded, slower highlight
    /// pass overwriting a fresher one once it finishes (see `derivationGeneration` above for why
    /// `.task(id:)` cancellation alone doesn't prevent this — `Task.detached` isn't structurally
    /// linked to it).
    @State private var highlightGeneration: UInt64 = 0

    init(
        content: String,
        jsonData: Data? = nil,
        findQuery: String? = nil,
        findNavigationID: UUID? = nil,
        findDebugLoggingEnabled: Bool = false,
        preservesScrollPositionOnContentChange: Bool = false,
        onAddFieldRewrite: ((String, String) -> Void)? = nil
    ) {
        self.content = content
        self.jsonData = jsonData
        self.findQuery = findQuery
        self.findNavigationID = findNavigationID
        self.findDebugLoggingEnabled = findDebugLoggingEnabled
        self.preservesScrollPositionOnContentChange = preservesScrollPositionOnContentChange
        self.onAddFieldRewrite = onAddFieldRewrite
        _syntaxHighlightingEnabled = State(initialValue: content.count <= rawViewHighlightingThreshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rawToolbar
            rawContent
        }
        .task(id: HighlightTaskKey(content: content, enabled: syntaxHighlightingEnabled)) {
            await computeHighlighting()
        }
    }

    private var rawToolbar: some View {
        let exceedsThreshold = content.count > rawViewHighlightingThreshold
        return HStack(spacing: 8) {
            Toggle(isOn: $syntaxHighlightingEnabled) {
                Text("Syntax highlighting")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .disabled(exceedsThreshold)
            .accessibilityLabel("Syntax highlighting")
            .accessibilityHint(
                exceedsThreshold
                    ? "Disabled for large files to prevent freezing"
                    : "Toggles colored syntax highlighting for legibility and accessibility"
            )

            if exceedsThreshold {
                Text("(disabled for large file)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isComputingHighlighting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Applying syntax highlighting")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var rawContent: some View {
        RawJSONTextView(
            content: content,
            jsonData: jsonData,
            highlightedContent: syntaxHighlightingEnabled ? highlightedContent : nil,
            highlightQuery: findQuery,
            highlightNavigationID: findNavigationID,
            findDebugLoggingEnabled: findDebugLoggingEnabled,
            preservesScrollPositionOnContentChange: preservesScrollPositionOnContentChange,
            onAddFieldRewrite: onAddFieldRewrite
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Computes syntax highlighting off the main actor.
    ///
    /// Concurrency: tokenization runs via `runDetachedCancellable(priority: .utility)`
    /// (`JoesProxy/Utilities/DetachedCancellable.swift`) — `.utility`, not `.userInitiated`, so it
    /// never outranks the proxy's own request-handling Tasks for the shared cooperative thread
    /// pool, and bridges cancellation down to the detached child. That bridge can't interrupt
    /// tokenization already mid-flight (`JSONSyntaxHighlighter` has no cancellation checkpoints),
    /// so `highlightGeneration` is checked before the result is written: a superseded, slower
    /// pass can finish after a newer one and must not clobber it. `[HighlightSpan]` is a fully
    /// `Sendable` value type; the `NSAttributedString` is assembled back on the `MainActor` so no
    /// AppKit objects cross the concurrency boundary. See
    /// memlog/Research/ADR-Swift-Concurrency-Request-Pipeline-Latency-And-Snapshot-Routing.md §6.
    private func computeHighlighting() async {
        guard syntaxHighlightingEnabled else {
            highlightedContent = nil
            isComputingHighlighting = false
            return
        }
        isComputingHighlighting = true
        highlightGeneration &+= 1
        let generation = highlightGeneration
        let spans: [HighlightSpan] = await runDetachedCancellable(priority: .utility) {
            JSONSyntaxHighlighter.spans(for: content)
        }
        guard generation == highlightGeneration else {
            // A newer call superseded this one; it owns resetting `isComputingHighlighting`.
            return
        }
        let attributed = NSMutableAttributedString(
            string: content,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
        )
        attributed.applyHighlightSpans(spans)
        highlightedContent = attributed
        isComputingHighlighting = false
    }

    /// Equatable key that drives the `.task(id:)` lifecycle for highlighting.
    private struct HighlightTaskKey: Equatable {
        let content: String
        let enabled: Bool
    }
}

/// Wraps `NSTextView` inside an `NSScrollView` for display of raw JSON text.
///
/// Applies a pre-computed `NSAttributedString` when available, falling back to
/// plain monospace text. All expensive work (tokenization, attribute building) is
/// done off-thread before being passed in; `updateNSView` never blocks the main thread.
private struct RawJSONTextView: NSViewRepresentable {
    let content: String
    let jsonData: Data?
    /// Pre-computed highlighted attributed string, or `nil` for plain text.
    let highlightedContent: NSAttributedString?
    /// Query to bring into view using the native `NSTextView` find indicator.
    let highlightQuery: String?
    /// Unique token for the active find navigation; changes replay the native pulse.
    let highlightNavigationID: UUID?
    let findDebugLoggingEnabled: Bool
    var preservesScrollPositionOnContentChange: Bool = false
    var onAddFieldRewrite: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onAddFieldRewrite: onAddFieldRewrite)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineBreakMode = .byClipping

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        context.coordinator.jsonData = jsonData
        context.coordinator.content = content
        applyContent(to: textView, coordinator: context.coordinator)
        scrollToHighlightIfNeeded(in: textView, coordinator: context.coordinator)
        return scrollView
    }

    private func applyContent(to textView: NSTextView, coordinator: Coordinator) {
        applyContent(to: textView, scrollView: nil, coordinator: coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onAddFieldRewrite = onAddFieldRewrite
        context.coordinator.jsonData = jsonData
        context.coordinator.preservesScrollPositionOnContentChange = preservesScrollPositionOnContentChange
        let shouldPreserveScroll = preservesScrollPositionOnContentChange &&
            highlightNavigationID == nil &&
            context.coordinator.content != content
        if shouldPreserveScroll {
            context.coordinator.savedScrollOrigin = scrollView.contentView.bounds.origin
        }
        context.coordinator.content = content
        applyContent(to: textView, scrollView: scrollView, coordinator: context.coordinator)
        if shouldPreserveScroll, let savedOrigin = context.coordinator.savedScrollOrigin {
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.savedScrollOrigin = nil
        }
        scrollToHighlightIfNeeded(in: textView, coordinator: context.coordinator)
    }

    /// Applies either the pre-computed highlighted string or plain monospace text.
    /// Guards against redundant updates using coordinator identity tracking.
    private func applyContent(to textView: NSTextView, scrollView: NSScrollView?, coordinator: Coordinator) {
        let mode = DisplayMode(content: content, highlightedContent: highlightedContent)
        guard coordinator.lastDisplayMode != mode else { return }
        coordinator.lastDisplayMode = mode

        if let highlighted = highlightedContent {
            textView.textStorage?.setAttributedString(highlighted)
        } else {
            textView.textStorage?.setAttributedString(plainAttributedString())
        }
    }

    private func plainAttributedString() -> NSAttributedString {
        NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
        )
    }

    private func scrollToHighlightIfNeeded(in textView: NSTextView, coordinator: Coordinator) {
        let trimmedQuery = highlightQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty,
              !content.isEmpty,
              content.count >= trimmedQuery.count else {
            coordinator.lastHighlightTrigger = nil
            logFind("Raw JSON highlight skipped query='\(trimmedQuery)' contentCount=\(content.count)")
            return
        }

        let trigger = HighlightTrigger(
            content: content,
            query: trimmedQuery,
            navigationID: highlightNavigationID
        )
        guard coordinator.lastHighlightTrigger != trigger else {
            logFind("Raw JSON highlight skipped unchanged trigger query='\(trimmedQuery)' token=\(highlightNavigationID?.uuidString ?? "nil")")
            return
        }
        coordinator.lastHighlightTrigger = trigger

        guard let range = content.range(
            of: trimmedQuery,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            logFind("Raw JSON highlight found no displayed-content match for query='\(trimmedQuery)' contentCount=\(content.count)")
            return
        }

        let nsRange = NSRange(range, in: content)
        logFind("Raw JSON highlight scrolling nsRange=\(nsRange.location)..<\(nsRange.location + nsRange.length) query='\(trimmedQuery)' contentCount=\(content.count) token=\(highlightNavigationID?.uuidString ?? "nil")")
        textView.scrollRangeToVisible(nsRange)
        textView.showFindIndicator(for: nsRange)
    }

    private func logFind(_ message: String) {
        guard findDebugLoggingEnabled else { return }
        debugPrint("Find debug: \(message)")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onAddFieldRewrite: ((String, String) -> Void)?
        var jsonData: Data?
        var content: String = ""
        var preservesScrollPositionOnContentChange = false
        var savedScrollOrigin: NSPoint?
        var lastDisplayMode: DisplayMode?
        var lastHighlightTrigger: HighlightTrigger?

        init(onAddFieldRewrite: ((String, String) -> Void)?) {
            self.onAddFieldRewrite = onAddFieldRewrite
        }

        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard onAddFieldRewrite != nil,
                  let jsonData,
                  let line = line(at: charIndex, in: textView),
                  let parsed = JSONPathResolver.parsePrettifiedLine(line) else {
                return menu
            }

            let paths = JSONPathResolver.paths(
                forLeafKey: parsed.key,
                matchingValue: parsed.value,
                in: jsonData
            )
            guard let path = paths.first else {
                return menu
            }

            let item = NSMenuItem(
                title: "Add Field Rewrite for “\(parsed.key)”",
                action: #selector(addFieldRewriteFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = RewriteMenuPayload(path: path, value: parsed.value)
            menu.insertItem(item, at: 0)
            if menu.items.count > 1 {
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }

        @objc private func addFieldRewriteFromMenu(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? RewriteMenuPayload else {
                return
            }
            onAddFieldRewrite?(payload.path, payload.value)
        }

        private func line(at charIndex: Int, in textView: NSTextView) -> String? {
            guard let text = textView.string as String? else {
                return nil
            }
            let nsText = text as NSString
            let clampedIndex = max(0, min(charIndex, nsText.length))
            let lineRange = nsText.lineRange(for: NSRange(location: clampedIndex, length: 0))
            return nsText.substring(with: lineRange)
        }

        private final class RewriteMenuPayload: NSObject {
            let path: String
            let value: String

            init(path: String, value: String) {
                self.path = path
                self.value = value
            }
        }
    }

    struct HighlightTrigger: Equatable {
        let content: String
        let query: String
        let navigationID: UUID?
    }

    /// Tracks the last applied state to avoid redundant `setAttributedString` calls.
    ///
    /// Uses reference identity (`===`) for `NSAttributedString` comparison so that
    /// the coordinator check is O(1) and does not re-scan large attributed strings.
    struct DisplayMode: Equatable {
        let content: String
        let highlightedContent: NSAttributedString?

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.content == rhs.content else { return false }
            switch (lhs.highlightedContent, rhs.highlightedContent) {
            case (nil, nil):       return true
            case (let l?, let r?): return l === r
            default:               return false
            }
        }
    }
}
