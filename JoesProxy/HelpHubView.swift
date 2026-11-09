//
//  HelpHubView.swift
//  JoesProxy
//
//  Central in-app help hub surfaced from Help > Help Topics & Glossary.
//

import SwiftUI

struct HelpHubView: View {
    @Environment(\.appTextScale) private var appTextScale
    @Binding var isPresented: Bool
    let focusedTopic: MainWindowHelpTopic?
    let certificateSetupTitle: String
    let openCertificateSetup: () -> Void
    let openMacOSGuide: () -> Void
    let openIOSGuide: () -> Void
    let openTVOSGuide: () -> Void
    @State private var searchQuery = ""
    @State private var documentationLoaded = false
    @State private var catalogTopicID = "agent-documentation"
    @State private var catalogMatches: [DocumentationCatalog.Entry] = []
    private let setupGuideColumns = [GridItem(.adaptive(minimum: 180), alignment: .leading)]

    private var matchingTopics: [MainWindowHelpTopic] {
        guard !searchQuery.isEmpty else { return [] }
        return HelpSearchIndex.topicResults(for: searchQuery)
    }

    private var matchingGlossaryEntries: [HelpGlossaryEntry] {
        guard !searchQuery.isEmpty else { return [] }
        return HelpSearchIndex.glossaryResults(for: searchQuery)
    }

