//
//  MainWindowHelpSupport.swift
//  JoesProxy
//
//  Contextual help drawer content and topic resolution for the main window.
//

import SwiftUI

enum MainWindowHelpTopic: String, CaseIterable, Identifiable {
    case certificateSetup
    case trafficStates
    case systemProxyRouting
    case capturedSessions
    case requestInspector
    case networkThrottling
    case localOverrides
    case bookmarksReplay
    case bookmarkResponseRewrites
    case mediaInfo
    case mcpAndCLI
    case exportPrivacy
    case visualizationExport

    var id: String { rawValue }

    var hubSectionID: String {
        switch self {
        case .certificateSetup, .systemProxyRouting, .mcpAndCLI:
            return HelpHubSectionID.gettingStarted.rawValue
        case .trafficStates:
            return HelpHubSectionID.trafficStates.rawValue
        case .capturedSessions, .networkThrottling, .localOverrides, .bookmarksReplay, .bookmarkResponseRewrites, .requestInspector, .mediaInfo:
            return HelpHubSectionID.sessionTools.rawValue
        case .exportPrivacy, .visualizationExport:
            return HelpHubSectionID.importExport.rawValue
        }
    }

    var title: String {
        HelpDocumentation.topic(rawValue)?.title ?? rawValue
    }

    var summary: String {
        HelpDocumentation.topic(rawValue)?.summary ?? "Documentation unavailable."
    }

    var whatThisIs: String {
        HelpDocumentation.text(rawValue, section: "overview")
    }

    var whyYouAreSeeingIt: [String] {
        HelpDocumentation.bullets(rawValue, section: "context")
    }

    var nextSteps: [String] {
        HelpDocumentation.bullets(rawValue, section: "steps")
    }

    var relatedTopics: [MainWindowHelpTopic] {
        (HelpDocumentation.topic(rawValue)?.relatedTopics ?? []).compactMap(Self.init(rawValue:))
    }

    var searchKeywords: [String] {
        HelpDocumentation.topic(rawValue)?.keywords ?? []
    }

    var searchableText: [String] {
        [title, summary, whatThisIs]
            + whyYouAreSeeingIt
            + nextSteps
            + searchKeywords
    }

    func matchesSearch(_ query: String) -> Bool {
        let normalizedQuery = HelpSearchIndex.normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        return searchableText.contains { HelpSearchIndex.normalize($0).contains(normalizedQuery) }
    }
}

enum HelpHubSectionID: String, CaseIterable, Identifiable {
    case gettingStarted
    case trafficStates
    case sessionTools
    case importExport
    case troubleshooting
    case glossary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted:
            return "Getting Started"
        case .trafficStates:
            return "Traffic States"
        case .sessionTools:
            return "Session Tools"
        case .importExport:
            return "Import / Export"
        case .troubleshooting:
            return "Troubleshooting"
        case .glossary:
            return "Glossary"
        }
    }

    var summary: String {
        switch self {
        case .gettingStarted:
            return "Certificate setup, system proxy routing, and MCP/CLI onboarding."
        case .trafficStates:
            return "What inspected and tunneled traffic mean, and why they differ."
        case .sessionTools:
            return "Sessions, Timeline, overrides, throttling, Media Info, bookmarks, and the inspector."
        case .importExport:
            return "Recording persistence, HAR export, PNG visualization export, and privacy guidance."
        case .troubleshooting:
            return "Common reasons traffic, trust, or bodies are unavailable."
        case .glossary:
            return "Definitions for proxy, overrides, media, MCP/CLI, and certificate terminology."
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .gettingStarted:
            return ["setup", "onboarding", "certificate setup", "device setup", "system proxy", "mcp", "cli"]
        case .trafficStates:
            return ["https", "inspected", "tunneled", "traffic states", "inspection reason"]
        case .sessionTools:
            return [
                "sessions", "inspector", "bookmarks", "replay", "response rewrite", "local overrides",
                "map local", "map remote", "block", "throttle", "media info", "timeline"
            ]
        case .importExport:
            return ["export", "import", "har", "recording", "privacy", "visualization", "png chart"]
        case .troubleshooting:
            return ["problems", "troubleshooting", "why not working", "trust required"]
        case .glossary:
            return ["glossary", "terms", "terminology", "proxy terminology", "definitions"]
        }
    }

    var searchableText: [String] {
        [title, summary] + searchKeywords
    }
}

