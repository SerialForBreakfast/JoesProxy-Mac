//
//  MCPStatefulMockService.swift
//  JoesProxy
//
//  MCP tool service for Autonomous AI Virtual State-Machine Backends.
//

import Foundation

@MainActor
final class MCPStatefulMockService {

    private let coordinator: StatefulMockCoordinator
    private let store: StatefulMockStore

    init(coordinator: StatefulMockCoordinator) {
        self.coordinator = coordinator
        self.store = coordinator.store
    }

    /// Lists all currently installed virtual backends.
    func listBackends() async -> [MCPStatefulBackendDTO] {
        let all = await store.allBackends()
        return all.map { b in
            MCPStatefulBackendDTO(
                id: b.id.rawValue.uuidString,
                name: b.name,
                originHost: b.originHost,
                activeState: b.activeState,
                possibleStates: b.possibleStates,
                supportedCollections: b.supportedCollections,
                isEnabled: b.isEnabled
            )
        }
    }

    /// Lists all available built-in presets.
    func listPresets() -> [MCPStatefulMockPresetSummaryDTO] {
        StatefulMockPresets.allPresets.map { p in
            MCPStatefulMockPresetSummaryDTO(
                id: p.id,
                title: p.title,
                summary: p.summary,
                defaultHost: p.defaultHost
            )
        }
    }

    /// Installs a built-in state-machine preset on a virtual backend.
    func installPreset(presetID: String, customHost: String? = nil) async throws -> MCPStatefulBackendDTO {
        guard let preset = StatefulMockPresets.allPresets.first(where: { $0.id == presetID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Preset '\(presetID)' not found.")
        }

        await coordinator.installPreset(preset, customHost: customHost)
        let installed = await store.allBackends().last { $0.name.contains(preset.title) || $0.originHost == (customHost ?? preset.defaultHost) }

        guard let backend = installed else {
            throw MCPStructuredError(code: .internalFailure, message: "Failed to verify installation of preset '\(presetID)'.")
        }

        return MCPStatefulBackendDTO(
            id: backend.id.rawValue.uuidString,
            name: backend.name,
            originHost: backend.originHost,
            activeState: backend.activeState,
            possibleStates: backend.possibleStates,
            supportedCollections: backend.supportedCollections,
            isEnabled: backend.isEnabled
        )
    }

    /// Forces a virtual backend into a specific state machine state.
    func setState(backendIDString: String, state: String) async throws -> MCPStatefulBackendDTO {
        guard let uuid = UUID(uuidString: backendIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Invalid UUID string: \(backendIDString)")
        }
        let backendID = StatefulBackendID(rawValue: uuid)
        guard let backend = await store.backend(id: backendID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Backend ID \(backendIDString) not found.")
        }

        guard backend.possibleStates.contains(state) else {
            throw MCPStructuredError(code: .malformedRequest, message: "State '\(state)' is not valid for backend '\(backend.name)'. Possible states: \(backend.possibleStates.joined(separator: ", "))")
        }

        await coordinator.setState(backendID: backendID, state: state)
        let updated = await store.backend(id: backendID) ?? backend

        return MCPStatefulBackendDTO(
            id: updated.id.rawValue.uuidString,
            name: updated.name,
            originHost: updated.originHost,
            activeState: updated.activeState,
            possibleStates: updated.possibleStates,
            supportedCollections: updated.supportedCollections,
            isEnabled: updated.isEnabled
        )
    }

    /// Queries in-memory entities from a virtual backend collection.
    func queryEntities(backendIDString: String, collection: String) async throws -> MCPStatefulMockCollectionDTO {
        guard let uuid = UUID(uuidString: backendIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Invalid UUID string: \(backendIDString)")
        }
        let backendID = StatefulBackendID(rawValue: uuid)
        guard let backend = await store.backend(id: backendID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Backend ID \(backendIDString) not found.")
        }

        let entities = await store.fetchAllEntities(backendID: backend.id, collection: collection)
        let entityDTOs = entities.map {
            MCPStatefulMockEntityDTO(id: $0.id, collection: $0.collection, fields: $0.fields)
        }

        return MCPStatefulMockCollectionDTO(
            backendID: backendIDString,
            collection: collection,
            entityCount: entityDTOs.count,
            entities: entityDTOs
        )
    }

    /// Resets a virtual backend's state machine to initial and clears dynamic entities.
    func resetBackend(backendIDString: String) async throws -> Bool {
        guard let uuid = UUID(uuidString: backendIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Invalid UUID string: \(backendIDString)")
        }
        let backendID = StatefulBackendID(rawValue: uuid)
        await coordinator.resetBackend(id: backendID)
        return true
    }
}
