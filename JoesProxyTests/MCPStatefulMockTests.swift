//
//  MCPStatefulMockTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Stateful Virtual Backend tool endpoints and operations.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPStatefulMockTests: XCTestCase {

    func testMCPStatefulMockServiceLifecycle() async throws {
        let store = StatefulMockStore()
        let coordinator = StatefulMockCoordinator(store: store)
        let service = MCPStatefulMockService(coordinator: coordinator)

        // 1. List presets
        let presets = service.listPresets()
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.contains(where: { $0.id == "ecommerce_cart" }))

        // 2. Install preset via MCP
        let installed = try await service.installPreset(presetID: "ecommerce_cart", customHost: "api.shop.local")
        XCTAssertEqual(installed.originHost, "api.shop.local")
        XCTAssertEqual(installed.activeState, "EmptyCart")

        // 3. Set State via MCP
        let stateUpdated = try await service.setState(backendIDString: installed.id, state: "ItemAdded")
        XCTAssertEqual(stateUpdated.activeState, "ItemAdded")

        // 4. Query in-memory entities via MCP
        let collectionDTO = try await service.queryEntities(backendIDString: installed.id, collection: "products")
        XCTAssertEqual(collectionDTO.collection, "products")
        XCTAssertEqual(collectionDTO.entityCount, 2)

        // 5. Reset backend via MCP
        let reset = try await service.resetBackend(backendIDString: installed.id)
        XCTAssertTrue(reset)

        let backends = await service.listBackends()
        let found = backends.first(where: { $0.id == installed.id })
        XCTAssertEqual(found?.activeState, "EmptyCart")
    }
}
