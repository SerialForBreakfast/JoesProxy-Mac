//
//  FaultBisectionModels.swift
//  JoesProxy
//
//  Domain models for Dynamic AI Fault Bisection & Root-Cause Isolation.
//

import Foundation

/// Represents a distinct upstream API endpoint candidate in the bisection window.
struct BisectionEndpointCandidate: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(method) \(host)\(path)" }
    let method: String
    let host: String
    let path: String
    let sessionIDs: [UUID]
    let statusCode: Int?
    let contentType: String?
    let isJSON: Bool

    var displayTitle: String {
        "\(method) \(path)"
    }
}

/// Scope of candidate sessions and distinct endpoints identified for bisection.
struct FaultBisectionCandidateScope: Codable, Equatable, Sendable {
    let anchorSessionID: UUID
    let windowDuration: TimeInterval
    let candidateSessionIDs: [UUID]
    let distinctEndpoints: [BisectionEndpointCandidate]
}

/// The stage/kind of bisection step currently being evaluated.
enum BisectionStepKind: String, Codable, Equatable, Sendable {
    case candidateWindow
    case binaryPartition
    case endpointIsolation
    case jsonFieldMutation
    case verification
}

/// The observed client-side outcome after applying a bisection mutation.
enum BisectionClientOutcome: String, Codable, Equatable, Sendable {
    case crashed
    case failedAssertion
    case emptyOrMalformed
    case succeeded
    case unknown
}

/// A specific JSON mutation applied to a payload to isolate field-level failures.
struct JSONFieldMutation: Codable, Equatable, Sendable {
    let keyPath: [String]
    let mutationType: JSONFieldMutationType
    let originalValueSummary: String?
    let mutatedValueSummary: String?

    var formattedKeyPath: String {
        keyPath.joined(separator: ".")
    }
}

/// Type of surgical JSON mutation applied.
enum JSONFieldMutationType: String, Codable, Equatable, Sendable {
    case nullify
    case omitKey
    case emptyArray
    case emptyString
    case zeroNumber
    case toggleBoolean
}

/// Result of an individual bisection test step.
struct BisectionStepResult: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(stepNumber)_\(kind.rawValue)" }
    let stepNumber: Int
    let kind: BisectionStepKind
    let testedEndpoints: [String]
    let testedFieldMutation: JSONFieldMutation?
    let mutationDescription: String
    let clientOutcome: BisectionClientOutcome
    let logSnippets: [String]
    let timestamp: Date
}

/// Status of the overall bisection run.
enum BisectionRunStatus: String, Codable, Equatable, Sendable {
    case ready
    case inProgress
    case isolated
    case inconclusive
    case cancelled
}

/// Next actionable command recommended by the bisection engine.
struct BisectionNextAction: Codable, Equatable, Sendable {
    let stepNumber: Int
    let kind: BisectionStepKind
    let targetEndpoints: [BisectionEndpointCandidate]
    let fieldMutation: JSONFieldMutation?
    let actionDescription: String
    let isTerminal: Bool
}

/// Executive Root Cause Finding produced upon bisection convergence.
struct FaultBisectionFinding: Codable, Equatable, Sendable {
    let culpritEndpoint: BisectionEndpointCandidate
    let culpritKeyPath: String?
    let exactWireFault: String
    let observedClientError: String?
    let confidenceScore: Double
    let proposedFixTitle: String
    let proposedMockJSON: String?
    let curlReproducer: String
}

/// Full bisection report recording complete history, candidate tree, and finding.
struct FaultBisectionReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let anchorSessionID: UUID
    let startedAt: Date
    let completedAt: Date?
    let status: BisectionRunStatus
    let candidateScope: FaultBisectionCandidateScope
    let steps: [BisectionStepResult]
    let finding: FaultBisectionFinding?
}
