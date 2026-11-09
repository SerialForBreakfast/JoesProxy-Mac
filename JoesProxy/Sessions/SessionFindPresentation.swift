import Foundation

/// Pagination and presentation policy for the session Find panel result list.
enum SessionFindPresentation {
    /// Maximum Find rows rendered on first publish to avoid SwiftUI list microhangs on large captures.
    static let initialVisibleResultCount = 200

    /// Additional rows revealed each time the user taps **Show more**.
    static let visibleResultIncrement = 200

    /// Returns the prefix of `results` that should be rendered for the current visible limit.
    static func displayedResults(from results: [SessionFindResult], visibleLimit: Int) -> [SessionFindResult] {
        guard visibleLimit > 0 else {
            return []
        }

        return Array(results.prefix(visibleLimit))
    }

    /// Number of matches not yet shown in the Find panel list.
    static func hiddenResultCount(totalCount: Int, visibleLimit: Int) -> Int {
        max(0, totalCount - visibleLimit)
    }

    /// Computes the next visible limit after **Show more**, clamped to `totalCount`.
    static func nextVisibleLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(totalCount, currentLimit + visibleResultIncrement)
    }

    /// Resets pagination when a new query run starts or Find state is cleared.
    static func initialVisibleLimit(for totalCount: Int) -> Int {
        min(totalCount, initialVisibleResultCount)
    }
}
