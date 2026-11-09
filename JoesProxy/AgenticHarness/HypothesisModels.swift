//
//  HypothesisModels.swift
//  JoesProxy
//
//  Domain models for Hypothesis DAGs, Ephemeral Micro-Mutations,
//  and Autonomous Fault Bisection State Machines.
//

import Foundation

/// Status of an individual node in the hypothesis graph.
enum HypothesisNodeStatus: String, Codable, Equatable, Sendable {
    case untested = "Untested"
    case evaluating = "Evaluating"
    case proven = "Proven"
    case disproven = "Disproven"
    case pruned = "Pruned"

    var isTerminal: Bool {
        switch self {
        case .proven, .disproven, .pruned:
            return true
        case .untested, .evaluating:
            return false
        }
    }
}

/// An ephemeral micro-mutation executed on the proxy wire to test a hypothesis.
enum EphemeralMicroMutation: Codable, Equatable, Sendable {
    case jsonRewrite(urlPattern: String, locator: String, operation: String, value: String)
    case statusCodeFault(urlPattern: String, statusCode: Int, responseBody: String?)
    case latencyInjection(urlPattern: String, delayMs: Int)
    case headerMutation(urlPattern: String, headerName: String, value: String?)
    case dropConnection(urlPattern: String)

    var description: String {
        switch self {
        case .jsonRewrite(let pattern, let loc, let op, let val):
            return "JSON Rewrite: \(op) '\(val)' at '\(loc)' for '\(pattern)'"
        case .statusCodeFault(let pattern, let code, _):
            return "Status Fault: Return HTTP \(code) for '\(pattern)'"
        case .latencyInjection(let pattern, let delay):
            return "Latency Delay: Inject +\(delay)ms on '\(pattern)'"
        case .headerMutation(let pattern, let name, let val):
            return "Header Mutation: Set '\(name)' = '\(val ?? "<remove>")' on '\(pattern)'"
        case .dropConnection(let pattern):
            return "Drop Connection for '\(pattern)'"
        }
    }
}

/// Concrete telemetry criteria used to verify if a hypothesis is proven or disproven.
enum EvaluationCriteria: Codable, Equatable, Sendable {
    case clientEmittedErrorBeacon(urlPattern: String, parameterContains: String?)
    case clientShowedHTTPStatus(statusCode: Int)
    case clientRetriedRequest(urlPattern: String, minCount: Int)
    case customEvidenceMatch(key: String, expectedValue: String)

    var description: String {
        switch self {
        case .clientEmittedErrorBeacon(let pattern, let param):
            return "Client emits error beacon to '\(pattern)'" + (param != nil ? " containing '\(param!)'" : "")
        case .clientShowedHTTPStatus(let code):
            return "Client encounters HTTP status \(code)"
        case .clientRetriedRequest(let pattern, let count):
            return "Client retries request to '\(pattern)' at least \(count) times"
        case .customEvidenceMatch(let k, let v):
            return "Evidence match: '\(k)' == '\(v)'"
        }
    }
}

/// A single node in the active hypothesis DAG.
struct HypothesisNode: Identifiable, Codable, Equatable, Sendable {
    var id: String // e.g. "H1", "H1.1", "H2"
    var title: String
    var explanation: String
    var parentID: String? // nil for root hypotheses
    var mutation: EphemeralMicroMutation
    var expectedOutcome: EvaluationCriteria
    var status: HypothesisNodeStatus = .untested
    var evidenceSummary: String? = nil
    var evaluatedAt: Date? = nil
}

/// Represents the active multi-branch hypothesis graph.
struct HypothesisGraph: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var targetBugDescription: String
    var nodes: [HypothesisNode]
    var currentNodeID: String?
    var isCompleted: Bool = false
    var isolatedRootCauseNodeID: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var provenNode: HypothesisNode? {
        guard let rootID = isolatedRootCauseNodeID else {
            return nodes.first(where: { $0.status == .proven })
        }
        return nodes.first(where: { $0.id == rootID })
    }

    var progressPercentage: Double {
        guard !nodes.isEmpty else { return 0.0 }
        let evaluatedCount = nodes.filter(\.status.isTerminal).count
        return (Double(evaluatedCount) / Double(nodes.count)) * 100.0
    }
}

/// Final diagnosis report generated upon completing hypothesis graph bisection.
struct HypothesisBisectionReport: Codable, Equatable, Sendable {
    var graphID: UUID
    var graphName: String
    var targetBugDescription: String
    var totalNodesEvaluated: Int
    var prunedBranchesCount: Int
    var provenRootCauseNode: HypothesisNode?
    var confidenceScore: Double // 0.0 to 1.0
    var recommendedRemediation: String
    var executionTimeMs: Double
}
