import Combine
import Foundation

/// Matches a session produced by bookmark/request execution through the live proxy.
///
/// Concurrency: `@MainActor` — scan and subscribe must run without an intervening suspension
/// so a session cannot slip through the gap (same invariant as ``ProxyViewModel``'s matcher).
@MainActor
final class MCPExecutedSessionMatcher {
    private let sessionStore: any SessionStore
    private let matchTimeout: TimeInterval

    init(sessionStore: any SessionStore, matchTimeout: TimeInterval = 2) {
        self.sessionStore = sessionStore
        self.matchTimeout = matchTimeout
    }

    /// Waits for the session produced by an executed request.
    ///
    /// One initial scan covers sessions captured before the wait began; after that, only
    /// records arriving via store changes are checked.
    func waitForMatch(
        request: CapturedRequest,
        startedAt: Date
    ) async -> SessionRecord? {
        if let existing = newestMatchingSession(for: request, startedAt: startedAt) {
            return existing
        }

        // No suspension between the scan above and the subscription below (both on the
        // main actor), so a session can't slip through the gap.
        return await withCheckedContinuation { (continuation: CheckedContinuation<SessionRecord?, Never>) in
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?
            var finished = false

            func finish(_ session: SessionRecord?) {
                guard !finished else { return }
                finished = true
                cancellable?.cancel()
                timeoutTask?.cancel()
                continuation.resume(returning: session)
            }

            cancellable = sessionStore.sessionChangesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    guard let self else {
                        finish(nil)
                        return
                    }
                    let candidates: [SessionRecord]
                    switch change {
                    case .appended(let session, _), .updated(let session, _):
                        candidates = [session]
                    case .updatedBatch(let sessions, _):
                        candidates = sessions
                    case .bodiesStripped, .removed, .cleared, .loaded:
                        return
                    }
                    for session in candidates where self.matches(session, request: request, startedAt: startedAt) {
                        finish(session)
                        return
                    }
                }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.matchTimeout))
                finish(nil)
            }
        }
    }

    private func newestMatchingSession(for request: CapturedRequest, startedAt: Date) -> SessionRecord? {
        sessionStore.sessions
            .filter { matches($0, request: request, startedAt: startedAt) }
            .max { lhs, rhs in
                lhs.timing.startedAt < rhs.timing.startedAt
            }
    }

    private func matches(
        _ session: SessionRecord,
        request: CapturedRequest,
        startedAt: Date
    ) -> Bool {
        session.timing.startedAt >= startedAt.addingTimeInterval(-1) &&
            session.request.method.caseInsensitiveCompare(request.method) == .orderedSame &&
            session.request.scheme == request.scheme &&
            session.request.host.caseInsensitiveCompare(request.host) == .orderedSame &&
            Self.normalizePath(session.request.path) == Self.normalizePath(request.path) &&
            Self.canonicalPort(for: session.request) == Self.canonicalPort(for: request)
    }

    private static func normalizePath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        return path.hasPrefix("/") ? path : "/\(path)"
    }

    private static func canonicalPort(for request: CapturedRequest) -> Int {
        if let port = request.port {
            return port
        }
        return request.scheme == .https ? 443 : 80
    }
}
