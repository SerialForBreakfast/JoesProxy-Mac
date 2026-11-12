import Combine
import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import JoesProxy

final class LoopbackDestinationPolicyTests: XCTestCase {

    private func makeIsolatedConfig() throws -> (config: UserDefaultsAppConfiguration, cleanup: () -> Void) {
        let suiteName = "LoopbackDestinationPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Unable to create isolated UserDefaults suite")
        }
        return (
            UserDefaultsAppConfiguration(userDefaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func makeRequest(
        method: String = "GET",
        scheme: SessionScheme = .http,
        host: String = "api.example.com",
        port: Int = 80,
        path: String = "/v1/feed",
        headers: [HTTPHeaderField] = []
    ) -> CapturedRequest {
        CapturedRequest(
            method: method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )
    }

    // MARK: - Address Classification & Normalization

    func testIPv4MappedIPv6UnwrapsAndMatchesIPv4Classification() throws {
        let mappedLoopbackDotted = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("::ffff:127.0.0.1"))
        let mappedLoopbackHex = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("[::ffff:7f00:1]"))
        let mappedLoopbackOther = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("::ffff:127.0.0.2"))
        let mappedLinkLocal = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("::ffff:169.254.169.254"))
        let mappedPublic = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("::ffff:93.184.216.34"))

        XCTAssertEqual(LoopbackAddressInspector.classify(mappedLoopbackDotted), .loopback)
        XCTAssertEqual(LoopbackAddressInspector.classify(mappedLoopbackHex), .loopback)
        XCTAssertEqual(LoopbackAddressInspector.classify(mappedLoopbackOther), .loopback)
        XCTAssertEqual(LoopbackAddressInspector.classify(mappedLinkLocal), .unspecifiedOrLinkLocal)
        XCTAssertEqual(LoopbackAddressInspector.classify(mappedPublic), .external)
    }

    func testRejectsObfuscatedNumericAndMalformedHosts() {
        let disallowed = [
            "2130706433",       // decimal integer 127.0.0.1
            "0x7f000001",       // hex integer
            "127.1",            // short dotted IPv4
            "0177.0.0.1",       // octal leading-zero octet
            "127.0.0.1.",       // numeric literal with trailing dot
            "[127.0.0.1]",      // IPv4 in brackets
            "[::1",             // unclosed bracket
            "::1]",             // unmatched bracket
            "localhost:8080",   // port smuggled in host
            "user@127.0.0.1",   // userinfo in host
            "127.0.0.1%lo0",    // scope ID smuggling
            ""                  // empty host
        ]
        let policy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [8080])
        for host in disallowed {
            XCTAssertThrowsError(
                try LoopbackAddressInspector.validateStaticDestination(
                    host: host,
                    port: 8080,
                    scheme: .http,
                    allowLoopbackDestination: true,
                    policy: policy,
                    reservedRegistry: ReservedListenerRegistry()
                ),
                "Expected host '\(host)' to be rejected"
            )
        }
    }

    func testNormalizesBracketedIPv6AndTrailingDotLocalhost() throws {
        let policy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [3000])
        let registry = ReservedListenerRegistry()

        let v6 = try LoopbackAddressInspector.validateStaticDestination(
            host: "[::1]",
            port: 3000,
            scheme: .http,
            allowLoopbackDestination: true,
            policy: policy,
            reservedRegistry: registry
        )
        XCTAssertEqual(v6.normalizedHost, "::1")
        XCTAssertTrue(v6.isStaticLoopback)

        let trailingLocalhost = try LoopbackAddressInspector.validateStaticDestination(
            host: "LOCALHOST.",
            port: 3000,
            scheme: .http,
            allowLoopbackDestination: true,
            policy: policy,
            reservedRegistry: registry
        )
        XCTAssertEqual(trailingLocalhost.normalizedHost, "localhost")
        XCTAssertTrue(trailingLocalhost.isStaticLoopback)
    }

    // MARK: - Policy, Intent, Reserved Listeners, Single-Shot DNS

    func testEnforcesGlobalPermissionExplicitRuleIntentAndAuthorizedPorts() {
        let registry = ReservedListenerRegistry()

        assertPolicyDenied(.permissionDisabled) {
            try LoopbackAddressInspector.validateStaticDestination(
                host: "127.0.0.1",
                port: 3000,
                scheme: .http,
                allowLoopbackDestination: true,
                policy: .disabled,
                reservedRegistry: registry
            )
        }

        let enabledPolicy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [3000])
        assertPolicyDenied(.explicitRuleIntentRequired) {
            try LoopbackAddressInspector.validateStaticDestination(
                host: "127.0.0.1",
                port: 3000,
                scheme: .http,
                allowLoopbackDestination: false,
                policy: enabledPolicy,
                reservedRegistry: registry
            )
        }

        assertPolicyDenied(.portNotAuthorized) {
            try LoopbackAddressInspector.validateStaticDestination(
                host: "::ffff:127.0.0.1",
                port: 4000,
                scheme: .http,
                allowLoopbackDestination: true,
                policy: enabledPolicy,
                reservedRegistry: registry
            )
        }
    }

    func testReservedListenerRejectsLoopbackAndLocalInterfaceIPs() throws {
        let registry = ReservedListenerRegistry()
        let token = registry.reserve(owner: "ProxyServer", port: 8888, boundHost: nil)
        defer { registry.release(token) }

        let policy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [8888])
        assertPolicyDenied(.reservedDestination) {
            try LoopbackAddressInspector.validateStaticDestination(
                host: "127.0.0.1",
                port: 8888,
                scheme: .http,
                allowLoopbackDestination: true,
                policy: policy,
                reservedRegistry: registry
            )
        }

        if let localIF = ReservedListenerRegistry.localInterfaceAddresses().first(where: {
            LoopbackAddressInspector.classify($0) != .unspecifiedOrLinkLocal
        }) {
            assertPolicyDenied(.reservedDestination) {
                try LoopbackAddressInspector.resolveAndValidate(
                    destinationHost: localIF.canonicalIPString,
                    port: 8888,
                    scheme: .http,
                    isMapRemote: true,
                    allowLoopbackDestination: true,
                    preserveHostHeader: false,
                    policy: policy,
                    reservedRegistry: registry
                )
            }
        }
    }

    func testSingleShotDNSRejectsHiddenLoopbackLinkLocalAndMixedResolutions() throws {
        let registry = ReservedListenerRegistry()
        let v4Loopback = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("127.0.0.1"))
        let v4External = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("93.184.216.34"))
        let v4LinkLocal = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("169.254.169.254"))

        assertPolicyDenied(.permissionDisabled) {
            try LoopbackAddressInspector.resolveAndValidate(
                destinationHost: "sneaky-rebind.example.test",
                port: 8080,
                scheme: .http,
                isMapRemote: true,
                allowLoopbackDestination: false,
                preserveHostHeader: false,
                policy: .disabled,
                reservedRegistry: registry,
                resolver: { _, _ in [v4Loopback] }
            )
        }

        let enabledPolicy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [8080])
        assertPolicyDenied(.mixedResolutionRejected) {
            try LoopbackAddressInspector.resolveAndValidate(
                destinationHost: "mixed.example.test",
                port: 8080,
                scheme: .http,
                isMapRemote: true,
                allowLoopbackDestination: true,
                preserveHostHeader: false,
                policy: enabledPolicy,
                reservedRegistry: registry,
                resolver: { _, _ in [v4External, v4Loopback] }
            )
        }

        assertPolicyDenied(.addressForbidden) {
            try LoopbackAddressInspector.resolveAndValidate(
                destinationHost: "metadata.example.test",
                port: 8080,
                scheme: .http,
                isMapRemote: true,
                allowLoopbackDestination: true,
                preserveHostHeader: false,
                policy: enabledPolicy,
                reservedRegistry: registry,
                resolver: { _, _ in [v4LinkLocal] }
            )
        }

        assertPolicyDenied(.resolutionFailed) {
            try LoopbackAddressInspector.resolveAndValidate(
                destinationHost: "nxdomain.example.test",
                port: 8080,
                scheme: .http,
                isMapRemote: true,
                allowLoopbackDestination: true,
                preserveHostHeader: false,
                policy: enabledPolicy,
                reservedRegistry: registry,
                resolver: { host, _ in
                    throw MapRemoteValidationError.policyDenied(.resolutionFailed, "NXDOMAIN \(host)")
                }
            )
        }
    }

    // MARK: - Host Authority & TLS SNI Separation

    func testCanonicalHostAuthorityAndPreserveHostSeparation() throws {
        XCTAssertEqual(LoopbackAddressInspector.canonicalHostAuthority(host: "::1", port: 80, scheme: .http), "[::1]")
        XCTAssertEqual(LoopbackAddressInspector.canonicalHostAuthority(host: "[::1]", port: 8080, scheme: .http), "[::1]:8080")
        XCTAssertEqual(LoopbackAddressInspector.canonicalHostAuthority(host: "127.0.0.1", port: 443, scheme: .http), "127.0.0.1:443")
        XCTAssertEqual(LoopbackAddressInspector.canonicalHostAuthority(host: "127.0.0.1", port: 80, scheme: .https), "127.0.0.1:80")
        XCTAssertEqual(LoopbackAddressInspector.canonicalHostAuthority(host: "dev.example.test.", port: 443, scheme: .https), "dev.example.test")

        let policy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [8443])
        let registry = ReservedListenerRegistry()
        let localIP = try XCTUnwrap(LoopbackAddressInspector.parseLiteralIP("127.0.0.1"))

        let preserved = try LoopbackAddressInspector.resolveAndValidate(
            destinationHost: "localhost",
            port: 8443,
            scheme: .https,
            incomingHeaders: [HTTPHeaderField(name: "Host", value: "api.prod.example.com")],
            originalRequestHost: "api.prod.example.com",
            originalRequestPort: 443,
            originalRequestScheme: .https,
            isMapRemote: true,
            allowLoopbackDestination: true,
            preserveHostHeader: true,
            policy: policy,
            reservedRegistry: registry,
            resolver: { _, _ in [localIP] }
        )
        XCTAssertEqual(preserved.httpHostHeaderValue, "api.prod.example.com")
        XCTAssertEqual(preserved.tlsServerName, "localhost")

        let literalPreserved = try LoopbackAddressInspector.resolveAndValidate(
            destinationHost: "127.0.0.1",
            port: 8443,
            scheme: .https,
            incomingHeaders: [HTTPHeaderField(name: "Host", value: "api.prod.example.com")],
            originalRequestHost: "api.prod.example.com",
            originalRequestPort: 443,
            originalRequestScheme: .https,
            isMapRemote: true,
            allowLoopbackDestination: true,
            preserveHostHeader: true,
            policy: policy,
            reservedRegistry: registry
        )
        XCTAssertEqual(literalPreserved.httpHostHeaderValue, "api.prod.example.com")
        XCTAssertNil(literalPreserved.tlsServerName)

        let nonDefaultPreserved = try LoopbackAddressInspector.resolveAndValidate(
            destinationHost: "127.0.0.1",
            port: 8443,
            scheme: .http,
            incomingHeaders: [HTTPHeaderField(name: "Host", value: "api.prod.example.com:9443")],
            originalRequestHost: "api.prod.example.com",
            originalRequestPort: 9443,
            originalRequestScheme: .http,
            isMapRemote: true,
            allowLoopbackDestination: true,
            preserveHostHeader: true,
            policy: policy,
            reservedRegistry: registry
        )
        XCTAssertEqual(nonDefaultPreserved.httpHostHeaderValue, "api.prod.example.com:9443")

        let ipv6NonDefaultPreserved = try LoopbackAddressInspector.resolveAndValidate(
            destinationHost: "127.0.0.1",
            port: 8443,
            scheme: .http,
            incomingHeaders: [HTTPHeaderField(name: "Host", value: "[0:0::1]:8443")],
            originalRequestHost: "::1",
            originalRequestPort: 8443,
            originalRequestScheme: .http,
            isMapRemote: true,
            allowLoopbackDestination: true,
            preserveHostHeader: true,
            policy: policy,
            reservedRegistry: registry
        )
        XCTAssertEqual(ipv6NonDefaultPreserved.httpHostHeaderValue, "[::1]:8443")

        // Reject conflicting duplicate Host headers, identical duplicate Host headers, and
        // Host headers that disagree with the matched request's host or port.
        for badHeaders in [
            [
                HTTPHeaderField(name: "Host", value: "a.example.com"),
                HTTPHeaderField(name: "Host", value: "b.example.com")
            ],
            [
                HTTPHeaderField(name: "Host", value: "api.prod.example.com"),
                HTTPHeaderField(name: "Host", value: "api.prod.example.com")
            ],
            [HTTPHeaderField(name: "Host", value: "evil.example.com")],
            [HTTPHeaderField(name: "Host", value: "api.prod.example.com:9999")]
        ] {
            assertPolicyDenied(.invalidOriginalHost) {
                try LoopbackAddressInspector.resolveAndValidate(
                    destinationHost: "127.0.0.1",
                    port: 8443,
                    scheme: .http,
                    incomingHeaders: badHeaders,
                    originalRequestHost: "api.prod.example.com",
                    originalRequestPort: 443,
                    originalRequestScheme: .https,
                    isMapRemote: true,
                    allowLoopbackDestination: true,
                    preserveHostHeader: true,
                    policy: policy,
                    reservedRegistry: registry
                )
            }
        }
    }

    // MARK: - Store Fail-Closed & Revocation Persistence

    func testStoreReturnsDeniedDecisionInsteadOfFallingThroughUpstreamAndRevokesPersistently() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/feed",
            headers: [HTTPHeaderField(name: "Host", value: "api.example.com")]
        )
        let rule = try await store.addMapRemoteRule(
            from: request,
            label: "Local Backend",
            remoteHost: "127.0.0.1",
            remotePort: 3000,
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: true
        )
        XCTAssertEqual(rule.allowLoopbackDestination, true)
        XCTAssertEqual(rule.preserveHostHeader, true)

        let deniedDecision = try await store.ruleDecision(for: request, loopbackPolicy: .disabled)
        guard case .deniedMapRemote(let deniedID, let reason, _) = deniedDecision else {
            return XCTFail("Expected .deniedMapRemote, got \(deniedDecision)")
        }
        XCTAssertEqual(deniedID, rule.id)
        XCTAssertEqual(reason, MapRemoteDenialReason.permissionDisabled)

        let allowedPolicy = LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [3000])
        let allowedDecision = try await store.ruleDecision(for: request, loopbackPolicy: allowedPolicy)
        guard case .mapRemote(_, let host, let port, let scheme, _, let allowLoop, let preserveHost) = allowedDecision else {
            return XCTFail("Expected .mapRemote, got \(allowedDecision)")
        }
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(port, 3000)
        XCTAssertEqual(scheme, SessionScheme.http)
        XCTAssertTrue(allowLoop)
        XCTAssertTrue(preserveHost)

        let changed = await store.disableLoopbackMapRemoteRules(forRemovedPorts: nil)
        XCTAssertTrue(changed)
        let persisted = try await store.persistedData()
        let reloaded = ResponseOverrideStore()
        try await reloaded.loadPersistedData(persisted, loopbackPolicy: allowedPolicy)
        let afterRestore = try await reloaded.ruleDecision(for: request, loopbackPolicy: allowedPolicy)
        if case .noMatch = afterRestore {
            // Expected
        } else {
            XCTFail("Revoked rule must not silently resume on restore or re-enable, got \(afterRestore)")
        }
    }

    @MainActor
    func testSettingsViewModelRevocationDisablesPersistedLoopbackRuleImmediately() async throws {
        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }

        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [3000, 4000]

        let store = ResponseOverrideStore()
        let req = makeRequest(scheme: .http, host: "api.example.test", port: 80, path: "/v1/ping")
        let rule = try await store.addMapRemoteRule(
            from: req, label: "Local",
            remoteHost: "127.0.0.1", remotePort: 3000, remoteScheme: .http,
            allowLoopbackDestination: true
        )
        config.responseOverridesData = try await store.persistedData()

        let runtime = StubProxyRuntime()
        let viewModel = SettingsViewModel(configuration: config, proxyRuntime: runtime, responseOverrideStore: store)
        XCTAssertTrue(viewModel.isLoopbackMapRemoteEnabled)
        XCTAssertEqual(viewModel.authorizedLoopbackPorts, [3000, 4000])

        viewModel.removeAuthorizedLoopbackPort(3000)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(config.authorizedLoopbackMapRemotePorts, [4000])
        let updatedRule = await store.rule(id: rule.id)
        XCTAssertEqual(updatedRule?.isEnabled, false)
    }

    // MARK: - Live End-to-End Proxy Forwarding, Host Preservation, Loop 508, and Revocation

    @MainActor
    func testEndToEndProxyLoopbackRemappingHostPreservationAndRevocation() async throws {
        let localBackend = try LocalEchoHTTPServer(holdStreamOnPath: "/stream")
        try await localBackend.start()
        defer { Task { await localBackend.stop() } }

        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }
        config.isLoopbackMapRemoteEnabled = false
        config.authorizedLoopbackMapRemotePorts = []

        let store = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: sessionStore)
        let proxy = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: .passThrough,
            configuration: config,
            sessionRecorder: recorder,
            responseOverrideStore: store
        )
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let targetReq = makeRequest(method: "GET", scheme: .http, host: "backend.example.invalid", port: 80, path: "/items")
        let postReq = makeRequest(method: "POST", scheme: .http, host: "backend.example.invalid", port: 80, path: "/items")

        _ = try await store.addMapRemoteRule(
            from: targetReq,
            label: "GET Local",
            matchMode: .pathPrefix,
            matchPath: "/",
            remoteHost: "127.0.0.1",
            remotePort: Int(localBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: true
        )
        _ = try await store.addMapRemoteRule(
            from: postReq,
            label: "POST Local",
            matchMode: .pathPrefix,
            matchPath: "/",
            remoteHost: "localhost",
            remotePort: Int(localBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: false
        )

        let denied = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid/items?a=1 HTTP/1.1\r\nHost: backend.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(denied.statusLine.contains("403 Forbidden"), "Got \(denied.statusLine)")
        XCTAssertEqual(denied.headers["x-joesproxy-denial-reason"], MapRemoteDenialReason.permissionDisabled.rawValue)
        XCTAssertEqual(localBackend.receivedRequests.count, 0)

        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [Int(localBackend.boundPort)]

        let getOK = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid/items?a=1 HTTP/1.1\r\nHost: backend.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(getOK.statusLine.contains("200 OK"), "Got \(getOK.statusLine)")
        let recordedGET = try XCTUnwrap(localBackend.receivedRequests.last)
        XCTAssertEqual(recordedGET.hostHeader, "backend.example.invalid")
        XCTAssertEqual(recordedGET.hopHeader, "1")

        // Verify nondefault port and bracketed IPv6 preserved Host authority end-to-end.
        let nonDefaultReq = makeRequest(method: "GET", scheme: .http, host: "backend.example.invalid", port: 8443, path: "/v2")
        _ = try await store.addMapRemoteRule(
            from: nonDefaultReq,
            label: "GET Nondefault Port Local",
            remoteHost: "127.0.0.1",
            remotePort: Int(localBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: true
        )
        let nonDefaultOK = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid:8443/v2 HTTP/1.1\r\nHost: backend.example.invalid:8443\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(nonDefaultOK.statusLine.contains("200 OK"), "Got \(nonDefaultOK.statusLine)")
        XCTAssertEqual(localBackend.receivedRequests.last?.hostHeader, "backend.example.invalid:8443")

        let ipv6Req = makeRequest(method: "GET", scheme: .http, host: "::1", port: 8443, path: "/v6")
        _ = try await store.addMapRemoteRule(
            from: ipv6Req,
            label: "GET Bracketed IPv6 Local",
            remoteHost: "127.0.0.1",
            remotePort: Int(localBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: true
        )
        let ipv6OK = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://[::1]:8443/v6 HTTP/1.1\r\nHost: [0:0::1]:8443\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(ipv6OK.statusLine.contains("200 OK"), "Got \(ipv6OK.statusLine)")
        XCTAssertEqual(localBackend.receivedRequests.last?.hostHeader, "[::1]:8443")

        let spoofedHostCountBefore = localBackend.receivedRequests.count
        let mismatchedHost = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid/items?a=1 HTTP/1.1\r\nHost: spoofed.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(mismatchedHost.statusLine.contains("403 Forbidden"), "Got \(mismatchedHost.statusLine)")
        XCTAssertEqual(mismatchedHost.headers["x-joesproxy-denial-reason"], MapRemoteDenialReason.invalidOriginalHost.rawValue)
        XCTAssertEqual(localBackend.receivedRequests.count, spoofedHostCountBefore)

        let postOK = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "POST http://backend.example.invalid/items HTTP/1.1\r\nHost: backend.example.invalid\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello-world"
        )
        XCTAssertTrue(postOK.statusLine.contains("200 OK"), "Got \(postOK.statusLine)")
        let recordedPOST = try XCTUnwrap(localBackend.receivedRequests.last)
        XCTAssertEqual(recordedPOST.hostHeader, "localhost:\(localBackend.boundPort)")
        XCTAssertEqual(recordedPOST.body, "hello-world")

        let loopResp = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid/items HTTP/1.1\r\nHost: backend.example.invalid\r\nX-JoesProxy-MapRemote-Hop: 3\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(loopResp.statusLine.contains("508 Loop Detected"), "Got \(loopResp.statusLine)")

        let reservedReq = makeRequest(method: "GET", scheme: .http, host: "self-loop.example.invalid", port: 80, path: "/self")
        config.authorizedLoopbackMapRemotePorts.append(Int(proxy.port))
        _ = try await store.addMapRemoteRule(
            from: reservedReq,
            label: "Self Target",
            remoteHost: "127.0.0.1",
            remotePort: Int(proxy.port),
            remoteScheme: .http,
            allowLoopbackDestination: true
        )
        let reservedResp = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://self-loop.example.invalid/self HTTP/1.1\r\nHost: self-loop.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(reservedResp.statusLine.contains("403 Forbidden"), "Got \(reservedResp.statusLine)")
        XCTAssertEqual(reservedResp.headers["x-joesproxy-denial-reason"], MapRemoteDenialReason.reservedDestination.rawValue)

        await localBackend.stop()
        let refused = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://backend.example.invalid/items HTTP/1.1\r\nHost: backend.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(refused.statusLine.contains("502 Bad Gateway"), "Got \(refused.statusLine)")

        try await Task.sleep(for: .milliseconds(100))
        let hasMapRemoteSession = sessionStore.sessions.contains { $0.response?.source == .mapRemote }
        XCTAssertTrue(hasMapRemoteSession)
    }

    func testRevocationClosesInFlightLoopbackStream() async throws {
        let streamingBackend = try LocalEchoHTTPServer(holdStreamOnPath: "/stream")
        try await streamingBackend.start()
        defer { Task { await streamingBackend.stop() } }

        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }
        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [Int(streamingBackend.boundPort)]

        let store = ResponseOverrideStore()
        let proxy = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: .passThrough,
            configuration: config,
            responseOverrideStore: store
        )
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let streamReq = makeRequest(method: "GET", scheme: .http, host: "stream.example.invalid", port: 80, path: "/stream")
        _ = try await store.addMapRemoteRule(
            from: streamReq,
            label: "Stream Local",
            remoteHost: "127.0.0.1",
            remotePort: Int(streamingBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true
        )

        let streamClosedExpectation = expectation(description: "In-flight stream closes on revocation")
        let task = Task.detached {
            _ = try? await Self.sendViaProxyRaw(
                proxyPort: proxy.port,
                rawRequest: "GET http://stream.example.invalid/stream HTTP/1.1\r\nHost: stream.example.invalid\r\nConnection: close\r\n\r\n"
            )
            streamClosedExpectation.fulfill()
        }

        for _ in 0..<40 {
            if !streamingBackend.receivedRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(streamingBackend.receivedRequests.isEmpty)

        config.isLoopbackMapRemoteEnabled = false
        _ = await store.disableLoopbackMapRemoteRules(forRemovedPorts: nil)
        ActiveMapRemoteSessionRegistry.shared.cancelLoopbackSessions(forPorts: nil)

        await fulfillment(of: [streamClosedExpectation], timeout: 3.0)
        task.cancel()
    }

    @MainActor
    func testSettingsViewModelSingleActionRevocationClosesEstablishedAndInFlightPreflightPreservesUnrelatedAndStaysDisabled() async throws {
        let localBackend = try LocalEchoHTTPServer(holdStreamOnPath: "/stream")
        try await localBackend.start()
        defer { Task { await localBackend.stop() } }

        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }

        let store = ResponseOverrideStore()
        let runtime = StubProxyRuntime()
        let viewModel = SettingsViewModel(
            configuration: config,
            proxyRuntime: runtime,
            responseOverrideStore: store
        )

        viewModel.isLoopbackMapRemoteEnabled = true
        viewModel.authorizedLoopbackPortsDraft = "\(localBackend.boundPort)"
        viewModel.commitAuthorizedLoopbackPortsDraft()

        let proxy = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: .passThrough,
            configuration: config,
            responseOverrideStore: store
        )
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let loopbackRuleReq = makeRequest(
            method: "GET",
            scheme: .http,
            host: "revoked.example.invalid",
            port: 80,
            path: "/"
        )
        let loopbackRule = try await store.addMapRemoteRule(
            from: loopbackRuleReq,
            label: "Revocable Local Rule",
            matchMode: .pathPrefix,
            matchPath: "/",
            remoteHost: "127.0.0.1",
            remotePort: Int(localBackend.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true
        )

        let unrelatedRule = ResponseOverrideRule(
            label: "Unrelated Map Local",
            requestMethod: "GET",
            requestScheme: .http,
            host: "unrelated.example.invalid",
            port: 80,
            path: "/health",
            matchMode: .exactPath,
            sourceKind: .inlineText,
            sourceDescription: ResponseOverrideSourceKind.inlineText.sourceDescription,
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "text/plain")],
            bodySource: .inline(Data("healthy".utf8))
        )
        try await store.addRule(unrelatedRule)

        // 1. Start an established loopback stream on /stream.
        let establishedClosed = expectation(description: "Established loopback stream closes cleanly on Settings toggle OFF")
        let establishedTask = Task.detached {
            _ = try? await Self.sendViaProxyRaw(
                proxyPort: proxy.port,
                rawRequest: "GET http://revoked.example.invalid/stream HTTP/1.1\r\nHost: revoked.example.invalid\r\nConnection: close\r\n\r\n"
            )
            establishedClosed.fulfill()
        }
        for _ in 0..<40 {
            if !localBackend.receivedRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(localBackend.receivedRequests.map(\.uri), ["/stream"])

        // 2. Hold a second loopback request between initial validation and active-session registration.
        let reachedWindowExpectation = expectation(description: "Mid-setup request paused between validation and registration")
        final class GateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            private var signaled = false
            func wait() async {
                await withCheckedContinuation { cont in
                    lock.withLock {
                        if signaled {
                            cont.resume()
                        } else {
                            continuation = cont
                        }
                    }
                }
            }
            func release() {
                let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                    signaled = true
                    let existing = continuation
                    continuation = nil
                    return existing
                }
                cont?.resume()
            }
        }
        let gate = GateBox()
        ProxyConnectionHandler.beforeLoopbackRegistrationPauseForTesting = { @Sendable in
            ProxyConnectionHandler.beforeLoopbackRegistrationPauseForTesting = nil
            reachedWindowExpectation.fulfill()
            await gate.wait()
        }
        defer {
            ProxyConnectionHandler.beforeLoopbackRegistrationPauseForTesting = nil
            gate.release()
        }

        let inFlightResponseTask = Task {
            try await self.sendViaProxy(
                proxyPort: proxy.port,
                rawRequest: "GET http://revoked.example.invalid/mid-setup HTTP/1.1\r\nHost: revoked.example.invalid\r\nConnection: close\r\n\r\n"
            )
        }
        await fulfillment(of: [reachedWindowExpectation], timeout: 3.0)

        // 3. Trigger ONLY the real SettingsViewModel user action (no manual store/registry calls).
        viewModel.isLoopbackMapRemoteEnabled = false

        // Release the paused request and verify it aborts before reaching the local server.
        gate.release()
        let inFlightResult = try await inFlightResponseTask.value
        XCTAssertTrue(inFlightResult.statusLine.contains("403 Forbidden"), "Got \(inFlightResult.statusLine)")
        XCTAssertEqual(
            inFlightResult.headers["x-joesproxy-denial-reason"],
            MapRemoteDenialReason.permissionDisabled.rawValue
        )
        await fulfillment(of: [establishedClosed], timeout: 3.0)
        establishedTask.cancel()
        XCTAssertEqual(localBackend.receivedRequests.map(\.uri), ["/stream"])

        // 4. Unrelated non-loopback traffic continues working unaffected.
        let unrelatedResult = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://unrelated.example.invalid/health HTTP/1.1\r\nHost: unrelated.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(unrelatedResult.statusLine.hasPrefix("HTTP/1.1 200"), "Got \(unrelatedResult.statusLine)")
        XCTAssertEqual(unrelatedResult.body, "healthy")
        let storedUnrelated = await store.rule(id: unrelatedRule.id)
        XCTAssertEqual(storedUnrelated?.isEnabled, true)

        // 5. Wait for SettingsViewModel async persistence and verify re-enabling does not resurrect the rule.
        for _ in 0..<40 {
            let currentRule = await store.rule(id: loopbackRule.id)
            if currentRule?.isEnabled == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let disabledRule = await store.rule(id: loopbackRule.id)
        XCTAssertEqual(disabledRule?.isEnabled, false)

        viewModel.isLoopbackMapRemoteEnabled = true
        let afterReenable = try await sendViaProxy(
            proxyPort: proxy.port,
            rawRequest: "GET http://revoked.example.invalid/after-reenable HTTP/1.1\r\nHost: revoked.example.invalid\r\nConnection: close\r\n\r\n"
        )
        XCTAssertNotEqual(afterReenable.body, "ok:/after-reenable")
        XCTAssertEqual(localBackend.receivedRequests.map(\.uri), ["/stream"])
    }

    // MARK: - Integrated Authoring (MCP, CLI, Scenarios, Effect Bundles)

    @MainActor
    func testMCPLoopbackCreateActivateRevalidationAndRevisionInvalidation() async throws {
        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopbackMCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let approvalStore = MCPApprovalStore()
        let policyStore = MCPPolicyStore(persistenceURL: tempDir.appendingPathComponent("policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: tempDir.appendingPathComponent("grants.json"))
        let auditStore = MCPAuditStore(persistenceURL: tempDir.appendingPathComponent("audit.json"))
        auditStore.load()
        let journalStore = MCPEffectJournalStore(persistenceURL: tempDir.appendingPathComponent("journal.json"))
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let mediaService = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let operationCoordinator = MCPOperationCoordinator(
            sessionStore: sessionStore,
            mediaService: mediaService,
            snapshotService: snapshotService,
            policyStore: policyStore,
            auditStore: auditStore
        )
        let client = MCPClientRecord(
            id: "cli-test",
            displayName: "CLI Test",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let mutationService = MCPMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            loopbackPolicyReader: { config.loopbackDestinationPolicy }
        )
        let openWorldService = MCPOpenWorldService(
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkExecutor: URLSessionBookmarkExecutor(),
            sessionMatcher: MCPExecutedSessionMatcher(sessionStore: sessionStore, matchTimeout: 0.05),
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            operationCoordinator: operationCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            runningProxyPort: { nil },
            loopbackPolicyReader: { config.loopbackDestinationPolicy }
        )

        let baseArgs: [String: Any] = [
            "method": "GET",
            "host": "api.example.test",
            "path": "/v1/feed",
            "remoteHost": "127.0.0.1",
            "remotePort": 3000,
            "remoteScheme": "http",
            "allowLoopbackDestination": true,
            "preserveHostHeader": true
        ]

        // 1. Denied while permission is OFF.
        do {
            _ = try await mutationService.handleTool(name: "propose_create_map_remote", arguments: baseArgs, client: client)
            XCTFail("Expected policyDenied while global loopback permission is disabled")
        } catch let err as MCPStructuredError {
            XCTAssertEqual(err.code, .policyDenied)
        }

        // 2. Enable global permission & port 3000 -> propose & apply disabled rule.
        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [3000]

        let isoEncoder = JSONEncoder()
        isoEncoder.dateEncodingStrategy = .iso8601

        let proposal = try await mutationService.handleTool(name: "propose_create_map_remote", arguments: baseArgs, client: client)
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        do {
            _ = try await mutationService.handleTool(name: "apply_create_map_remote", arguments: ["proposalToken": token], client: client)
            XCTFail("Expected approvalRequired")
        } catch let err as MCPStructuredError where err.code == .approvalRequired {
            let reqID = try XCTUnwrap(err.details?["requestID"])
            let auth = try approvalStore.approve(requestID: reqID)
            let authDict = try JSONSerialization.jsonObject(with: isoEncoder.encode(auth))
            _ = try await mutationService.handleTool(
                name: "apply_create_map_remote",
                arguments: ["proposalToken": token, "approval": authDict],
                client: client
            )
        }

        let currentRules = await responseOverrideStore.rules()
        let created = try XCTUnwrap(currentRules.first)
        XCTAssertTrue(created.allowLoopbackDestination)
        XCTAssertTrue(created.preserveHostHeader)
        let originalRevision = created.mcpTargetRevision

        // 3. Semantic change invalidates mcpTargetRevision (including preserveHostHeader).
        try await responseOverrideStore.updateMapRemoteRule(
            id: created.id,
            label: created.label,
            matchMode: created.matchMode,
            remoteHost: "127.0.0.1",
            remotePort: 3000,
            remoteScheme: .http,
            allowLoopbackDestination: true,
            preserveHostHeader: false
        )
        let maybeUpdated = await responseOverrideStore.rule(id: created.id)
        let updated = try XCTUnwrap(maybeUpdated)
        XCTAssertNotEqual(updated.mcpTargetRevision, originalRevision)

        // 4. activate_map_remote disclosure includes Host behavior, client scope, and loopback flag;
        //    revoking global permission before retrying activation fails closed.
        var approvalReqID: String?
        do {
            _ = try await openWorldService.handleTool(
                name: "activate_map_remote",
                arguments: ["overrideID": created.id.uuidString],
                client: client,
                mcpSessionID: "s1"
            )
            XCTFail("Expected approvalRequired")
        } catch let err as MCPStructuredError where err.code == .approvalRequired {
            let reason = err.details?["reason"] ?? err.message
            XCTAssertTrue(reason.contains("LOCAL MAC LOOPBACK"), reason)
            XCTAssertTrue(reason.contains("all clients"), reason)
            XCTAssertTrue(reason.contains("Host"), reason)
            approvalReqID = err.details?["requestID"]
        }

        let approvedAuth = try approvalStore.approve(requestID: try XCTUnwrap(approvalReqID))
        let approvedDict = try JSONSerialization.jsonObject(with: isoEncoder.encode(approvedAuth))
        config.isLoopbackMapRemoteEnabled = false

        do {
            _ = try await openWorldService.handleTool(
                name: "activate_map_remote",
                arguments: ["overrideID": created.id.uuidString, "approval": approvedDict],
                client: client,
                mcpSessionID: "s1"
            )
            XCTFail("Expected policyDenied when permission was revoked before activation")
        } catch let err as MCPStructuredError {
            XCTAssertEqual(err.code, .policyDenied)
        }
    }

    @MainActor
    func testScenarioAndEffectBundleLoopbackCompatAndActivationRevalidation() async throws {
        // Legacy EffectBundleResponseEffect JSON lacking new fields decodes safely to nil (false).
        let legacyEffectJSON = """
        {
            "id": "\(UUID().uuidString)",
            "requestMethod": "GET",
            "requestScheme": "https",
            "host": "api.example.com",
            "path": "/v1",
            "matchMode": "exactPath",
            "sourceKind": "mapRemote",
            "statusCode": 200,
            "headers": [],
            "bodySource": {"kind": "none", "assetIDs": []},
            "mapRemoteHost": "staging.example.com",
            "mapRemotePort": 443,
            "mapRemoteScheme": "https",
            "mapRemoteQueryPolicy": "preserve",
            "liveResponseRewrites": [],
            "dropConnection": false,
            "forceNoCache": false,
            "missingFilePolicy": "strictLocal"
        }
        """
        let decodedEffect = try JSONDecoder().decode(EffectBundleResponseEffect.self, from: Data(legacyEffectJSON.utf8))
        XCTAssertNil(decodedEffect.allowLoopbackDestination)
        XCTAssertNil(decodedEffect.preserveHostHeader)

        // Scenario loopback compile & roundtrip.
        let matcher = MCPMutationMatcher(method: "GET", scheme: .http, host: "api.example.com", port: 80, path: "/v1", matchMode: .exactPath)
        let loopbackDraft = MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: "loopback-scn"),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Local Backend",
            purpose: "Route API to local port 3000.",
            originatingClientID: "cli-test",
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [MCPScenarioPrecondition(kind: .captureActive, detail: nil)],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.mapRemote(
                matcher: matcher,
                remoteHost: "127.0.0.1",
                remotePort: 3000,
                remoteScheme: .http,
                allowLoopbackDestination: true,
                preserveHostHeader: true
            )],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 10, retention: 60),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .mapRemote)]
        )
        XCTAssertThrowsError(try MCPScenarioCompiler.compile(draft: loopbackDraft, loopbackPolicy: .disabled))
        let compiled = try MCPScenarioCompiler.compile(
            draft: loopbackDraft,
            loopbackPolicy: LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [3000])
        )
        let disclosure = MCPScenarioCompiler.approvalDisclosure(for: compiled)
        XCTAssertTrue(disclosure.openWorldDisclosures.first?.expectedSideEffect.contains("local Mac loopback") == true)
        let scenarioData = try MCPScenarioJSONCodec.encodeDraft(loopbackDraft)
        let decodedDraft = try MCPScenarioJSONCodec.decodeDraft(from: scenarioData)
        XCTAssertEqual(decodedDraft, loopbackDraft)

        // EffectBundleActivationCoordinator rejects unauthorized loopback bundle and activates when permitted.
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopbackBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let packageDir = rootDir.appendingPathComponent("local.jproxy-effects", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        let bundleID = UUID()
        let effectID = UUID()
        let manifest = EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: bundleID,
            name: "Loopback Bundle",
            notes: "",
            createdAt: Date(),
            appVersion: "test",
            privacy: .exactContent,
            defaultTTLSeconds: 60,
            assets: [],
            responseEffects: [
                EffectBundleResponseEffect(
                    id: effectID,
                    label: "Local Map Remote",
                    requestMethod: "GET",
                    requestScheme: .http,
                    host: "api.example.com",
                    port: 80,
                    path: "/v1",
                    matchMode: .exactPath,
                    sourceKind: .mapRemote,
                    statusCode: 200,
                    headers: [],
                    bodySource: .none,
                    mapRemoteHost: "127.0.0.1",
                    mapRemotePort: 3000,
                    mapRemoteScheme: .http,
                    mapRemotePath: nil,
                    mapRemoteQueryPolicy: .preserve,
                    mapRemoteQuery: nil,
                    allowLoopbackDestination: true,
                    preserveHostHeader: true,
                    bookmarkRewriteRequest: nil,
                    liveResponseRewrites: [],
                    expectedSchemaFingerprint: nil,
                    dropConnection: false,
                    forceNoCache: false,
                    notFoundRelativePath: nil,
                    missingFilePolicy: .strictLocal,
                    graphQLOperationName: nil,
                    matchQueryKey: nil,
                    matchQueryValue: nil,
                    matchHeaderName: nil,
                    matchHeaderValue: nil,
                    sourceClientAddress: nil
                )
            ],
            hlsSubstitutions: []
        )
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: packageDir.appendingPathComponent("manifest.json"))

        let repository = EffectBundleRepository(
            persistenceURL: rootDir.appendingPathComponent("repo.json"),
            packagesRootURL: rootDir.appendingPathComponent("packages")
        )
        let record = try repository.importPackage(at: packageDir, owner: .localUser)
        let store = ResponseOverrideStore()
        let hlsCoordinator = HLSSubstitutionCoordinator(
            runStore: HLSFixtureRunStore(),
            routeStore: HLSSubstitutionRouteStore(),
            responseOverrideStore: store
        )

        let deniedCoordinator = EffectBundleActivationCoordinator(
            repository: repository,
            responseOverrideStore: store,
            hlsCoordinator: hlsCoordinator,
            runtimeRootURL: rootDir.appendingPathComponent("runtime-denied"),
            loopbackPolicyProvider: { .disabled },
            schedulesTimers: false
        )
        do {
            _ = try await deniedCoordinator.activateFromLocalUI(reviewed: record)
            XCTFail("Expected loopbackMapRemoteDenied when global permission is OFF")
        } catch EffectBundleError.loopbackMapRemoteDenied(let id, _) {
            XCTAssertEqual(id, effectID)
        }

        let allowedCoordinator = EffectBundleActivationCoordinator(
            repository: repository,
            responseOverrideStore: store,
            hlsCoordinator: hlsCoordinator,
            runtimeRootURL: rootDir.appendingPathComponent("runtime-allowed"),
            loopbackPolicyProvider: { LoopbackDestinationPolicy(isEnabled: true, authorizedPorts: [3000]) },
            schedulesTimers: false
        )
        _ = try await allowedCoordinator.activateFromLocalUI(reviewed: record)
        let maybeInstalled = await store.rule(id: effectID)
        let installedRule = try XCTUnwrap(maybeInstalled)
        XCTAssertTrue(installedRule.allowLoopbackDestination)
        XCTAssertTrue(installedRule.preserveHostHeader)
        XCTAssertTrue(installedRule.isEnabled)
        _ = try await allowedCoordinator.stopFromLocalUI(id: bundleID)
    }

    func testCLIMapRemoteInvocationParsing() throws {
        let invocation = try CLIInvocation.parse([
            "response", "map-remote", "prepare",
            "--method", "GET",
            "--scheme", "https",
            "--host", "api.example.com",
            "--path", "/v1/feed",
            "--remote-host", "127.0.0.1",
            "--remote-port", "3000",
            "--remote-scheme", "http",
            "--allow-loopback",
            "--preserve-host"
        ])
        XCTAssertEqual(invocation.command, ["response", "map-remote", "prepare"])
        XCTAssertEqual(invocation.options["remote-host"], "127.0.0.1")
        XCTAssertEqual(invocation.options["remote-port"], "3000")
        XCTAssertEqual(invocation.options["remote-scheme"], "http")
        XCTAssertTrue(invocation.flags.contains("allow-loopback"))
        XCTAssertTrue(invocation.flags.contains("preserve-host"))
    }

    @MainActor
    func testHLSVODDirectVersusLoopbackMapRemoteProxyControl() async throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/sdr-six-second-positive-v1")
        let origin = LocalHLSVODOriginServer(rootDirectory: fixtureDirectory)
        try await origin.start()
        defer { Task { await origin.stop() } }

        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }
        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [Int(origin.boundPort)]

        let store = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: sessionStore)
        let proxy = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: .passThrough,
            configuration: config,
            sessionRecorder: recorder,
            responseOverrideStore: store
        )
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let ruleReq = makeRequest(method: "GET", scheme: .http, host: "cdn.example.invalid", port: 80, path: "/")
        _ = try await store.addMapRemoteRule(
            from: ruleReq,
            label: "Local HLS VOD",
            matchMode: .pathPrefix,
            matchPath: "/",
            remoteHost: "127.0.0.1",
            remotePort: Int(origin.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true
        )

        // Direct fetches against origin
        let directMaster = try await Self.fetchHTTP(port: origin.boundPort, request: "GET /master.m3u8 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.boundPort)\r\nConnection: close\r\n\r\n")
        let directPlaylist = try await Self.fetchHTTP(port: origin.boundPort, request: "GET /video-360/stream.m3u8 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.boundPort)\r\nConnection: close\r\n\r\n")
        let directSeg = try await Self.fetchHTTP(port: origin.boundPort, request: "GET /video-360/seg-000.ts HTTP/1.1\r\nHost: 127.0.0.1:\(origin.boundPort)\r\nConnection: close\r\n\r\n")

        // Remapped fetches through JoesProxy
        let proxiedRedirect = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/redirect-master.m3u8 HTTP/1.1\r\nHost: cdn.example.invalid\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(proxiedRedirect.statusLine.contains("302"))

        let proxiedMaster = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/master.m3u8 HTTP/1.1\r\nHost: cdn.example.invalid\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(proxiedMaster.body, directMaster.body)

        let proxiedAbs = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/abs-master.m3u8 HTTP/1.1\r\nHost: cdn.example.invalid\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(String(decoding: proxiedAbs.body, as: UTF8.self).contains("http://cdn.example.invalid/video-360/stream.m3u8"))

        let proxiedPlaylist = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/video-360/stream.m3u8 HTTP/1.1\r\nHost: cdn.example.invalid\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(proxiedPlaylist.body, directPlaylist.body)

        let proxiedSeg = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/video-360/seg-000.ts HTTP/1.1\r\nHost: cdn.example.invalid\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(proxiedSeg.body, directSeg.body)

        let proxiedRange = try await Self.fetchHTTP(port: proxy.port, request: "GET http://cdn.example.invalid/video-360/seg-000.ts HTTP/1.1\r\nHost: cdn.example.invalid\r\nRange: bytes=0-255\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(proxiedRange.statusLine.contains("206"))
        XCTAssertEqual(proxiedRange.body, directSeg.body.prefix(256))

        try await Task.sleep(for: .milliseconds(100))
        let remappedPaths = Set(
            sessionStore.sessions
                .filter { $0.response?.source == .mapRemote }
                .map { $0.request.path }
        )
        XCTAssertTrue(remappedPaths.contains("/master.m3u8"))
        XCTAssertTrue(remappedPaths.contains("/video-360/stream.m3u8"))
        XCTAssertTrue(remappedPaths.contains("/video-360/seg-000.ts"))
    }

    @MainActor
    func testHLSVODDirectVersusLoopbackMapRemoteWithMediaStreamValidator() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JOESPROXY_RUN_EXTERNAL_HLS_VALIDATOR"] == "1",
            "Set JOESPROXY_RUN_EXTERNAL_HLS_VALIDATOR=1 (TEST_RUNNER_JOESPROXY_RUN_EXTERNAL_HLS_VALIDATOR=1) to run external mediastreamvalidator/msvsummary checks."
        )
        let msvPath = "/usr/local/bin/mediastreamvalidator"
        let summaryPath = "/usr/local/bin/msvsummary"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: msvPath)
                && FileManager.default.isExecutableFile(atPath: summaryPath),
            "Apple HLS Tools (mediastreamvalidator/msvsummary) not installed under /usr/local/bin."
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureDirectory = repoRoot.appendingPathComponent("Fixtures/HLS/sdr-six-second-positive-v1")
        let origin = LocalHLSVODOriginServer(rootDirectory: fixtureDirectory)
        try await origin.start()
        defer { Task { await origin.stop() } }

        let (config, cleanup) = try makeIsolatedConfig()
        defer { cleanup() }
        config.isLoopbackMapRemoteEnabled = true
        config.authorizedLoopbackMapRemotePorts = [Int(origin.boundPort)]

        let store = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: sessionStore)
        let proxy = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: .passThrough,
            configuration: config,
            sessionRecorder: recorder,
            responseOverrideStore: store
        )
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let ruleReq = makeRequest(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(proxy.port),
            path: "/"
        )
        let rule = try await store.addMapRemoteRule(
            from: ruleReq,
            label: "Local HLS VOD Validator Control",
            matchMode: .pathPrefix,
            matchPath: "/",
            remoteHost: "127.0.0.1",
            remotePort: Int(origin.boundPort),
            remoteScheme: .http,
            allowLoopbackDestination: true
        )

        let artifactRoot = repoRoot
            .appendingPathComponent("build/hls-validation", isDirectory: true)
            .appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let directDir = artifactRoot.appendingPathComponent("direct", isDirectory: true)
        let remappedDir = artifactRoot.appendingPathComponent("remapped", isDirectory: true)
        try FileManager.default.createDirectory(at: directDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remappedDir, withIntermediateDirectories: true)

        let versionResult = try Self.runExternalTool(
            executablePath: msvPath,
            arguments: ["--version"],
            timeoutSeconds: 15,
            logDirectory: artifactRoot,
            logPrefix: "msv-version"
        )
        XCTAssertFalse(versionResult.timedOut, "mediastreamvalidator --version timed out")
        XCTAssertEqual(versionResult.exitCode, 0)
        let versionText = (versionResult.stdout + "\n" + versionResult.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let playlistRelPaths = [
            "master.m3u8",
            "video-360/stream.m3u8",
            "video-720/stream.m3u8",
            "video-1080/stream.m3u8",
            "audio-en/stream.m3u8"
        ]
        var playlistSHA256s: [String: String] = [:]
        for rel in playlistRelPaths {
            playlistSHA256s[rel] = try Self.sha256Hex(of: fixtureDirectory.appendingPathComponent(rel))
        }
        let segmentRenditions = ["video-360", "video-720", "video-1080", "audio-en"]
        var expectedSegmentPaths = Set<String>()
        var segmentSHA256s: [String: String] = [:]
        for rendition in segmentRenditions {
            for index in 0..<15 {
                let rel = String(format: "%@/seg-%03d.ts", rendition, index)
                expectedSegmentPaths.insert("/" + rel)
                segmentSHA256s[rel] = try Self.sha256Hex(of: fixtureDirectory.appendingPathComponent(rel))
            }
        }
        let expectedAllPaths = Set(playlistRelPaths.map { "/" + $0 }).union(expectedSegmentPaths)

        let directJSON = directDir.appendingPathComponent("validation_data.json")
        let directArgs = [
            "--exit-code.threshold", "must",
            "--timeout", "120",
            "--validation-data-path", directJSON.path,
            "http://127.0.0.1:\(origin.boundPort)/master.m3u8"
        ]
        let directRun = try Self.runExternalTool(
            executablePath: msvPath,
            arguments: directArgs,
            timeoutSeconds: 150,
            logDirectory: directDir,
            logPrefix: "msv"
        )
        let directSummaryMD = directDir.appendingPathComponent("summary.md")
        let directSummaryHTML = directDir.appendingPathComponent("validation_data.html")
        var directSummaryHTMLTimedOut = false
        var directSummaryMDTimedOut = false
        var directSummaryRun = ExternalToolResult(exitCode: -1, stdout: "", stderr: "", timedOut: false)
        if !directRun.timedOut && FileManager.default.fileExists(atPath: directJSON.path) {
            let htmlRes = try Self.runExternalTool(
                executablePath: summaryPath,
                arguments: ["-o", directSummaryHTML.path, directJSON.path],
                timeoutSeconds: 30,
                logDirectory: directDir,
                logPrefix: "msvsummary-html"
            )
            directSummaryHTMLTimedOut = htmlRes.timedOut
            directSummaryRun = try Self.runExternalTool(
                executablePath: summaryPath,
                arguments: ["--format", "markdown", "--detail", "summary", "-o", directSummaryMD.path, directJSON.path],
                timeoutSeconds: 30,
                logDirectory: directDir,
                logPrefix: "msvsummary-md"
            )
            directSummaryMDTimedOut = directSummaryRun.timedOut
        }

        // mediastreamvalidator uses CFNetwork/NSURLSession and ignores POSIX http_proxy env vars.
        // Route explicitly through JoesProxy's origin-form HTTP handler matching 127.0.0.1:<proxy.port> -> 127.0.0.1:<origin.boundPort>.
        let remappedJSON = remappedDir.appendingPathComponent("validation_data.json")
        let remappedArgs = [
            "--exit-code.threshold", "must",
            "--timeout", "120",
            "--validation-data-path", remappedJSON.path,
            "http://127.0.0.1:\(proxy.port)/master.m3u8"
        ]
        let proxyURL = "http://127.0.0.1:\(proxy.port)"
        let remappedRun = try Self.runExternalTool(
            executablePath: msvPath,
            arguments: remappedArgs,
            timeoutSeconds: 150,
            logDirectory: remappedDir,
            logPrefix: "msv"
        )
        try await Task.sleep(for: .milliseconds(250))

        let remappedSummaryHTML = remappedDir.appendingPathComponent("validation_data.html")
        let remappedSummaryMD = remappedDir.appendingPathComponent("summary.md")
        var remappedSummaryHTMLTimedOut = false
        var remappedSummaryMDTimedOut = false
        var remappedSummaryRun = ExternalToolResult(exitCode: -1, stdout: "", stderr: "", timedOut: false)
        if !remappedRun.timedOut && FileManager.default.fileExists(atPath: remappedJSON.path) {
            let htmlRes = try Self.runExternalTool(
                executablePath: summaryPath,
                arguments: ["-o", remappedSummaryHTML.path, remappedJSON.path],
                timeoutSeconds: 30,
                logDirectory: remappedDir,
                logPrefix: "msvsummary-html"
            )
            remappedSummaryHTMLTimedOut = htmlRes.timedOut
            remappedSummaryRun = try Self.runExternalTool(
                executablePath: summaryPath,
                arguments: ["--format", "markdown", "--detail", "summary", "-o", remappedSummaryMD.path, remappedJSON.path],
                timeoutSeconds: 30,
                logDirectory: remappedDir,
                logPrefix: "msvsummary-md"
            )
            remappedSummaryMDTimedOut = remappedSummaryRun.timedOut
        }

        let anyTimedOut = directRun.timedOut || remappedRun.timedOut || directSummaryHTMLTimedOut || directSummaryMDTimedOut || remappedSummaryHTMLTimedOut || remappedSummaryMDTimedOut
        let captured = sessionStore.sessions
        let remappedSessions = captured.filter { $0.response?.source == .mapRemote }
        let remappedPaths = Set(remappedSessions.map { $0.request.path })
        let directObject = (try? Data(contentsOf: directJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let remappedObject = (try? Data(contentsOf: remappedJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let directFindings = directObject.map(Self.normalizedMSVFindings(from:)) ?? []
        let remappedFindings = remappedObject.map(Self.normalizedMSVFindings(from:)) ?? []

        let receipt: [String: Any] = [
            "artifactRoot": artifactRoot.path,
            "status": anyTimedOut ? "incomplete_timeout" : "complete",
            "proxyRoutingMode": "origin-form-direct-listener",
            "deviceHTTPSAndPlayerScope": "separate_acceptance_required",
            "toolVersion": versionText,
            "fixtureProfile": "sdr-six-second-positive-v1",
            "masterPlaylistSHA256": playlistSHA256s["master.m3u8"] ?? "",
            "playlistSHA256s": playlistSHA256s,
            "segmentSHA256s": segmentSHA256s,
            "ruleID": rule.id.uuidString,
            "proxyEndpoint": proxyURL,
            "originEndpoint": "http://127.0.0.1:\(origin.boundPort)",
            "directTimedOut": directRun.timedOut,
            "remappedTimedOut": remappedRun.timedOut,
            "directExitCode": directRun.exitCode,
            "directArguments": directArgs,
            "remappedExitCode": remappedRun.exitCode,
            "remappedArguments": remappedArgs,
            "directFindings": Array(directFindings).sorted(),
            "remappedFindings": Array(remappedFindings).sorted(),
            "totalProxySessions": captured.count,
            "remappedSessionCount": remappedSessions.count,
            "expectedDistinctPathCount": expectedAllPaths.count,
            "remappedPaths": Array(remappedPaths).sorted()
        ]
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try receiptData.write(to: artifactRoot.appendingPathComponent("capture-receipt.json"))

        XCTAssertFalse(anyTimedOut, "External HLS tool exceeded wall-clock deadline (partial artifacts retained under \(artifactRoot.path))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directJSON.path), "Direct validation_data.json missing")
        XCTAssertEqual(directSummaryRun.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directSummaryHTML.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directSummaryMD.path))
        XCTAssertEqual(directRun.exitCode, 0, "Direct baseline MSV exited \(directRun.exitCode): \(directRun.stderr)")

        XCTAssertTrue(FileManager.default.fileExists(atPath: remappedJSON.path), "Remapped validation_data.json missing")
        XCTAssertEqual(remappedSummaryRun.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remappedSummaryHTML.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remappedSummaryMD.path))

        XCTAssertEqual(remappedPaths, expectedAllPaths, "Remapped HLS requests must cover all 5 playlists and exact set of 60 distinct segment paths")
        XCTAssertTrue(
            remappedSessions.allSatisfy { $0.response?.statusCode == 200 },
            "Every remapped HLS playlist/segment request must deliver HTTP 200"
        )
        XCTAssertEqual(remappedRun.exitCode, directRun.exitCode, "Remapped MSV exit code differed from direct baseline")
        XCTAssertEqual(
            directFindings,
            Set(["433088|MustAuth|/M01", "242528|ShouldAuth|/M01"]),
            "Direct baseline findings changed from pinned sdr-six-second-positive-v1 expectation"
        )
        XCTAssertEqual(remappedFindings, directFindings, "Remapped MSV findings must match direct baseline findings")
        let directStructureKeys = Set((directObject?["structure"] as? [String: Any])?.keys.map { $0 } ?? [])
        let remappedStructureKeys = Set((remappedObject?["structure"] as? [String: Any])?.keys.map { $0 } ?? [])
        XCTAssertFalse(directStructureKeys.isEmpty)
        XCTAssertEqual(remappedStructureKeys, directStructureKeys)
    }

    private struct ExternalToolResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedMSVFindings(from jsonObject: [String: Any]) -> Set<String> {
        guard let messages = jsonObject["messages"] as? [String: [[String: Any]]] else {
            return []
        }
        var results = Set<String>()
        for (codeKey, entries) in messages {
            for entry in entries {
                let code = entry["errorCode"].map { "\($0)" } ?? codeKey
                let subtype = (entry["subtype"] as? String) ?? "unknown"
                let sourceID = (entry["sourceID"] as? String) ?? "unknown"
                results.insert("\(code)|\(subtype)|\(sourceID)")
            }
        }
        return results
    }

    private static func runExternalTool(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        timeoutSeconds: TimeInterval,
        logDirectory: URL,
        logPrefix: String
    ) throws -> ExternalToolResult {
        let stdoutURL = logDirectory.appendingPathComponent("\(logPrefix).stdout.log")
        let stderrURL = logDirectory.appendingPathComponent("\(logPrefix).stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides {
            env[key] = value
        }
        process.environment = env
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        try process.run()

        let waitOutcome = finished.wait(timeout: .now() + timeoutSeconds)
        var timedOut = false
        if waitOutcome == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2.0) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2.0)
            }
        }
        process.terminationHandler = nil

        let out = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let exitCode = timedOut ? Int32(-1) : process.terminationStatus
        return ExternalToolResult(exitCode: exitCode, stdout: out, stderr: err, timedOut: timedOut)
    }

    private static func fetchHTTP(port: UInt16, request: String) async throws -> (statusLine: String, body: Data) {
        let raw = try await sendViaProxyRaw(proxyPort: port, rawRequest: request)
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            return ("", raw)
        }
        let head = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
        let statusLine = head.components(separatedBy: "\r\n").first ?? ""
        return (statusLine, Data(raw[range.upperBound...]))
    }

    // MARK: - Helpers

    private func assertPolicyDenied(_ expected: MapRemoteDenialReason, _ block: () throws -> Any) {
        do {
            _ = try block()
            XCTFail("Expected MapRemoteDenialReason.\(expected.rawValue)")
        } catch MapRemoteValidationError.policyDenied(let actual, _) {
            XCTAssertEqual(actual, expected)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    private func sendViaProxy(proxyPort: UInt16, rawRequest: String) async throws -> (statusLine: String, headers: [String: String], body: String) {
        let raw = try await Self.sendViaProxyRaw(proxyPort: proxyPort, rawRequest: rawRequest)
        let text = String(decoding: raw, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        return (statusLine, headers, body)
    }

    private static func sendViaProxyRaw(proxyPort: UInt16, rawRequest: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                    return
                }
                defer { close(fd) }

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = proxyPort.bigEndian
                inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

                let connectResult = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connectResult == 0 else {
                    continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                    return
                }

                let bytes = Array(rawRequest.utf8)
                _ = bytes.withUnsafeBytes { ptr in
                    Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
                }

                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                    if count > 0 {
                        output.append(buffer, count: count)
                    } else {
                        break
                    }
                }
                continuation.resume(returning: output)
            }
        }
    }
}

