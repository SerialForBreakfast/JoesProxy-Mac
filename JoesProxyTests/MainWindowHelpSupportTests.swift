import XCTest
@testable import JoesProxy

final class MainWindowHelpSupportTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await HelpDocumentation.load()
    }
    func testSuggestedTopicPrefersCertificateSetupWhenTrustNeedsAttention() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: true,
            selectedSessionInspectionKind: nil,
            hasActiveOverrides: true,
            exportStateIsActive: true,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .certificateSetup)
    }

    func testSuggestedTopicPrefersExportWhenExportStateIsActive() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: nil,
            hasActiveOverrides: false,
            exportStateIsActive: true,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .exportPrivacy)
    }

    func testSuggestedTopicPrefersVisualizationExportWhenVisualizationSheetIsActive() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: nil,
            hasActiveOverrides: false,
            exportStateIsActive: true,
            visualizationExportStateIsActive: true
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .visualizationExport)
    }

    func testSuggestedTopicUsesBookmarksWhenBookmarksPaneIsActive() {
        let context = MainWindowHelpContext(
            primaryContext: .bookmarks,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: .tunneledTLS,
            hasActiveOverrides: true,
            exportStateIsActive: false,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .bookmarksReplay)
    }

    func testSuggestedTopicUsesRequestInspectorForTunneledSelection() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: .tunneledTLS,
            hasActiveOverrides: false,
            exportStateIsActive: false,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .requestInspector)
    }

    func testSuggestedTopicUsesLocalOverridesWhenOverridesAreActive() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: .plain,
            hasActiveOverrides: true,
            exportStateIsActive: false,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .localOverrides)
    }

    func testSuggestedTopicFallsBackToCapturedSessions() {
        let context = MainWindowHelpContext(
            primaryContext: .sessions,
            certificateNeedsAttention: false,
            selectedSessionInspectionKind: .plain,
            hasActiveOverrides: false,
            exportStateIsActive: false,
            visualizationExportStateIsActive: false
        )

        XCTAssertEqual(MainWindowHelpResolver.suggestedTopic(for: context), .capturedSessions)
    }

    func testTopicSearchMatchesLegacySSLTerm() {
        XCTAssertTrue(MainWindowHelpTopic.certificateSetup.matchesSearch("ssl"))
    }

    func testTopicSearchMatchesMapLocalAlias() {
        XCTAssertTrue(MainWindowHelpTopic.localOverrides.matchesSearch("map local"))
        XCTAssertTrue(MainWindowHelpTopic.localOverrides.matchesSearch("map remote"))
        XCTAssertTrue(MainWindowHelpTopic.localOverrides.matchesSearch("block request"))
    }

    func testTopicSearchMatchesSystemProxyAndMediaAndMCP() {
        XCTAssertTrue(MainWindowHelpTopic.systemProxyRouting.matchesSearch("strict capture"))
        XCTAssertTrue(MainWindowHelpTopic.mediaInfo.matchesSearch("m3u8"))
        XCTAssertTrue(MainWindowHelpTopic.mcpAndCLI.matchesSearch("joesproxyctl"))
        XCTAssertTrue(MainWindowHelpTopic.capturedSessions.matchesSearch("timeline"))
    }

    func testTopicSearchMatchesBookmarkResponseRewriteKeywords() {
        XCTAssertTrue(MainWindowHelpTopic.bookmarkResponseRewrites.matchesSearch("json path"))
        XCTAssertTrue(MainWindowHelpTopic.bookmarkResponseRewrites.matchesSearch("preview patches"))
    }

    func testGlossarySearchFindsBookmarkResponseRewriteTerm() {
        let matches = HelpSearchIndex.glossaryResults(for: "response rewrite")
        XCTAssertTrue(matches.contains { $0.term == "Bookmark Response Rewrites" })
    }

    func testGlossarySearchFindsConnectTerm() {
        let matches = HelpSearchIndex.glossaryResults(for: "connect")

        XCTAssertEqual(matches.first?.term, "CONNECT")
    }

    func testGlossarySearchFindsShippedOverrideAndAgentTerms() {
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "map remote").contains { $0.term == "Map Remote" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "block").contains { $0.term == "Block" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "no caching").contains { $0.term == "No Caching" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "system proxy").contains { $0.term == "System Proxy Routing" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "media info").contains { $0.term == "Media Info" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "mcp").contains { $0.term == "MCP" })
    }

    func testTopicSearchMatchesVisualizationExportKeywords() {
        XCTAssertTrue(MainWindowHelpTopic.visualizationExport.matchesSearch("waterfall"))
        XCTAssertTrue(MainWindowHelpTopic.visualizationExport.matchesSearch("provenance"))
    }

    func testGlossarySearchFindsExportVisualizationTerm() {
        let matches = HelpSearchIndex.glossaryResults(for: "png chart")
        XCTAssertTrue(matches.contains { $0.term == "Export Visualization" })
    }

    func testSectionSearchFindsGlossaryByKeyword() {
        let matches = HelpSearchIndex.sectionResults(for: "proxy terminology")

        XCTAssertEqual(matches, [.glossary])
    }

    func testGlossarySearchFindsRecentFeatureTerms() {
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "effect bundle").contains { $0.term == "Effect Bundle" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "synthetic origin").contains { $0.term == "Synthetic Asset Origin" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "crash recovery").contains { $0.term == "Crash Recovery Off-Path Save" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "instruments").contains { $0.term == "Xcode Instruments Diagnostics" })
        XCTAssertTrue(HelpSearchIndex.glossaryResults(for: "cli json").contains { $0.term == "Deterministic CLI Filtering" })
    }

    func testTopicSearchMatchesRecentFeatureKeywords() {
        XCTAssertTrue(MainWindowHelpTopic.localOverrides.matchesSearch("effect bundle"))
        XCTAssertTrue(MainWindowHelpTopic.mediaInfo.matchesSearch("assets.joesproxy.invalid"))
        XCTAssertTrue(MainWindowHelpTopic.mcpAndCLI.matchesSearch("instruments"))
        XCTAssertTrue(MainWindowHelpTopic.mcpAndCLI.matchesSearch("sessions search"))
        XCTAssertTrue(MainWindowHelpTopic.exportPrivacy.matchesSearch("crash recovery"))
    }

    func testHelpTopicsIncludeShippedSurfaces() {
        let topics = Set(MainWindowHelpTopic.allCases)
        XCTAssertTrue(topics.contains(.systemProxyRouting))
        XCTAssertTrue(topics.contains(.mediaInfo))
        XCTAssertTrue(topics.contains(.mcpAndCLI))
        XCTAssertEqual(MainWindowHelpTopic.allCases.count, 13)
    }
}
