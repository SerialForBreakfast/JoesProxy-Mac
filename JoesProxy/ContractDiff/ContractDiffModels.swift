//
//  ContractDiffModels.swift
//  JoesProxy
//
//  Domain models for Autonomous API Regression, Breaking Change Detection, and Schema Diffing.
//

import Foundation

/// Classification of the impact of a detected schema change.
enum SchemaChangeSeverity: String, Codable, Equatable, Sendable {
    case breaking = "Breaking"
    case compatibleAddition = "Compatible Addition"
    case informational = "Informational"
}

/// The specific nature of a schema difference.
enum SchemaChangeKind: Codable, Equatable, Sendable {
    case removedField(expectedType: String)
    case addedField(actualType: String)
    case typeMutation(expectedType: String, actualType: String)
    case unexpectedNull(expectedType: String)
    case statusCodeMismatch(expectedCode: Int, actualCode: Int)
    case contentTypeMismatch(expectedType: String, actualType: String)

    var summary: String {
        switch self {
        case .removedField(let type):
            return "Removed field (expected \(type))"
        case .addedField(let type):
            return "Added field (\(type))"
        case .typeMutation(let exp, let act):
            return "Type mutation (expected \(exp), found \(act))"
        case .unexpectedNull(let exp):
            return "Unexpected null (expected \(exp))"
        case .statusCodeMismatch(let exp, let act):
            return "Status code mismatch (expected \(exp), received \(act))"
        case .contentTypeMismatch(let exp, let act):
            return "Content-Type mismatch (expected \(exp), received \(act))"
        }
    }
}

/// A specific field-level schema difference at a JSONPath.
struct SchemaFieldDiff: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    let jsonPath: String
    let kind: SchemaChangeKind
    let severity: SchemaChangeSeverity
    let explanation: String
}

/// Contract diff evaluation report for a single endpoint/session.
struct EndpointContractDiffReport: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    let endpoint: String
    let method: String
    let path: String
    let isCompliant: Bool
    let breakingChangeCount: Int
    let compatibleAdditionCount: Int
    let fieldDiffs: [SchemaFieldDiff]
}

/// Summary report for a multi-endpoint contract regression suite run.
struct ContractRegressionSuiteSummary: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    let timestamp: Date
    let totalEndpointsTested: Int
    let compliantEndpointsCount: Int
    let breakingEndpointsCount: Int
    let totalBreakingChanges: Int
    let endpointReports: [EndpointContractDiffReport]

    var isSuitePassed: Bool {
        totalBreakingChanges == 0
    }
}
