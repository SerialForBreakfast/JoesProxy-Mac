//
//  MCPLLMInspectionService.swift
//  JoesProxy
//
//  MCP tool endpoints for LLM streaming inspection, token jitter profiling,
//  and in-flight stream fault sandboxing.
//

import Foundation

@MainActor
final class MCPLLMInspectionService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - LLM Stream Inspection

    func llmStreamInspection(
        sessionIDs: [UUID] = [],
        configuredCanaries: [String] = [],
        policyRevision: MCPPolicyRevision
    ) throws -> [MCPLLMStreamReportDTO] {
        let candidates: [SessionRecord]
        if sessionIDs.isEmpty {
            candidates = sessionStore.sessions
        } else {
            candidates = sessionStore.sessions.filter { sessionIDs.contains($0.id) }
        }

        var reports: [MCPLLMStreamReportDTO] = []

        for session in candidates {
            if let report = LLMStreamAuditorEngine.auditSession(session: session, configuredCanaryTokens: configuredCanaries) {
                let tokenDTOs = report.tokens.map { t in
                    MCPLLMTokenDeltaDTO(
                        index: t.index,
                        text: t.text,
                        role: t.role,
                        toolCallDelta: t.toolCallDelta,
                        relativeTimestampMs: t.relativeTimestampMs
                    )
                }

                let toolDTOs = report.toolCalls.map { tc in
                    MCPLLMToolCallDTO(
                        id: tc.id,
                        name: tc.name,
                        argumentsJSON: tc.argumentsJSON,
                        isComplete: tc.isComplete
                    )
                }

                reports.append(
                    MCPLLMStreamReportDTO(
                        sessionID: report.sessionID.uuidString,
                        modelName: report.modelName,
                        format: report.format.rawValue,
                        totalTokens: report.totalTokens,
                        totalChunks: report.totalChunks,
                        timeToFirstTokenMs: report.timeToFirstTokenMs,
                        totalStreamDurationMs: report.totalStreamDurationMs,
                        tokensPerSecond: report.tokensPerSecond,
                        interTokenJitterMs: report.interTokenJitterMs,
                        finishReason: report.finishReason,
                        tokens: tokenDTOs,
                        assembledText: report.assembledText,
                        toolCalls: toolDTOs,
                        canaryViolations: report.canaryViolations,
                        qualityScore: report.qualityScore,
                        disclosure: makeDisclosure(policyRevision: policyRevision)
                    )
                )
            }
        }

        return reports
    }

    // MARK: - Propose LLM Stream Fault

    func proposeLLMStreamFault(
        name: String,
        urlPattern: String,
        faultKind: String,
        delayMs: Int? = nil,
        targetTokenIndex: Int? = nil,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPLLMStreamFaultProposalDTO {
        let kind: LLMStreamFaultKind
        let clean = faultKind.lowercased()

        if clean.contains("stall") || clean.contains("delay") {
            kind = .tokenStall(delayMs: delayMs ?? 500, atTokenIndex: targetTokenIndex ?? 5)
        } else if clean.contains("tool") || clean.contains("corrupt") {
            kind = .corruptToolCallArguments(toolName: "any_tool")
        } else if clean.contains("truncat") {
            kind = .truncatedStream(atTokenIndex: targetTokenIndex ?? 10)
        } else {
            kind = .injectedErrorEnvelope(code: "server_error", message: "Injected artificial stream error")
        }

        let rule = LLMStreamFaultRule(
            name: name,
            urlPattern: urlPattern,
            faultKind: kind,
            isEnabled: true
        )

        LLMStreamFaultInjector.shared.registerRule(rule)

        return MCPLLMStreamFaultProposalDTO(
            ruleID: rule.id.uuidString,
            name: rule.name,
            urlPattern: rule.urlPattern,
            faultKindDescription: rule.faultKind.description,
            isEnabled: rule.isEnabled,
            status: "Active LLM stream fault rule registered on proxy wire",
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Helpers

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
