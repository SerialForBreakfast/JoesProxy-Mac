//
//  FaultBisectionCoordinator.swift
//  JoesProxy
//
//  Coordinates the live lifecycle, step execution, and ephemeral sandboxing of AI Fault Bisection.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class FaultBisectionCoordinator: ObservableObject {

    @Published private(set) var activeReport: FaultBisectionReport?
    @Published private(set) var currentAction: BisectionNextAction?
    @Published private(set) var isRunning: Bool = false

    private let sessionStore: any SessionStore
    private var activeAnchorSession: SessionRecord?

    init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Starts a new bisection session anchored at a given session ID.
    @discardableResult
    func startBisection(
        anchorSessionID: UUID,
        windowSeconds: TimeInterval = 30.0
    ) -> FaultBisectionReport? {
        guard let anchor = sessionStore.sessions.first(where: { $0.id == anchorSessionID }) else {
            return nil
        }

        self.activeAnchorSession = anchor
        let scope = FaultBisectionEngine.buildCandidateScope(
            anchorSession: anchor,
            allSessions: sessionStore.sessions,
            windowSeconds: windowSeconds
        )

        let initialAction = FaultBisectionEngine.nextAction(scope: scope, priorSteps: [])
        let report = FaultBisectionReport(
            id: UUID(),
            anchorSessionID: anchorSessionID,
            startedAt: Date(),
            completedAt: nil,
            status: initialAction.isTerminal ? .isolated : .inProgress,
            candidateScope: scope,
            steps: [],
            finding: nil
        )

        self.activeReport = report
        self.currentAction = initialAction
        self.isRunning = !initialAction.isTerminal

        return report
    }

    /// Advances the bisection session with the observed outcome of the current step.
    @discardableResult
    func recordStepOutcome(
        outcome: BisectionClientOutcome,
        logSnippet: String? = nil
    ) -> FaultBisectionReport? {
        guard var report = activeReport, let action = currentAction, isRunning else {
            return nil
        }

        let stepResult = BisectionStepResult(
            stepNumber: action.stepNumber,
            kind: action.kind,
            testedEndpoints: action.targetEndpoints.map { $0.id },
            testedFieldMutation: action.fieldMutation,
            mutationDescription: action.actionDescription,
            clientOutcome: outcome,
            logSnippets: logSnippet.map { [$0] } ?? [],
            timestamp: Date()
        )

        var updatedSteps = report.steps
        updatedSteps.append(stepResult)

        let nextAction = FaultBisectionEngine.nextAction(
            scope: report.candidateScope,
            priorSteps: updatedSteps
        )

        let isDone = nextAction.isTerminal
        let finding: FaultBisectionFinding?
        if isDone, let anchor = activeAnchorSession, let culprit = nextAction.targetEndpoints.first ?? report.candidateScope.distinctEndpoints.first {
            finding = FaultBisectionEngine.synthesizeFinding(
                anchorSession: anchor,
                culprit: culprit,
                steps: updatedSteps
            )
        } else {
            finding = nil
        }

        let updatedReport = FaultBisectionReport(
            id: report.id,
            anchorSessionID: report.anchorSessionID,
            startedAt: report.startedAt,
            completedAt: isDone ? Date() : nil,
            status: isDone ? .isolated : .inProgress,
            candidateScope: report.candidateScope,
            steps: updatedSteps,
            finding: finding
        )

        self.activeReport = updatedReport
        self.currentAction = nextAction
        self.isRunning = !isDone

        return updatedReport
    }

    /// Cancels the active bisection run and tears down all temporary mutations.
    func cancelBisection() {
        guard var report = activeReport else { return }

        self.activeReport = FaultBisectionReport(
            id: report.id,
            anchorSessionID: report.anchorSessionID,
            startedAt: report.startedAt,
            completedAt: Date(),
            status: .cancelled,
            candidateScope: report.candidateScope,
            steps: report.steps,
            finding: nil
        )
        self.isRunning = false
        self.currentAction = nil
    }
}
