import XCTest
@testable import JoesProxy

final class DeviceScopedOverrideTests: XCTestCase {
    private var overrideStore: ResponseOverrideStore!

    override func setUp() async throws {
        try await super.setUp()
        overrideStore = ResponseOverrideStore()
    }

    private func makeRequest(path: String, clientAddress: String?) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil,
            clientAddress: clientAddress
        )
    }

    private func makeSession(request: CapturedRequest) -> SessionRecord {
        SessionRecord(
            request: request,
            timing: SessionTiming(startedAt: Date())
        )
    }

    func testSessionFilterEngineMatchesClientAddress() {
        let engine = SessionFilterEngine()
        let req1 = makeRequest(path: "/v1/feed", clientAddress: "192.168.1.50")
        let s1 = makeSession(request: req1)

        let req2 = makeRequest(path: "/v1/feed", clientAddress: "192.168.1.100")
        let s2 = makeSession(request: req2)

        var criteria = SessionFilterCriteria()
        criteria.clientAddressMatch = "192.168.1.50"

        let filtered = engine.filter([s1, s2], criteria: criteria, searchText: "")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.request.clientAddress, "192.168.1.50")
    }

    func testPerDeviceOverrideRuleScoping() async throws {
        // Create rule scoped strictly to 192.168.1.50
        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/config",
            matchMode: .exactPath,
            sourceKind: .inlineText,
            sourceDescription: "Inline Text",
            statusCode: 200,
            headers: [],
            bodySource: .inline("{\"device\":\"phone\"}".data(using: .utf8)),
            sourceClientAddress: "192.168.1.50"
        )
        try await overrideStore.addRule(rule)

        // Request from 192.168.1.50 should match (mapLocal)
        let matchingReq = makeRequest(path: "/v1/config", clientAddress: "192.168.1.50")
        let matchDecision = try await overrideStore.ruleDecision(for: matchingReq)
        if case .mapLocal = matchDecision {
            // expected
        } else {
            XCTFail("Expected .mapLocal decision for matching clientAddress, got \(matchDecision)")
        }

        // Request from 192.168.1.100 should bypass (noMatch)
        let bypassingReq = makeRequest(path: "/v1/config", clientAddress: "192.168.1.100")
        let bypassDecision = try await overrideStore.ruleDecision(for: bypassingReq)
        if case .noMatch = bypassDecision {
            // expected
        } else {
            XCTFail("Expected .noMatch decision for non-matching clientAddress, got \(bypassDecision)")
        }

        // Request from Mac loopback should bypass (noMatch)
        let loopbackReq = makeRequest(path: "/v1/config", clientAddress: "127.0.0.1")
        let loopbackDecision = try await overrideStore.ruleDecision(for: loopbackReq)
        if case .noMatch = loopbackDecision {
            // expected
        } else {
            XCTFail("Expected .noMatch decision for loopback request, got \(loopbackDecision)")
        }
    }

    func testGlobalRuleMatchesAnyClientAddress() async throws {
        let globalRule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/global",
            matchMode: .exactPath,
            sourceKind: .inlineText,
            sourceDescription: "Inline Text",
            statusCode: 200,
            headers: [],
            bodySource: .inline("{\"scope\":\"global\"}".data(using: .utf8)),
            sourceClientAddress: nil
        )
        try await overrideStore.addRule(globalRule)

        let reqA = makeRequest(path: "/v1/global", clientAddress: "192.168.1.50")
        let decA = try await overrideStore.ruleDecision(for: reqA)
        if case .mapLocal = decA {
            // expected
        } else {
            XCTFail("Expected .mapLocal for reqA, got \(decA)")
        }

        let reqB = makeRequest(path: "/v1/global", clientAddress: "192.168.1.100")
        let decB = try await overrideStore.ruleDecision(for: reqB)
        if case .mapLocal = decB {
            // expected
        } else {
            XCTFail("Expected .mapLocal for reqB, got \(decB)")
        }
    }

    func testMCPDeviceServiceListAndSetAlias() async {
        let registry = DeviceRegistry()
        let service = MCPDeviceService(registry: registry)

        _ = await registry.recordClientConnection(ipAddress: "192.168.1.88")
        let listResp = await service.listDevices()
        XCTAssertEqual(listResp.devices.count, 1)
        XCTAssertEqual(listResp.devices.first?.ipAddress, "192.168.1.88")

        let aliasReq = MCPSetDeviceAliasRequestDTO(ipAddress: "192.168.1.88", alias: "QA iPad")
        let setResp = await service.setDeviceAlias(request: aliasReq)
        XCTAssertNotNil(setResp)
        XCTAssertEqual(setResp?.device.customAlias, "QA iPad")
        XCTAssertEqual(setResp?.device.displayName, "QA iPad")
    }

    func testDeviceToolsAreRegisteredAndPolicyRouted() {
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.isSuperset(of: [
            "list_discovered_devices",
            "set_device_alias"
        ]))
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "list_discovered_devices"), .deviceInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "set_device_alias"), .deviceAliasManage)
    }

    func testDeviceScopeSurvivesPersistenceRoundTrip() async throws {
        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/persisted",
            sourceKind: .inlineText,
            sourceDescription: "Inline Text",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("scoped".utf8)),
            sourceClientAddress: "192.168.1.88"
        )
        try await overrideStore.addRule(rule)

        let persisted = try await overrideStore.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(persisted)

        let restoredRules = await restored.rules()
        XCTAssertEqual(restoredRules.first?.sourceClientAddress, "192.168.1.88")
    }

    func testDeviceScopeChangesTargetRevision() {
        let global = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/revision",
            sourceKind: .inlineText,
            sourceDescription: "Inline Text",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("same-body".utf8))
        )
        var scoped = global
        scoped.sourceClientAddress = "192.168.1.88"

        XCTAssertNotEqual(
            MCPTargetRevisionFingerprint.revision(for: global),
            MCPTargetRevisionFingerprint.revision(for: scoped)
        )
    }
}
