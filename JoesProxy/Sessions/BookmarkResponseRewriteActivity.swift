import Foundation

/// Session-scoped telemetry for a bookmark response rewrite enabled during the current proxy run.
struct BookmarkResponseRewriteActivity: Equatable, Sendable {
    let enabledAt: Date
    var lastInterceptAt: Date?
    var lastInterceptPath: String?
    var lastAppliedCount: Int
    var lastSkippedCount: Int
    var lastAppliedPaths: [String]
    var lastSkippedPaths: [String]

    init(
        enabledAt: Date = Date(),
        lastInterceptAt: Date? = nil,
        lastInterceptPath: String? = nil,
        lastAppliedCount: Int = 0,
        lastSkippedCount: Int = 0,
        lastAppliedPaths: [String] = [],
        lastSkippedPaths: [String] = []
    ) {
        self.enabledAt = enabledAt
        self.lastInterceptAt = lastInterceptAt
        self.lastInterceptPath = lastInterceptPath
        self.lastAppliedCount = lastAppliedCount
        self.lastSkippedCount = lastSkippedCount
        self.lastAppliedPaths = lastAppliedPaths
        self.lastSkippedPaths = lastSkippedPaths
    }

    var hasIntercepted: Bool {
        lastInterceptAt != nil
    }
}

/// Outcome of refreshing a bookmark saved response from captured session traffic.
enum BookmarkSavedResponseRefreshResult: Equatable, Sendable {
    case refreshed
    case noMatchingSession
    case noSavableBody
}

/// Summary of the session that would supply a bookmark saved-response refresh.
struct BookmarkSavedResponseRefreshCandidate: Equatable, Sendable {
    let method: String
    let host: String
    let path: String
    let startedAt: Date
}
