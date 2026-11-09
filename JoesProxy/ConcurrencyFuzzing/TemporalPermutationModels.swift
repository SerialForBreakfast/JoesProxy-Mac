//
//  TemporalPermutationModels.swift
//  JoesProxy
//
//  Domain models for concurrent request temporal permutation,
//  arrival order scheduling, and async race-condition fuzzing.
//

import Foundation

/// Represents a single target endpoint involved in a concurrent request batch.
struct PermutationEndpoint: Identifiable, Codable, Equatable, Sendable {
    var id: String // e.g. "AUTH", "CONFIG", "FEED"
    var name: String
    var urlPattern: String
    var method: String = "GET"
}

/// Status of an individual temporal arrival sequence evaluation.
enum PermutationOutcomeStatus: String, Codable, Equatable, Sendable {
    case untested = "Untested"
    case evaluating = "Evaluating"
    case passed = "Safe"
    case raceConditionDetected = "Race Condition"
    case clientTimeout = "Timeout"
}

/// A specific sequential ordering of response arrivals with computed micro-delays.
struct PermutationSequence: Identifiable, Codable, Equatable, Sendable {
    var id: Int // 1-indexed sequence number
    var order: [String] // Array of endpoint IDs in arrival order
    var delaysMs: [String: Int] // Endpoint ID -> injected delay in ms
    var status: PermutationOutcomeStatus = .untested
    var clientOutcomeSummary: String? = nil
    var errorDetected: Bool = false
}

/// Active plan for fuzzing a batch of concurrent endpoints across all temporal permutations.
struct TemporalPermutationPlan: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var targetBatchDescription: String
    var endpoints: [PermutationEndpoint]
    var sequences: [PermutationSequence]
    var activeSequenceIndex: Int?
    var isCompleted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var activeSequence: PermutationSequence? {
        guard let idx = activeSequenceIndex, idx < sequences.count else { return nil }
        return sequences[idx]
    }

    var progressPercentage: Double {
        guard !sequences.isEmpty else { return 0.0 }
        let completed = sequences.filter { $0.status != .untested && $0.status != .evaluating }.count
        return (Double(completed) / Double(sequences.count)) * 100.0
    }
}

/// Comprehensive report synthesizing race-condition findings and minimal failing orderings.
struct RaceConditionFuzzReport: Codable, Equatable, Sendable {
    var planID: UUID
    var planName: String
    var targetBatchDescription: String
    var totalSequencesTested: Int
    var failingSequencesCount: Int
    var safeSequencesCount: Int
    var minimalFailingOrder: [String]?
    var rootCauseSummary: String
    var recommendedDefensiveFix: String
    var executionDurationMs: Double
}
