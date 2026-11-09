//
//  StatefulMockEngine.swift
//  JoesProxy
//
//  Evaluates requests against virtual stateful backends, executes transitions, and handles CRUD routing.
//

import Foundation

enum StatefulMockEngine {

    /// Evaluates a captured request against active stateful virtual backends and returns a synthetic response if handled.
    static func handleRequest(
        _ request: CapturedRequest,
        in store: StatefulMockStore
    ) async -> CapturedResponse? {
        guard let backend = await store.backend(forHost: request.host) else {
            return nil
        }

        let method = request.method.uppercased()
        let path = request.path

        // 1. Check for State Machine Transition Rule
        if let rule = backend.transitionRules.first(where: {
            $0.fromState == backend.activeState &&
            $0.method == method &&
            matchesPath(pattern: $0.pathPattern, path: path)
        }) {
            // Apply state transition
            await store.setState(backendID: backend.id, state: rule.toState)

            // Render response
            let interpolated = interpolate(
                template: rule.responseBodyTemplate,
                request: request,
                state: rule.toState
            )
            let bodyData = interpolated.data(using: .utf8) ?? Data()

            return CapturedResponse(
                statusCode: rule.responseStatusCode,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json"),
                    HTTPHeaderField(name: "X-JoesProxy-Virtual-State", value: rule.toState)
                ],
                bodyData: bodyData,
                bodySize: bodyData.count
            )
        }

        // 2. Check for Generic In-Memory Collection CRUD Routing
        for collection in backend.supportedCollections {
            let collectionPrefix = "/\(collection)"
            if path == collectionPrefix || path == "\(collectionPrefix)/" {
                if method == "GET" {
                    // List entities
                    let entities = await store.fetchAllEntities(backendID: backend.id, collection: collection)
                    let arrayJSON = entities.map { entity -> [String: Any] in
                        var dict: [String: Any] = entity.fields
                        dict["id"] = entity.id
                        return dict
                    }
                    let data = (try? JSONSerialization.data(withJSONObject: arrayJSON, options: [.prettyPrinted])) ?? "[]".data(using: .utf8)!
                    return CapturedResponse(
                        statusCode: 200,
                        headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                        bodyData: data,
                        bodySize: data.count
                    )
                } else if method == "POST" {
                    // Create entity
                    let bodyDict = request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    var fields: [String: String] = [:]
                    for (k, v) in bodyDict {
                        fields[k] = "\(v)"
                    }
                    let newID = fields["id"] ?? "ent_\(UUID().uuidString.prefix(8).lowercased())"
                    let entity = StatefulMockEntity(id: newID, collection: collection, fields: fields)
                    await store.insertEntity(backendID: backend.id, entity: entity)

                    var responseDict: [String: Any] = fields
                    responseDict["id"] = newID
                    let data = (try? JSONSerialization.data(withJSONObject: responseDict, options: [.prettyPrinted])) ?? "{}".data(using: .utf8)!
                    return CapturedResponse(
                        statusCode: 201,
                        headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                        bodyData: data,
                        bodySize: data.count
                    )
                }
            } else if path.hasPrefix("\(collectionPrefix)/") {
                let entityID = String(path.dropFirst(collectionPrefix.count + 1))
                if method == "GET" {
                    // Get single entity
                    if let entity = await store.fetchEntity(backendID: backend.id, collection: collection, id: entityID) {
                        var dict: [String: Any] = entity.fields
                        dict["id"] = entity.id
                        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])) ?? "{}".data(using: .utf8)!
                        return CapturedResponse(
                            statusCode: 200,
                            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                            bodyData: data,
                            bodySize: data.count
                        )
                    } else {
                        let errData = "{\"error\": \"not_found\"}".data(using: .utf8)!
                        return CapturedResponse(
                            statusCode: 404,
                            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                            bodyData: errData,
                            bodySize: errData.count
                        )
                    }
                } else if method == "DELETE" {
                    // Delete entity
                    let deleted = await store.deleteEntity(backendID: backend.id, collection: collection, id: entityID)
                    let resp = deleted ? "{\"deleted\": true}" : "{\"error\": \"not_found\"}"
                    let data = resp.data(using: .utf8)!
                    return CapturedResponse(
                        statusCode: deleted ? 200 : 404,
                        headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                        bodyData: data,
                        bodySize: data.count
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Template Engine

    static func interpolate(
        template: String,
        request: CapturedRequest,
        state: String
    ) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{uuid}}", with: UUID().uuidString)
        result = result.replacingOccurrences(of: "{{state}}", with: state)

        let isoDate = ISO8601DateFormatter().string(from: Date())
        result = result.replacingOccurrences(of: "{{now}}", with: isoDate)

        return result
    }

    // MARK: - Matching Helpers

    static func matchesPath(pattern: String, path: String) -> Bool {
        if pattern == path { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return path.hasPrefix(prefix)
        }
        return false
    }
}
