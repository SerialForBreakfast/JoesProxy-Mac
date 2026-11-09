//
//  OpenAPISyntheticMockGenerator.swift
//  JoesProxy
//
//  Generates synthetic JSON mock response bodies directly from OpenAPI JSON schemas
//  supporting valid default, boundary edge, null field, and empty collection modes.
//

import Foundation

enum OpenAPIMockGenerationMode: String, Codable, Sendable, CaseIterable {
    case validDefault
    case boundaryEdge
    case nullFields
    case emptyCollections
}

enum OpenAPISyntheticMockGenerator {

    static func generateMockData(
        for schema: OpenAPIJSONSchema,
        mode: OpenAPIMockGenerationMode = .validDefault,
        prettyPrinted: Bool = true
    ) throws -> Data {
        let jsonObject = generateMockValue(for: schema, mode: mode, depth: 0)
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: jsonObject, options: options)
    }

    static func generateMockValue(
        for schema: OpenAPIJSONSchema,
        mode: OpenAPIMockGenerationMode,
        depth: Int
    ) -> Any {
        if depth > 8 {
            return [:]
        }

        // Use explicit example or default if present in validDefault mode
        if mode == .validDefault {
            if let ex = schema.exampleValue {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(ex.utf8)) {
                    return parsed
                }
                return ex
            }
            if let def = schema.defaultValue {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(def.utf8)) {
                    return parsed
                }
                return def
            }
            if let firstEnum = schema.enumValues?.first {
                return firstEnum
            }
        }

        guard let type = schema.type else {
            if schema.resolvedProperties != nil {
                return generateMockObject(schema: schema, mode: mode, depth: depth)
            }
            return [:]
        }

        switch type {
        case .string:
            if let firstEnum = schema.enumValues?.first {
                return firstEnum
            }
            if let format = schema.format {
                switch format {
                case "uuid":
                    return "12345678-1234-1234-1234-123456789abc"
                case "email":
                    return "user@example.com"
                case "date-time":
                    return "2026-08-25T12:00:00Z"
                default:
                    break
                }
            }
            if mode == .boundaryEdge {
                return ""
            }
            return "sample_string"

        case .integer:
            if mode == .boundaryEdge {
                return 0
            }
            return 42

        case .number:
            if mode == .boundaryEdge {
                return 0.0
            }
            return 19.99

        case .boolean:
            if mode == .boundaryEdge {
                return false
            }
            return true

        case .array:
            if mode == .emptyCollections {
                return []
            }
            if let itemSchema = schema.resolvedItems {
                let count = (mode == .boundaryEdge) ? 1 : 2
                var items: [Any] = []
                for _ in 0..<count {
                    items.append(generateMockValue(for: itemSchema, mode: mode, depth: depth + 1))
                }
                return items
            }
            return []

        case .object:
            return generateMockObject(schema: schema, mode: mode, depth: depth)

        case .null:
            return NSNull()
        }
    }

    private static func generateMockObject(
        schema: OpenAPIJSONSchema,
        mode: OpenAPIMockGenerationMode,
        depth: Int
    ) -> [String: Any] {
        var dict: [String: Any] = [:]
        guard let props = schema.resolvedProperties else {
            return dict
        }

        let requiredKeys = Set(schema.required ?? [])

        for (key, propSchema) in props {
            let isRequired = requiredKeys.contains(key)

            if mode == .emptyCollections {
                if propSchema.type == .array {
                    dict[key] = [Any]()
                    continue
                } else if !isRequired {
                    continue
                }
            }

            if mode == .nullFields {
                if propSchema.nullable == true {
                    dict[key] = NSNull()
                    continue
                } else if !isRequired {
                    continue
                }
            }

            dict[key] = generateMockValue(for: propSchema, mode: mode, depth: depth + 1)
        }

        return dict
    }
}