private final class StubProxyRuntime: ProxyRuntime, @unchecked Sendable {
    var currentState: ProxyRuntimeState { .stopped }
    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> { Just(.stopped).eraseToAnyPublisher() }
    func start() async {}
    func stop() async {}
    func sdkEventServerStatus() async -> SDKEventServerStatus { .stopped }
}

private final class LocalEchoHTTPServer: @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let uri: String
        let hostHeader: String?
        let hopHeader: String?
        let body: String
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var serverChannel: Channel?
    private let lock = NSLock()
    private let holdStreamOnPath: String?
    private var _requests: [RecordedRequest] = []
    private(set) var boundPort: UInt16 = 0

    var receivedRequests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    init(holdStreamOnPath: String? = nil) {
        self.holdStreamOnPath = holdStreamOnPath
    }

    func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(EchoHandler(server: self))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.serverChannel = channel
        self.boundPort = UInt16(channel.localAddress?.port ?? 0)
    }

    func stop() async {
        try? await serverChannel?.close().get()
        serverChannel = nil
        try? await group.shutdownGracefully()
    }

    fileprivate func record(_ req: RecordedRequest) -> Bool {
        lock.withLock { _requests.append(req) }
        return holdStreamOnPath == req.uri
    }

    private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: LocalEchoHTTPServer
        private var head: HTTPRequestHead?
        private var body = Data()

        init(server: LocalEchoHTTPServer) {
            self.server = server
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h):
                head = h
                body = Data()
            case .body(var buf):
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    body.append(contentsOf: bytes)
                }
            case .end:
                guard let head else { return }
                let hostHeader = head.headers.first(name: "Host")
                let hopHeader = head.headers.first(name: "X-JoesProxy-MapRemote-Hop")
                let bodyString = String(decoding: body, as: UTF8.self)
                let holdOpen = server.record(RecordedRequest(
                    method: head.method.rawValue,
                    uri: head.uri,
                    hostHeader: hostHeader,
                    hopHeader: hopHeader,
                    body: bodyString
                ))
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "text/plain")
                if holdOpen {
                    headers.add(name: "Cache-Control", value: "no-cache")
                    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .ok, headers: headers))), promise: nil)
                    let chunk = context.channel.allocator.buffer(string: "data: ping\n\n")
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(chunk))), promise: nil)
                } else {
                    let reply = "ok:\(head.uri)"
                    headers.add(name: "Content-Length", value: "\(reply.utf8.count)")
                    headers.add(name: "Connection", value: "close")
                    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .ok, headers: headers))), promise: nil)
                    context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: reply)))), promise: nil)
                    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                        context.close(promise: nil)
                    }
                }
            }
        }
    }
}