struct HelpGlossaryEntry: Identifiable, Equatable {
    let term: String
    let aliases: [String]
    let description: String
    let relatedTopic: MainWindowHelpTopic?
    let sectionID: HelpHubSectionID

    var id: String { term }

    var searchableText: [String] {
        [term, description] + aliases
    }

    func matchesSearch(_ query: String) -> Bool {
        let normalizedQuery = HelpSearchIndex.normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        return searchableText.contains { HelpSearchIndex.normalize($0).contains(normalizedQuery) }
    }
}

enum HelpSearchIndex {
    static var glossaryEntries: [HelpGlossaryEntry] {
        (HelpDocumentation.catalog?.index.topics ?? []).filter { $0.category == "glossary" }.map {
            HelpGlossaryEntry(term: $0.title, aliases: $0.keywords,
                description: HelpDocumentation.text($0.id, section: "definition"),
                relatedTopic: $0.relatedTopics.first.flatMap(MainWindowHelpTopic.init(rawValue:)),
                sectionID: $0.hubSectionID.flatMap(HelpHubSectionID.init(rawValue:)) ?? .glossary)
        }
    }

    static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func topicResults(for query: String) -> [MainWindowHelpTopic] {
        MainWindowHelpTopic.allCases.filter { $0.matchesSearch(query) }
    }

    static func glossaryResults(for query: String) -> [HelpGlossaryEntry] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return glossaryEntries
            .compactMap { entry -> (HelpGlossaryEntry, Int)? in
                let score = glossarySearchScore(for: entry, normalizedQuery: normalizedQuery)
                guard score > 0 else { return nil }
                return (entry, score)
            }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.term.localizedCaseInsensitiveCompare($1.0.term) == .orderedAscending
                }
                return $0.1 > $1.1
            }
            .map(\.0)
    }

    static func sectionResults(for query: String) -> [HelpHubSectionID] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        return HelpHubSectionID.allCases.filter { section in
            section.searchableText.contains { normalize($0).contains(normalizedQuery) }
        }
    }

    private static func glossarySearchScore(for entry: HelpGlossaryEntry, normalizedQuery: String) -> Int {
        let normalizedTerm = normalize(entry.term)
        if normalizedTerm == normalizedQuery {
            return 400
        }

        if entry.aliases.contains(where: { normalize($0) == normalizedQuery }) {
            return 300
        }

        if normalizedTerm.hasPrefix(normalizedQuery) {
            return 200
        }

        if entry.aliases.contains(where: { normalize($0).contains(normalizedQuery) }) {
            return 120
        }

        if normalize(entry.description).contains(normalizedQuery) {
            return 80
        }

        if entry.matchesSearch(normalizedQuery) {
            return 40
        }

        return 0
    }
}

enum MainWindowPrimaryHelpContext: Equatable {
    case sessions
    case bookmarks
}

struct MainWindowHelpContext: Equatable {
    let primaryContext: MainWindowPrimaryHelpContext
    let certificateNeedsAttention: Bool
    let selectedSessionInspectionKind: SessionInspectionKind?
    let hasActiveOverrides: Bool
    let exportStateIsActive: Bool
    let visualizationExportStateIsActive: Bool
}

