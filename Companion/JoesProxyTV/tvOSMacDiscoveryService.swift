import Foundation
import OSLog

private let tvOSReachabilityLogger = Logger(subsystem: "com.ShowBlender.JoesProxyTV", category: "Reachability")

/// Reachability probe for the Mac profile server used by the Apple TV setup flow.
struct TVOSReachabilitySetupProbe: TVOSProxySetupProbing {
    private let urlSession: URLSession
    private let timeoutSeconds: TimeInterval

    init(
        urlSession: URLSession = .shared,
        timeoutSeconds: TimeInterval = 5
    ) {
        self.urlSession = urlSession
        self.timeoutSeconds = timeoutSeconds
    }

    func probeProfileServer(host: String, port: Int = 8765, path: String = "profile") async -> TVOSReachabilityResult {
        let trimmedHost = TVOSDiscoveredProxy.normalizedHost(host)
        guard !trimmedHost.isEmpty,
              let baseURL = URL(string: "http://\(trimmedHost):\(port)") else {
            tvOSReachabilityLogger.warning("Profile probe rejected invalid host hostPresent=\(!trimmedHost.isEmpty, privacy: .public) port=\(port, privacy: .public)")
            return .blocked(.invalidMacHost)
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let profileURL = baseURL.appendingPathComponent(normalizedPath.isEmpty ? "profile" : normalizedPath)
        tvOSReachabilityLogger.info(
            "Profile probe started host=\(trimmedHost, privacy: .public) port=\(port, privacy: .public) profilePath=\(profileURL.path, privacy: .public)"
        )

        do {
            let rootStatus = try await statusCode(for: baseURL)
            tvOSReachabilityLogger.info("Profile probe root status=\(rootStatus, privacy: .public) url=\(baseURL.absoluteString, privacy: .public)")
            guard (200..<500).contains(rootStatus) else {
                tvOSReachabilityLogger.warning("Profile probe root unavailable status=\(rootStatus, privacy: .public)")
                return .blocked(.profileServerUnavailable)
            }

            let profileStatus = try await statusCode(for: profileURL)
            tvOSReachabilityLogger.info("Profile probe profile status=\(profileStatus, privacy: .public) url=\(profileURL.absoluteString, privacy: .public)")
            guard (200..<400).contains(profileStatus) else {
                tvOSReachabilityLogger.warning("Profile probe profile unavailable status=\(profileStatus, privacy: .public)")
                return .blocked(.profileServerUnavailable)
            }

            tvOSReachabilityLogger.info("Profile probe reachable baseURL=\(baseURL.absoluteString, privacy: .public) profileURL=\(profileURL.absoluteString, privacy: .public)")
            return .reachable(baseURL: baseURL, profileURL: profileURL)
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                tvOSReachabilityLogger.warning("Profile probe URL error code=\((error as NSError).code, privacy: .public) description=\(error.localizedDescription, privacy: .public)")
                return .blocked(.firewallLikelyBlocking)
            }

            tvOSReachabilityLogger.error("Profile probe failed error=\(error.localizedDescription, privacy: .public)")
            return .blocked(.differentNetworkLikely)
        }
    }

    private func statusCode(for url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        let (_, response) = try await urlSession.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
