import Foundation
import os

/// Result of a `TrafficWatchVerifier` watch operation.
enum TrafficWatchResult: Equatable, Sendable {
    /// Watch not yet started.
    case ready
    /// Watch is active — polling for matching traffic.
    case watching
    /// A session matching the predicate was found.
    case captured(UUID)
    /// Watch ended without finding a matching session.
    case noTrafficDetected
}

/// Watches the session store for sessions matching a caller-supplied predicate.
///
/// Used by macOS and iOS setup walkthroughs to confirm that traffic is routing
/// through JoesProxy. Each verify step supplies its own filter predicate so a
/// single service covers all source types:
///
/// ```swift
/// // macOS: match HTTP from Safari (loopback + Macintosh UA)
/// await verifier.watch(matching: { session in
///     TrafficSource.classify(
///         clientAddress: session.request.clientAddress,
///         userAgent: session.request.userAgent
///     ) == .mac
///     && session.request.host == "captive.apple.com"
/// }, timeoutNanoseconds: 15_000_000_000)
///
/// // iOS/tvOS: match any traffic from a physical device (non-loopback IP)
/// await verifier.watch(matching: { session in
///     TrafficSource.classify(
///         clientAddress: session.request.clientAddress,
///         userAgent: session.request.userAgent
///     ) == .device
/// }, timeoutNanoseconds: 60_000_000_000)
/// ```
///
/// Checking existing sessions before polling means a session captured just
/// before the watch starts is still caught (avoids the TOCTOU gap between
/// opening a URL and starting the watch).
@MainActor
final class TrafficWatchVerifier {
    typealias SessionPredicate = (SessionRecord) -> Bool

    private let sessionStore: any SessionStore
    private let logger = Logger(
        subsystem: "com.JoesProxyApp.TrafficWatch",
        category: "TrafficWatchVerifier"
    )

    init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Watches for a session matching `predicate`.
    ///
    /// Checks existing sessions first, then polls at 100ms intervals until a
    /// match appears or `timeoutNanoseconds` elapses. Respects cooperative
    /// Task cancellation — returns `.noTrafficDetected` if cancelled.
    ///
    /// - Parameters:
    ///   - predicate: Returns `true` for a session that counts as captured.
    ///   - timeoutNanoseconds: How long to poll before giving up.
    /// - Returns: `.captured(id)` on first match, `.noTrafficDetected` on timeout or cancel.
    func watch(
        matching predicate: @escaping SessionPredicate,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async -> TrafficWatchResult {
        if let existing = sessionStore.sessions.last(where: predicate) {
            logger.info("Traffic watch: matched existing session \(existing.id)")
            return .captured(existing.id)
        }

        let pollInterval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0

        while elapsed < timeoutNanoseconds {
            guard !Task.isCancelled else {
                logger.info("Traffic watch: cancelled after \(elapsed / 1_000_000)ms")
                return .noTrafficDetected
            }
            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval

            if let session = sessionStore.sessions.last(where: predicate) {
                logger.info("Traffic watch: matched session \(session.id) after \(elapsed / 1_000_000)ms")
                return .captured(session.id)
            }
        }

        logger.info("Traffic watch: timed out after \(elapsed / 1_000_000_000)s")
        return .noTrafficDetected
    }
}
