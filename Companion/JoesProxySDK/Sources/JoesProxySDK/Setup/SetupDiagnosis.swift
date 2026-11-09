import Foundation

public enum ProxySDKSetupStatus: Equatable, Sendable {
    case proxyNotFound
    case proxyFoundCertNotInstalled
    case proxyFoundCertNotTrusted
    case ready(certExpiry: Date?)
}

public protocol CertTrustProbing: Sendable {
    func run(proxyHost: String, port: Int) async -> ProxySDKSetupStatus
}

public struct CertTrustProbe: CertTrustProbing {
    private let httpProbe: any ProxyHTTPProbing
    private let httpsProbe: any ProxyHTTPSProbing

    public init(
        httpProbe: any ProxyHTTPProbing = URLSessionProxyHTTPProbe(),
        httpsProbe: any ProxyHTTPSProbing = URLSessionProxyHTTPSProbe()
    ) {
        self.httpProbe = httpProbe
        self.httpsProbe = httpsProbe
    }

    public func run(proxyHost: String, port: Int) async -> ProxySDKSetupStatus {
        guard port > 0, port <= 65_535 else {
            return .proxyNotFound
        }

        let httpResult = await httpProbe.probe(proxyHost: proxyHost, port: port)
        guard httpResult == .reachable else {
            return .proxyNotFound
        }

        switch await httpsProbe.probe(proxyHost: proxyHost, port: port) {
        case .trusted(let certificateExpiry):
            return .ready(certExpiry: certificateExpiry)
        case .untrustedCertificate:
            return .proxyFoundCertNotTrusted
        case .connectionFailed:
            return .proxyFoundCertNotInstalled
        }
    }
}

public protocol ProxyHTTPProbing: Sendable {
    func probe(proxyHost: String, port: Int) async -> ProxyHTTPProbeResult
}

public enum ProxyHTTPProbeResult: Equatable, Sendable {
    case reachable
    case unreachable
}

public protocol ProxyHTTPSProbing: Sendable {
    func probe(proxyHost: String, port: Int) async -> ProxyHTTPSProbeResult
}

public enum ProxyHTTPSProbeResult: Equatable, Sendable {
    case trusted(certificateExpiry: Date?)
    case untrustedCertificate
    case connectionFailed
}

public struct URLSessionProxyHTTPProbe: ProxyHTTPProbing {
    public init() {}

    public func probe(proxyHost: String, port: Int) async -> ProxyHTTPProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxyDictionary(host: proxyHost, port: port)
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3

        guard let url = URL(string: "http://captive.apple.com/") else {
            return .unreachable
        }

        do {
            let (_, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unreachable
            }
            return (200..<500).contains(httpResponse.statusCode) ? .reachable : .unreachable
        } catch {
            return .unreachable
        }
    }
}

public struct URLSessionProxyHTTPSProbe: ProxyHTTPSProbing {
    public init() {}

    public func probe(proxyHost: String, port: Int) async -> ProxyHTTPSProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxyDictionary(host: proxyHost, port: port)
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3

        guard let url = URL(string: "https://captive.apple.com/") else {
            return .connectionFailed
        }

        do {
            let (_, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .connectionFailed
            }
            return (200..<500).contains(httpResponse.statusCode) ? .trusted(certificateExpiry: nil) : .connectionFailed
        } catch {
            return classify(error)
        }
    }

    private func classify(_ error: Error) -> ProxyHTTPSProbeResult {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorSecureConnectionFailed:
                return .untrustedCertificate
            default:
                return .connectionFailed
            }
        }
        return .connectionFailed
    }
}

private func proxyDictionary(host: String, port: Int) -> [AnyHashable: Any] {
    [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: host,
        kCFNetworkProxiesHTTPPort as String: port,
        "HTTPSEnable": true,
        "HTTPSProxy": host,
        "HTTPSPort": port
    ]
}
