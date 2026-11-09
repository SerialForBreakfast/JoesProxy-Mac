import Foundation
import Observation

/// Historical table input arrays share these objects instead of retaining summary snapshots.
/// MainActor owns metadata updates; cells observe only their row, not the workspace dictionary.
@MainActor @Observable
final class SessionTableRowPresentation: Identifiable, Equatable {
    nonisolated let id: SessionRecord.ID
    private(set) var summary: SessionSummary

    init(summary: SessionSummary) {
        id = summary.id
        self.summary = summary
    }

    func update(_ summary: SessionSummary) {
        precondition(summary.id == id)
        if self.summary != summary { self.summary = summary }
    }

    nonisolated static func == (lhs: SessionTableRowPresentation, rhs: SessionTableRowPresentation) -> Bool {
        lhs === rhs
    }
}

/// Pagination policy for the live-capture session table to limit SwiftUI `Table` row churn.
enum SessionTablePresentation {
    /// Maximum session rows rendered while the proxy is actively capturing.
    static let liveCaptureInitialVisibleSessionCount = 500

    /// Additional rows revealed each time the user taps **Show older sessions**.
    static let liveCaptureVisibleSessionIncrement = 500

    /// Returns the visible slice of `sessions` for the current sort order and limit.
    ///
    /// `sessions` is always in ascending (oldest-first) order. When `newestFirst` is true the
    /// last `visibleLimit` entries are taken and reversed so the table shows newest at top.
    /// Generic so `[SessionRecord]` and `[SessionSummary]` share the same windowing.
    static func displayedSessions<Element>(
        from sessions: [Element],
        visibleLimit: Int,
        newestFirst: Bool
    ) -> [Element] {
        guard visibleLimit > 0, sessions.count > visibleLimit else {
            return newestFirst ? Array(sessions.reversed()) : sessions
        }

        if newestFirst {
            return Array(sessions.suffix(visibleLimit).reversed())
        }

        return Array(sessions.prefix(visibleLimit))
    }

    /// Number of captured sessions not yet shown in the windowed table.
    static func hiddenSessionCount(totalCount: Int, visibleLimit: Int) -> Int {
        max(0, totalCount - visibleLimit)
    }

    /// Computes the next visible limit after **Show older sessions**, clamped to `totalCount`.
    static func nextVisibleLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(totalCount, currentLimit + liveCaptureVisibleSessionIncrement)
    }

    /// Resets pagination when a new capture run starts or sessions are loaded.
    /// Returns the default limit when there are no sessions yet, so that windowing
    /// works correctly once sessions start arriving.
    static func initialVisibleLimit(for totalCount: Int) -> Int {
        totalCount > 0 ? min(totalCount, liveCaptureInitialVisibleSessionCount) : liveCaptureInitialVisibleSessionCount
    }

    /// True if the element at `index` (in an ascending, oldest-first array of `totalCount`
    /// elements) falls inside the slice `displayedSessions(...)` would return for the same
    /// `visibleLimit`/`newestFirst`. Single source of truth for "is this position hidden by
    /// windowing" — shared by the pinning helper below and by hidden-count computation so the
    /// two can't silently disagree about what "in the window" means.
    static func isIndexWithinWindow(
        index: Int,
        totalCount: Int,
        visibleLimit: Int,
        newestFirst: Bool
    ) -> Bool {
        guard visibleLimit > 0, totalCount > visibleLimit else { return true }
        return newestFirst ? index >= totalCount - visibleLimit : index < visibleLimit
    }

    /// `displayedSessions(from:visibleLimit:newestFirst:)`, but if `selectedIndex` refers to
    /// an element outside the natural window, that element is appended so it's never hidden.
    ///
    /// Appending — not inserting at a fixed top/bottom UI slot — is correct for both sort
    /// directions: windowing always keeps a contiguous run from one end of the ascending
    /// array (`suffix` for newest-first, `prefix` for oldest-first), so anything windowing
    /// excludes is, by construction, beyond the window's trailing edge in display order. A
    /// pinned session therefore always belongs immediately after the window's last displayed
    /// entry, keeping reading order coherent instead of sticking it to a fixed slot.
    static func displayedSessionsPinningSelection<Element: Equatable>(
        from sessions: [Element],
        visibleLimit: Int,
        newestFirst: Bool,
        selectedIndex: Int?
    ) -> [Element] {
        let windowed = displayedSessions(from: sessions, visibleLimit: visibleLimit, newestFirst: newestFirst)
        guard let selectedIndex, sessions.indices.contains(selectedIndex) else {
            return windowed
        }
        let pinnedElement = sessions[selectedIndex]
        guard !isIndexWithinWindow(
            index: selectedIndex,
            totalCount: sessions.count,
            visibleLimit: visibleLimit,
            newestFirst: newestFirst
        ) else {
            return windowed
        }
        // Guard against duplicate entries in the rendered table:
        if windowed.contains(pinnedElement) {
            return windowed
        }
        return windowed + [pinnedElement]
    }
}
