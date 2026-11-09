//
//  OpenAPISchemaModels.swift
//  JoesProxy
//
//  In-memory schema models for parsed OpenAPI 3.0 / 3.1 specifications, operations,
//  parameters, and response JSON schemas.
//

import Foundation

enum OpenAPIJSONDataType: String, Codable, Sendable, Equatable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
    case null
}

final class OpenAPIJSONSchemaBox: Codable, Sendable, Equatable {
    let schema: OpenAPIJSONSchema

    init(_ schema: OpenAPIJSONSchema) {
        self.schema = schema
    }

    static func == (lhs: OpenAPIJSONSchemaBox, rhs: OpenAPIJSONSchemaBox) -> Bool {
        lhs.schema == rhs.schema
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(schema)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.schema = try container.decode(OpenAPIJSONSchema.self)
    }
}

struct OpenAPIJSONSchema: Codable, Sendable, Equatable {
    var type: OpenAPIJSONDataType?
    var format: String?
    var description: String?
    var required: [String]?
    var properties: [String: OpenAPIJSONSchemaBox]?
    var items: OpenAPIJSONSchemaBox?
    var enumValues: [String]?
    var defaultValue: String?
    var exampleValue: String?
    var nullable: Bool?

    init(
        type: OpenAPIJSONDataType? = nil,
        format: String? = nil,
        description: String? = nil,
        required: [String]? = nil,
        properties: [String: OpenAPIJSONSchema]? = nil,
        items: OpenAPIJSONSchema? = nil,
        enumValues: [String]? = nil,
        defaultValue: String? = nil,
        exampleValue: String? = nil,
        nullable: Bool? = nil
    ) {
        self.type = type
        self.format = format
        self.description = description
        self.required = required
        self.properties = properties?.mapValues { OpenAPIJSONSchemaBox($0) }
        self.items = items.map { OpenAPIJSONSchemaBox($0) }
        self.enumValues = enumValues
        self.defaultValue = defaultValue
        self.exampleValue = exampleValue
        self.nullable = nullable
    }

    var resolvedProperties: [String: OpenAPIJSONSchema]? {
        properties?.mapValues { $0.schema }
    }

    var resolvedItems: OpenAPIJSONSchema? {
        items?.schema
    }
}

enum OpenAPIParameterLocation: String, Codable, Sendable, Equatable {
    case query
    case header
    case path
    case cookie
}

struct OpenAPIParameterDefinition: Codable, Sendable, Equatable {
    let name: String
    let location: OpenAPIParameterLocation
    let required: Bool
    let schema: OpenAPIJSONSchema?

    init(name: String, location: OpenAPIParameterLocation, required: Bool = false, schema: OpenAPIJSONSchema? = nil) {
        self.name = name
        self.location = location
        self.required = required
        self.schema = schema
    }
}

struct OpenAPIResponseDefinition: Codable, Sendable, Equatable {
    let statusCode: String
    let description: String?
    let content: [String: OpenAPIJSONSchema]

    init(statusCode: String, description: String? = nil, content: [String: OpenAPIJSONSchema] = [:]) {
        self.statusCode = statusCode
        self.description = description
        self.content = content
    }
}

struct OpenAPIOperationDefinition: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let method: String
    let pathTemplate: String
    let summary: String?
    let description: String?
    let tags: [String]
    let parameters: [OpenAPIParameterDefinition]
    let responses: [String: OpenAPIResponseDefinition]

    init(
        id: String,
        method: String,
        pathTemplate: String,
        summary: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        parameters: [OpenAPIParameterDefinition] = [],
        responses: [String: OpenAPIResponseDefinition] = [:]
    ) {
        self.id = id
        self.method = method
        self.pathTemplate = pathTemplate
        self.summary = summary
        self.description = description
        self.tags = tags
        self.parameters = parameters
        self.responses = responses
    }
}

struct OpenAPISchemaDocument: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let version: String
    let servers: [String]
    let operations: [OpenAPIOperationDefinition]

    init(
        id: UUID = UUID(),
        title: String,
        version: String,
        servers: [String] = [],
        operations: [OpenAPIOperationDefinition] = []
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.servers = servers
        self.operations = operations
    }
}
