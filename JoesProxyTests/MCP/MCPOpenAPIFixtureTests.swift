import XCTest
@testable import JoesProxy

/// AW-0 fixture guard: the synthetic OpenAPI document and scenario draft must stay valid JSON
/// and compile under the shipped scenario codec. Does not touch the live Application Support registry.
final class MCPOpenAPIFixtureTests: XCTestCase {
    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI", isDirectory: true)
    }

    func testCatalogOpenAPIDocumentIsJSONObjectWithRequiredOperations() throws {
        let data = try Data(contentsOf: fixturesURL.appendingPathComponent("catalog-v1.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["openapi"] as? String, "3.0.3")
        let paths = try XCTUnwrap(object["paths"] as? [String: Any])
        XCTAssertNotNil(paths["/v1/health"])
        XCTAssertNotNil(paths["/v1/items"])
        XCTAssertNotNil(paths["/v1/items/{itemId}"])
        XCTAssertNotNil(paths["/v1/stream"])
        let servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.first?["url"] as? String, "http://catalog.example.invalid")
    }

    func testExampleBodiesAreJSON() throws {
        for name in [
            "health.json",
            "items-available.json",
            "items-archived.json",
            "item-1.json",
            "item-not-found.json",
            "item-created.json"
        ] {
            let data = try Data(contentsOf: fixturesURL.appendingPathComponent(name))
            XCTAssertNotNil(
                try JSONSerialization.jsonObject(with: data),
                "\(name) must be valid JSON"
            )
        }
    }

    func testScenarioDraftCompilesFourExactPathMapLocalFaults() throws {
        let data = try Data(contentsOf: fixturesURL.appendingPathComponent("aw0-catalog-scenario.json"))
        let draft = try MCPScenarioJSONCodec.decodeDraft(from: data)
        XCTAssertEqual(draft.faults.count, 4)
        let compiled = try MCPScenarioCompiler.compile(draft: draft)
        XCTAssertEqual(compiled.faults.count, 4)
        XCTAssertEqual(compiled.target.hosts, ["catalog.example.invalid"])
        let paths = compiled.faults.compactMap { fault -> String? in
            if case .mapLocal(let matcher, _, _, _) = fault { return matcher.path }
            return nil
        }
        XCTAssertEqual(paths, [
            "/v1/health",
            "/v1/items",
            "/v1/items/item-1",
            "/v1/items/item-missing"
        ])
        XCTAssertFalse(
            paths.contains("/v1/items/{itemId}"),
            "Today's matcher cannot express an OpenAPI path template; the draft must use concrete exactPath ids."
        )
    }

    /// Serving-path proof for AW-0: exactPath hits the four staged routes and misses the unstaged
    /// template id plus POST. Uses an in-memory store — never the live Application Support registry.
    func testExactPathHitsStagedRoutesAndMissesTemplateAndPOST() async throws {
        let store = ResponseOverrideStore()
        let fixtures = fixturesURL
        let health = try Data(contentsOf: fixtures.appendingPathComponent("health.json"))
        let list = try Data(contentsOf: fixtures.appendingPathComponent("items-available.json"))
        let item = try Data(contentsOf: fixtures.appendingPathComponent("item-1.json"))
        let missing = try Data(contentsOf: fixtures.appendingPathComponent("item-not-found.json"))

        for (path, status, body) in [
            ("/v1/health", 200, health),
            ("/v1/items", 200, list),
            ("/v1/items/item-1", 200, item),
            ("/v1/items/item-missing", 404, missing)
        ] as [(String, Int, Data)] {
            _ = try await store.addRule(
                ResponseOverrideRule(
                    requestMethod: "GET",
                    requestScheme: .http,
                    host: "catalog.example.invalid",
                    port: 80,
                    path: path,
                    matchMode: .exactPath,
                    sourceKind: .inlineText,
                    sourceDescription: "aw0",
                    statusCode: status,
                    headers: [],
                    bodySource: .inline(body)
                )
            )
        }

        func request(method: String = "GET", path: String) -> CapturedRequest {
            CapturedRequest(
                method: method,
                scheme: .http,
                host: "catalog.example.invalid",
                port: 80,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        }

        guard case .mapLocal(let healthHit) = try await store.ruleDecision(for: request(path: "/v1/health")) else {
            return XCTFail("health must hit")
        }
        XCTAssertEqual(healthHit.statusCode, 200)
        XCTAssertEqual(healthHit.bodyData, health)

        guard case .mapLocal(let itemHit) = try await store.ruleDecision(for: request(path: "/v1/items/item-1")) else {
            return XCTFail("item-1 must hit")
        }
        XCTAssertEqual(itemHit.bodyData, item)

        guard case .mapLocal(let missingHit) = try await store.ruleDecision(for: request(path: "/v1/items/item-missing")) else {
            return XCTFail("item-missing must hit")
        }
        XCTAssertEqual(missingHit.statusCode, 404)

        if case .noMatch = try await store.ruleDecision(for: request(path: "/v1/items/item-2")) {
        } else {
            XCTFail("exactPath cannot serve OpenAPI {itemId} for an unstaged id")
        }

        if case .noMatch = try await store.ruleDecision(for: request(method: "POST", path: "/v1/items")) {
        } else {
            XCTFail("unstaged POST must fail open")
        }
    }

    func testMCPCatalogHasNoMapLocalUpdateInPlaceTool() {
        let names = MCPCapabilitiesManifestBuilder.productionTools.map(\.name)
        XCTAssertTrue(names.contains("propose_create_map_local"))
        XCTAssertTrue(names.contains("apply_create_map_local"))
        XCTAssertFalse(names.contains(where: { $0.contains("update_map_local") || $0.contains("update_rule") }))
        XCTAssertTrue(MCPSubscriptionResource.allowedURIs.contains("joesproxy://capture/summary"))
    }
}
