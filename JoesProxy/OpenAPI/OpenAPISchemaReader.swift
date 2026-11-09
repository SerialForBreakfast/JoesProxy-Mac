//
//  OpenAPISchemaReader.swift
//  JoesProxy
//
//  Parses OpenAPI 3.0 and 3.1 JSON documents into typed `OpenAPISchemaDocument` models.
//

import Foundation

enum OpenAPISchemaReaderError: Error, Equatable, LocalizedError {
    case invalidJSON(String)
    case missingInfo
    case missingPaths

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return "Invalid OpenAPI JSON document: \(detail)"
        case .missingInfo: return "OpenAPI document missing required 'info' object."
        case .missingPaths: return "OpenAPI document missing 'paths' object."
        }
    }
}

enum OpenAPISchemaReader {

    static func parse(data: Data) throws -> OpenAPISchemaDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAPISchemaReaderError.invalidJSON("Root must be a JSON object.")
        }
        return try parse(root: root)
    }

    static func parse(root: [String: Any]) throws -> OpenAPISchemaDocument {
        guard let info = root["info"] as? [String: Any] else {
            throw OpenAPISchemaReaderError.missingInfo
        }

        let title = info["title"] as? String ?? "OpenAPI Spec"
        let version = info["version"] as? String ?? "1.0.0"

        var serverURLs: [String] = []
        if let servers = root["servers"] as? [[String: Any]] {
            for server in servers {
                if let url = server["url"] as? String {
                    serverURLs.append(url)
                }
            }
        }

        let components = root["components"] as? [String: Any] ?? [:]
        let schemaComponents = components["schemas"] as? [String: Any] ?? [:]

        guard let paths = root["paths"] as? [String: Any] else {
            throw OpenAPISchemaReaderError.missingPaths
        }

        var operations: [OpenAPIOperationDefinition] = []
        let httpMethods = ["get", "post", "put", "patch", "delete", "head", "options", "trace"]

        for (pathTemplate, pathValue) in paths {
            guard let pathDict = pathValue as? [String: Any] else { continue }

            for method in httpMethods {
                guard let opDict = pathDict[method] as? [String: Any] else { continue }

                let summary = opDict["summary"] as? String
                let description = opDict["description"] as? String
                let tags = opDict["tags"] as? [String] ?? []
                let opID = opDict["operationId"] as? String ?? "\(method.uppercased()) \(pathTemplate)"

                var parameters: [OpenAPIParameterDefinition] = []
                if let paramsList = opDict["parameters"] as? [[String: Any]] {
                    for p in paramsList {
                        if let name = p["name"] as? String,
                           let inStr = p["in"] as? String,
                           let loc = OpenAPIParameterLocation(rawValue: inStr) {
                            let required = p["required"] as? Bool ?? false
                            let pSchemaDict = p["schema"] as? [String: Any]
                            let parsedPSchema = pSchemaDict.map { parseSchema($0, components: schemaComponents) }
                            parameters.append(
                                OpenAPIParameterDefinition(name: name, location: loc, required: required, schema: parsedPSchema)
                            )
                        }
                    }
                }

                var responses: [String: OpenAPIResponseDefinition] = [:]
                if let respDict = opDict["responses"] as? [String: Any] {
                    for (code, rValue) in respDict {
                        guard let rDict = rValue as? [String: Any] else { continue }
                        let rDesc = rDict["description"] as? String

                        var contentMap: [String: OpenAPIJSONSchema] = [:]
                        if let contentDict = rDict["content"] as? [String: Any] {
                            for (contentType, cValue) in contentDict {
                                guard let cDict = cValue as? [String: Any],
                                      let schemaDict = cDict["schema"] as? [String: Any] else { continue }
                                contentMap[contentType] = parseSchema(schemaDict, components: schemaComponents)
                            }
                        }
                        responses[code] = OpenAPIResponseDefinition(statusCode: code, description: rDesc, content: contentMap)
                    }
                }

                operations.append(
                    OpenAPIOperationDefinition(
                        id: opID,
                        method: method.uppercased(),
                        pathTemplate: pathTemplate,
                        summary: summary,
                        description: description,
                        tags: tags,
                        parameters: parameters,
                        responses: responses
                    )
                )
            }
        }

        return OpenAPISchemaDocument(
            title: title,
            version: version,
            servers: serverURLs,
            operations: operations
        )
    }

    static func parseSchema(_ dict: [String: Any], components: [String: Any], depth: Int = 0) -> OpenAPIJSONSchema {
        if depth > 10 {
            return OpenAPIJSONSchema(type: .object, description: "Max schema depth exceeded")
        }

        // Handle $ref resolution
        if let ref = dict["$ref"] as? String, ref.hasPrefix("#/components/schemas/") {
            let schemaName = String(ref.dropFirst("#/components/schemas/".count))
            if let resolved = components[schemaName] as? [String: Any] {
                return parseSchema(resolved, components: components, depth: depth + 1)
            }
        }

        let typeStr = dict["type"] as? String
        let dataType = typeStr.flatMap { OpenAPIJSONDataType(rawValue: $0.lowercased()) }
        let format = dict["format"] as? String
        let description = dict["description"] as? String
        let required = dict["required"] as? [String]
        let enumVals = (dict["enum"] as? [Any])?.compactMap { "\($0)" }
        let defaultValue = dict["default"].map { "\($0)" }
        let exampleValue = dict["example"].map { "\($0)" }
        let nullable = dict["nullable"] as? Bool

        var properties: [String: OpenAPIJSONSchema]? = nil
        if let propsDict = dict["properties"] as? [String: Any] {
            var parsedProps: [String: OpenAPIJSONSchema] = [:]
            for (k, v) in propsDict {
                if let subDict = v as? [String: Any] {
                    parsedProps[k] = parseSchema(subDict, components: components, depth: depth + 1)
                }
            }
            properties = parsedProps
        }

        var itemsSchema: OpenAPIJSONSchema? = nil
        if let itemsDict = dict["items"] as? [String: Any] {
            itemsSchema = parseSchema(itemsDict, components: components, depth: depth + 1)
        }

        return OpenAPIJSONSchema(
            type: dataType,
            format: format,
            description: description,
            required: required,
            properties: properties,
            items: itemsSchema,
            enumValues: enumVals,
            defaultValue: defaultValue,
            exampleValue: exampleValue,
            nullable: nullable
        )
    }
}
