import Foundation

struct ReproReplayResult: Codable, Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    let expectedStatusCode: Int?
    let observedStatusCode: Int?
    let reproducedExpectedStatus: Bool?
    let summary: String
}

@MainActor
final class ReproReplayEngine {
    private let packageEngine: ReproPackageEngine
    private let bookmarkExecutor: any BookmarkExecuting

    init(
        packageEngine: ReproPackageEngine = ReproPackageEngine(),
        bookmarkExecutor: any BookmarkExecuting = URLSessionBookmarkExecutor()
    ) {
        self.packageEngine = packageEngine
        self.bookmarkExecutor = bookmarkExecutor
    }

    func replay(session: ReproSession, proxyPort: UInt16) async throws -> ReproReplayResult {
        guard let request = packageEngine.capturedRequest(for: session) else {
            throw ReproPackageError.noReplayableSessions
        }
        let bookmark = Bookmark(name: "Reproduction \(session.id)", request: request)
        let execution = try await bookmarkExecutor.execute(
            bookmark: bookmark,
            proxyPort: proxyPort,
            stripCredentials: true
        )
        let expected = session.expectedOutcome.statusCode
        let reproduced = expected.flatMap { expected in
            execution.statusCode.map { $0 == expected }
        }
        let summary: String
        if let expected, let observed = execution.statusCode {
            summary = reproduced == true
                ? "Observed the expected HTTP status \(expected)."
                : "Expected HTTP status \(expected), but observed \(observed)."
        } else if let observed = execution.statusCode {
            summary = "Replay completed with HTTP status \(observed); the package did not define a status expectation."
        } else {
            summary = "Replay completed, but no HTTP status was available for validation."
        }
        return ReproReplayResult(
            sessionID: session.id,
            startedAt: execution.startedAt,
            expectedStatusCode: expected,
            observedStatusCode: execution.statusCode,
            reproducedExpectedStatus: reproduced,
            summary: summary
        )
    }
}

