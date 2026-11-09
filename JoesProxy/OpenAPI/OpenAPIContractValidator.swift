//
//  OpenAPIContractValidator.swift
//  JoesProxy
//
//  Validates captured response JSON payloads against OpenAPI JSON schemas, detecting
//  contract drift, missing required keys, type mismatches, and format violations.
//

import Foundation

enum OpenAPIValidationStatus: String, Codable, Sendable, Equatable {
    case valid
    case drift
    case undocumentedEndpoint
    case undocumentedStatusCode
    case unsupportedContentType
    case malformedPayload
}

struct OpenAPIContractViolation: Codable, Sendable, Equatable, Hashable {
    let keyPath: String
    let expected: String
    let actual: String
    let reason: String

    init(keyPath: String, expected: String, actual: String, reason: String) {
        self.keyPath = keyPath
        self.expected = expected
        self.actual = actual
        self.reason = reason
    }
}

struct OpenAPIValidationReport: Codable, Sendable, Equatable {
    let status: OpenAPIValidationStatus
    let operationID: String?
    let pathTemplate: String?
    let statusCode: String
    let violations: [OpenAPIContractViolation]
    let badgeText: String
    let badgeTint: String

    init(
        status: OpenAPIValidationStatus,
        operationID: String? = nil,
        pathTemplate: String? = nil,
        statusCode: String,
        violations: [OpenAPIContractViolation] = []
    ) {
        self.status = status
        self.operationID = operationID
        self.pathTemplate = pathTemplate
        self.statusCode = statusCode
        self.violations = violations

        switch status {
        case .valid:
            self.badgeText = "Contract Valid"
            self.badgeTint = "green"
        case .drift:
            self.badgeText = violations.count == 1 ? "1 Violation" : "\(violations.count) Violations"
            self.badgeTint = "red"
        case .undocumentedEndpoint:
            self.badgeText = "Undocumented Route"
            self.badgeTint = "secondary"
        case .undocumentedStatusCode:
            self.badgeText = "Undocumented Status"
            self.badgeTint = "orange"
        case .unsupportedContentType:
            self.badgeText = "Non-JSON Body"
            self.badgeTint = "secondary"
        case .malformedPayload:
            self.badgeText = "Malformed JSON"
            self.badgeTint = "red"
        }
    }
}

enum OpenAPIContractValidator {

    private static let isoDateFormatter = ISO8601DateFormatter()

    static func validate(
        session: SessionRecord,
        schemaStore: OpenAPISchemaStore
    ) async -> OpenAPIValidationReport {
        guard let match = await schemaStore.match(method: session.request.method, path: session.request.path) else {
            return OpenAPIValidationReport(
                status: .undocumentedEndpoint,
                statusCode: session.response.map { "\($0.statusCode)" } ?? "0"
            )
        }

        let op = match.operation
        let statusCode = session.response.map { "\($0.statusCode)" } ?? "200"

        guard let responseDef = op.responses[statusCode] ?? op.responses["default"] else {
            return OpenAPIValidationReport(
                status: .undocumentedStatusCode,
                operationID: op.id,
                pathTemplate: op.pathTemplate,
                statusCode: statusCode
            )
        }

        // Find matching content type (e.g. application/json)
        guard let jsonSchema = responseDef.content.first(where: { $0.key.lowercased().contains("json") })?.value else {
            return OpenAPIValidationReport(
                status: .valid,
                operationID: op.id,
                pathTemplate: op.pathTemplate,
                statusCode: statusCode
            )
        }

        guard let bodyData = session.response?.bodyData, !bodyData.isEmpty else {
            return OpenAPIValidationReport(
                status: .valid,
                operationID: op.id,
                pathTemplate: op.pathTemplate,
                statusCode: statusCode
            )
        }

        guard let jsonRoot = try? JSONSerialization.jsonObject(with: bodyData) else {
            return OpenAPIValidationReport(
                status: .malformedPayload,
                operationID: op.id,
                pathTemplate: op.pathTemplate,
                statusCode: statusCode,
                violations: [
                    OpenAPIContractViolation(keyPath: "root", expected: "valid JSON", actual: "invalid JSON", reason: "Response body could not be parsed as JSON.")
                ]
            )
        }

        let violations = validateValue(jsonRoot, against: jsonSchema, keyPath: "root")
        let status: OpenAPIValidationStatus = violations.isEmpty ? .valid : .drift

        return OpenAPIValidationReport(
            status: status,
            operationID: op.id,
            pathTemplate: op.pathTemplate,
            statusCode: statusCode,
            violations: violations
        )
    }