enum MainWindowHelpResolver {
    static func suggestedTopic(for context: MainWindowHelpContext) -> MainWindowHelpTopic {
        if context.certificateNeedsAttention {
            return .certificateSetup
        }

        if context.visualizationExportStateIsActive {
            return .visualizationExport
        }

        if context.exportStateIsActive {
            return .exportPrivacy
        }

        if context.primaryContext == .bookmarks {
            return .bookmarksReplay
        }

        if context.selectedSessionInspectionKind == .tunneledTLS {
            return .requestInspector
        }

        if context.hasActiveOverrides {
            return .localOverrides
        }

        return .capturedSessions
    }
}

struct MainWindowHelpDrawer: View {
    @Environment(\.appTextScale) private var appTextScale
    @Binding var selectedTopic: MainWindowHelpTopic
    let onOpenHelpHub: () -> Void
    let onOpenCertificateSetup: () -> Void
    let onOpenHTTPSRules: () -> Void
    @State private var searchQuery = ""
    @State private var documentationLoaded = false

    private var matchingTopics: [MainWindowHelpTopic] {
        guard !searchQuery.isEmpty else { return [] }
        return HelpSearchIndex.topicResults(for: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField
            if !searchQuery.isEmpty {
                searchResultsSection
            }
            topicPicker
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(title: "What This Is", body: selectedTopic.whatThisIs)
                    listSection(title: "Why You Are Seeing It", items: selectedTopic.whyYouAreSeeingIt)
                    listSection(title: "What You Can Do Next", items: selectedTopic.nextSteps)
                    actionsSection
                    relatedTopicsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityIdentifier("mainWindowHelpDrawer")
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
    }

    private var searchField: some View {
        TextField("Search help topics and glossary terms", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .appFont(.body, scale: appTextScale)
            .accessibilityLabel("Search help")
            .accessibilityHint("Searches contextual help topics and proxy terminology.")
            .accessibilityIdentifier("mainWindowHelpSearchField")
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matches")
                .appFont(.subheadline, scale: appTextScale, weight: .semibold)

            if matchingTopics.isEmpty {
                Text("No matching help topics.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchingTopics) { topic in
                    Button(topic.title) {
                        selectedTopic = topic
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedTopic.title)
                .appFont(.title3, scale: appTextScale, weight: .semibold)
                .accessibilityIdentifier("mainWindowHelpDrawerTitle")
            Text(selectedTopic.summary)
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mainWindowHelpDrawerSummary")
        }
    }

    private var topicPicker: some View {
        Picker("Help Topic", selection: $selectedTopic) {
            ForEach(MainWindowHelpTopic.allCases) { topic in
                Text(topic.title).tag(topic)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Browse help topics")
        .accessibilityIdentifier("mainWindowHelpTopicPicker")
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .appFont(.subheadline, scale: appTextScale, weight: .semibold)
            Text(body)
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(.subheadline, scale: appTextScale, weight: .semibold)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6 * appTextScale))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    Text(item)
                        .appFont(.subheadline, scale: appTextScale)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .appFont(.subheadline, scale: appTextScale, weight: .semibold)

            HStack(spacing: 10) {
                switch selectedTopic {
                case .certificateSetup:
                    Button("Open HTTPS Setup", action: onOpenCertificateSetup)
                        .buttonStyle(.borderedProminent)
                    Button("Browse Help Topics & Glossary", action: onOpenHelpHub)
                        .buttonStyle(.borderless)
                case .trafficStates:
                    Button("Open HTTPS Rules", action: onOpenHTTPSRules)
                        .buttonStyle(.borderedProminent)
                    Button("Browse Help Topics & Glossary", action: onOpenHelpHub)
                        .buttonStyle(.borderless)
                default:
                    Button("Browse Help Topics & Glossary", action: onOpenHelpHub)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var relatedTopicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related Topics")
                .appFont(.subheadline, scale: appTextScale, weight: .semibold)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(selectedTopic.relatedTopics) { topic in
                    Button(topic.title) {
                        selectedTopic = topic
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

#if !AGW4_AGENT_TARGET
struct ContextualHelpWindowView: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    @EnvironmentObject private var viewModel: ProxyViewModel

    private var textScale: CGFloat {
        viewModel.appTextSize.fontScale
    }

    var body: some View {
        MainWindowHelpDrawer(
            selectedTopic: Binding(
                get: { presentationState.contextualHelpTopic },
                set: { presentationState.contextualHelpTopic = $0 }
            ),
            onOpenHelpHub: {
                presentationState.presentHelpHub()
            },
            onOpenCertificateSetup: {
                presentationState.presentCertificateSetup()
            },
            onOpenHTTPSRules: {
                presentationState.presentHTTPSRules()
            }
        )
        .padding(16)
        .environment(\.appTextScale, textScale)
        .frame(
            minWidth: 420,
            idealWidth: min(max(520 * textScale, CGFloat(480)), CGFloat(760)),
            minHeight: min(max(560 * textScale, CGFloat(560)), CGFloat(820))
        )
        .accessibilityIdentifier("contextualHelpWindow")
    }
}

/// Compact quick help for the visualization export sheet.
struct VisualizationExportQuickHelp: View {
    @Environment(\.appTextScale) private var appTextScale
    var onOpenHelpTopic: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Visualization")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            Text("Turn captured traffic into a shareable PNG chart with privacy-safe defaults.")
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                quickHelpBullet("V1 chart types: Session Timeline, Request Waterfall, and Host Health Summary.")
                quickHelpBullet("PNG is the only export format in V1. PDF, SVG, and interactive dashboards are deferred.")
                quickHelpBullet("Scope differs by chart: timelines use selected or filtered sessions; waterfalls add host scopes; host health uses filtered results or host selections.")
                quickHelpBullet("Redaction is on by default for auth headers, cookies, tokens, query parameters, user identifiers, bodies, and artwork.")
                quickHelpBullet("Allow raw values only for internal artifacts you will not share outside a trusted team.")
                quickHelpBullet("Footer provenance can note partial capture or stripped bodies when source data was incomplete.")
            }

            if let onOpenHelpTopic {
                Divider()

                Button("Open Full Help Topic") {
                    onOpenHelpTopic()
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens the Export Visualization help topic.")
                .accessibilityIdentifier("visualizationExportOpenFullHelpButton")
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(14)
        .accessibilityIdentifier("visualizationExportQuickHelp")
    }

    private func quickHelpBullet(_ text: String) -> some View {
        Label {
            Text(text)
                .appFont(.caption, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "circle.fill")
                .appFont(.caption2, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Compact quick help for the bookmark response rewrite inspector.
struct BookmarkResponseRewritesQuickHelp: View {
    @Environment(\.appTextScale) private var appTextScale
    var onOpenHelpTopic: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmark Response Rewrites")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            Text("Intercept matching traffic and return this bookmark's saved JSON with selected fields replaced.")
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                quickHelpBullet("Right-click a field in Folder or Prettified view to prefill the JSON path.")
                quickHelpBullet("Use nested paths such as movie.shortDescription when fields are not at the root.")
                quickHelpBullet("Use JSON value type for arrays and objects (e.g. castNames).")
                quickHelpBullet("The active banner shows waiting state, last intercept, and recent mismatched paths.")
                quickHelpBullet("Refresh Saved Response when paths fail validation or the API shape changed.")
                quickHelpBullet("Preview Patches overlays rewrites in Folder/Prettified views without reloading large JSON bodies.")
                quickHelpBullet("Start the proxy, tap Enable for Session, then re-trigger the request in your client.")
            }

            if let onOpenHelpTopic {
                Divider()

                Button("Open Full Help Topic") {
                    onOpenHelpTopic()
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens the Bookmark Response Rewrites help topic.")
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(14)
    }

    private func quickHelpBullet(_ text: String) -> some View {
        Label {
            Text(text)
                .appFont(.caption, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "circle.fill")
                .appFont(.caption2, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
    }
}
#endif
