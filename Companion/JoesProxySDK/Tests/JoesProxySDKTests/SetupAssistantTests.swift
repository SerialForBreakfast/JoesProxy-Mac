import Foundation
import Testing
@testable import JoesProxySDK

@Suite("Setup Assistant", .serialized)
@MainActor
struct SetupAssistantTests {
    @Test func probeOnceMapsProxyNotFoundToConfigureProxyStep() async {
        let assistant = SetupAssistant(
            configuration: Self.configuration(),
            probe: SequenceCertTrustProbe(statuses: [.proxyNotFound])
        )

        let status = await assistant.probeOnce()

        #expect(status == .proxyNotFound)
        #expect(assistant.status == .proxyNotFound)
        #expect(assistant.step == .configureProxy)
    }

    @Test func probeOnceMapsCertInstallAndTrustSteps() async {
        let assistant = SetupAssistant(
            configuration: Self.configuration(),
            probe: SequenceCertTrustProbe(statuses: [.proxyFoundCertNotInstalled, .proxyFoundCertNotTrusted])
        )

        _ = await assistant.probeOnce()
        #expect(assistant.step == .installCertificate)

        _ = await assistant.probeOnce()
        #expect(assistant.step == .trustCertificate)
    }

    @Test func probeOnceMapsReadyStepAndPreservesExpiry() async {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let assistant = SetupAssistant(
            configuration: Self.configuration(),
            probe: SequenceCertTrustProbe(statuses: [.ready(certExpiry: expiry)])
        )

        _ = await assistant.probeOnce()

        #expect(assistant.status == .ready(certExpiry: expiry))
        #expect(assistant.step == .ready)
    }

    @Test func profileURLStringProvidesManualTVOSProfileURL() {
        let configuration = Self.configuration()

        #expect(configuration.profileURLString == "http://macbook.local:9090/profile")
    }

    @Test func readyWithNearExpiryPublishesCertificateWarning() async {
        let expiry = Date().addingTimeInterval(60)
        let assistant = SetupAssistant(
            configuration: Self.configuration(),
            probe: SequenceCertTrustProbe(statuses: [.ready(certExpiry: expiry)])
        )

        _ = await assistant.probeOnce()

        #expect(assistant.certificateWarning == .expiresSoon(expiry))
    }

    @Test func readyWithDistantExpiryDoesNotPublishCertificateWarning() async {
        let expiry = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let assistant = SetupAssistant(
            configuration: Self.configuration(),
            probe: SequenceCertTrustProbe(statuses: [.ready(certExpiry: expiry)])
        )

        _ = await assistant.probeOnce()

        #expect(assistant.certificateWarning == nil)
    }

    @Test func startRunsLoopUntilReadyAndStops() async {
        let probe = SequenceCertTrustProbe(statuses: [.proxyNotFound, .proxyFoundCertNotTrusted, .ready(certExpiry: nil)])
        let assistant = SetupAssistant(
            configuration: Self.configuration(probeIntervalNanoseconds: 0),
            probe: probe,
            sleep: { _ in }
        )

        assistant.start()
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(assistant.status == .ready(certExpiry: nil))
        #expect(assistant.step == .ready)
        #expect(!assistant.isRunning)
        #expect(await probe.requestCount == 3)
    }

    @Test func startIsIdempotentWhileLoopIsRunning() async {
        let gate = ProbeGate()
        let probe = GatedCertTrustProbe(status: .proxyNotFound, gate: gate)
        let assistant = SetupAssistant(
            configuration: Self.configuration(probeIntervalNanoseconds: 1_000_000_000),
            probe: probe,
            sleep: { _ in }
        )

        assistant.start()
        assistant.start()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(assistant.isRunning)
        #expect(await probe.requestCount == 1)

        await gate.open()
        assistant.stop()
        #expect(!assistant.isRunning)
    }

    @Test func stopCancelsProbeLoop() async {
        let probe = SequenceCertTrustProbe(statuses: [.proxyNotFound, .proxyFoundCertNotTrusted])
        let assistant = SetupAssistant(
            configuration: Self.configuration(probeIntervalNanoseconds: 1_000_000_000),
            probe: probe,
            sleep: { _ in }
        )

        assistant.start()
        try? await Task.sleep(nanoseconds: 20_000_000)
        assistant.stop()

        #expect(!assistant.isRunning)
        let requestCount = await probe.requestCount
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await probe.requestCount == requestCount)
    }

    private static func configuration(probeIntervalNanoseconds: UInt64 = 0) -> SetupAssistantConfiguration {
        SetupAssistantConfiguration(
            proxyHost: "macbook.local",
            proxyPort: 9090,
            profileURL: URL(string: "http://macbook.local:9090/profile"),
            probeIntervalNanoseconds: probeIntervalNanoseconds
        )
    }
}

private actor SequenceCertTrustProbe: CertTrustProbing {
    private var statuses: [ProxySDKSetupStatus]
    private(set) var requestCount = 0

    init(statuses: [ProxySDKSetupStatus]) {
        self.statuses = statuses
    }

    func run(proxyHost: String, port: Int) async -> ProxySDKSetupStatus {
        requestCount += 1
        guard statuses.count > 1 else {
            return statuses.first ?? .proxyNotFound
        }
        return statuses.removeFirst()
    }
}

private actor GatedCertTrustProbe: CertTrustProbing {
    private let status: ProxySDKSetupStatus
    private let gate: ProbeGate
    private(set) var requestCount = 0

    init(status: ProxySDKSetupStatus, gate: ProbeGate) {
        self.status = status
        self.gate = gate
    }

    func run(proxyHost: String, port: Int) async -> ProxySDKSetupStatus {
        requestCount += 1
        await gate.wait()
        return status
    }
}

private actor ProbeGate {
    private var isOpen = false

    func open() {
        isOpen = true
    }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