    private var matchingSections: [HelpHubSectionID] {
        guard !searchQuery.isEmpty else { return [] }
        return HelpSearchIndex.sectionResults(for: searchQuery)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    if let focusedTopic {
                        focusedTopicSection(focusedTopic)
                    }
                    searchSection(proxy: proxy)
                    catalogSection
                        .id("documentationCatalog")
                    if !searchQuery.isEmpty {
                        searchResultsSection(proxy: proxy)
                    }
                    gettingStartedSection
                        .id(HelpHubSectionID.gettingStarted.rawValue)
                    systemProxySection
                        .id("systemProxyRouting")
                    trafficStatesSection
                        .id(HelpHubSectionID.trafficStates.rawValue)
                    sessionToolsSection
                        .id(HelpHubSectionID.sessionTools.rawValue)
                    explorerBrowserSection
                        .id("explorerBrowser")
                    networkConditioningSection
                        .id("networkConditioning")
                    mediaInfoSection
                        .id("mediaInfo")
                    mcpAndCLISection
                        .id("mcpAndCLI")
                    bookmarksWorkflowSection
                        .id("bookmarksWorkflow")
                    bookmarkResponseRewritesSection
                        .id("bookmarkResponseRewrites")
                    recordingSaveModesSection
                        .id("recordingSaveModes")
                    importExportSection
                        .id(HelpHubSectionID.importExport.rawValue)
                    troubleshootingSection
                        .id(HelpHubSectionID.troubleshooting.rawValue)
                    glossarySection
                        .id(HelpHubSectionID.glossary.rawValue)
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .accessibilityIdentifier("helpHubView")
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
        .task(id: searchQuery) {
            guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                catalogMatches = []
                return
            }
            let page = try? await DocumentationService.shared.query(.init(operation: "search", query: searchQuery, limit: 10), source: "installed", appVersion: Bundle.main.marketingVersionOrDev)
            guard !Task.isCancelled else { return }
            catalogMatches = page?.entries ?? []
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 680, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("helpHubDoneButton")
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Help Topics & Glossary")
                .appFont(.title2, scale: appTextScale, weight: .semibold)

            Text("Start here for HTTPS setup, system proxy routing, traffic states, session tools, Media Info, MCP/CLI, and recording guidance.")
                .appFont(.body, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func searchSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search help topics, setup steps, or glossary terms", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .appFont(.body, scale: appTextScale)
                .accessibilityLabel("Search help")
                .accessibilityHint("Searches Help topics, setup guides, and proxy terminology.")
                .accessibilityIdentifier("helpHubSearchField")

            if !searchQuery.isEmpty {
                Button("Clear Search") {
                    searchQuery = ""
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(HelpHubSectionID.gettingStarted.rawValue, anchor: .top)
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
    }

    private func focusedTopicSection(_ topic: MainWindowHelpTopic) -> some View {
        GroupBox("Recommended For This Step") {
            VStack(alignment: .leading, spacing: 10) {
                Text(topic.title)
                    .appFont(.headline, scale: appTextScale, weight: .semibold)

                Text(topic.summary)
                    .appFont(.body, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What You Can Do Next")
                        .appFont(.subheadline, scale: appTextScale, weight: .semibold)

                    ForEach(Array(topic.nextSteps.enumerated()), id: \.offset) { _, step in
                        helpBullet(step)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultsSection(proxy: ScrollViewProxy) -> some View {
        GroupBox("Search Results") {
            VStack(alignment: .leading, spacing: 14) {
                if matchingTopics.isEmpty && matchingGlossaryEntries.isEmpty && matchingSections.isEmpty && catalogMatches.isEmpty {
                    Text("No matches for “\(searchQuery)”. Try terms like CONNECT, Map Local, Block, MCP, Media Info, or HAR.")
                        .appFont(.subheadline, scale: appTextScale)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(catalogMatches, id: \.topic.id) { entry in
                        Button(entry.topic.title) {
                            catalogTopicID = entry.topic.id
                            proxy.scrollTo("documentationCatalog", anchor: .top)
                        }
                        .accessibilityIdentifier("helpCatalogResult-\(entry.topic.id)")
                    }
                    if !matchingTopics.isEmpty {
                        searchTopicResults(proxy: proxy)
                    }

                    if !matchingGlossaryEntries.isEmpty {
                        searchGlossaryResults(proxy: proxy)
                    }

                    if !matchingSections.isEmpty {
                        searchSectionResults(proxy: proxy)
                    }
                }
            }
        }
    }

    private func searchTopicResults(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Topics")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(matchingTopics) { topic in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(topic.hubSectionID, anchor: .top)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title)
                            .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        Text(topic.summary)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func searchGlossaryResults(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terms")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(matchingGlossaryEntries) { entry in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(entry.sectionID.rawValue, anchor: .top)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.term)
                            .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        Text(entry.description)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func searchSectionResults(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sections")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(matchingSections) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(section.rawValue, anchor: .top)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        Text(section.summary)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var gettingStartedSection: some View {
        GroupBox("Getting Started") {
            VStack(alignment: .leading, spacing: 14) {
                helpParagraph(HelpDocumentation.text("hub-gettingStarted", section: "p1"))

                VStack(alignment: .leading, spacing: 8) {
                    helpBullet(HelpDocumentation.text("hub-gettingStarted", section: "p2"))
                    helpBullet(HelpDocumentation.text("hub-gettingStarted", section: "p3"))
                    helpBullet(HelpDocumentation.text("hub-gettingStarted", section: "p4"))
                    helpBullet(HelpDocumentation.text("hub-gettingStarted", section: "p5"))
                    helpBullet(HelpDocumentation.text("hub-gettingStarted", section: "p6"))
                }

                LazyVGrid(columns: setupGuideColumns, alignment: .leading, spacing: 8) {
                    setupGuideButton(certificateSetupTitle, action: openCertificateSetup)
                    setupGuideButton("macOS Setup Guide", action: openMacOSGuide)
                    setupGuideButton("iOS Setup Guide", action: openIOSGuide)
                    setupGuideButton("Apple TV Setup Guide", action: openTVOSGuide)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var systemProxySection: some View {
        GroupBox("System Proxy Routing") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-systemProxy", section: "p1"))

                helpDefinition(
                    term: "Ambient traffic",
                    description: HelpDocumentation.text("hub-systemProxy", section: "p2")
                )
                helpDefinition(
                    term: "Strict Capture",
                    description: HelpDocumentation.text("hub-systemProxy", section: "p3")
                )
                helpDefinition(
                    term: "Routing status",
                    description: HelpDocumentation.text("hub-systemProxy", section: "p4")
                )
            }
        }
    }

    private var trafficStatesSection: some View {
        GroupBox("Traffic States") {
            VStack(alignment: .leading, spacing: 10) {
                helpDefinition(term: "HTTPS Inspected", description: HelpDocumentation.text("hub-trafficStates", section: "p1"))
                helpDefinition(term: "HTTPS Tunneled", description: HelpDocumentation.text("hub-trafficStates", section: "p2"))
                helpDefinition(term: "Inspection Reason", description: HelpDocumentation.text("hub-trafficStates", section: "p3"))
                helpDefinition(term: "Certificate Pinning", description: HelpDocumentation.text("hub-trafficStates", section: "p4"))
            }
        }
    }

    private var sessionToolsSection: some View {
        GroupBox("Session Tools") {
            VStack(alignment: .leading, spacing: 10) {
                helpDefinition(term: "Captured Sessions", description: HelpDocumentation.text("hub-sessionTools", section: "p1"))
                helpDefinition(term: "Bookmarks", description: HelpDocumentation.text("hub-sessionTools", section: "p2"))
                helpDefinition(
                    term: "Bookmark Response Rewrites",
                    description: HelpDocumentation.text("hub-sessionTools", section: "p3")
                )
                helpDefinition(
                    term: "Local Overrides",
                    description: HelpDocumentation.text("hub-sessionTools", section: "p4")
                )
                helpDefinition(
                    term: "Effect Bundles",
                    description: HelpDocumentation.text("hub-sessionTools", section: "p5")
                )
                helpDefinition(term: "Map Local", description: HelpDocumentation.text("hub-sessionTools", section: "p6"))
                helpDefinition(term: "Block", description: HelpDocumentation.text("hub-sessionTools", section: "p7"))
                helpDefinition(term: "Map Remote", description: HelpDocumentation.text("hub-sessionTools", section: "p8"))
                helpDefinition(term: "Request Inspector", description: HelpDocumentation.text("hub-sessionTools", section: "p9"))
            }
        }
    }

    private var networkConditioningSection: some View {
        GroupBox("Network Throttling & No Caching") {
            VStack(alignment: .leading, spacing: 10) {
                helpDefinition(
                    term: "Network Throttling",
                    description: HelpDocumentation.text("hub-networkConditioning", section: "p1")
                )
                helpDefinition(
                    term: "No Caching",
                    description: HelpDocumentation.text("hub-networkConditioning", section: "p2")
                )
                helpParagraph(HelpDocumentation.text("hub-networkConditioning", section: "p3"))
            }
        }
    }

    private var mediaInfoSection: some View {
        GroupBox("Media Info") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-mediaInfo", section: "p1"))

                helpDefinition(
                    term: "HLS / DASH",
                    description: HelpDocumentation.text("hub-mediaInfo", section: "p2")
                )
                helpDefinition(
                    term: "HLS fixtures",
                    description: HelpDocumentation.text("hub-mediaInfo", section: "p3")
                )
                helpDefinition(
                    term: "Synthetic Asset Origin",
                    description: HelpDocumentation.text("hub-mediaInfo", section: "p4")
                )
                helpParagraph(HelpDocumentation.text("hub-mediaInfo", section: "p5"))
            }
        }
    }

    private var mcpAndCLISection: some View {
        GroupBox("MCP And CLI") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-mcpAndCLI", section: "p1"))

                helpDefinition(
                    term: "MCP Management",
                    description: HelpDocumentation.text("hub-mcpAndCLI", section: "p2")
                )
                helpDefinition(
                    term: "Approvals",
                    description: HelpDocumentation.text("hub-mcpAndCLI", section: "p3")
                )
                helpDefinition(
                    term: "Xcode Instruments",
                    description: HelpDocumentation.text("hub-mcpAndCLI", section: "p4")
                )
                helpDefinition(
                    term: "Deterministic Filtering",
                    description: HelpDocumentation.text("hub-mcpAndCLI", section: "p5")
                )
                helpDefinition(
                    term: "Cleanup",
                    description: HelpDocumentation.text("hub-mcpAndCLI", section: "p6")
                )
                helpParagraph(HelpDocumentation.text("hub-mcpAndCLI", section: "p7"))
            }
        }
    }

    private var explorerBrowserSection: some View {
        GroupBox("Table, Explorer, and Timeline") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-explorerBrowser", section: "p1"))

                helpDefinition(
                    term: "Explorer grouping",
                    description: HelpDocumentation.text("hub-explorerBrowser", section: "p2")
                )
                helpDefinition(
                    term: "Persistence",
                    description: HelpDocumentation.text("hub-explorerBrowser", section: "p3")
                )
                helpDefinition(
                    term: "Timeline",
                    description: HelpDocumentation.text("hub-explorerBrowser", section: "p4")
                )

                helpParagraph(HelpDocumentation.text("hub-explorerBrowser", section: "p5"))
            }
        }
    }

    private var bookmarksWorkflowSection: some View {
        GroupBox("Bookmarks Workflow") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-bookmarksWorkflow", section: "p1"))

                helpDefinition(
                    term: "1. Save a request",
                    description: HelpDocumentation.text("hub-bookmarksWorkflow", section: "p2")
                )
                helpDefinition(
                    term: "2. Refresh auth",
                    description: HelpDocumentation.text("hub-bookmarksWorkflow", section: "p3")
                )
                helpDefinition(
                    term: "3. Run the bookmark",
                    description: HelpDocumentation.text("hub-bookmarksWorkflow", section: "p4")
                )
                helpDefinition(
                    term: "4. Mock JSON responses",
                    description: HelpDocumentation.text("hub-bookmarksWorkflow", section: "p5")
                )

                helpParagraph(HelpDocumentation.text("hub-bookmarksWorkflow", section: "p6"))
            }
        }
    }

    private var bookmarkResponseRewritesSection: some View {
        GroupBox("Bookmark Response Rewrites") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p1"))

                helpDefinition(
                    term: "1. Save the response",
                    description: HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p2")
                )
                helpDefinition(
                    term: "2. Choose JSON paths",
                    description: HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p3")
                )
                helpDefinition(
                    term: "3. Preview and enable",
                    description: HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p4")
                )
                helpDefinition(
                    term: "4. Verify intercept",
                    description: HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p5")
                )

                helpParagraph(HelpDocumentation.text("hub-bookmarkResponseRewrites", section: "p6"))
            }
        }
    }

    private var recordingSaveModesSection: some View {
        GroupBox("Recording Save Modes") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph(HelpDocumentation.text("hub-recordingSaveModes", section: "p1"))

                helpParagraph(HelpDocumentation.text("hub-recordingSaveModes", section: "p2"))

                helpDefinition(
                    term: "Full Recording",
                    description: HelpDocumentation.text("hub-recordingSaveModes", section: "p3")
                )
                helpDefinition(
                    term: "Metadata Only",
                    description: HelpDocumentation.text("hub-recordingSaveModes", section: "p4")
                )
                helpDefinition(
                    term: "Text Bodies Only",
                    description: HelpDocumentation.text("hub-recordingSaveModes", section: "p5")
                )
                helpDefinition(
                    term: "Media Focused",
                    description: HelpDocumentation.text("hub-recordingSaveModes", section: "p6")
                )

                helpParagraph(HelpDocumentation.text("hub-recordingSaveModes", section: "p7"))
            }
        }
    }

