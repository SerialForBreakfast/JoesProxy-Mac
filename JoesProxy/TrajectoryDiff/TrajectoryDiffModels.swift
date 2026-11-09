//
//  TrajectoryDiffModels.swift
//  JoesProxy
//
//  Domain models for multi-session trajectory sequence alignment,
//  behavioral divergence detection, and branching trees.
//

import Foundation

/// Type of alignment status for a step between baseline and candidate sessions.
enum TrajectoryStepType: String, Codable, Equatable, Sendable {
    case matched = "Matched"
    case payloadDiverged = "Payload Diverged"
    case statusCodeMismatch = "Status Code Mismatch"
    case missingInCandidate = "Missing In Candidate"
    case unexpectedInCandidate = "Unexpected In Candidate"
}

/// The specific mechanism of divergence at the branching point.
enum TrajectoryDivergenceKind: Codable, Equatable, Sendable {
    case statusCodeChange(baseline: Int, candidate: Int)
    case payloadFieldDelta(keyPath: String, baseline: String, candidate: String)
    case missingFollowup(url: String)
    case unexpectedRequest(url: String)

    var description: String {
        switch self {
        case .statusCodeChange(let b, let c):
            return "HTTP Status Code changed from \(b) to \(c)"
        case .payloadFieldDelta(let kp, let b, let c):
            return "Payload field '\(kp)' changed from '\(b)' to '\(c)'"
        case .missingFollowup(let url):
            return "Missing expected follow-up request to '\(url)'"
        case .unexpectedRequest(let url):
            return "Unexpected request emitted to '\(url)'"
        }
    }
}

/// A single step aligned across baseline and candidate session traces.
struct TrajectoryAlignedStep: Identifiable, Codable, Equatable, Sendable {
    var id: Int // 1-indexed step number
    var stepType: TrajectoryStepType
    var baselineSessionID: UUID?
    var candidateSessionID: UUID?
    var requestSignature: String // e.g. "GET /api/v1/feed"
    var baselineStatusCode: Int?
    var candidateStatusCode: Int?
    var relativeTimestampDeltaMs: Double
    var divergenceSummary: String? = nil
}

/// Comprehensive report comparing two session recording trajectories.
struct TrajectoryDiffReport: Codable, Equatable, Sendable {
    var reportID: UUID = UUID()
    var baselineRunName: String
    var candidateRunName: String
    var totalBaselineRequests: Int
    var totalCandidateRequests: Int
    var alignedSteps: [TrajectoryAlignedStep]
    var divergencePointIndex: Int?
    var divergencePointSummary: String?
    var divergenceKind: TrajectoryDivergenceKind?
    var similarityScore: Double // 0 to 100%
    var executionDurationMs: Double
}
