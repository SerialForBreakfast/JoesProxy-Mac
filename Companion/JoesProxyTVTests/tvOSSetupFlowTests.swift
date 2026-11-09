import Foundation
import XCTest
@testable import JoesProxyTV

@MainActor
final class TVOSSetupFlowTests: XCTestCase {
    func testInitialStateStartsAtWelcomeAndPersistsManualHost() {
        let defaults = makeDefaults()
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: defaults
        )

        XCTAssertEqual(state.currentStep, .welcome)
        state.manualMacHost = "192.168.1.44"

        let reloaded = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: defaults
        )
        XCTAssertEqual(reloaded.manualMacHost, "192.168.1.44")
    }

    func testStepCompletionAdvancesAndPersistsConfirmedStep() {
        let defaults = makeDefaults()
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: defaults
        )

        state.markCurrentStepComplete()

        XCTAssertEqual(state.currentStep, .findMac)
        XCTAssertEqual(state.status(for: .welcome), .manualConfirmed)

        let reloaded = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: defaults
        )
        XCTAssertEqual(reloaded.status(for: .welcome), .manualConfirmed)
    }

    func testVerifyTrafficPingWithoutSDKEventsEndsNoTrafficObserved() async {
        URLProtocolStub.responses = [
            "http://captive.apple.com/hotspot-detect.html": 200
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let urlSession = URLSession(configuration: configuration)

        let defaults = makeDefaults()
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: defaults,
            urlSession: urlSession
        )
        state.trafficObservationTimeoutNanoseconds = 50_000_000
        state.trafficObservationPollNanoseconds = 10_000_000
        state.go(to: .verifyTraffic)

        await state.sendTrafficVerificationPing()

        XCTAssertEqual(state.currentStep, .verifyTraffic)
        XCTAssertEqual(state.trafficVerificationResult, .noTrafficObserved)
        XCTAssertNotEqual(state.status(for: .verifyTraffic), .passed)
    }

    @MainActor
    func testObserveTrafficClassifiesInspectedVerificationEvent() async throws {
        let verificationData = try verificationFixtureData(
            url: "http://captive.apple.com/hotspot-detect.html",
            method: "GET",
            redactionLevel: "queryRedacted",
            httpProtocol: "HTTP/1.1"
        )
        let transport = TVOSFixtureReplayProxyTransport(fixtureData: [verificationData])
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(transport: transport),
            userDefaults: makeDefaults()
        )
        state.trafficObservationTimeoutNanoseconds = 100_000_000
        state.trafficObservationPollNanoseconds = 10_000_000

        await state.observeTrafficFromMacSDK()

        XCTAssertEqual(state.trafficVerificationResult, .trafficInspected(host: "captive.apple.com"))
        XCTAssertEqual(state.status(for: .verifyTraffic), .passed)
    }

    func testGoToNextStepSkipsTroubleshooting() {
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: makeDefaults()
        )
        state.go(to: .trustCertificate)
        state.markCurrentStepComplete()

        XCTAssertEqual(state.currentStep, .verifyTraffic)
    }

    func testReachabilitySuccessMarksCheckStepPassed() async {
        let defaults = makeDefaults()
        let probe = MockSetupProbe(result: .reachable(
            baseURL: URL(string: "http://192.168.1.20:8765")!,
            profileURL: URL(string: "http://192.168.1.20:8765/profile")!
        ))
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(setupProbe: probe),
            userDefaults: defaults
        )
        state.manualMacHost = "192.168.1.20"

        await state.checkReachability()

        XCTAssertEqual(state.status(for: .checkReachability), .passed)
        XCTAssertEqual(state.profileURLText, "http://192.168.1.20:8765/profile")
    }

    func testReachabilityBlockedMapsToStepIssue() async {
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(setupProbe: MockSetupProbe(result: .blocked(.firewallLikelyBlocking))),
            userDefaults: makeDefaults()
        )
        state.manualMacHost = "192.168.1.20"

        await state.checkReachability()

        XCTAssertEqual(state.status(for: .checkReachability), .blocked(.firewallLikelyBlocking))
    }

    func testDiscoveryFailureLeavesManualFallbackMessage() async {
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(discoveryService: TVOSMockDiscoveryService(proxies: [])),
            userDefaults: makeDefaults()
        )

        await state.discoverAndConnect(source: "test")

        XCTAssertEqual(state.discoveredProxies, [])
        XCTAssertNil(state.selectedProxy)
        XCTAssertEqual(state.connectionState, .rejected(TVOSSetupIssue.macNotFound.title))
        XCTAssertEqual(
            state.discoveryStatusMessage,
            "No Mac was found with Bonjour. Confirm JoesProxy is running on the Mac, SDK connections are enabled, and both devices are on the same network. You can also enter the Mac IP address manually."
        )
    }

    func testDiscoverySuccessSelectsProxyAndStoresHost() async {
        let proxy = TVOSDiscoveredProxy.fixture
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(discoveryService: TVOSMockDiscoveryService(proxies: [proxy])),
            userDefaults: makeDefaults()
        )

        await state.discoverAndConnect(source: "test")

        XCTAssertEqual(state.discoveredProxies, [proxy])
        XCTAssertEqual(state.selectedProxy, proxy)
        XCTAssertEqual(state.manualMacHost, proxy.host)
        XCTAssertEqual(state.connectionState, .connected(proxy))
        XCTAssertEqual(
            state.discoveryStatusMessage,
            "Found \(proxy.name) at \(proxy.host). Connecting to SDK event channel."
        )
    }

    func testBonjourTrailingDotIsRemovedFromManualProfileURL() {
        let state = TVOSSetupPresentationState(
            sdkFacade: TVOSMockProxySDKClient(),
            userDefaults: makeDefaults()
        )

        state.manualMacHost = "TestMac.local."

        XCTAssertEqual(state.profileURLText, "http://TestMac.local:8765/profile")
    }

    func testDiscoveredProxyNormalizesFullyQualifiedBonjourHost() {
        let proxy = TVOSDiscoveredProxy(
            name: "JoesProxy on TestMac",
            host: "TestMac.local.",
            proxyPort: 9090,
            profilePort: 8765,
            sdkPort: 9091,
            profilePath: "profile"
        )

        XCTAssertEqual(proxy.host, "TestMac.local")
        XCTAssertEqual(proxy.profileURL?.absoluteString, "http://TestMac.local:8765/profile")
    }

    func testReachabilityProbeChecksRootAndProfile() async {
        URLProtocolStub.responses = [
            "http://10.0.0.2:8765": 200,
            "http://10.0.0.2:8765/profile": 200
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let probe = TVOSReachabilitySetupProbe(urlSession: URLSession(configuration: configuration))

        let result = await probe.probeProfileServer(host: "10.0.0.2", port: 8765, path: "profile")

        XCTAssertEqual(
            result,
            .reachable(
                baseURL: URL(string: "http://10.0.0.2:8765")!,
                profileURL: URL(string: "http://10.0.0.2:8765/profile")!
            )
        )
    }

    func testReachabilityProbeMapsMissingProfileToUnavailable() async {
        URLProtocolStub.responses = [
            "http://10.0.0.3:8765": 200,
            "http://10.0.0.3:8765/profile": 404
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let probe = TVOSReachabilitySetupProbe(urlSession: URLSession(configuration: configuration))

        let result = await probe.probeProfileServer(host: "10.0.0.3", port: 8765, path: "profile")

        XCTAssertEqual(result, .blocked(.profileServerUnavailable))
    }

    func testSDKFixturesDecodeThroughReplayTransport() async throws {
        let fixtureNames = [
            "handshake-ack-v1",
            "network-event-completed-v1",
            "annotation-instant-v1"
        ]
        let fixtureURLs = fixtureNames.map(fixtureURL)
        let transport = try TVOSFixtureReplayProxyTransport(fixtureURLs: fixtureURLs)

        let headers = await transport.collectedEvents()

        XCTAssertEqual(headers.map(\.type), ["handshakeAck", "networkEvent", "annotationEvent"])
    }

    func testAnnotationRecorderStoresOutboundDrafts() async {
        let sender = TVOSRecordingAnnotationSender()
        let draft = TVOSAnnotationDraft(
            kind: .profileInstalled,
            label: "Profile installed",
            metadata: ["step": "installProfile"]
        )

        await sender.record(draft)

        let recorded = await sender.recordedAnnotations()
        XCTAssertEqual(recorded, [draft])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TVOSSetupFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JoesProxyTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("SDKEventSchema")
            .appendingPathComponent(name)
            .appendingPathExtension("json")
    }

    private func verificationFixtureData(
        url: String,
        method: String,
        redactionLevel: String,
        httpProtocol: String
    ) throws -> Data {
        let envelope: [String: Any] = [
            "type": "networkEvent",
            "version": 1,
            "id": "00000000-0000-0000-0000-000000000201",
            "sentAt": "2026-06-28T17:00:01.300Z",
            "payload": [
                "id": "00000000-0000-0000-0000-000000000301",
                "sessionID": "00000000-0000-0000-0000-000000000401",
                "phase": "completed",
                "timestamp": "2026-06-28T17:00:01.250Z",
                "url": url,
                "redactionLevel": redactionLevel,
                "method": method,
                "statusCode": 200,
                "timing": [
                    "dns": NSNull(),
                    "tcp": NSNull(),
                    "tls": NSNull(),
                    "ttfb": 0.1,
                    "transfer": 0.0,
                    "total": 0.1
                ],
                "sizes": [
                    "requestBytes": 0,
                    "responseBytes": 128,
                    "compressedResponseBytes": NSNull()
                ],
                "connectionInfo": [
                    "httpProtocol": httpProtocol,
                    "isConnectionReused": false,
                    "cdnRegion": NSNull()
                ],
                "redirectCount": 0,
                "retryCount": 0,
                "cacheStatus": NSNull(),
                "certificateExpiry": NSNull(),
                "annotations": [] as [String],
                "sourceSDK": NSNull(),
                "lane": "api",
                "connectionID": NSNull(),
                "parentEventID": NSNull()
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}

private struct MockSetupProbe: TVOSProxySetupProbing {
    let result: TVOSReachabilityResult

    func probeProfileServer(host: String, port: Int, path: String) async -> TVOSReachabilityResult {
        result
    }
}

private final class URLProtocolStub: URLProtocol {
    static var responses: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let statusCode = Self.responses[url.absoluteString] ?? 500
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
