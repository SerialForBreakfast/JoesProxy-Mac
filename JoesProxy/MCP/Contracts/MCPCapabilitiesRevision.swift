import Foundation

/// Integer revision bumped when MCP tools, DTO shapes, or documented workflows change.
///
/// Combined with the app marketing version to form ``MCPCapabilitiesManifest/bundleVersion``.
enum MCPCapabilitiesRevision {
    static let current = 29

    /// Human-readable compatibility token, e.g. `1.2.1+1`.
    static func bundleVersion(appVersion: String = Bundle.main.marketingVersionOrDev) -> String {
        "\(appVersion)+\(current)"
    }
}
