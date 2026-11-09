import Foundation

public protocol JoesProxyDiscovering: Sendable {
    @MainActor
    func discover(timeout: TimeInterval) async throws -> DiscoveredJoesProxyService
}

public struct BonjourTXTRecord: Equatable, Sendable {
    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public init(data: Data?) {
        guard let data else {
            values = [:]
            return
        }

        let dictionary = NetService.dictionary(fromTXTRecord: data)
        values = dictionary.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = String(data: entry.value, encoding: .utf8)
        }
    }

    public var sdkPort: Int? {
        values["sdkPort"].flatMap(Int.init)
    }

    public var profilePath: String? {
        values["profilePath"]
    }

    public var version: Int? {
        values["version"].flatMap(Int.init)
    }
}

public struct BonjourJoesProxyDiscovery: JoesProxyDiscovering {
    public init() {}

    @MainActor
    public func discover(timeout: TimeInterval = 2) async throws -> DiscoveredJoesProxyService {
        try await BonjourDiscoverySession(timeout: timeout).discover()
    }
}

@MainActor
private final class BonjourDiscoverySession: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let timeout: TimeInterval
    private let browser = NetServiceBrowser()
    private var continuation: CheckedContinuation<DiscoveredJoesProxyService, Error>?
    private var resolved = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
        super.init()
        browser.delegate = self
    }

    func discover() async throws -> DiscoveredJoesProxyService {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            browser.searchForServices(ofType: "_joesproxy._tcp.", inDomain: "local.")

            DispatchQueue.main.asyncAfter(deadline: .now() + max(self.timeout, 0)) { [weak self] in
                self?.finish(.failure(ProxySDKError.discoveryTimedOut))
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !resolved else {
            return
        }
        resolved = true
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = BonjourTXTRecord(data: sender.txtRecordData())
        guard let host = sender.hostName else {
            finish(.failure(ProxySDKError.serviceResolutionFailed))
            return
        }

        finish(
            .success(
                DiscoveredJoesProxyService(
                    name: sender.name,
                    host: host,
                    port: sender.port,
                    sdkPort: txt.sdkPort,
                    profilePath: txt.profilePath,
                    version: txt.version
                )
            )
        )
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(ProxySDKError.serviceResolutionFailed))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(.failure(ProxySDKError.serviceResolutionFailed))
    }

    private func finish(_ result: Result<DiscoveredJoesProxyService, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        browser.stop()

        switch result {
        case .success(let service):
            continuation.resume(returning: service)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
