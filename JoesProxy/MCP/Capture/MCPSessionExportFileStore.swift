import Foundation

/// Writes bulk `sessions_export` payloads to a JoesProxy-managed directory when inline MCP
/// responses would exceed the response budget, or when the caller requests file delivery.
///
/// Concurrency: `@MainActor` — used only from ``MCPProtocolService`` on the main actor.
/// Paths are always under Application Support (or an injected test directory); clients cannot
/// choose arbitrary filesystem locations.
@MainActor
enum MCPSessionExportFileStore {
    static let directoryName = "MCPExports"

    /// Default Application Support directory for spilled export artifacts.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes export bytes with owner-only permissions and returns the absolute file path.
    ///
    /// - Parameters:
    ///   - data: Encoded export payload (HAR / JSON / NDJSON).
    ///   - format: File extension stem (`har`, `json`, `ndjson`).
    ///   - directory: Target directory; created if missing.
    /// - Returns: Absolute path string for the written file.
    static func writeExport(
        data: Data,
        format: String,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext: String
        switch format.lowercased() {
        case "har": ext = "har"
        case "ndjson": ext = "ndjson"
        case "jproxy-repro": ext = "jproxy-repro"
        default: ext = "json"
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url.path
    }
}
