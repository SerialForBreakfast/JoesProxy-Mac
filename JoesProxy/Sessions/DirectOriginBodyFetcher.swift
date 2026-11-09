import Foundation

/// P3 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): on-demand body
/// recapture needs its own, larger ceiling than `CaptureBodyLimiter`'s 1MB live-capture cap — that
/// cap is exactly what a body-larger-than-1MB recapture exists to bypass. 20 MB is generous for a
/// real catalog/API response (the field session's body was ~500KB) while still bounded — an
/// on-demand, rare, explicit action, not a passive per-request cap applied to all live traffic.
enum SessionBodyRecaptureBudget {
    static let maxBodyBytes = 20 * 1_048_576
}

/// Result of a direct-to-origin body recapture — deliberately narrower than
/// `BookmarkExecutionResult`: callers backfilling a session's stored body need the bytes
/// themselves, not just a status code.
struct DirectOriginFetchResult: Sendable {
    let bodyData: Data
    let statusCode: Int?
    /// `true` when the real response body was larger than the caller's `maxBodyBytes` ceiling —
    /// `bodyData` holds exactly `maxBodyBytes` bytes in that case, not the full response.
    let bodyTruncatedAtCeiling: Bool
}

enum DirectOriginFetchError: LocalizedError {
    case invalidRequestURL
    case timedOut
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequestURL:
            return "The request URL could not be built from the captured request."
        case .timedOut:
            return "The direct request timed out before the origin server responded."
        case .networkFailure(let message):
            return message
        }
    }
}

protocol DirectOriginBodyFetching: AnyObject {
    /// Fetches a response body directly from the real origin server — deliberately bypassing the
    /// local proxy (and therefore `CaptureBodyLimiter`'s 1MB per-response capture cap) so an
    /// on-demand recapture can retrieve a body larger than ordinary live capture ever retains.
    /// Stops reading once `maxBodyBytes` is reached rather than buffering an unbounded response.
    ///
    /// - Parameter includeCredentials: When `false` (the default elsewhere in this codebase for
    ///   replay-style tools — see `MCPOpenWorldService`), strips Authorization/Cookie/API-key
    ///   headers before sending. A stripped request may get a different (e.g. 401) response than
    ///   the original — the same tradeoff `replay_request`/`execute_bookmark` already accept.
    func fetch(
        request: CapturedRequest,
        includeCredentials: Bool,
        maxBodyBytes: Int
    ) async throws -> DirectOriginFetchResult
}

final class URLSessionDirectOriginBodyFetcher: DirectOriginBodyFetching {
    func fetch(
        request captured: CapturedRequest,
        includeCredentials: Bool,
        maxBodyBytes: Int
    ) async throws -> DirectOriginFetchResult {
        guard let url = MediaDetector.absoluteURL(for: captured) else {
            throw DirectOriginFetchError.invalidRequestURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = captured.method
        request.httpBody = captured.bodyData

        for header in captured.headers {
            let lowercased = header.name.lowercased()
            if URLSessionBookmarkExecutor.transportExcludedHeaderNames.contains(lowercased) {
                continue
            }
            if !includeCredentials, URLSessionBookmarkExecutor.credentialHeaderNames.contains(lowercased) {
                continue
            }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        // Deliberately NOT `.ephemeral` with a `connectionProxyDictionary` — this must reach the
        // real origin directly, not loop back through this app's own proxy listener (which would
        // re-apply the same 1MB `CaptureBodyLimiter` cap this feature exists to bypass).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120

        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        do {
            let (byteStream, response) = try await session.bytes(for: request)
            var accumulated = Data()
            accumulated.reserveCapacity(min(maxBodyBytes, 1_048_576))
            var truncated = false
            for try await byte in byteStream {
                if accumulated.count >= maxBodyBytes {
                    truncated = true
                    break
                }
                accumulated.append(byte)
            }
            return DirectOriginFetchResult(
                bodyData: accumulated,
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                bodyTruncatedAtCeiling: truncated
            )
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw DirectOriginFetchError.timedOut
            default:
                let presentation = NetworkFailureClassifier.presentation(for: error)
                throw DirectOriginFetchError.networkFailure(presentation.userFacingMessage)
            }
        } catch {
            let presentation = NetworkFailureClassifier.presentation(for: error)
            throw DirectOriginFetchError.networkFailure(presentation.userFacingMessage)
        }
    }
}
