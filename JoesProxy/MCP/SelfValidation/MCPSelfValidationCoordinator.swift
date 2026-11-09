import CFNetwork
import Foundation

/// Active resources for one self-validation run (AI-5, AI-6).
struct MCPSelfValidationRunContext {
    let runID: MCPValidationRunID
    let lane: MCPSelfValidationLane
    let validationProxyPort: UInt16
    let fixtureBaseURL: URL
    let scenarioStack: MCPSelfValidationScenarioStack
    let featureStack: MCPSelfValidationFeatureStack

    /// Builds a URLSession that routes HTTP through the validation proxy lane.
    func makeProxiedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: validationProxyPort
        ]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}

/// Orchestrates isolated self-validation runs with bounded timeouts and guaranteed cleanup (AI-5).
///
/// Concurrency: `@MainActor` — publishes run state to the management panel and serializes begin/end.
@MainActor
final class MCPSelfValidationCoordinator: ObservableObject {
    static let defaultRunTimeout: TimeInterval = 120

    @Published private(set) var activeRun: MCPSelfValidationRunSummary?
    @Published private(set) var lastCompletedRun: MCPSelfValidationRunSummary?

    private var currentLane: MCPSelfValidationLane?
    private var currentFixture: MCPSelfValidationFixtureOrigin?
    private var currentProxyLane: MCPSelfValidationProxyLane?
    private var currentScenarioStack: MCPSelfValidationScenarioStack?

    /// Runs an isolated validation operation with automatic setup/teardown.
    @discardableResult
    func withRun(
        timeout: TimeInterval = MCPSelfValidationCoordinator.defaultRunTimeout,
        operation: @escaping (MCPSelfValidationRunContext) async throws -> Void
    ) async throws -> MCPSelfValidationRunSummary {
        let context = try await beginRun()
        var operationError: Error?
        var outcome: MCPSelfValidationRunOutcome = .succeeded
        var failureMessage: String?

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await operation(context)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw MCPSelfValidationError.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
        } catch let error as MCPSelfValidationError where error == .timedOut {
            outcome = .timedOut
            failureMessage = "Self-validation run timed out after \(Int(timeout)) seconds."
            operationError = error
        } catch {
            outcome = .failed
            failureMessage = error.localizedDescription
            operationError = error
        }

