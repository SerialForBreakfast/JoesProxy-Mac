//
//  StatefulMockStore.swift
//  JoesProxy
//
//  Thread-safe in-memory database and state registry for virtual stateful backends.
//

import Foundation

actor StatefulMockStore {

    private var backends: [UUID: StatefulVirtualBackend] = [:]
    private var entitiesByBackendID: [UUID: [String: [String: StatefulMockEntity]]] = [:] // backendID -> collection -> id -> entity

    init() {}

    // MARK: - Backend Registration

    func registerBackend(_ backend: StatefulVirtualBackend, initialEntities: [StatefulMockEntity] = []) {
        let id = backend.id.rawValue
        backends[id] = backend
        entitiesByBackendID[id] = [:]

        for entity in initialEntities {
            insertEntity(backendID: backend.id, entity: entity)
        }
    }

    func removeBackend(id: StatefulBackendID) {
        let uuid = id.rawValue
        backends.removeValue(forKey: uuid)
        entitiesByBackendID.removeValue(forKey: uuid)
    }

    func activeBackends() -> [StatefulVirtualBackend] {
        Array(backends.values.filter { $0.isEnabled })
    }

    func allBackends() -> [StatefulVirtualBackend] {
        Array(backends.values)
    }

    func backend(forHost host: String) -> StatefulVirtualBackend? {
        let targetHost = host.lowercased()
        return backends.values.first { $0.isEnabled && ($0.originHost == targetHost || targetHost.contains($0.originHost) || $0.originHost.contains(targetHost)) }
    }

    func backend(id: StatefulBackendID) -> StatefulVirtualBackend? {
        backends[id.rawValue]
    }

    // MARK: - State Machine Control

    @discardableResult
    func setState(backendID: StatefulBackendID, state: String) -> Bool {
        guard var b = backends[backendID.rawValue] else { return false }
        b.activeState = state
        backends[backendID.rawValue] = b
        return true
    }

    func resetBackend(id: StatefulBackendID) {
        guard var b = backends[id.rawValue] else { return }
        b.activeState = b.initialState
        backends[id.rawValue] = b
        entitiesByBackendID[id.rawValue] = [:]
    }

    // MARK: - In-Memory Entity CRUD

    func insertEntity(backendID: StatefulBackendID, entity: StatefulMockEntity) {
        let uuid = backendID.rawValue
        var collections = entitiesByBackendID[uuid] ?? [:]
        var collection = collections[entity.collection] ?? [:]
        collection[entity.id] = entity
        collections[entity.collection] = collection
        entitiesByBackendID[uuid] = collections
    }

    func fetchEntity(backendID: StatefulBackendID, collection: String, id: String) -> StatefulMockEntity? {
        entitiesByBackendID[backendID.rawValue]?[collection]?[id]
    }

    func fetchAllEntities(backendID: StatefulBackendID, collection: String) -> [StatefulMockEntity] {
        guard let map = entitiesByBackendID[backendID.rawValue]?[collection] else {
            return []
        }
        return Array(map.values).sorted(by: { $0.createdAt < $1.createdAt })
    }

    @discardableResult
    func deleteEntity(backendID: StatefulBackendID, collection: String, id: String) -> Bool {
        guard var collections = entitiesByBackendID[backendID.rawValue],
              var collectionMap = collections[collection] else {
            return false
        }
        let removed = collectionMap.removeValue(forKey: id) != nil
        collections[collection] = collectionMap
        entitiesByBackendID[backendID.rawValue] = collections
        return removed
    }

    func allCollections(backendID: StatefulBackendID) -> [String: [StatefulMockEntity]] {
        guard let collections = entitiesByBackendID[backendID.rawValue] else {
            return [:]
        }
        var result: [String: [StatefulMockEntity]] = [:]
        for (col, items) in collections {
            result[col] = Array(items.values).sorted(by: { $0.createdAt < $1.createdAt })
        }
        return result
    }
}
