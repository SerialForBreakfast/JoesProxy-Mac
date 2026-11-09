//
//  MCPDataLineageService.swift
//  JoesProxy
//
//  MCP tool endpoints for data lineage tracing, MITM response watermarking,
//  and analytics beacon attribution.
//

import Foundation

@MainActor
final class MCPDataLineageService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - Trace Data Lineage (Reverse Search)

    func traceDataLineage(
        targetValue: String,
        candidateSessionIDs: [UUID] = [],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPDataLineageSearchResultDTO {
        let candidates: [SessionRecord]
        if candidateSessionIDs.isEmpty {
            candidates = sessionStore.sessions
        } else {
            candidates = sessionStore.sessions.filter { candidateSessionIDs.contains($0.id) }
        }

        let flows = DataLineageEngine.searchReverseLineage(
            targetValue: targetValue,
            candidateSessions: candidates
        )

        let flowDTOs = flows.map(mapFlowToDTO)

        return MCPDataLineageSearchResultDTO(
            targetQuery: targetValue,
            candidateSessionsInspected: candidates.count,
            matchingFlowsCount: flows.count,
            flows: flowDTOs,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Audit Analytics Attribution

    func auditAnalyticsAttribution(
        sinkSessionID: UUID,
        candidateSourceSessionIDs: [UUID] = [],
        policyRevision: MCPPolicyRevision
    ) async throws -> MCPAnalyticsAttributionDTO {
        guard let sinkSession = sessionStore.sessions.first(where: { $0.id == sinkSessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Analytics session ID \(sinkSessionID) not found.")
        }

        let upstreamCandidates: [SessionRecord]
        if candidateSourceSessionIDs.isEmpty {
            // All sessions prior to sink session
            upstreamCandidates = sessionStore.sessions.filter { $0.id != sinkSessionID }
        } else {
            upstreamCandidates = sessionStore.sessions.filter { candidateSourceSessionIDs.contains($0.id) }
        }

        let report = await DataLineageEngine.auditAnalytics(
            sinkSession: sinkSession,
            upstreamSessions: upstreamCandidates
        )

        let flowDTOs = report.flows.map(mapFlowToDTO)
        let unattributedDTOs = report.unattributedParameters.map { node in
            MCPDataLineageNodeDTO(
                sessionID: node.sessionID.uuidString,
                endpointURL: node.endpointURL,
                httpMethod: node.httpMethod,
                keypath: node.keypath,
                value: node.value
            )
        }

        return MCPAnalyticsAttributionDTO(
            sinkSessionID: report.sinkSessionID.uuidString,
            sinkURL: report.sinkURL,
            totalTrackingParameters: report.totalTrackingParameters,
            attributedCount: report.attributedCount,
            unattributedCount: report.unattributedCount,
            attributionPercentage: report.attributionPercentage,
            flows: flowDTOs,
            unattributedParameters: unattributedDTOs,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Propose Provenance Watermark Rule

    func proposeProvenanceWatermark(
        name: String,
        urlPattern: String,
        targetKeypaths: [String] = [],
        strategy: String,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPWatermarkProposalDTO {
        let strat: WatermarkInjectionStrategy
        let clean = strategy.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("prefix") {
            strat = .prefix(tag: "JP_PROV")
        } else if clean.contains("property") {
            strat = .property(key: "_jp_source", value: "JP_ORIGIN")
        } else if clean.contains("auto") {
            strat = .autoAllStrings(tagPrefix: "SRC")
        } else {
            strat = .suffix(tag: "JP_SRC")
        }

        let rule = DataWatermarkRule(
            name: name,
            urlPattern: urlPattern,
            targetKeypaths: targetKeypaths,
            strategy: strat,
            isEnabled: true
        )

        return MCPWatermarkProposalDTO(
            ruleID: rule.id.uuidString,
            urlPattern: rule.urlPattern,
            strategy: rule.strategy.title,
            targetKeypaths: rule.targetKeypaths,
            isEnabled: rule.isEnabled,
            status: "Preview only — no live watermarking-application path exists yet, so this rule is not registered or persisted anywhere.",
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Helpers

    private func mapFlowToDTO(_ flow: DataLineageFlow) -> MCPDataLineageFlowDTO {
        let src = MCPDataLineageNodeDTO(
            sessionID: flow.sourceNode.sessionID.uuidString,
            endpointURL: flow.sourceNode.endpointURL,
            httpMethod: flow.sourceNode.httpMethod,
            keypath: flow.sourceNode.keypath,
            value: flow.sourceNode.value
        )
        let sink = MCPDataLineageNodeDTO(
            sessionID: flow.sinkNode.sessionID.uuidString,
            endpointURL: flow.sinkNode.endpointURL,
            httpMethod: flow.sinkNode.httpMethod,
            keypath: flow.sinkNode.keypath,
            value: flow.sinkNode.value
        )
        return MCPDataLineageFlowDTO(
            id: flow.id.uuidString,
            sourceNode: src,
            watermarkToken: flow.watermarkToken,
            sinkNode: sink,
            latencyMs: flow.latencyMs,
            matchConfidence: flow.matchConfidence,
            flowType: flow.flowType.rawValue
        )
    }

    private func makeDisclosure(policyRevision: MCPPolicyRevision) -> MCPMediaDisclosureContextDTO {
        MCPMediaDisclosureContextDTO(
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyRevision,
            generatedAt: Date(),
            removedFields: [],
            partialResultReason: nil,
            truncated: false
        )
    }
}