        let finished = await endRun(outcome: outcome, failureMessage: failureMessage)
        if let operationError {
            throw operationError
        }
        if finished.outcome == .cleanupFailed {
            throw MCPSelfValidationError.cleanupFailed(finished.failureMessage ?? "Cleanup failed.")
        }
        return finished
    }

    /// Starts fixture origin, validation proxy, and lane stack for a new run.
    @discardableResult
    func beginRun() async throws -> MCPSelfValidationRunContext {
        guard activeRun == nil else {
            throw MCPSelfValidationError.validationRunAlreadyActive
        }

        let runID = MCPValidationRunID.generate()
        let startedAt = Date()
        let lane = MCPSelfValidationLane(validationRunID: runID)
        let fixture = MCPSelfValidationFixtureOrigin()
        let proxyLane = MCPSelfValidationProxyLane(lane: lane)

        currentLane = lane
        currentFixture = fixture
        currentProxyLane = proxyLane

        activeRun = MCPSelfValidationRunSummary(
            runID: runID,
            phase: .running,
            outcome: nil,
            startedAt: startedAt,
            finishedAt: nil,
            validationProxyPort: nil,
            fixturePort: nil,
            failureMessage: nil
        )

        do {
            try await fixture.start()
            try await proxyLane.start()
        } catch {
            await tearDownInfrastructure()
            activeRun = nil
            currentLane = nil
            currentFixture = nil
            currentProxyLane = nil
            throw error
        }

        let stack = MCPSelfValidationScenarioStackFactory.makeStack(
            lane: lane,
            validationProxyPort: proxyLane.port
        )
        currentScenarioStack = stack

        let featureStack = MCPSelfValidationFeatureStackFactory.makeStack(
            lane: lane,
            validationProxyPort: proxyLane.port,
            scenarioStack: stack
        )

        activeRun?.validationProxyPort = proxyLane.port
        activeRun?.fixturePort = fixture.port

        return MCPSelfValidationRunContext(
            runID: runID,
            lane: lane,
            validationProxyPort: proxyLane.port,
            fixtureBaseURL: fixture.baseURL,
            scenarioStack: stack,
            featureStack: featureStack
        )
    }

    /// Drains scenario cleanup, stops infrastructure, and clears lane stores.
    @discardableResult
    func endRun(
        outcome: MCPSelfValidationRunOutcome = .succeeded,
        failureMessage: String? = nil
    ) async -> MCPSelfValidationRunSummary {
        guard var summary = activeRun else {
            return lastCompletedRun ?? MCPSelfValidationRunSummary(
                runID: MCPValidationRunID.generate(),
                phase: .idle,
                outcome: .failed,
                startedAt: Date(),
                finishedAt: Date(),
                validationProxyPort: nil,
                fixturePort: nil,
                failureMessage: MCPSelfValidationError.validationRunNotActive.localizedDescription
            )
        }

        summary.phase = .cleaningUp
        activeRun = summary

        var resolvedOutcome = outcome
        var resolvedFailure = failureMessage

        if let runtime = currentScenarioStack?.runtime {
            await runtime.drainPendingCleanups()
            let unresolved = currentLane?.scenarioStore.unresolvedScenarios() ?? []
            let blocking = unresolved.filter { record in
                switch record.phase {
                case .cleanupRequired, .cleaningUp, .running, .observing, .evaluating, .armed, .awaitingApproval:
                    return true
                case .draft, .validating, .completed, .failed, .inconclusive, .canceled:
                    return false
                }
            }
            if !blocking.isEmpty, resolvedOutcome == .succeeded {
                resolvedOutcome = .cleanupFailed
                resolvedFailure = "Unresolved scenarios remain after cleanup: \(blocking.map(\.id.rawValue).joined(separator: ", "))"
            }
        }

        if resolvedOutcome == .succeeded, let lane = currentLane {
            if let orphan = await orphanedMCPEffectDescription(lane: lane) {
                resolvedOutcome = .cleanupFailed
                resolvedFailure = orphan
            }
        }

        summary.validationProxyPort = currentProxyLane?.port ?? summary.validationProxyPort
        summary.fixturePort = currentFixture?.port ?? summary.fixturePort

        await tearDownInfrastructure()

        summary.phase = .idle
        summary.outcome = resolvedOutcome
        summary.failureMessage = resolvedFailure
        summary.finishedAt = Date()

        activeRun = nil
        lastCompletedRun = summary
        currentLane = nil
        currentFixture = nil
        currentProxyLane = nil
        currentScenarioStack = nil

        return summary
    }

    /// Extends the existing unresolved-scenario check (above) to standalone, non-scenario MCP
    /// effects: an override or bookmark rewrite left enabled after a test's own cleanup call is
    /// just as much a "cleanup failure" as an unresolved scenario, per AI-6's exit criterion that
    /// cleanup failures must fail the test — not something each test has to remember to assert.
    private func orphanedMCPEffectDescription(lane: MCPSelfValidationLane) async -> String? {
        let orphanedRules = await lane.responseOverrideStore.rules().filter { rule in
            rule.mcpOrigin == .mcp && rule.isEnabled
        }
        if !orphanedRules.isEmpty {
            return "Enabled MCP-origin overrides remain after cleanup: \(orphanedRules.map(\.id.uuidString).joined(separator: ", "))"
        }

        let orphanedRewrites = lane.bookmarkStore.loadBookmarks()
            .filter { $0.mcpOrigin == .mcp }
            .flatMap { $0.responseRewrites.filter(\.isRuleEnabled) }
        if !orphanedRewrites.isEmpty {
            return "Enabled MCP-origin bookmark rewrites remain after cleanup: \(orphanedRewrites.map(\.id.uuidString).joined(separator: ", "))"
        }

        return nil
    }

    private func tearDownInfrastructure() async {
        if let proxyLane = currentProxyLane {
            await proxyLane.stop()
        }
        if let fixture = currentFixture {
            await fixture.stop()
        }
        if let lane = currentLane {
            await lane.clear()
        }
    }
}

private extension MCPSelfValidationError {
    var localizedDescription: String {
        switch self {
        case .validationRunAlreadyActive:
            return "A self-validation run is already active."
        case .validationRunNotActive:
            return "No self-validation run is active."
        case .timedOut:
            return "Self-validation run timed out."
        case .cleanupFailed(let message):
            return message
        case .fixtureUnavailable:
            return "Self-validation fixture origin is unavailable."
        case .proxyUnavailable:
            return "Self-validation proxy lane is unavailable."
        }
    }
}