    static func validateValue(
        _ value: Any,
        against schema: OpenAPIJSONSchema,
        keyPath: String
    ) -> [OpenAPIContractViolation] {
        var violations: [OpenAPIContractViolation] = []

        // Null check
        if value is NSNull {
            if schema.nullable == true || schema.type == .null {
                return []
            } else {
                return [
                    OpenAPIContractViolation(
                        keyPath: keyPath,
                        expected: schema.type?.rawValue ?? "non-null",
                        actual: "null",
                        reason: "Field is not nullable."
                    )
                ]
            }
        }

        // Type validation
        if let type = schema.type {
            switch type {
            case .string:
                if let str = value as? String {
                    if let enumVals = schema.enumValues, !enumVals.contains(str) {
                        violations.append(
                            OpenAPIContractViolation(
                                keyPath: keyPath,
                                expected: "one of [\(enumVals.joined(separator: ", "))]",
                                actual: "\"\(str)\"",
                                reason: "String value is not in declared enum."
                            )
                        )
                    }
                    if let format = schema.format {
                        if format == "uuid" && UUID(uuidString: str) == nil {
                            violations.append(
                                OpenAPIContractViolation(
                                    keyPath: keyPath,
                                    expected: "UUID format",
                                    actual: "\"\(str)\"",
                                    reason: "String is not a valid UUID."
                                )
                            )
                        } else if format == "email" && (!str.contains("@") || !str.contains(".")) {
                            violations.append(
                                OpenAPIContractViolation(
                                    keyPath: keyPath,
                                    expected: "email format",
                                    actual: "\"\(str)\"",
                                    reason: "String is not a valid email address."
                                )
                            )
                        } else if format == "date-time" && isoDateFormatter.date(from: str) == nil {
                            violations.append(
                                OpenAPIContractViolation(
                                    keyPath: keyPath,
                                    expected: "ISO 8601 date-time",
                                    actual: "\"\(str)\"",
                                    reason: "String is not a valid ISO 8601 timestamp."
                                )
                            )
                        }
                    }
                } else {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "string",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected string value."
                        )
                    )
                }

            case .integer:
                if let num = value as? NSNumber, CFNumberIsFloatType(num as CFNumber) == false {
                    // Valid integer
                } else if value is Int {
                    // Valid integer
                } else {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "integer",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected integer value."
                        )
                    )
                }

            case .number:
                if !(value is NSNumber) && !(value is Double) && !(value is Int) {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "number",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected number value."
                        )
                    )
                }

            case .boolean:
                if !(value is Bool) {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "boolean",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected boolean value."
                        )
                    )
                }

            case .array:
                if let arr = value as? [Any] {
                    if let itemSchema = schema.resolvedItems {
                        for (index, elem) in arr.enumerated() {
                            violations.append(
                                contentsOf: validateValue(elem, against: itemSchema, keyPath: "\(keyPath)[\(index)]")
                            )
                        }
                    }
                } else {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "array",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected array value."
                        )
                    )
                }

            case .object:
                if let dict = value as? [String: Any] {
                    // Check required properties
                    if let reqKeys = schema.required {
                        for reqKey in reqKeys {
                            if dict[reqKey] == nil {
                                violations.append(
                                    OpenAPIContractViolation(
                                        keyPath: "\(keyPath).\(reqKey)",
                                        expected: "required key '\(reqKey)'",
                                        actual: "missing",
                                        reason: "Required property is missing."
                                    )
                                )
                            }
                        }
                    }
                    // Check defined properties
                    if let properties = schema.resolvedProperties {
                        for (propKey, propSchema) in properties {
                            if let propValue = dict[propKey] {
                                violations.append(
                                    contentsOf: validateValue(propValue, against: propSchema, keyPath: "\(keyPath).\(propKey)")
                                )
                            }
                        }
                    }
                } else {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "object",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected JSON object."
                        )
                    )
                }

            case .null:
                if !(value is NSNull) {
                    violations.append(
                        OpenAPIContractViolation(
                            keyPath: keyPath,
                            expected: "null",
                            actual: "\(typeDescription(of: value))",
                            reason: "Expected null."
                        )
                    )
                }
            }
        }

        return violations
    }

    private static func typeDescription(of value: Any) -> String {
        if value is String { return "string" }
        if value is Bool { return "boolean" }
        if value is Int { return "integer" }
        if value is NSNumber { return "number" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        if value is NSNull { return "null" }
        return "\(type(of: value))"
    }
}
