//
//  StatefulMockEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for dynamic routing, state-machine transitions, and template interpolation.
//

import XCTest
@testable import JoesProxy

final class StatefulMockEngineTests: XCTestCase {

    func testStateTransitionRuleExecutionAndResponse() async {
        let store = StatefulMockStore()
        let preset = StatefulMockPresets.ecommerceCartPreset
        let backend = preset.backendFactory("api.store.example.com")
        await store.registerBackend(backend, initialEntities: preset.initialEntities)

        // 1. Initial State: EmptyCart
        var fetched = await store.backend(id: backend.id)
        XCTAssertEqual(fetched?.activeState, "EmptyCart")

        // 2. Request POST /cart/items -> triggers transition to ItemAdded
        let req1 = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/cart/items",
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: "{\"productId\":\"prod_001\",\"quantity\":1}".data(using: .utf8),
            bodySize: 35
        )

        let resp1 = await StatefulMockEngine.handleRequest(req1, in: store)
        XCTAssertNotNil(resp1)
        XCTAssertEqual(resp1?.statusCode, 201)

        fetched = await store.backend(id: backend.id)
        XCTAssertEqual(fetched?.activeState, "ItemAdded")

        // 3. Request POST /cart/checkout -> triggers transition to CheckedOut with dynamic UUID
        let req2 = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/cart/checkout",
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )

        let resp2 = await StatefulMockEngine.handleRequest(req2, in: store)
        XCTAssertNotNil(resp2)
        XCTAssertEqual(resp2?.statusCode, 200)

        let bodyString = resp2?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyString.contains("order_confirmed"))
        XCTAssertFalse(bodyString.contains("{{uuid}}")) // UUID must be interpolated

        fetched = await store.backend(id: backend.id)
        XCTAssertEqual(fetched?.activeState, "CheckedOut")
    }

    func testGenericCollectionCRUDRouting() async {
        let store = StatefulMockStore()
        let preset = StatefulMockPresets.ecommerceCartPreset
        let backend = preset.backendFactory("api.store.example.com")
        await store.registerBackend(backend, initialEntities: preset.initialEntities)

        // 1. GET /products -> List 2 products
        let listReq = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/products",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let listResp = await StatefulMockEngine.handleRequest(listReq, in: store)
        XCTAssertEqual(listResp?.statusCode, 200)

        let bodyString = listResp?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyString.contains("Wireless Noise-Cancelling Headphones"))

        // 2. GET /products/prod_001 -> Single item
        let singleReq = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/products/prod_001",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let singleResp = await StatefulMockEngine.handleRequest(singleReq, in: store)
        XCTAssertEqual(singleResp?.statusCode, 200)

        // 3. POST /products -> Create new item
        let postReq = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/products",
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: "{\"id\":\"prod_999\",\"title\":\"USB-C Cable\",\"price\":\"19.99\"}".data(using: .utf8),
            bodySize: 50
        )
        let postResp = await StatefulMockEngine.handleRequest(postReq, in: store)
        XCTAssertEqual(postResp?.statusCode, 201)

        // 4. GET /products/prod_999 -> Verify newly created item
        let verifyReq = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.store.example.com",
            port: 443,
            path: "/products/prod_999",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let verifyResp = await StatefulMockEngine.handleRequest(verifyReq, in: store)
        XCTAssertEqual(verifyResp?.statusCode, 200)
        let verifyBody = verifyResp?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(verifyBody.contains("USB-C Cable"))
    }
}
