//
//  StatefulMockStoreTests.swift
//  JoesProxyTests
//
//  Unit tests for in-memory database CRUD and state management.
//

import XCTest
@testable import JoesProxy

final class StatefulMockStoreTests: XCTestCase {

    func testBackendRegistrationAndStateTransitions() async {
        let store = StatefulMockStore()
        let backend = StatefulVirtualBackend(
            name: "Test Auth",
            originHost: "auth.example.com",
            description: "Auth backend",
            initialState: "LoggedOut",
            possibleStates: ["LoggedOut", "Authenticated", "TokenExpired"]
        )

        await store.registerBackend(backend)

        let fetched = await store.backend(forHost: "auth.example.com")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.activeState, "LoggedOut")

        let changed = await store.setState(backendID: backend.id, state: "Authenticated")
        XCTAssertTrue(changed)

        let updated = await store.backend(id: backend.id)
        XCTAssertEqual(updated?.activeState, "Authenticated")

        await store.resetBackend(id: backend.id)
        let reset = await store.backend(id: backend.id)
        XCTAssertEqual(reset?.activeState, "LoggedOut")
    }

    func testInMemoryCollectionCRUDOperations() async {
        let store = StatefulMockStore()
        let backend = StatefulVirtualBackend(
            name: "Test Store",
            originHost: "store.example.com",
            description: "E-Commerce",
            initialState: "Ready",
            possibleStates: ["Ready"],
            supportedCollections: ["products"]
        )

        let initialProd = StatefulMockEntity(
            id: "prod_1",
            collection: "products",
            fields: ["name": "Keyboard", "price": "99.99"]
        )

        await store.registerBackend(backend, initialEntities: [initialProd])

        // 1. Fetch initial
        let prods = await store.fetchAllEntities(backendID: backend.id, collection: "products")
        XCTAssertEqual(prods.count, 1)
        XCTAssertEqual(prods.first?.fields["name"], "Keyboard")

        // 2. Insert new
        let secondProd = StatefulMockEntity(
            id: "prod_2",
            collection: "products",
            fields: ["name": "Mouse", "price": "49.99"]
        )
        await store.insertEntity(backendID: backend.id, entity: secondProd)

        let prodsAfterInsert = await store.fetchAllEntities(backendID: backend.id, collection: "products")
        XCTAssertEqual(prodsAfterInsert.count, 2)

        // 3. Delete
        let deleted = await store.deleteEntity(backendID: backend.id, collection: "products", id: "prod_1")
        XCTAssertTrue(deleted)

        let prodsAfterDelete = await store.fetchAllEntities(backendID: backend.id, collection: "products")
        XCTAssertEqual(prodsAfterDelete.count, 1)
        XCTAssertEqual(prodsAfterDelete.first?.id, "prod_2")
    }
}
