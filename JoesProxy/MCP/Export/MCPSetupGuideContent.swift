import Foundation

/// The portable export keeps its legacy filename while reading the shared catalog source.
enum MCPSetupGuideContent {
    static let resourceName = "doc-setup"

    static var markdown: String {
        guard let directory = try? DocumentationCatalog.bundledDirectory(),
              let value = try? String(contentsOf: directory.appendingPathComponent(resourceName + ".md"), encoding: .utf8),
              !value.isEmpty else {
            return "# Documentation unavailable\n\nReopen a complete JoesProxy installation. The setup guide was not substituted."
        }
        return value
    }
}
