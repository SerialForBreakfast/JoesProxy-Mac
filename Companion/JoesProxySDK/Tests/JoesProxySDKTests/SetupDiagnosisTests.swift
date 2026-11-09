import Foundation
import Testing
@testable import JoesProxySDK

@Suite("Setup Diagnosis")
struct SetupDiagnosisTests {
    @Test func noHTTPReachabilityReturnsProxyNotFound() async {
        let probe = CertTrustProbe(
            httpProbe: StubHTTPProbe(result: .unreachable),
            httpsProbe: StubHTTPSProbe(result: .trusted(certificateExpiry: nil))
        )

        let status = await probe.run(proxyHost: "macbook.local", port: 9090)

        #expect(status == .proxyNotFound)
    }

    @Test func httpsConnectionFailureReturnsCertNotInstalled() async {
        let probe = CertTrustProbe(
            httpProbe: StubHTTPProbe(result: .reachable),
            httpsProbe: StubHTTPSProbe(result: .connectionFailed)
        )

        let status = await probe.run(proxyHost: "macbook.local", port: 9090)

        #expect(status == .proxyFoundCertNotInstalled)
    }

    @Test func httpsTrustFailureReturnsCertNotTrusted() async {
        let probe = CertTrustProbe(
            httpProbe: StubHTTPProbe(result: .reachable),
            httpsProbe: StubHTTPSProbe(result: .untrustedCertificate)
        )

        let status = await probe.run(proxyHost: "macbook.local", port: 9090)

        #expect(status == .proxyFoundCertNotTrusted)
    }

    @Test func trustedHTTPSReturnsReadyWithExpiry() async {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let probe = CertTrustProbe(
            httpProbe: StubHTTPProbe(result: .reachable),
            httpsProbe: StubHTTPSProbe(result: .trusted(certificateExpiry: expiry))
        )

        let status = await probe.run(proxyHost: "macbook.local", port: 9090)

        #expect(status == .ready(certExpiry: expiry))
    }

    @Test func invalidPortReturnsProxyNotFound() async {
        let probe = CertTrustProbe(
            httpProbe: StubHTTPProbe(result: .reachable),
            httpsProbe: StubHTTPSProbe(result: .trusted(certificateExpiry: nil))
        )

        let status = await probe.run(proxyHost: "macbook.local", port: 0)

        #expect(status == .proxyNotFound)
    }
}

private struct StubHTTPProbe: ProxyHTTPProbing {
    let result: ProxyHTTPProbeResult

    func probe(proxyHost: String, port: Int) async -> ProxyHTTPProbeResult {
        result
    }
}

private struct StubHTTPSProbe: ProxyHTTPSProbing {
    let result: ProxyHTTPSProbeResult

    func probe(proxyHost: String, port: Int) async -> ProxyHTTPSProbeResult {
        result
    }
}
