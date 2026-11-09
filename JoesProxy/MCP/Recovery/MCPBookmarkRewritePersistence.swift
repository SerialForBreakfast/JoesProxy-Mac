import Foundation

/// Shared bookmark rewrite persistence used by mutation apply and recovery restore.
enum MCPBookmarkRewritePersistence {
    static func setRewriteEnabled(
        bookmarkID: UUID,
        rewriteID: UUID,
        isEnabled: Bool,
        bookmarkStore: any BookmarkStore
    ) throws {
        var bookmarks = bookmarkStore.loadBookmarks()
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            throw MCPStructuredError(code: .conflict, message: "Bookmark not found during rewrite update.")
        }
        guard let rewriteIndex = bookmarks[index].responseRewrites.firstIndex(where: { $0.id == rewriteID }) else {
            throw MCPStructuredError(code: .conflict, message: "Rewrite not found during rewrite update.")
        }
        bookmarks[index].responseRewrites[rewriteIndex].isRuleEnabled = isEnabled
        let updated = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmarks[index])
        bookmarks[index] = updated
        try MCPBookmarkStoreSupport.saveBookmarks(
            bookmarks,
            to: bookmarkStore,
            applyingRevisionToUpdated: updated,
            provenance: updated.mcpProvenance,
            origin: updated.mcpOrigin
        )
    }
}
