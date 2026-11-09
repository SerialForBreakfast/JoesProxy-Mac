//
//  HypothesisDAGEngine.swift
//  JoesProxy
//
//  Graph state machine and execution harness for active hypothesis testing,
//  branch pruning, and autonomous fault bisection.
//

import Foundation

@MainActor
final class HypothesisDAGEngine {
    static let shared = HypothesisDAGEngine()

    private var activeGraphs: [UUID: HypothesisGraph] = [:]
    private var completedReports: [UUID: HypothesisBisectionReport] = [:]

    func proposeGraph(
        name: String,
        targetBugDescription: String,
        nodes: [HypothesisNode]
    ) -> HypothesisGraph {
        var graph = HypothesisGraph(
            name: name,
            targetBugDescription: targetBugDescription,
            nodes: nodes
        )

        // Select first untested root node (parentID == nil)
        let rootNode = nodes.first(where: { $0.parentID == nil && $0.status == .untested }) ?? nodes.first(where: { $0.status == .untested })
        if let root = rootNode {
            graph.currentNodeID = root.id
            if let idx = graph.nodes.firstIndex(where: { $0.id == root.id }) {
                graph.nodes[idx].status = .evaluating
            }
        }

        activeGraphs[graph.id] = graph
        return graph
    }

    func getGraph(id: UUID) -> HypothesisGraph? {
        activeGraphs[id]
    }

    func allGraphs() -> [HypothesisGraph] {
        Array(activeGraphs.values)
    }

    func getReport(graphID: UUID) -> HypothesisBisectionReport? {
        completedReports[graphID]
    }

    /// Advances the hypothesis graph state machine with observed client telemetry evidence.
    func step(
        graphID: UUID,
        observedEvidenceMatches: Bool,
        evidenceSummary: String
    ) -> (graph: HypothesisGraph, report: HypothesisBisectionReport?) {
        guard var graph = activeGraphs[graphID] else {
            fatalError("Graph ID \(graphID) not found")
        }

        guard let curID = graph.currentNodeID, let curIdx = graph.nodes.firstIndex(where: { $0.id == curID }) else {
            return (graph, completedReports[graphID])
        }

        graph.nodes[curIdx].evaluatedAt = Date()
        graph.nodes[curIdx].evidenceSummary = evidenceSummary

        if observedEvidenceMatches {
            // Node is PROVEN
            graph.nodes[curIdx].status = .proven

            // Check if this proven node has children to refine the hypothesis further
            let children = graph.nodes.filter { $0.parentID == curID && $0.status == .untested }
            if let nextChild = children.first {
                graph.currentNodeID = nextChild.id
                if let childIdx = graph.nodes.firstIndex(where: { $0.id == nextChild.id }) {
                    graph.nodes[childIdx].status = .evaluating
                }
            } else {
                // Leaf hypothesis reached and proven -> Conclude Bisection
                graph.isCompleted = true
                graph.isolatedRootCauseNodeID = curID
                graph.currentNodeID = nil

                let report = buildReport(for: graph, provenNode: graph.nodes[curIdx])
                completedReports[graphID] = report
                activeGraphs[graphID] = graph
                return (graph, report)
            }
        } else {
            // Node is DISPROVEN
            graph.nodes[curIdx].status = .disproven

            // Recursively PRUNE all child hypotheses of this disproven branch
            pruneChildren(of: curID, in: &graph)

            // Advance to next untested sibling or untested node
            let remainingUntested = graph.nodes.filter { $0.status == .untested }
            if let nextNode = remainingUntested.first {
                graph.currentNodeID = nextNode.id
                if let nextIdx = graph.nodes.firstIndex(where: { $0.id == nextNode.id }) {
                    graph.nodes[nextIdx].status = .evaluating
                }
            } else {
                // No more untested hypotheses remain
                graph.isCompleted = true
                graph.currentNodeID = nil

                let report = buildReport(for: graph, provenNode: nil)
                completedReports[graphID] = report
                activeGraphs[graphID] = graph
                return (graph, report)
            }
        }

        graph.updatedAt = Date()
        activeGraphs[graphID] = graph
        return (graph, nil)
    }

    func resetGraph(id: UUID) -> HypothesisGraph? {
        guard var graph = activeGraphs[id] else { return nil }
        for idx in 0..<graph.nodes.count {
            graph.nodes[idx].status = .untested
            graph.nodes[idx].evidenceSummary = nil
            graph.nodes[idx].evaluatedAt = nil
        }
        graph.isCompleted = false
        graph.isolatedRootCauseNodeID = nil

        let rootNode = graph.nodes.first(where: { $0.parentID == nil }) ?? graph.nodes.first
        if let root = rootNode {
            graph.currentNodeID = root.id
            if let idx = graph.nodes.firstIndex(where: { $0.id == root.id }) {
                graph.nodes[idx].status = .evaluating
            }
        }

        graph.updatedAt = Date()
        activeGraphs[id] = graph
        completedReports.removeValue(forKey: id)
        return graph
    }

    // MARK: - Private Helpers

    private func pruneChildren(of parentID: String, in graph: inout HypothesisGraph) {
        let directChildren = graph.nodes.filter { $0.parentID == parentID && $0.status == .untested }
        for child in directChildren {
            if let childIdx = graph.nodes.firstIndex(where: { $0.id == child.id }) {
                graph.nodes[childIdx].status = .pruned
                graph.nodes[childIdx].evidenceSummary = "Pruned: Parent branch '\(parentID)' was disproven"
                pruneChildren(of: child.id, in: &graph)
            }
        }
    }

    private func buildReport(for graph: HypothesisGraph, provenNode: HypothesisNode?) -> HypothesisBisectionReport {
        let totalEvaluated = graph.nodes.filter(\.status.isTerminal).count
        let prunedCount = graph.nodes.filter({ $0.status == .pruned }).count
        let duration = max(1.0, Date().timeIntervalSince(graph.createdAt) * 1000.0)

        let remediation: String
        if let node = provenNode {
            remediation = "Root cause confirmed at [\(node.id)] '\(node.title)'. Fix recommendation: Verify defensive handling for '\(node.mutation.description)'."
        } else {
            remediation = "No tested hypothesis reproduced the target bug. Recommend expanding hypothesis graph with additional boundary and temporal mutation nodes."
        }

        return HypothesisBisectionReport(
            graphID: graph.id,
            graphName: graph.name,
            targetBugDescription: graph.targetBugDescription,
            totalNodesEvaluated: totalEvaluated,
            prunedBranchesCount: prunedCount,
            provenRootCauseNode: provenNode,
            confidenceScore: provenNode != nil ? 1.0 : 0.0,
            recommendedRemediation: remediation,
            executionTimeMs: duration
        )
    }
}
