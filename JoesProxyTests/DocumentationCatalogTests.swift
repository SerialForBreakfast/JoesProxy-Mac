import Foundation
import XCTest
@testable import JoesProxy

final class DocumentationCatalogTests: XCTestCase {
    func testAutomaticDeviceSetupIsDiscoverableWithoutClaimingRoutingEvidence() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let search = try catalog.execute(.init(operation: "search", query: "PAC"),
                                         source: "installed", appVersion: "test")
        XCTAssertTrue(search.entries.contains { $0.topic.id == "setup-ios" })
        let guidance = try catalog.execute(.init(operation: "read", topic: "setup-ios", section: "p10"),
                                           source: "installed", appVersion: "test")
        let text = guidance.entries.flatMap(\.sections).map(\.markdown).joined(separator: "\n")
        XCTAssertTrue(text.contains("optional direct fallback"))
        XCTAssertTrue(text.contains("do not establish device routing"))
        XCTAssertTrue(text.contains("Configure Proxy to Off"))
    }

    func testWorkspaceGuidanceIsDiscoverableAndEquivalentForInstalledAndLiveReads() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let search = try catalog.execute(.init(operation: "search", query: "supervision"),
            source: "installed", appVersion: "test")
        XCTAssertTrue(search.entries.contains { $0.topic.id == "agent-documentation" })
        let query = DocumentationCatalog.Query(operation: "read", topic: "agent-documentation", section: "workspace")
        let installed = try catalog.execute(query, source: "installed", appVersion: "test")
        let live = try catalog.execute(query, source: "running-server", appVersion: "test")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(installed.entries), try encoder.encode(live.entries))
        XCTAssertLessThanOrEqual(try encoder.encode(installed).count, 8192)
        XCTAssertTrue(installed.entries.flatMap(\.sections).contains { $0.markdown.contains("does not grant approval") })
    }

    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JoesProxy/Resources/Documentation")
    }

    func testAllContextualTopicsHaveReadableSectionsAndValidLinks() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        XCTAssertTrue(Set(MainWindowHelpTopic.allCases.map(\.rawValue)).isSubset(of: Set(catalog.index.topics.map(\.id))))
        for topic in catalog.index.topics {
            let page = try catalog.execute(.init(operation: "read", topic: topic.id, maxResponseBytes: 32768), source: "installed", appVersion: "test")
            XCTAssertFalse(page.entries.isEmpty)
            XCTAssertTrue(page.entries.allSatisfy { !$0.sections.isEmpty })
        }
    }

    func testPaginationIsBoundedAndRejectsQueryChanges() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        var query = DocumentationCatalog.Query(operation: "list", limit: 1)
        let first = try catalog.execute(query, source: "installed", appVersion: "test")
        query.cursor = try XCTUnwrap(first.nextCursor)
        let second = try catalog.execute(query, source: "installed", appVersion: "test")
        XCTAssertNotEqual(first.entries.first?.topic.id, second.entries.first?.topic.id)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(second).count, 8192)
        query.operation = "search"
        query.query = "media"
        XCTAssertThrowsError(try catalog.execute(query, source: "installed", appVersion: "test")) { error in
            XCTAssertEqual((error as? DocumentationCatalog.Failure)?.reason, "staleCursor")
        }
    }

    func testSearchAndLiveOfflineParityDoNotInventRuntimeEvidence() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let query = DocumentationCatalog.Query(operation: "search", query: "Media Info")
        let installed = try catalog.execute(query, source: "installed", appVersion: "test")
        let live = try catalog.execute(query, source: "running-server", appVersion: "test")
        XCTAssertEqual(installed.entries.first?.topic.id, "mediaInfo")
        XCTAssertEqual(installed.catalogDigest, live.catalogDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(installed.entries), try encoder.encode(live.entries))
        XCTAssertTrue(live.notice.contains("not runtime readiness"))
        XCTAssertTrue(try catalog.execute(.init(operation: "search", query: "unfindablesyntheticword"), source: "installed", appVersion: "test").entries.isEmpty)
    }

    func testInvalidQueriesDoNotSilentlyChangeMeaning() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        for query in [DocumentationCatalog.Query(operation: "search", query: " "),
                      .init(operation: "read", topic: "missing"),
                      .init(operation: "read", topic: "mediaInfo", section: "missing"),
                      .init(operation: "list", topic: "mediaInfo"),
                      .init(operation: "read", query: "ignored", topic: "mediaInfo"),
                      .init(operation: "list", maxResponseBytes: 1),
                      .init(operation: "list", limit: 21)] {
            XCTAssertThrowsError(try catalog.execute(query, source: "installed", appVersion: "test"))
        }
        XCTAssertThrowsError(try DocumentationCatalog.Query(operation: "list", arguments: ["limit": true]))
        XCTAssertThrowsError(try DocumentationCatalog.Query(operation: "list", arguments: ["limit": 1.5]))
        XCTAssertThrowsError(try DocumentationCatalog.Query(operation: "read", arguments: ["topic": 42]))
        XCTAssertThrowsError(try DocumentationCatalog(directory: directory.appendingPathComponent("missing")))
    }

    func testDocumentationToolsRemainCoreAndReadOnly() {
        for name in ["documentation_list", "documentation_search", "documentation_read"] {
            XCTAssertEqual(MCPCapabilityRouter.capability(forTool: name), .agentResource)
            XCTAssertTrue(MCPToolset.allCases.allSatisfy { $0.includes(toolName: name) })
        }
        XCTAssertEqual(MCPCapabilityRouter.capability(forResource: "joesproxy://docs/index"), .agentResource)
    }

    func testGeneratedReferencesMatchGovernedDefinitions() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let tools = catalog.topicSections("reference-tools")
        XCTAssertEqual(tools.count, MCPCapabilitiesManifestBuilder.productionTools.count + 1)
        for tool in MCPCapabilitiesManifestBuilder.productionTools {
            let section = try XCTUnwrap(tools.first { $0.title == tool.name })
            XCTAssertTrue(section.markdown.contains(tool.description), "Regenerate the tool reference after registry changes: \(tool.name)")
        }
        let commands = CLIApplication.help.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("joesproxyctl ") && !$0.hasPrefix("joesproxyctl - ") }
        let reference = catalog.topicSections("reference-cli").map(\.markdown).joined(separator: "\n")
        XCTAssertEqual(catalog.topicSections("reference-cli").count, commands.count + 1)
        for command in commands { XCTAssertTrue(reference.contains(command), "Regenerate CLI documentation: \(command)") }
        for topic in catalog.index.topics {
            for reference in topic.capabilityReferences ?? [] {
                XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionTools.contains { $0.name == reference })
            }
        }
    }

    func testExportedSkillAndNativePromptsTeachTargetedDocumentation() throws {
        let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: root.appendingPathComponent(".agents/skills/joesproxy-mcp-diagnostics/SKILL.md"), encoding: .utf8)
        for text in [skill, MCPDiagnosticPrompt.body, MCPSetupOnboardingPrompt.body] {
            XCTAssertTrue(text.contains("documentation_search"))
            XCTAssertTrue(text.contains("documentation_read"))
            XCTAssertTrue(text.contains("joesproxyctl docs"))
        }
    }

    func testSelectedWorkflowStepsIncludeSafetyContext() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let page = try catalog.execute(.init(operation: "read", topic: "workflow-mocking", section: "observe"), source: "installed", appVersion: "test")
        XCTAssertEqual(page.entries.first?.safetyContext.first?.id, "safety")
        XCTAssertTrue(page.entries.first?.safetyContext.first?.markdown.contains("not activation authority") == true)
        let result = try catalog.execute(.init(operation: "search", query: "documentation_read"), source: "installed", appVersion: "test")
        XCTAssertTrue(result.entries.contains { $0.topic.id == "reference-tools" && $0.matchedSectionID != nil })
    }

    func testMalformedResourcesAndBrokenReferencesAreRejected() throws {
        let scratch = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/DocumentationCatalogTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let indexURL = scratch.appendingPathComponent("documentation-index.json")
        var topic: [String: Any] = ["id": "test", "title": "Test", "summary": "Synthetic test", "category": "test",
            "keywords": [], "relatedTopics": [], "file": "doc-test.md"]
        func writeIndex(version: Int = 1, topics: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "revision": "test", "topics": topics]).write(to: indexURL)
        }
        try writeIndex(topics: [topic])
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
        let contentURL = scratch.appendingPathComponent("doc-test.md")
        try "## Test {#test}\nSynthetic content".write(to: contentURL, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try DocumentationCatalog(directory: scratch))
        try writeIndex(version: 999, topics: [topic])
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
        try writeIndex(topics: [topic, topic])
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
        topic["relatedTopics"] = ["missing"]
        try writeIndex(topics: [topic])
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
        topic["relatedTopics"] = []
        try writeIndex(topics: [topic])
        try "## Test {#test}\nFirst\n## Duplicate {#test}\nSecond".write(to: contentURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
        try Data("not JSON".utf8).write(to: indexURL)
        XCTAssertThrowsError(try DocumentationCatalog(directory: scratch))
    }

    func testSyntheticGuidanceJourneysUseBoundedTargetedReads() throws {
        let catalog = try DocumentationCatalog(directory: directory)
        let journeys = [("setup", "setup", "core"), ("missing body", "workflow-evidence", "bodies"),
            ("image", "workflow-mocking", "observe"), ("client", "workflow-mocking", "prepare"),
            ("revision", "workflow-mocking", "recovery"), ("target", "workflow-evidence", "target"),
            ("cleanup", "workflow-evidence", "cleanup")]
        var totalBytes = 0
        for (term, topic, section) in journeys {
            let search = try catalog.execute(.init(operation: "search", query: term, limit: 3, maxResponseBytes: 4096), source: "installed", appVersion: "test")
            XCTAssertFalse(search.entries.isEmpty)
            let read = try catalog.execute(.init(operation: "read", topic: topic, section: section, maxResponseBytes: 8192), source: "installed", appVersion: "test")
            XCTAssertEqual(read.entries.count, 1)
            let bytes = try JSONEncoder().encode(search).count + JSONEncoder().encode(read).count
            totalBytes += bytes
            XCTAssertLessThanOrEqual(bytes, 12288)
        }
        print("Documentation synthetic retrieval receipt: journeys=7 calls=14 payloadBytes=\(totalBytes); tokens not measured; no target execution")
        for section in catalog.topicSections("workflow-mocking") {
            let page = try catalog.execute(.init(operation: "read", topic: "workflow-mocking",
                section: section.id, maxResponseBytes: 8192), source: "installed", appVersion: "test")
            XCTAssertEqual(page.entries.first?.sections.first?.id, section.id)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(page).count, 8192)
        }
    }

    func testBundledExecutableFindsOfflineResources() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/joesproxyctl")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["docs", "list", "--limit", "1", "--format", "json"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let page = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(page["source"] as? String, "installed")
        XCTAssertEqual((page["entries"] as? [Any])?.count, 1)
        XCTAssertEqual(page["catalogDigest"] as? String, try DocumentationCatalog(directory: directory).digest)
    }
}
