//
//  StatefulMockModels.swift
//  JoesProxy
//
//  Domain models for Intelligent Generative Mocking & State-Machine Backends.
//

import Foundation

/// Unique identity for a virtual stateful backend.
struct StatefulBackendID: Codable, Hashable, Sendable, Equatable, Identifiable {
    var rawValue: UUID

    var id: UUID { rawValue }

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A stored in-memory entity in a virtual collection (e.g. users, products, cart_items).
struct StatefulMockEntity: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let collection: String
    let fields: [String: String]
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        collection: String,
        fields: [String: String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.collection = collection
        self.fields = fields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Type of mutation action applied on a state transition.
enum StatefulMutationActionType: String, Codable, Equatable, Sendable {
    case none
    case clearCollection
    case seedCollection
    case updateEntityField
    case customJSON
}

/// Rule governing a state machine transition triggered by an incoming HTTP request.
struct StatefulMockTransitionRule: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(fromState)->\(toState):\(method) \(pathPattern)" }
    let fromState: String
    let toState: String
    let method: String
    let pathPattern: String
    let responseStatusCode: Int
    let responseBodyTemplate: String
    let mutationAction: StatefulMutationActionType
    let mutationPayload: String?

    init(
        fromState: String,
        toState: String,
        method: String,
        pathPattern: String,
        responseStatusCode: Int = 200,
        responseBodyTemplate: String,
        mutationAction: StatefulMutationActionType = .none,
        mutationPayload: String? = nil
    ) {
        self.fromState = fromState
        self.toState = toState
        self.method = method.uppercased()
        self.pathPattern = pathPattern
        self.responseStatusCode = responseStatusCode
        self.responseBodyTemplate = responseBodyTemplate
        self.mutationAction = mutationAction
        self.mutationPayload = mutationPayload
    }
}

/// Definition of a complete virtual stateful backend with state machine and CRUD collections.
struct StatefulVirtualBackend: Identifiable, Codable, Equatable, Sendable {
    let id: StatefulBackendID
    let name: String
    let originHost: String
    let description: String
    let initialState: String
    var activeState: String
    let possibleStates: [String]
    let supportedCollections: [String]
    let transitionRules: [StatefulMockTransitionRule]
    var isEnabled: Bool

    init(
        id: StatefulBackendID = StatefulBackendID(),
        name: String,
        originHost: String,
        description: String,
        initialState: String,
        activeState: String? = nil,
        possibleStates: [String],
        supportedCollections: [String] = [],
        transitionRules: [StatefulMockTransitionRule] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.originHost = originHost.lowercased()
        self.description = description
        self.initialState = initialState
        self.activeState = activeState ?? initialState
        self.possibleStates = possibleStates
        self.supportedCollections = supportedCollections
        self.transitionRules = transitionRules
        self.isEnabled = isEnabled
    }
}

/// Preset template ready for 1-click installation.
struct StatefulMockPreset: Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let defaultHost: String
    let backendFactory: (String) -> StatefulVirtualBackend
    let initialEntities: [StatefulMockEntity]
}