private final class LocalHLSVODOriginServer: @unchecked Sendable {
    private let rootDirectory: URL
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var serverChannel: Channel?
    private(set) var boundPort: UInt16 = 0

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func start() async throws {
        let root = self.rootDirectory
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HLSOriginHandler(rootDirectory: root))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.serverChannel = channel
        self.boundPort = UInt16(channel.localAddress?.port ?? 0)
    }

    func stop() async {
        try? await serverChannel?.close().get()
        serverChannel = nil
        try? await group.shutdownGracefully()
    }

    private final class HLSOriginHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let rootDirectory: URL
        private var head: HTTPRequestHead?

        init(rootDirectory: URL) {
            self.rootDirectory = rootDirectory
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h):
                head = h
            case .body:
                break
            case .end:
                guard let head else { return }
                let path = head.uri.components(separatedBy: "?").first ?? "/"
                if path == "/redirect-master.m3u8" {
                    var headers = HTTPHeaders()
                    headers.add(name: "Location", value: "/master.m3u8")
                    headers.add(name: "Content-Length", value: "0")
                    headers.add(name: "Connection", value: "close")
                    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .found, headers: headers))), promise: nil)
                    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                    return
                }
                if path == "/abs-master.m3u8" {
                    let body = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nhttp://cdn.example.invalid/video-360/stream.m3u8\n".utf8)
                    sendData(body, status: .ok, contentType: "application/vnd.apple.mpegurl", head: head, context: context)
                    return
                }
                let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let fileURL = rootDirectory.appendingPathComponent(relative)
                guard !relative.isEmpty,
                      let fileData = try? Data(contentsOf: fileURL) else {
                    let empty = Data()
                    sendData(empty, status: .notFound, contentType: "text/plain", head: head, context: context)
                    return
                }
                let contentType = relative.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
                if let rangeHeader = head.headers.first(name: "Range"),
                   rangeHeader.hasPrefix("bytes=") {
                    let bounds = String(rangeHeader.dropFirst(6)).split(separator: "-")
                    if bounds.count == 2,
                       let start = Int(bounds[0]),
                       let end = Int(bounds[1]),
                       start >= 0, end >= start, end < fileData.count {
                        let slice = fileData.subdata(in: start..<(end + 1))
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: contentType)
                        headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(fileData.count)")
                        headers.add(name: "Content-Length", value: "\(slice.count)")
                        headers.add(name: "Connection", value: "close")
                        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .partialContent, headers: headers))), promise: nil)
                        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: slice)))), promise: nil)
                        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                        return
                    }
                }
                sendData(fileData, status: .ok, contentType: contentType, head: head, context: context)
            }
        }

        private func sendData(_ data: Data, status: HTTPResponseStatus, contentType: String, head: HTTPRequestHead, context: ChannelHandlerContext) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(data.count)")
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
            if !data.isEmpty {
                context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: data)))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

