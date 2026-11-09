//
//  ScreenshotDemoSessions.swift
//  JoesProxy
//
//  Static demo sessions for screenshot capture. Used when the app is launched
//  with --screenshot-demo so Fastlane can capture the UI without running real
//  network requests.
//

import Foundation

enum ScreenshotDemoSessions {

    /// Launch argument that enables pre-populated demo sessions for screenshot capture.
    static let launchArgument = LaunchArgument.screenshotDemo

    enum BrowserModeOverride: String {
        case table
        case explorer
        case timeline
    }

    /// Returns true when the app was launched with --screenshot-demo.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var browserModeOverride: BrowserModeOverride? {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix(LaunchArgument.screenshotBrowserModePrefix) else {
                continue
            }

            let rawValue = String(argument.dropFirst(LaunchArgument.screenshotBrowserModePrefix.count))
            return BrowserModeOverride(rawValue: rawValue)
        }

        return nil
    }

    static var textSizeOverride: AppTextSize? {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix(LaunchArgument.screenshotTextSizePrefix) else {
                continue
            }

            let rawValue = String(argument.dropFirst(LaunchArgument.screenshotTextSizePrefix.count))
            return AppTextSize(rawValue: rawValue)
        }

        return nil
    }

    static var sessionCountOverride: Int? {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix(LaunchArgument.screenshotDemoSessionCountPrefix) else {
                continue
            }

            let rawValue = String(argument.dropFirst(LaunchArgument.screenshotDemoSessionCountPrefix.count))
            guard let count = Int(rawValue), count > 0 else {
                return nil
            }
            return count
        }

        return nil
    }

    /// Pre-built session records with varied domains, methods, and status codes.
    /// Used to populate the session list for screenshot capture.
    static func makeDemoSessions(count: Int? = nil) -> [SessionRecord] {
        let resolvedCount = max(count ?? sessionCountOverride ?? 4, 1)
        guard resolvedCount > 4 else {
            return Array(makeBaseDemoSessions().prefix(resolvedCount))
        }

        return makePerformanceDemoSessions(count: resolvedCount)
    }

    private static func makeBaseDemoSessions() -> [SessionRecord] {
        let now = Date()
        let oneSecond: TimeInterval = 1.0

        return [
            SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .https,
                    inspectionKind: .interceptedTLS,
                    host: "catalog.example.com",
                    port: 443,
                    path: "/users/demo",
                    headers: [
                        HTTPHeaderField(name: "Accept", value: "application/json"),
                        HTTPHeaderField(name: "User-Agent", value: Bundle.main.joesProxyUserAgentProductToken)
                    ],
                    bodyData: nil,
                    bodySize: nil
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [
                        HTTPHeaderField(name: "Content-Type", value: "application/json"),
                        HTTPHeaderField(name: "X-Demo-Request-Id", value: "demo-request-001")
                    ],
                    bodyData: "{\"login\":\"demo\"}".data(using: .utf8),
                    bodySize: 16
                ),
                state: .completed,
                timing: SessionTiming(startedAt: now.addingTimeInterval(-3 * oneSecond), completedAt: now.addingTimeInterval(-2.9 * oneSecond))
            ),
            SessionRecord(
                request: CapturedRequest(
                    method: "POST",
                    scheme: .https,
                    inspectionKind: .interceptedTLS,
                    host: "echo.example.com",
                    port: 443,
                    path: "/post",
                    headers: [
                        HTTPHeaderField(name: "Content-Type", value: "application/json"),
                        HTTPHeaderField(name: "Accept", value: "application/json")
                    ],
                    bodyData: "{\"test\":\"screenshot\"}".data(using: .utf8),
                    bodySize: 22
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [
                        HTTPHeaderField(name: "Content-Type", value: "application/json")
                    ],
                    bodyData: "{\"json\":{\"test\":\"screenshot\"}}".data(using: .utf8),
                    bodySize: 28
                ),
                state: .completed,
                timing: SessionTiming(startedAt: now.addingTimeInterval(-2 * oneSecond), completedAt: now.addingTimeInterval(-1.95 * oneSecond))
            ),
            SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .https,
                    inspectionKind: .tunneledTLS,
                    host: "example.com",
                    port: 443,
                    path: "example.com:443",
                    headers: [
                        HTTPHeaderField(name: "User-Agent", value: Bundle.main.joesProxyUserAgentProductToken)
                    ],
                    bodyData: nil,
                    bodySize: nil
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [
                        HTTPHeaderField(name: "Connection", value: "close")
                    ],
                    bodyData: nil,
                    bodySize: nil
                ),
                state: .completed,
                timing: SessionTiming(startedAt: now.addingTimeInterval(-1 * oneSecond), completedAt: now)
            ),
            SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .https,
                    inspectionKind: .interceptedTLS,
                    host: "api.example.com",
                    port: 443,
                    path: "/v1/users",
                    headers: [
                        HTTPHeaderField(name: "Authorization", value: "Bearer ***"),
                        HTTPHeaderField(name: "Accept", value: "application/json")
                    ],
                    bodyData: nil,
                    bodySize: nil
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [
                        HTTPHeaderField(name: "Content-Type", value: "application/json")
                    ],
                    bodyData: "{\"users\":[]}".data(using: .utf8),
                    bodySize: 12
                ),
                state: .completed,
                timing: SessionTiming(startedAt: now.addingTimeInterval(-0.5 * oneSecond), completedAt: now)
            )
        ]
    }

    private static func makePerformanceDemoSessions(count: Int) -> [SessionRecord] {
        let hosts = [
            isEnabled ? "catalog.example.com" : "api.github.com",
            isEnabled ? "echo.example.com" : "httpbin.org",
            "example.com",
            "api.example.com",
            "media.example.com",
            "video.cdn.example.net",
            "auth.example.com",
            "images.example.net"
        ]
        let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "CONNECT"]
        let statuses = [200, 201, 204, 301, 302, 400, 401, 403, 404, 429, 500, 503]
        let schemes: [SessionScheme] = [.http, .https]
        let inspections: [SessionInspectionKind] = [.plain, .interceptedTLS, .tunneledTLS]
        let now = Date()

        return (0..<count).map { index in
            let host = hosts[index % hosts.count]
            let method = methods[index % methods.count]
            let scheme = schemes[index % schemes.count]
            let inspectionKind = inspections[index % inspections.count]
            let statusCode = statuses[index % statuses.count]
            let startedAt = now.addingTimeInterval(TimeInterval(-count + index))
            let path = syntheticPath(for: index, method: method)
            let bodyText = bodyText(for: index, host: host, method: method)
            let bodyData = inspectionKind == .tunneledTLS ? nil : bodyText.data(using: .utf8)

            return SessionRecord(
                request: CapturedRequest(
                    method: method,
                    scheme: scheme,
                    inspectionKind: inspectionKind,
                    host: host,
                    port: scheme == .https ? 443 : 80,
                    path: inspectionKind == .tunneledTLS ? "\(host):443" : path,
                    headers: [
                        HTTPHeaderField(name: "Accept", value: "application/json"),
                        HTTPHeaderField(name: "User-Agent", value: Bundle.main.joesProxyUserAgentProductToken),
                        HTTPHeaderField(name: "X-Demo-Index", value: String(index))
                    ],
                    bodyData: method == "GET" || method == "CONNECT" ? nil : bodyData,
                    bodySize: method == "GET" || method == "CONNECT" ? nil : bodyData?.count
                ),
                response: CapturedResponse(
                    statusCode: statusCode,
                    headers: [
                        HTTPHeaderField(name: "Content-Type", value: contentType(for: index)),
                        HTTPHeaderField(name: "Cache-Control", value: index.isMultiple(of: 2) ? "no-cache" : "max-age=60")
                    ],
                    bodyData: bodyData,
                    bodySize: bodyData?.count
                ),
                state: statusCode >= 400 ? .failed : .completed,
                timing: SessionTiming(
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.03 + Double(index % 7) * 0.01)
                ),
                failure: statusCode >= 400 ? SessionFailure(message: "Synthetic failure \(statusCode)") : nil
            )
        }
    }

    private static func syntheticPath(for index: Int, method: String) -> String {
        switch index % 5 {
        case 0:
            return "/v1/users/\(index % 120)/profile"
        case 1:
            return "/v2/projects/\(index % 40)/builds/\(1000 + index)"
        case 2:
            return "/assets/\(index % 12)/thumbnail-\(index % 200).jpg"
        case 3:
            return "/stream/\(index % 8)/segment-\(index % 250).m4s"
        default:
            return method == "CONNECT" ? "example.com:443" : "/graphql?op=query\(index % 25)"
        }
    }

    private static func contentType(for index: Int) -> String {
        switch index % 5 {
        case 0:
            return "application/json"
        case 1:
            return "text/plain"
        case 2:
            return "image/jpeg"
        case 3:
            return "video/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private static func bodyText(for index: Int, host: String, method: String) -> String {
        "{\"index\":\(index),\"host\":\"\(host)\",\"method\":\"\(method)\"}"
    }

    /// Creates a session store pre-populated with demo sessions.
    static func makePreSeededSessionStore(count: Int? = nil) -> InMemorySessionStore {
        let store = InMemorySessionStore()
        for session in makeDemoSessions(count: count) {
            store.append(session)
        }
        return store
    }
}
