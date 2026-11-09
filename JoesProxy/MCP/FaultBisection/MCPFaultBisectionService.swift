//
//  MCPFaultBisectionService.swift
//  JoesProxy
//
//  MCP tool service for Autonomous AI Fault Bisection and Root Cause Isolation.
//

import Foundation

@MainActor
final class MCPFaultBisectionService {

    private let coordinator: FaultBisectionCoordinator
    private let sessionStore: any SessionStore

    init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
        self.coordinator = FaultBisectionCoordinator(sessionStore: sessionStore)
    }

    /// Starts an autonomous bisection run anchored at a session ID.
    func startBisection(
        sessionID: UUID,
        windowSeconds: TimeInterval = 30.0
    ) throws -> MCPFaultBisectionStartDTO {
        guard let report = coordinator.startBisection(anchorSessionID: sessionID, windowSeconds: windowSeconds),
              let action = coordinator.currentAction else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session ID \(sessionID) not found in capture history.")
        }

        return MCPFaultBisectionStartDTO(
            bisectionID: report.id.uuidString,
            anchorSessionID: sessionID.uuidString,
            status: report.status.rawValue,
            candidateCount: report.candidateScope.candidateSessionIDs.count,
            distinctEndpointCount: report.candidateScope.distinctEndpoints.count,
            currentStepNumber: action.stepNumber,
            currentStepKind: action.kind.rawValue,
            actionDescription: action.actionDescription
        )
    }

    /// Records the observed outcome of the current bisection step and returns the next action.
    func recordStep(
        outcome: String,
        logSnippet: String? = nil
    ) throws -> MCPFaultBisectionStepDTO {
        let clientOutcome: BisectionClientOutcome
        switch outcome.lowercased() {
        case "crashed", "crash":
            clientOutcome = .crashed
        case "failed_assertion", "assertion_failed", "failedassertion":
            clientOutcome = .failedAssertion
        case "succeeded", "success":
            clientOutcome = .succeeded
        case "empty", "malformed":
            clientOutcome = .emptyOrMalformed
        default:
            clientOutcome = .unknown
        }

        guard let report = coordinator.recordStepOutcome(outcome: clientOutcome, logSnippet: logSnippet) else {
            throw MCPStructuredError(code: .conflict, message: "No active bisection session running.")
        }

        let findingDTO: MCPFaultBisectionFindingDTO?
        if let finding = report.finding {
            findingDTO = MCPFaultBisectionFindingDTO(
                culpritEndpoint: finding.culpritEndpoint.displayTitle,
                culpritKeyPath: finding.culpritKeyPath,
                exactWireFault: finding.exactWireFault,
                observedClientError: finding.observedClientError,
                confidenceScore: finding.confidenceScore,
                proposedFixTitle: finding.proposedFixTitle,
                proposedMockJSON: finding.proposedMockJSON,
                curlReproducer: finding.curlReproducer
            )
        } else {
            findingDTO = nil
        }

        let action = coordinator.currentAction
        return MCPFaultBisectionStepDTO(
            bisectionID: report.id.uuidString,
            stepNumber: action?.stepNumber ?? report.steps.count,
            kind: action?.kind.rawValue ?? BisectionStepKind.verification.rawValue,
            actionDescription: action?.actionDescription ?? "Bisection completed.",
            isTerminal: action?.isTerminal ?? true,
            status: report.status.rawValue,
            finding: findingDTO
        )
    }

    /// Retrieves the current report and finding for a bisection run.
    func getReport() throws -> MCPFaultBisectionReportDTO {
        guard let report = coordinator.activeReport else {
            throw MCPStructuredError(code: .malformedRequest, message: "No active bisection report found.")
        }

        let findingDTO: MCPFaultBisectionFindingDTO?
        if let finding = report.finding {
            findingDTO = MCPFaultBisectionFindingDTO(
                culpritEndpoint: finding.culpritEndpoint.displayTitle,
                culpritKeyPath: finding.culpritKeyPath,
                exactWireFault: finding.exactWireFault,
                observedClientError: finding.observedClientError,
                confidenceScore: finding.confidenceScore,
                proposedFixTitle: finding.proposedFixTitle,
                proposedMockJSON: finding.proposedMockJSON,
                curlReproducer: finding.curlReproducer
            )
        } else {
            findingDTO = nil
        }

        return MCPFaultBisectionReportDTO(
            bisectionID: report.id.uuidString,
            anchorSessionID: report.anchorSessionID.uuidString,
            status: report.status.rawValue,
            stepCount: report.steps.count,
            candidateEndpointCount: report.candidateScope.distinctEndpoints.count,
            finding: findingDTO
        )
    }

    /// Cancels the active bisection run.
    func cancelBisection() -> Bool {
        coordinator.cancelBisection()
        return true
    }
}
