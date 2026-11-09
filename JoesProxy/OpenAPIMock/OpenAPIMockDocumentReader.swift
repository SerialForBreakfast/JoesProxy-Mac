import Foundation

/// Resolves an opaque OpenAPI document bookmark to local bytes. Never returns a filesystem path.
enum OpenAPIMockDocumentReader {
    /// Reads the JSON document referenced by `bookmark`.
    ///
    /// Uses a plain bookmark resolve (not security-scoped minting) so CLI-minted bookmarks
    /// work across the `joesproxyctl` → app process boundary, matching Map Local directories.
    static func data(from bookmark: OpenAPIDocumentBookmark) throws -> Data {
        var isStale = false
        let fileURL: URL
        do {
            fileURL = try URL(
                resolvingBookmarkData: bookmark.data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw OpenAPIMockPackError.bookmarkUnreadable(error.localizedDescription)
        }
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        var isDirectory = false
        if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]) {
            isDirectory = values.isDirectory == true
        }
        guard !isDirectory else {
            throw OpenAPIMockPackError.bookmarkUnreadable("Bookmark must point at an OpenAPI JSON file.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw OpenAPIMockPackError.bookmarkUnreadable(error.localizedDescription)
        }
        try OpenAPIMockPackBudget.validateDocumentBytes(data.count)
        return data
    }

    /// Mints a plain bookmark for a local OpenAPI JSON file. UI and CLI call this; MCP never sees the path.
    static func bookmark(forFileURL fileURL: URL) throws -> OpenAPIDocumentBookmark {
        let data: Data
        do {
            data = try fileURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw OpenAPIMockPackError.bookmarkUnreadable(error.localizedDescription)
        }
        return OpenAPIDocumentBookmark(data: data)
    }
}
