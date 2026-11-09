import CryptoKit
import Foundation

/// Deterministic JSON generation and subset validation for compiled mock fixtures.
enum OpenAPIMockFixtureSynthesizer {
    /// Builds a JSON value from a resolved schema. Does not guess `oneOf` / remote refs.
    static func generate(
        schema: [String: Any],
        seed: String,
        pointer: String,
        resolver: OpenAPIMockRefResolver
    ) throws -> OpenAPIMockJSONValue {
        var stack: [String] = []
        let resolved = try resolver.resolveSchema(schema, stack: &stack)
        let tags = OpenAPIMockSchemaWalker.tags(in: resolved)
        let report = OpenAPIMockSchemaSupport.classify(tags)
        if !report.unsupported.isEmpty {
            throw OpenAPIMockCompilerError.unsupportedSchema(report.unsupported)
        }
        return try generateResolved(resolved, seed: seed, pointer: pointer, resolver: resolver, depth: 0)
    }

    /// Validates `value` against a resolved schema. Extra properties are allowed unless `additionalProperties` is false.
    static func validate(
        _ value: OpenAPIMockJSONValue,
        schema: [String: Any],
        resolver: OpenAPIMockRefResolver
    ) throws {
        var stack: [String] = []
        let resolved = try resolver.resolveSchema(schema, stack: &stack)
        let tags = OpenAPIMockSchemaWalker.tags(in: resolved)
        let report = OpenAPIMockSchemaSupport.classify(tags)
        if !report.unsupported.isEmpty {
            return
        }
        try validateResolved(value, schema: resolved, resolver: resolver)
    }

    private static func generateResolved(
        _ schema: [String: Any],
        seed: String,
        pointer: String,
        resolver: OpenAPIMockRefResolver,
        depth: Int
    ) throws -> OpenAPIMockJSONValue {
        if let example = schema["example"], let value = OpenAPIMockJSONValue.fromAny(example) {
            return value
        }
        if let defaultValue = schema["default"], let value = OpenAPIMockJSONValue.fromAny(defaultValue) {
            return value
        }
        if let enums = schema["enum"] as? [Any], !enums.isEmpty {
            let named = enums.compactMap { item -> (String, Any)? in
                guard let json = OpenAPIMockJSONValue.fromAny(item) else { return nil }
                return (stableName(json), item)
            }.sorted { $0.0 < $1.0 }
            if let first = named.first, let value = OpenAPIMockJSONValue.fromAny(first.1) {
                return value
            }
        }

        let typeName = schema["type"] as? String ?? inferredType(schema)
        switch typeName {
        case "object":
            return try generateObject(schema, seed: seed, pointer: pointer, resolver: resolver, depth: depth)
        case "array":
            return try generateArray(schema, seed: seed, pointer: pointer, resolver: resolver, depth: depth)
        case "string":
            return .string(generateString(schema: schema, seed: seed, pointer: pointer))
        case "integer":
            return .integer(0)
        case "number":
            return .number(0)
        case "boolean":
            return .bool(false)
        case "null":
            return .null
        default:
            throw OpenAPIMockCompilerError.unsupportedSchema([.openAPI31])
        }
    }

    private static func generateObject(
        _ schema: [String: Any],
        seed: String,
        pointer: String,
        resolver: OpenAPIMockRefResolver,
        depth: Int
    ) throws -> OpenAPIMockJSONValue {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        var object: [String: OpenAPIMockJSONValue] = [:]
        for key in properties.keys.sorted() {
            guard required.contains(key) || propertyHasLiteral(properties[key]) else { continue }
            guard let rawProperty = properties[key] as? [String: Any] else { continue }
            var stack: [String] = []
            let propertySchema = try resolver.resolveSchema(rawProperty, stack: &stack)
            object[key] = try generateResolved(
                propertySchema,
                seed: seed,
                pointer: "\(pointer)/\(key)",
                resolver: resolver,
                depth: depth + 1
            )
        }
        return .object(object)
    }

    private static func generateArray(
        _ schema: [String: Any],
        seed: String,
        pointer: String,
        resolver: OpenAPIMockRefResolver,
        depth: Int
    ) throws -> OpenAPIMockJSONValue {
        guard let items = schema["items"] as? [String: Any] else {
            return .array([])
        }
        var stack: [String] = []
        let itemSchema = try resolver.resolveSchema(items, stack: &stack)
        let item = try generateResolved(
            itemSchema,
            seed: seed,
            pointer: "\(pointer)/0",
            resolver: resolver,
            depth: depth + 1
        )
        return .array([item])
    }

