//
//  ResilienceModels.swift
//  JoesProxy
//
//  Domain models for counterfactual payload mutations,
//  evaluator-optimizer breaking-point bisection, and client resilience matrices.
//

import Foundation

/// Type of counterfactual mutation to apply to a payload field.
enum CounterfactualMutationType: String, Codable, Equatable, Sendable {
    case nullify = "Nullify Field"
    case removeKey = "Remove Key"
    case typeCoerce = "Type Coercion"
    case emptyCollection = "Empty Collection"
    case boundaryExplosion = "Boundary Explosion"

    var description: String { rawValue }
}

/// Evaluation status of an individual field mutation candidate.
enum FieldResilienceStatus: String, Codable, Equatable, Sendable {
    case untested = "Untested"
    case evaluating = "Evaluating"
    case safe = "Resilient"
    case breakingPoint = "Breaking Point"
}

/// A single candidate mutation on a specific keypath of the JSON payload.
struct FieldMutationCandidate: Identifiable, Codable, Equatable, Sendable {
    var id: String // e.g. "MUT_1", "MUT_2"
    var keyPath: String // e.g. "$.user.profile.avatar_url"
    var mutationType: CounterfactualMutationType
    var originalValueDescription: String
    var mutatedValueDescription: String
    var status: FieldResilienceStatus = .untested
    var observedClientError: String? = nil
}

/// Isolated breaking point finding with defensive remediation recommendations.
struct BreakingPointFinding: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var candidateID: String
    var keyPath: String
    var mutationType: CounterfactualMutationType
    var mutatedPayloadSnippet: String
    var observedClientError: String?
    var defensiveFixRecommendation: String
}

/// Active plan for running an Evaluator-Optimizer bisection over a payload.
struct ResilienceBisectionPlan: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var targetSessionID: UUID
    var targetURL: String
    var baselinePayloadJSON: String
    var candidates: [FieldMutationCandidate]
    var activeCandidateIndex: Int?
    var isCompleted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var activeCandidate: FieldMutationCandidate? {
        guard let idx = activeCandidateIndex, idx < candidates.count else { return nil }
        return candidates[idx]
    }

    var progressPercentage: Double {
        guard !candidates.isEmpty else { return 0.0 }
        let evaluated = candidates.filter { $0.status != .untested && $0.status != .evaluating }.count
        return (Double(evaluated) / Double(candidates.count)) * 100.0
    }
}

/// Comprehensive report synthesizing client resilience score and breaking points.
struct ClientResilienceMatrixReport: Codable, Equatable, Sendable {
    var planID: UUID
    var planName: String
    var targetURL: String
    var totalFieldsTested: Int
    var breakingPointsCount: Int
    var resilientFieldsCount: Int
    var resilienceScore: Double // 0 to 100
    var breakingPoints: [BreakingPointFinding]
    var executionDurationMs: Double
}