    private var importExportSection: some View {
        GroupBox("Import / Export") {
            VStack(alignment: .leading, spacing: 10) {
                helpDefinition(term: "Save Recording", description: HelpDocumentation.text("hub-importExport", section: "p1"))
                helpDefinition(term: "Long Capture Storage", description: HelpDocumentation.text("hub-importExport", section: "p2"))
                helpDefinition(term: "Recording Save Modes", description: HelpDocumentation.text("hub-importExport", section: "p3"))
                helpDefinition(term: "Open Recording", description: HelpDocumentation.text("hub-importExport", section: "p4"))
                helpDefinition(term: "Export to HAR", description: HelpDocumentation.text("hub-importExport", section: "p5"))
                helpDefinition(term: "Crash Recovery Off-Path Save", description: HelpDocumentation.text("hub-importExport", section: "p6"))
                helpParagraph(HelpDocumentation.text("hub-importExport", section: "p7"))
                helpParagraph(HelpDocumentation.text("hub-importExport", section: "p8"))
            }
        }
    }

    private var troubleshootingSection: some View {
        GroupBox("Troubleshooting") {
            VStack(alignment: .leading, spacing: 10) {
                helpDefinition(term: "Trust required", description: HelpDocumentation.text("hub-troubleshooting", section: "p1"))
                helpDefinition(term: "Traffic not appearing", description: HelpDocumentation.text("hub-troubleshooting", section: "p2"))
                helpDefinition(term: "Bodies unavailable", description: HelpDocumentation.text("hub-troubleshooting", section: "p3"))
                helpDefinition(term: "Unexpected ambient traffic", description: HelpDocumentation.text("hub-troubleshooting", section: "p4"))
                helpDefinition(term: "Port conflict", description: HelpDocumentation.text("hub-troubleshooting", section: "p5"))
            }
        }
    }