    private static func generateString(schema: [String: Any], seed: String, pointer: String) -> String {
        let format = schema["format"] as? String
        let material = "\(seed)|\(pointer)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        switch format {
        case "uuid":
            let bytes = Array(digest.prefix(16))
            let uuid = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            return uuid.uuidString.lowercased()
        case "date-time":
            return "2020-01-01T00:00:00Z"
        case "email":
            return "synthetic@example.invalid"
        default:
            return "syn-\(hex.prefix(8))"
        }
    }

    private static func propertyHasLiteral(_ raw: Any?) -> Bool {
        guard let schema = raw as? [String: Any] else { return false }
        return schema["example"] != nil || schema["default"] != nil || schema["enum"] != nil
    }

    private static func inferredType(_ schema: [String: Any]) -> String {
        if schema["properties"] != nil || schema["required"] != nil { return "object" }
        if schema["items"] != nil { return "array" }
        return "object"
    }

    private static func stableName(_ value: OpenAPIMockJSONValue) -> String {
        (try? String(data: value.encodedData(), encoding: .utf8)) ?? ""
    }

    private static func validateResolved(
        _ value: OpenAPIMockJSONValue,
        schema: [String: Any],
        resolver: OpenAPIMockRefResolver
    ) throws {
        if let enums = schema["enum"] as? [Any] {
            let allowed = enums.compactMap(OpenAPIMockJSONValue.fromAny)
            if !allowed.contains(value) {
                throw OpenAPIMockCompilerError.schemaRejected("value is not in enum")
            }
        }
        let typeName = schema["type"] as? String
        switch (typeName, value) {
        case ("object", .object(let object)):
            try validateObject(object, schema: schema, resolver: resolver)
        case ("array", .array(let array)):
            try validateArray(array, schema: schema, resolver: resolver)
        case ("string", .string):
            break
        case ("integer", .integer):
            break
        case ("number", .integer), ("number", .number):
            break
        case ("boolean", .bool):
            break
        case ("null", .null):
            break
        case (nil, _):
            break
        default:
            throw OpenAPIMockCompilerError.schemaRejected("value does not match schema type \(typeName ?? "unknown")")
        }
    }

    private static func validateObject(
        _ object: [String: OpenAPIMockJSONValue],
        schema: [String: Any],
        resolver: OpenAPIMockRefResolver
    ) throws {
        let required = schema["required"] as? [String] ?? []
        for key in required where object[key] == nil {
            throw OpenAPIMockCompilerError.schemaRejected("missing required property \(key)")
        }
        if let additional = schema["additionalProperties"] as? Bool, additional == false {
            let allowed = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
            if let extra = object.keys.first(where: { !allowed.contains($0) }) {
                throw OpenAPIMockCompilerError.schemaRejected("additional property \(extra) is not allowed")
            }
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, nested) in object {
            guard let rawProperty = properties[key] as? [String: Any] else { continue }
            var stack: [String] = []
            let propertySchema = try resolver.resolveSchema(rawProperty, stack: &stack)
            try validateResolved(nested, schema: propertySchema, resolver: resolver)
        }
    }

    private static func validateArray(
        _ array: [OpenAPIMockJSONValue],
        schema: [String: Any],
        resolver: OpenAPIMockRefResolver
    ) throws {
        guard let items = schema["items"] as? [String: Any] else { return }
        var stack: [String] = []
        let itemSchema = try resolver.resolveSchema(items, stack: &stack)
        for item in array {
            try validateResolved(item, schema: itemSchema, resolver: resolver)
        }
    }
}

/// Collects tokenized schema/document feature tags for ``OpenAPIMockSchemaSupport``.
enum OpenAPIMockSchemaWalker {
    /// Tags present on a single resolved schema object (non-recursive).
    static func tags(in schema: [String: Any]) -> [OpenAPIMockFeatureTag] {
        var tags: [OpenAPIMockFeatureTag] = []
        if schema["oneOf"] != nil { tags.append(.oneOf) }
        if schema["anyOf"] != nil { tags.append(.anyOf) }
        if schema["allOf"] != nil { tags.append(.allOf) }
        if schema["not"] != nil { tags.append(.not) }
        if schema["discriminator"] != nil { tags.append(.discriminator) }
        if let ref = schema["$ref"] as? String, !(ref == "#" || ref.hasPrefix("#/")) {
            tags.append(.remoteRef)
        }
        if schema["xml"] != nil { tags.append(.xml) }
        if let additional = schema["additionalProperties"], additional is [String: Any] {
            tags.append(.additionalPropertiesSchema)
        }
        if schema["properties"] != nil { tags.append(.properties) }
        if schema["required"] != nil { tags.append(.required) }
        if schema["items"] != nil { tags.append(.items) }
        if schema["enum"] != nil { tags.append(.enum) }
        if schema["default"] != nil { tags.append(.default) }
        if schema["example"] != nil { tags.append(.example) }
        if let format = schema["format"] as? String {
            switch format {
            case "date-time": tags.append(.formatDateTime)
            case "uuid": tags.append(.formatUUID)
            case "email": tags.append(.formatEmail)
            case "binary", "byte": tags.append(.binaryGeneration)
            default: break
            }
        }
        if let typeName = schema["type"] as? String {
            switch typeName {
            case "object": tags.append(.object)
            case "array": tags.append(.array)
            case "string": tags.append(.string)
            case "number": tags.append(.number)
            case "integer": tags.append(.integer)
            case "boolean": tags.append(.boolean)
            case "file": tags.append(.binaryGeneration)
            default: break
            }
        } else if schema["type"] is [Any] {
            tags.append(.openAPI31)
        }
        return tags
    }

    /// Recursively collects tags from an imported OpenAPI document tree.
    static func collect(from node: Any, into tags: inout Set<OpenAPIMockFeatureTag>) {
        if let dictionary = node as? [String: Any] {
            for tag in Self.tags(in: dictionary) {
                tags.insert(tag)
            }
            if let ref = dictionary["$ref"] as? String, !(ref == "#" || ref.hasPrefix("#/")) {
                tags.insert(.remoteRef)
            }
            for (key, nested) in dictionary {
                if key == "oneOf" { tags.insert(.oneOf) }
                if key == "anyOf" { tags.insert(.anyOf) }
                if key == "allOf" { tags.insert(.allOf) }
                if key == "callbacks" { tags.insert(.callbacks) }
                if key == "links" { tags.insert(.links) }
                if key == "webhooks" { tags.insert(.webhooks) }
                if key == "xml" { tags.insert(.xml) }
                collect(from: nested, into: &tags)
            }
            return
        }
        if let array = node as? [Any] {
            for nested in array {
                collect(from: nested, into: &tags)
            }
        }
    }
}
