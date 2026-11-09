import Foundation
import CryptoKit

// Run from the repository root with the installed Swift toolchain; no packages are resolved.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("JoesProxy/Resources/Documentation")
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("JoesProxy.xcodeproj/project.pbxproj").path),
      FileManager.default.fileExists(atPath: resources.appendingPathComponent("documentation-index.json").path) else {
    fatalError("Run from the JoesProxy repository root with its documentation catalog present.")
}
let registry = try String(contentsOf: root.appendingPathComponent("JoesProxy/MCP/Capture/MCPCapabilitiesManifestBuilder.swift"), encoding: .utf8)
let pattern = #"ProductionTool\(name: "([^"]+)", description: "([^"]+)", capability: \.([A-Za-z]+)\)"#
let regex = try NSRegularExpression(pattern: pattern)
let source = registry as NSString
let matches = regex.matches(in: registry, range: NSRange(location: 0, length: source.length))
guard !matches.isEmpty else { fatalError("Registry syntax changed; update the generator and integrity tests.") }
var tools = """
# MCP tool reference

## Scope {#safety}

Generated from MCPCapabilitiesManifestBuilder.productionTools. This is an installed reference, not a grant or running availability claim. Use tools/list for exact input schemas and runtime_status for readiness. Mutation, replay and host profiling need their existing permissions.

"""
for match in matches {
    let name = source.substring(with: match.range(at: 1))
    let description = source.substring(with: match.range(at: 2))
    let capability = source.substring(with: match.range(at: 3))
    tools += "\n## \(name) {#\(name.replacingOccurrences(of: "_", with: "-"))}\n\n\(description)\n\nCapability category: \(capability).\n"
}
let cli = try String(contentsOf: root.appendingPathComponent("JoesProxyCLI/CLIApplication.swift"), encoding: .utf8)
guard let start = cli.range(of: "static let help = \"\"\""),
      let end = cli.range(of: "\"\"\"", range: start.upperBound..<cli.endIndex) else {
    fatalError("CLI help syntax changed; update the generator and integrity tests.")
}
let commands = cli[start.upperBound..<end.lowerBound].components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0.hasPrefix("joesproxyctl ") && !$0.hasPrefix("joesproxyctl - ") }
guard !commands.isEmpty else { fatalError("CLI reference cannot be empty.") }
var commandText = """
# CLI command reference

## Scope {#safety}

Generated from CLIApplication.help. These are parameterized syntax examples, not permission to execute. Replace placeholders with explicitly reviewed values. Offline docs require no credentials; live commands retain authentication, disclosure and approval boundaries.

"""
for (index, command) in commands.enumerated() {
    let identity = SHA256.hash(data: Data(command.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    commandText += "\n## Command \(index + 1) {#command-\(identity)}\n\n```text\n\(command)\n```\n"
}
for (name, content) in [("doc-reference-tools.md", tools), ("doc-reference-cli.md", commandText)] {
    let destination = resources.appendingPathComponent(name)
    guard destination.resolvingSymlinksInPath().deletingLastPathComponent().path == resources.resolvingSymlinksInPath().path else {
        fatalError("Reference destination must remain inside the documentation directory.")
    }
    try content.write(to: destination, atomically: true, encoding: .utf8)
}
print("Generated \(matches.count) tool and \(commands.count) command sections. Run DocumentationCatalogTests before handoff.")
