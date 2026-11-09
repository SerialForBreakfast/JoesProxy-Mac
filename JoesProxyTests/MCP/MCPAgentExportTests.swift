import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPAgentExportTests: XCTestCase {
    func testCursorSnippetMatchesMCPJSONShape() throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let snippet = MCPClientConfigSnippetBuilder.cursorMCPJSON(
            endpointURL: endpoint,
            bearerToken: MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder,
            clientLabel: "cursor"
        )
        let data = try XCTUnwrap(snippet.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["joesproxy-cursor"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, endpoint.absoluteString)
        let headers = try XCTUnwrap(entry["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer \(MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder)")
    }

    func testClaudeCodeCommandProducesValidatedInstallForm() throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let command = MCPClientConfigSnippetBuilder.claudeCodeCommand(
            endpointURL: endpoint,
            bearerToken: MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder,
            clientLabel: "claude-code"
        )
        XCTAssertTrue(command.contains("claude mcp add --transport http joesproxy-claude-code \(endpoint.absoluteString)"))
        XCTAssertTrue(command.contains("--header \"Authorization: Bearer \(MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder)\""))
        XCTAssertTrue(command.contains("claude mcp remove joesproxy-claude-code"))
    }

    func testCodexConfigUsesStableProjectScopedServerName() throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let config = MCPClientConfigSnippetBuilder.codexConfig(endpointURL: endpoint)

        XCTAssertTrue(config.contains("<project-root>/.codex/config.toml"))
        XCTAssertTrue(config.contains("[mcp_servers.joesproxy]"))
        XCTAssertFalse(config.contains("[mcp_servers.joesproxy_"))

        let instructions = MCPClientConfigSnippetBuilder.setupInstructions(
            for: .codexCLI,
            endpointURL: endpoint,
            clientLabel: "Codex 2"
        )
        guard case .fileEdit(let path, let content) = instructions.mechanism else {
            return XCTFail("Expected shared Codex project configuration instructions.")
        }
        XCTAssertEqual(path, ".codex/config.toml in your project root")
        XCTAssertTrue(content.contains("[mcp_servers.joesproxy]"))
        XCTAssertTrue(instructions.restartNote.contains("Codex CLI"))
        XCTAssertTrue(instructions.caveat?.contains("desktop app") == true)
    }

    func testJoesProxyCLISetupUsesBundledExecutableAndInteractiveEnrollment() throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let appURL = URL(fileURLWithPath: "/Applications/JoesProxy.app", isDirectory: true)
        let command = MCPClientConfigSnippetBuilder.joesProxyCLICommand(
            endpointURL: endpoint,
            appBundleURL: appURL
        )

        XCTAssertEqual(
            command,
            "'/Applications/JoesProxy.app/Contents/MacOS/joesproxyctl' auth login --endpoint 'http://127.0.0.1:9091/mcp'"
        )

        let instructions = MCPClientConfigSnippetBuilder.setupInstructions(
            for: .joesProxyCLI,
            endpointURL: endpoint,
            bearerToken: "secret-that-must-not-appear",
            clientLabel: "joesproxy-cli"
        )
        guard case .command(let setupCommand) = instructions.mechanism else {
            return XCTFail("Expected JoesProxy CLI to use an interactive command.")
        }
        XCTAssertTrue(setupCommand.contains("joesproxyctl' auth login --endpoint"))
        XCTAssertTrue(setupCommand.hasSuffix("'http://127.0.0.1:9091/mcp'"))
        XCTAssertFalse(setupCommand.contains("secret-that-must-not-appear"))
        XCTAssertTrue(instructions.restartNote.contains("Keychain"))
    }

    func testSetupInstructionsDispatchesCommandForClaudeCodeAndFileEditForOthers() throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let claudeCode = MCPClientConfigSnippetBuilder.setupInstructions(
            for: .claudeCode, endpointURL: endpoint, clientLabel: "claude-code"
        )
        guard case .command = claudeCode.mechanism else {
            return XCTFail("Expected Claude Code to be a command, not a file edit.")
        }

        let joesProxyCLI = MCPClientConfigSnippetBuilder.setupInstructions(
            for: .joesProxyCLI, endpointURL: endpoint, clientLabel: "joesproxy-cli"
        )
        guard case .command = joesProxyCLI.mechanism else {
            return XCTFail("Expected JoesProxy CLI to be an enrollment command.")
        }

        for kind: MCPClientKind in [.claudeDesktop, .cursor, .codexCLI, .other] {
            let instructions = MCPClientConfigSnippetBuilder.setupInstructions(
                for: kind, endpointURL: endpoint, clientLabel: "test"
            )
            guard case .fileEdit = instructions.mechanism else {
                return XCTFail("Expected \(kind) to be a file edit, not a command.")
            }
        }
    }

    func testBundleContainsVersionedManifestAndGuide() throws {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest(appVersion: "1.2.1")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-export-\(UUID().uuidString)", isDirectory: true)
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let bundleURL = try MCPAgentExportService.exportBundle(
            MCPAgentExportService.ExportRequest(
                destinationDirectory: destination,
                endpointURL: endpoint,
                bearerToken: nil,
                clientLabel: "test-agent",
                manifest: manifest
            )
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedManifest = try decoder.decode(MCPCapabilitiesManifest.self, from: manifestData)
        XCTAssertEqual(decodedManifest.bundleVersion, "1.2.1+\(MCPCapabilitiesRevision.current)")

        let guide = try String(contentsOf: bundleURL.appendingPathComponent("JOESPROXY_MCP_AGENT.md"))
        XCTAssertTrue(guide.contains("JoesProxy MCP Agent Guide"))
        XCTAssertTrue(guide.contains("media_readiness"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("cursor.mcp.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("claude.mcp.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("claude-code.command.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("codex.config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("README.txt").path))
        let portableGuide = try String(contentsOf: bundleURL.appendingPathComponent(MCPAgentExportService.portableSetupGuideFileName))
        XCTAssertTrue(portableGuide.contains("JoesProxy Setup Guide"))
        XCTAssertFalse(portableGuide.contains("Bearer "))
        XCTAssertFalse(portableGuide.contains("http://127.0.0.1:"))

        let claudeCodeCommandFile = try String(contentsOf: bundleURL.appendingPathComponent("claude-code.command.txt"))
        XCTAssertTrue(claudeCodeCommandFile.contains("claude mcp add --transport http"))
    }

    func testPortableSetupGuideCanBeExportedWithoutMCPEndpoint() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-guide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let fileURL = try MCPAgentExportService.writePortableSetupGuide(to: destination)
        XCTAssertEqual(fileURL.lastPathComponent, MCPAgentExportService.portableSetupGuideFileName)
        let content = try String(contentsOf: fileURL)
        XCTAssertTrue(content.contains("setup_readiness"))
        XCTAssertFalse(content.contains("Bearer "))
        XCTAssertFalse(content.contains("192.168."))
    }

    /// Folder export includes the routed package and the complete legacy single-file fallback.
    func testBundleContainsSkillFileMatchingCanonicalBody() throws {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-export-\(UUID().uuidString)", isDirectory: true)
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let bundleURL = try MCPAgentExportService.exportBundle(
            MCPAgentExportService.ExportRequest(
                destinationDirectory: destination,
                endpointURL: endpoint,
                bearerToken: nil,
                clientLabel: "test-agent",
                manifest: manifest
            )
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let skillFileURL = bundleURL.appendingPathComponent(MCPAgentExportService.skillFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFileURL.path))
        let skillContent = try String(contentsOf: skillFileURL)
        XCTAssertTrue(skillContent.hasPrefix("---\nname: joesproxy-mcp-diagnostics\n"))
        XCTAssertTrue(skillContent.hasSuffix(MCPDiagnosticPrompt.body))
        XCTAssertTrue(skillContent.contains("compatibility: [claude-code, codex, cursor]"))
        let package = bundleURL.appendingPathComponent(MCPDiagnosticSkill.directoryName)
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("SKILL.md")), MCPAgentExportService.skillMarkdown)
        for reference in MCPDiagnosticSkill.references {
            XCTAssertEqual(
                try String(contentsOf: package.appendingPathComponent("references/\(reference.fileName)")),
                reference.markdown
            )
        }
    }

    func testWriteSkillFileProducesUsableStandaloneFile() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let fileURL = try MCPAgentExportService.writeSkillFile(to: destination)
        XCTAssertEqual(fileURL.lastPathComponent, MCPAgentExportService.skillFileName)
        let content = try String(contentsOf: fileURL)
        XCTAssertEqual(content, MCPAgentExportService.standaloneSkillMarkdown)
        XCTAssertFalse(content.contains("](references/"), "Standalone sharing must not depend on missing sibling files")
    }

    func testBundleOmitsBearerByDefault() throws {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-export-\(UUID().uuidString)", isDirectory: true)
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let bundleURL = try MCPAgentExportService.exportBundle(
            MCPAgentExportService.ExportRequest(
                destinationDirectory: destination,
                endpointURL: endpoint,
                bearerToken: nil,
                clientLabel: "test-agent",
                manifest: manifest
            )
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        let cursor = try String(contentsOf: bundleURL.appendingPathComponent("cursor.mcp.json"))
        XCTAssertTrue(cursor.contains(MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder))
        XCTAssertFalse(cursor.contains("Bearer eyJ"))
    }

    func testBundleVersionMatchesAppVersion() {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        XCTAssertEqual(manifest.bundleVersion, MCPCapabilitiesRevision.bundleVersion())
        XCTAssertEqual(manifest.appVersion, Bundle.main.marketingVersionOrDev)
    }

    func testAgentGuideResourceMarkdownIsGenerated() {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let markdown = MCPAgentExportService.generateGuideMarkdown(manifest: manifest)
        XCTAssertTrue(markdown.contains("joesproxy://agent/capabilities"))
        XCTAssertTrue(markdown.contains("classify_session"))
        XCTAssertTrue(markdown.contains("### All tools"))
        XCTAssertTrue(markdown.contains("## CLI companion"))
        XCTAssertTrue(markdown.contains("deliverFile"))
        XCTAssertTrue(markdown.contains("section `workspace`"))
        XCTAssertTrue(markdown.contains("agents must not resolve their own live approvals"))
    }

    func testAgentGuideListsEveryManifestTool() {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let markdown = MCPAgentExportService.generateGuideMarkdown(manifest: manifest)
        for tool in manifest.tools {
            XCTAssertTrue(
                markdown.contains("`\(tool.name)`"),
                "Guide must list manifest tool `\(tool.name)`"
            )
        }
    }

    func testRepoDiagnosticSkillBodyMatchesPromptSource() throws {
        let skillURL = repoRoot()
            .appendingPathComponent(".agents/skills/joesproxy-mcp-diagnostics/SKILL.md")
        let skillText = try String(contentsOf: skillURL, encoding: .utf8)
        let body = try XCTUnwrap(Self.markdownBodyAfterFrontmatter(skillText))
        XCTAssertEqual(
            body,
            MCPDiagnosticSkill.entryBody,
            "Repo SKILL.md body must match the exported routed entry point"
        )
    }

    func testPortableReferencesAreLosslessAndMatchRepository() throws {
        let references = MCPDiagnosticSkill.references
        XCTAssertEqual(references.map(\.fileName), MCPDiagnosticSkill.routes.map(\.fileName))
        XCTAssertEqual(Set(references.map(\.fileName)).count, references.count)
        XCTAssertEqual(references.map(\.markdown).joined(), MCPDiagnosticPrompt.body)
        XCTAssertLessThan(MCPAgentExportService.skillMarkdown.utf8.count, 8_000)
        let directory = repoRoot().appendingPathComponent(".agents/skills/joesproxy-mcp-diagnostics/references")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(references.map(\.fileName)))
        for reference in references {
            XCTAssertFalse(reference.markdown.isEmpty)
            XCTAssertLessThan(reference.markdown.utf8.count, 24_000, "Split oversized reference \(reference.fileName)")
            XCTAssertTrue(MCPDiagnosticSkill.entryBody.contains("](references/\(reference.fileName))"))
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(reference.fileName)), reference.markdown)
        }
    }

    func testPortableSkillCoversEveryRegisteredProductionTool() {
        let portableContent = MCPDiagnosticSkill.entryBody + MCPDiagnosticSkill.references.map(\.markdown).joined()
        for tool in MCPCapabilitiesManifestBuilder.productionTools {
            XCTAssertTrue(portableContent.contains("`\(tool.name)`"),
                "Portable skill must cover registered tool \(tool.name), not just the generated guide")
        }
    }

    func testSkillPackagePropagatesReferenceWriteFailure() throws {
        let destination = repoRoot().appendingPathComponent("build/SkillRoutingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let package = destination.appendingPathComponent(MCPDiagnosticSkill.directoryName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: package.appendingPathComponent("references"))
        XCTAssertThrowsError(try MCPAgentExportService.writeSkillPackage(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("SKILL.md").path))
    }

    /// `skillMarkdown`'s frontmatter version is derived dynamically from `Bundle.main
    /// .marketingVersionOrDev` (no more hardcoded literal to drift) — this test instead proves the
    /// checked-in repo file's hand-maintained copy (which `bump_version.sh` is responsible for
    /// keeping current, since it can't read `Bundle.main` at authoring time) still matches the app's
    /// own version. A failure here means `bump_version.sh` wasn't run, or SKILL.md was hand-edited
    /// out of sync.
    func testExportSkillFrontmatterVersionMatchesRepoSkill() throws {
        let skillURL = repoRoot()
            .appendingPathComponent(".agents/skills/joesproxy-mcp-diagnostics/SKILL.md")
        let skillText = try String(contentsOf: skillURL, encoding: .utf8)
        let repoVersion = try XCTUnwrap(Self.frontmatterVersion(skillText))
        let exportVersion = try XCTUnwrap(Self.frontmatterVersion(MCPAgentExportService.skillMarkdown))
        XCTAssertEqual(exportVersion, repoVersion)
        XCTAssertEqual(repoVersion, Bundle.main.marketingVersion)
    }

    func testDiagnosticPlaybookMentionsExpandedCatalogAnchors() {
        let body = MCPDiagnosticPrompt.body
        XCTAssertTrue(body.contains("certificate_status"))
        XCTAssertTrue(body.contains("hls_fixture_capabilities"))
        XCTAssertTrue(body.contains("deliverFile"))
        XCTAssertTrue(body.contains("discover_response_structure"))
        XCTAssertTrue(body.contains("joesproxy://audit/recent"))
        XCTAssertTrue(body.contains("proxy_start"))
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let agents = url.appendingPathComponent("AGENTS.md")
            if FileManager.default.fileExists(atPath: agents.path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func markdownBodyAfterFrontmatter(_ text: String) -> String? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---\n") else { return nil }
        return String(afterOpen[closeRange.upperBound...])
    }

    private static func frontmatterVersion(_ text: String) -> String? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---\n") else { return nil }
        let frontmatter = afterOpen[..<closeRange.lowerBound]
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("version:") {
                return trimmed
                    .dropFirst("version:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