    private var glossarySection: some View {
        GroupBox("Glossary") {
            VStack(alignment: .leading, spacing: 10) {
                helpParagraph("Shared definitions used by Help search and contextual topics. Search above to jump to a term quickly.")

                ForEach(HelpSearchIndex.glossaryEntries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }) { entry in
                    helpDefinition(term: entry.term, description: entry.description)
                }
            }
        }
    }

    private var catalogSection: some View {
        GroupBox("Documentation Catalog & Agent Recipes") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Documentation topic", selection: $catalogTopicID) {
                    ForEach(HelpDocumentation.catalog?.index.topics ?? []) { topic in
                        Text(topic.title).tag(topic.id)
                    }
                }
                .accessibilityIdentifier("helpCatalogTopicPicker")
                DisclosureGroup("Read Selected Topic") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(HelpDocumentation.catalog?.topicSections(catalogTopicID) ?? [], id: \.id) { section in
                            Text(section.title).appFont(.headline, scale: appTextScale, weight: .semibold)
                            Text(verbatim: section.markdown)
                                .appFont(.body, scale: appTextScale)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityIdentifier("helpCatalogReadTopic")
            }
        }
    }

    private func helpParagraph(_ text: String) -> some View {
        Text(text)
            .appFont(.body, scale: appTextScale)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func helpBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6 * appTextScale))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupGuideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpDefinition(term: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(term)
                .appFont(.headline, scale: appTextScale, weight: .semibold)
            Text(description)
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HelpHubView(
        isPresented: .constant(true),
        focusedTopic: .certificateSetup,
        certificateSetupTitle: "HTTPS Setup",
        openCertificateSetup: {},
        openMacOSGuide: {},
        openIOSGuide: {},
        openTVOSGuide: {}
    )
}
