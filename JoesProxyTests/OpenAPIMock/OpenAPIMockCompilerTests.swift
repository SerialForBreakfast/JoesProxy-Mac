import XCTest
@testable import JoesProxy

/// AW-2 importer/compiler: catalog fixture, version gates, $ref safety, selection, stable digests.
final class OpenAPIMockCompilerTests: XCTestCase {
    private let packID = OpenAPIMockPackID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI", isDirectory: true)
    }

    func testCatalogCompilesSupportedOperationsAndSkipsStream() throws {
        let pack = try compileCatalog()
        XCTAssertEqual(pack.origin.host, "catalog.example.invalid")
        XCTAssertEqual(pack.origin.scheme, .http)
        XCTAssertEqual(pack.origin.port, 80)

        let templates = Set(pack.routes.map(\.pathTemplate.rawValue))
        XCTAssertEqual(templates, ["/v1/health", "/v1/items", "/v1/items/{itemId}"])
        XCTAssertTrue(pack.routes.contains { $0.method == "GET" && $0.pathTemplate.rawValue == "/v1/health" })
        XCTAssertTrue(pack.routes.contains { $0.method == "POST" && $0.pathTemplate.rawValue == "/v1/items" })
        XCTAssertFalse(pack.routes.contains { $0.pathTemplate.rawValue == "/v1/stream" })
        XCTAssertTrue(pack.report.unsupported.contains { $0.feature == .eventStream })

        let post = try XCTUnwrap(pack.routes.first { $0.method == "POST" })
        XCTAssertEqual(post.requestContentType, "application/json")

        let list = try XCTUnwrap(pack.routes.first { $0.method == "GET" && $0.pathTemplate.rawValue == "/v1/items" })
        XCTAssertEqual(list.queryConstraints.count, 1)
        XCTAssertEqual(list.queryConstraints[0].name, "status")
        XCTAssertFalse(list.queryConstraints[0].isRequired)
        XCTAssertEqual(list.queryConstraints[0].allowedValues, ["archived", "available"])
    }

    func testCatalogDeclaredExamplesMatchFixtureBytes() throws {
        let pack = try compileCatalog()
        let health = try fixture(pack, method: "GET", template: "/v1/health", status: 200)
        XCTAssertEqual(health.variant.sourceKind, .declaredExample)
        try assertJSONEquals(health.body, fixtureName: "health.json")

        let item = try fixture(pack, method: "GET", template: "/v1/items/{itemId}", status: 200)
        try assertJSONEquals(item.body, fixtureName: "item-1.json")

        let missing = try fixture(pack, method: "GET", template: "/v1/items/{itemId}", status: 404)
        XCTAssertEqual(missing.variant.sourceKind, .namedError)
        XCTAssertEqual(missing.variant.name, "not_found")
        try assertJSONEquals(missing.body, fixtureName: "item-not-found.json")

        let created = try fixture(pack, method: "POST", template: "/v1/items", status: 201)
        try assertJSONEquals(created.body, fixtureName: "item-created.json")

        let available = try XCTUnwrap(
            pack.fixturesByVariantID.values.first {
                $0.variant.name == "available" && $0.status == 200 && $0.variant.id.contains("/v1/items|")
            }
        )
        try assertJSONEquals(available.body, fixtureName: "items-available.json")
        XCTAssertEqual(available.variant.sourceKind, .declaredExample)
    }

    func testCatalogDefaultListVariantFollowsNameSort() throws {
        let pack = try compileCatalog()
        let list = try XCTUnwrap(pack.routes.first { $0.method == "GET" && $0.pathTemplate.rawValue == "/v1/items" })
        let defaultFixture = try XCTUnwrap(pack.fixturesByVariantID[list.variantIDs[0]])
        XCTAssertEqual(defaultFixture.variant.name, "archived")
        XCTAssertEqual(defaultFixture.variant.sourceKind, .declaredExample)
        XCTAssertTrue(list.variantIDs.contains { pack.fixturesByVariantID[$0]?.variant.name == "available" })
    }

    func testCatalogCompileIsDeterministic() throws {
        let first = try compileCatalog()
        let second = try compileCatalog()
        XCTAssertEqual(first.routes.map(\.id), second.routes.map(\.id))
        XCTAssertEqual(Set(first.fixturesByVariantID.keys), Set(second.fixturesByVariantID.keys))
        for (id, fixture) in first.fixturesByVariantID {
            XCTAssertEqual(fixture.body, second.fixturesByVariantID[id]?.body)
            XCTAssertEqual(fixture.variant.bodyDigest, second.fixturesByVariantID[id]?.variant.bodyDigest)
        }
    }

    func testItemTemplateMatchesConcreteIds() throws {
        let pack = try compileCatalog()
        let item = try XCTUnwrap(pack.routes.first { $0.pathTemplate.rawValue == "/v1/items/{itemId}" })
        let request = OpenAPIMockMatchRequest(
            method: "GET",
            origin: pack.origin,
            path: "/v1/items/item-2",
            query: [:],
            contentType: nil
        )
        XCTAssertEqual(try OpenAPIMockRouteMatcher.select(routes: pack.routes, request: request)?.id, item.id)
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: pack.routes,
                request: OpenAPIMockMatchRequest(
                    method: "GET",
                    origin: pack.origin,
                    path: "/v1/stream",
                    query: [:],
                    contentType: nil
                )
            )
        )
    }

    func testMalformedAndVersionMismatchedDocumentsAreRejected() throws {
        XCTAssertThrowsError(try compile(Data("{".utf8))) { error in
            guard let compilerError = error as? OpenAPIMockCompilerError,
                  case .malformedJSON = compilerError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
        XCTAssertThrowsError(try compile(Data("openapi: 3.0.3\ninfo: {}\n".utf8))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .yamlDocument)
        }
        XCTAssertThrowsError(try compile(document(["swagger": "2.0", "info": ["title": "x", "version": "1"], "paths": [:]]))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .unsupportedVersion("2.0"))
        }
        XCTAssertThrowsError(try compile(document(["openapi": "3.1.0", "info": ["title": "x", "version": "1"], "paths": [:]]))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .unsupportedVersion("3.1.0"))
        }
    }

    func testRemoteRefIsRejectedWithoutNetwork() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "r", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/x": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "x",
                                "content": [
                                    "application/json": [
                                        "schema": ["$ref": "https://example.invalid/schema.json"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .noSupportedOperations)
        }
        let packOrError = Result { try compile(document(spec)) }
        if case .failure(let error) = packOrError {
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .noSupportedOperations)
        }
    }

    func testReferenceCycleIsReported() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "c", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/cycle": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "c",
                                "content": [
                                    "application/json": [
                                        "schema": ["$ref": "#/components/schemas/A"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "components": [
                "schemas": [
                    "A": ["$ref": "#/components/schemas/B"],
                    "B": ["$ref": "#/components/schemas/A"]
                ]
            ]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .noSupportedOperations)
        }
    }

    func testRefDepthBudgetIsEnforced() throws {
        var schemas: [String: Any] = ["Leaf": ["type": "string", "example": "x"]]
        for index in stride(from: 8, through: 1, by: -1) {
            schemas["N\(index)"] = ["$ref": "#/components/schemas/N\(index + 1)"]
        }
        schemas["N9"] = ["$ref": "#/components/schemas/Leaf"]
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "d", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/deep": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "d",
                                "content": [
                                    "application/json": [
                                        "schema": ["$ref": "#/components/schemas/N1"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "components": ["schemas": schemas]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .noSupportedOperations)
        }
    }

    func testDocumentByteBudgetRejectsBeforeParse() {
        let oversized = Data(repeating: 0x7B, count: OpenAPIMockPackBudget.maxDocumentBytes + 1)
        XCTAssertThrowsError(try compile(oversized)) { error in
            XCTAssertEqual(
                error as? OpenAPIMockCompilerError,
                .pack(.documentTooLarge(byteCount: OpenAPIMockPackBudget.maxDocumentBytes + 1))
            )
        }
    }

    func testTooManyOperationsAreRejected() throws {
        var paths: [String: Any] = [:]
        for index in 1...33 {
            paths["/p/\(index)"] = [
                "get": [
                    "responses": [
                        "200": [
                            "description": "x",
                            "content": ["application/json": ["example": ["ok": true]]]
                        ]
                    ]
                ]
            ]
        }
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "many", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": paths
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .pack(.tooManyOperations(count: 33)))
        }
    }

    func testOneOfWithoutExampleIsReportedNotGuessed() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "u", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/union": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "u",
                                "content": [
                                    "application/json": [
                                        "schema": [
                                            "oneOf": [
                                                ["type": "string"],
                                                ["type": "integer"]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .noSupportedOperations)
        }
    }

    func testSchemaEnumAndDefaultFillWhenNoExample() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "e", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/status": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "e",
                                "content": [
                                    "application/json": [
                                        "schema": [
                                            "type": "string",
                                            "enum": ["archived", "available"]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "/v1/flag": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "d",
                                "content": [
                                    "application/json": [
                                        "schema": [
                                            "type": "boolean",
                                            "default": true
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let pack = try compile(document(spec))
        let status = try fixture(pack, method: "GET", template: "/v1/status", status: 200)
        XCTAssertEqual(status.variant.sourceKind, .schemaEnum)
        XCTAssertEqual(String(data: status.body, encoding: .utf8), "\"archived\"")
        let flag = try fixture(pack, method: "GET", template: "/v1/flag", status: 200)
        XCTAssertEqual(flag.variant.sourceKind, .schemaDefault)
        XCTAssertEqual(String(data: flag.body, encoding: .utf8), "true")
    }

    func testSyntheticGenerationIsStableAndSchemaValid() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "s", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/widget": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "s",
                                "content": [
                                    "application/json": [
                                        "schema": [
                                            "type": "object",
                                            "required": ["id", "name"],
                                            "properties": [
                                                "id": ["type": "string", "format": "uuid"],
                                                "name": ["type": "string"]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let first = try compile(document(spec))
        let second = try compile(document(spec))
        let fixture = try self.fixture(first, method: "GET", template: "/v1/widget", status: 200)
        XCTAssertEqual(fixture.variant.sourceKind, .synthetic)
        XCTAssertEqual(fixture.body, try self.fixture(second, method: "GET", template: "/v1/widget", status: 200).body)
        XCTAssertEqual(fixture.variant.bodyDigest, OpenAPIMockJSONValue.sha256Hex(fixture.body))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.body) as? [String: Any])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(object["id"] as? String)))
        XCTAssertEqual(try XCTUnwrap(object["name"] as? String).hasPrefix("syn-"), true)
    }

    func testLiteralFeaturedBeatsItemIdAfterCompile() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "p", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/catalog/items/{itemId}": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "id",
                                "content": ["application/json": ["example": ["id": "x"]]]
                            ]
                        ]
                    ]
                ],
                "/v1/catalog/items/featured": [
                    "get": [
                        "responses": [
                            "200": [
                                "description": "feat",
                                "content": ["application/json": ["example": ["id": "featured"]]]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let pack = try compile(document(spec))
        let featured = try OpenAPIMockRouteMatcher.select(
            routes: pack.routes,
            request: OpenAPIMockMatchRequest(
                method: "GET",
                origin: pack.origin,
                path: "/v1/catalog/items/featured",
                query: [:],
                contentType: nil
            )
        )
        XCTAssertEqual(featured?.pathTemplate.rawValue, "/v1/catalog/items/featured")
    }

    func testRemainingTieConflictsFailCompile() throws {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "t", "version": "1"],
            "servers": [["url": "http://catalog.example.invalid"]],
            "paths": [
                "/v1/{a}": [
                    "get": [
                        "responses": [
                            "200": ["description": "a", "content": ["application/json": ["example": ["a": 1]]]]
                        ]
                    ]
                ],
                "/v1/{b}": [
                    "get": [
                        "responses": [
                            "200": ["description": "b", "content": ["application/json": ["example": ["b": 1]]]]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            guard let compilerError = error as? OpenAPIMockCompilerError,
                  case .remainingTieConflict = compilerError else {
                return XCTFail("expected remainingTieConflict, got \(error)")
            }
        }
    }

    func testMissingOriginWithoutServersIsRejected() {
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "n", "version": "1"],
            "paths": [
                "/v1/x": [
                    "get": [
                        "responses": [
                            "200": ["description": "x", "content": ["application/json": ["example": ["ok": true]]]]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try compile(document(spec))) { error in
            XCTAssertEqual(error as? OpenAPIMockCompilerError, .missingOrigin)
        }
    }

    private func compileCatalog() throws -> OpenAPIMockCompiledPack {
        let data = try Data(contentsOf: fixturesURL.appendingPathComponent("catalog-v1.json"))
        return try compile(data)
    }

    private func compile(_ data: Data) throws -> OpenAPIMockCompiledPack {
        try OpenAPIMockCompiler.compile(
            OpenAPIMockCompileRequest(document: data, packID: packID, originOverride: nil)
        )
    }

    private func document(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertJSONEquals(_ actual: Data, fixtureName: String) throws {
        let expected = try Data(contentsOf: fixturesURL.appendingPathComponent(fixtureName))
        let actualObject = try JSONSerialization.jsonObject(with: actual)
        let expectedObject = try JSONSerialization.jsonObject(with: expected)
        let actualCanonical = try JSONSerialization.data(withJSONObject: actualObject, options: [.sortedKeys])
        let expectedCanonical = try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys])
        XCTAssertEqual(actualCanonical, expectedCanonical, fixtureName)
    }

    private func fixture(
        _ pack: OpenAPIMockCompiledPack,
        method: String,
        template: String,
        status: Int
    ) throws -> OpenAPIMockCompiledFixture {
        let match = pack.fixturesByVariantID.values.filter {
            $0.variant.id.hasPrefix("\(method)|\(template)|\(status)|")
        }
        XCTAssertFalse(match.isEmpty, "missing fixture \(method) \(template) \(status)")
        if match.count == 1 { return match[0] }
        return try XCTUnwrap(match.first { $0.status == status })
    }
}
