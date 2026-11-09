import CFNetwork
import Foundation

struct BookmarkExecutionResult: Sendable {
    let startedAt: Date
    let statusCode: Int?

    init(startedAt: Date, statusCode: Int? = nil) {
        self.startedAt = startedAt
        self.statusCode = statusCode
    }
}

enum BookmarkExecutionError: LocalizedError {
    case invalidRequestURL
    case invalidRequest(String)
    case timedOut
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequestURL:
            return "The bookmark request URL could not be built from the captured request."
        case .invalidRequest(let message):
            return message
        case .timedOut:
            return "The bookmark request timed out before the server responded."
        case .networkFailure(let message):
            return message
        }
    }
}

protocol BookmarkExecuting: AnyObject {
    /// Executes a bookmark request through the local proxy.
    ///
    /// - Parameter stripCredentials: When `true`, omits Authorization, Cookie, and related
    ///   credential headers. MCP open-world tools default to stripping; the UI keeps credentials.
    func execute(
        bookmark: Bookmark,
        proxyPort: UInt16,
        stripCredentials: Bool
    ) async throws -> BookmarkExecutionResult
}

extension BookmarkExecuting {
    /// Compatibility entry that preserves UI behavior (credentials forwarded).
    func execute(bookmark: Bookmark, proxyPort: UInt16) async throws -> BookmarkExecutionResult {
        try await execute(bookmark: bookmark, proxyPort: proxyPort, stripCredentials: false)
    }
}

final class URLSessionBookmarkExecutor: BookmarkExecuting {
    /// Header names always excluded from forwarded bookmark requests.
    static let transportExcludedHeaderNames: Set<String> = [
        "connection",
        "content-length",
        "host",
        "proxy-connection",
        "transfer-encoding"
    ]

    /// Credential headers stripped when `stripCredentials` is true (AH-5 open-world default).
    static let credentialHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "cookie2",
        "set-cookie",
        "x-api-key",
        "api-key"
    ]

    func execute(
        bookmark: Bookmark,
        proxyPort: UInt16,
        stripCredentials: Bool
    ) async throws -> BookmarkExecutionResult {
        if let validationMessage = BookmarkRequestEditing.validationMessage(for: bookmark.request) {
            throw BookmarkExecutionError.invalidRequest(validationMessage)
        }

        let preparedRequest = BookmarkRequestEditing.preparedRequest(forExecution: bookmark.request)

        guard let url = MediaDetector.absoluteURL(for: preparedRequest) else {
            throw BookmarkExecutionError.invalidRequestURL
        }

        let startedAt = Date()
        var request = URLRequest(url: url)
        request.httpMethod = preparedRequest.method
        request.httpBody = preparedRequest.bodyData

        for header in preparedRequest.headers {
            let lowercased = header.name.lowercased()
            if Self.transportExcludedHeaderNames.contains(lowercased) {
                continue
            }
            if stripCredentials, Self.credentialHeaderNames.contains(lowercased) {
                continue
            }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]

        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        do {
            let (_, response) = try await session.data(for: request)
            return BookmarkExecutionResult(
                startedAt: startedAt,
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw BookmarkExecutionError.timedOut
            default:
                let presentation = NetworkFailureClassifier.presentation(for: error)
                throw BookmarkExecutionError.networkFailure(presentation.userFacingMessage)
            }
        } catch {
            let presentation = NetworkFailureClassifier.presentation(for: error)
            throw BookmarkExecutionError.networkFailure(presentation.userFacingMessage)
        }
    }
}
