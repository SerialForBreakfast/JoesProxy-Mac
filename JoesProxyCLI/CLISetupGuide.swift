import Foundation

enum CLISetupGuide {
    static let resourceName = "doc-setup.md"

    static var markdown: String {
        guard let directory = try? DocumentationCatalog.bundledDirectory(),
              let value = try? String(contentsOf: directory.appendingPathComponent(resourceName), encoding: .utf8),
              !value.isEmpty else {
            return "# Documentation unavailable\n\nUse the CLI bundled with a complete JoesProxy installation. The setup guide was not substituted."
        }
        return value
    }
}
