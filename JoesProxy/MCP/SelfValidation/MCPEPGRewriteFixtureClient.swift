import SwiftUI

struct MCPEPGRewriteFixtureResult: Equatable, Sendable {
    let transformedTitles: [String]
    let restoredTitles: [String]
    let unrelatedResponseWasUnchanged: Bool
    let attributionWasRecorded: Bool
}

enum MCPEPGRewriteFixtureError: LocalizedError {
    case invalidResponse
    case missingValue(String)
    case unexpectedValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The fixture returned an invalid response."
        case .missingValue(let name):
            return "The fixture result omitted \(name)."
        case .unexpectedValue(let message):
            return message
        }
    }
}

/// Runs the EPG semantic-rewrite acceptance path against an isolated real proxy lane.
@MainActor
struct MCPEPGRewriteFixtureRunner {
    func run() async throws -> MCPEPGRewriteFixtureResult {
        var result: MCPEPGRewriteFixtureResult?
        let coordinator = MCPSelfValidationCoordinator()

        _ = try await coordinator.withRun { context in
            let baseline = try await fetch(context: context, route: .epgTarget)
            let baselineBody = try jsonObject(from: baseline.body)
            try await Task.sleep(for: .milliseconds(100))
            let capturedSession = try require(
                context.lane.sessionStore.sessions.last(where: {
                    $0.request.path == MCPSelfValidationFixtureRoute.epgTarget.rawValue
                }),
                named: "captured EPG session"
            )
            let sessionIDs = [capturedSession.id.uuidString]

            let structure = try await context.featureStack.mutationService.handleTool(
                name: "discover_response_structure",
                arguments: ["sessionIDs": sessionIDs],
                client: context.scenarioStack.validationClient
            )
            guard (structure["shapeDescription"] as? String)?.contains("title") == true else {
                throw MCPEPGRewriteFixtureError.unexpectedValue("Response structure did not expose EPG titles.")
            }

            let rewriteArguments: [String: Any] = [
                "method": "GET",
                "scheme": "http",
                "host": "127.0.0.1",
                "port": Int(context.fixtureBaseURL.port ?? 0),
                "path": MCPSelfValidationFixtureRoute.epgTarget.rawValue,
                "matchMode": "exactPath",
                "jsonPath": "$.channels[*].programs[*].title",
                "operation": "appendString",
                "overrideValue": ["type": "string", "value": "!"],
                "sessionIDs": sessionIDs
            ]
            let preview = try await context.featureStack.mutationService.handleTool(
                name: "preview_live_rewrite",
                arguments: rewriteArguments,
                client: context.scenarioStack.validationClient
            )
            guard preview["transformedCount"] as? Int == 1 else {
                throw MCPEPGRewriteFixtureError.unexpectedValue("Preview did not transform the captured EPG response.")
            }

            var proposalArguments = rewriteArguments
            proposalArguments.removeValue(forKey: "sessionIDs")
            proposalArguments["previewDigest"] = try require(
                preview["previewDigest"] as? String,
                named: "preview digest"
            )
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: proposalArguments,
                client: context.scenarioStack.validationClient
            )
            let proposalToken = try require(proposal["proposalToken"] as? String, named: "proposal token")
            _ = try await approvedMutationCall(
                context: context,
                tool: "apply_create_live_rewrite",
                arguments: ["proposalToken": proposalToken]
            )
            let ruleID = try require(await context.lane.responseOverrideStore.rules().last?.id, named: "rewrite rule")

            _ = try await approvedOpenWorldCall(
                context: context,
                tool: "activate_live_rewrite",
                arguments: ["overrideID": ruleID.uuidString]
            )
            let transformed = try jsonObject(from: try await fetch(context: context, route: .epgTarget).body)
            let unrelated = try await fetch(context: context, route: .ok)
            try await Task.sleep(for: .milliseconds(200))
            let attributionWasRecorded = context.lane.sessionStore.sessions.contains(where: {
                $0.request.path == MCPSelfValidationFixtureRoute.epgTarget.rawValue
                    && $0.response?.source == .liveResponseRewrite
            })

            let disableProposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_disable_rule",
                arguments: ["overrideID": ruleID.uuidString],
                client: context.scenarioStack.validationClient
            )
            let disableToken = try require(
                disableProposal["proposalToken"] as? String,
                named: "disable proposal token"
            )
            _ = try await approvedMutationCall(
                context: context,
                tool: "apply_disable_rule",
                arguments: ["proposalToken": disableToken]
            )
            let restored = try jsonObject(from: try await fetch(context: context, route: .epgTarget).body)

            guard epgRatings(transformed) == epgRatings(baselineBody),
                  transformed["generatedAt"] as? String == baselineBody["generatedAt"] as? String else {
                throw MCPEPGRewriteFixtureError.unexpectedValue("The rewrite changed unrelated EPG fields.")
            }

            result = MCPEPGRewriteFixtureResult(
                transformedTitles: epgTitles(transformed),
                restoredTitles: epgTitles(restored),
                unrelatedResponseWasUnchanged: unrelated.body == MCPSelfValidationFixtureRoute.ok.defaultBody,
                attributionWasRecorded: attributionWasRecorded
            )
        }

        return try require(result, named: "EPG fixture result")
    }

    private func fetch(
        context: MCPSelfValidationRunContext,
        route: MCPSelfValidationFixtureRoute
    ) async throws -> (body: String, statusCode: Int) {
        let session = context.makeProxiedURLSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: context.fixtureBaseURL.appendingPathComponent(route.rawValue))
        guard let httpResponse = response as? HTTPURLResponse,
              let body = String(data: data, encoding: .utf8) else {
            throw MCPEPGRewriteFixtureError.invalidResponse
        }
        return (body, httpResponse.statusCode)
    }

    private func approvedMutationCall(
        context: MCPSelfValidationRunContext,
        tool: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await context.featureStack.mutationService.handleTool(
                name: tool,
                arguments: arguments,
                client: context.scenarioStack.validationClient
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try require(error.details?["requestID"], named: "approval request ID")
            _ = try context.lane.approvalStore.approve(requestID: requestID)
            return try await context.featureStack.mutationService.handleTool(
                name: tool,
                arguments: arguments,
                client: context.scenarioStack.validationClient
            )
        }
    }

    private func approvedOpenWorldCall(
        context: MCPSelfValidationRunContext,
        tool: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await context.featureStack.openWorldService.handleTool(
                name: tool,
                arguments: arguments,
                client: context.scenarioStack.validationClient,
                mcpSessionID: context.runID.rawValue
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try require(error.details?["requestID"], named: "approval request ID")
            _ = try context.lane.approvalStore.approve(requestID: requestID)
            return try await context.featureStack.openWorldService.handleTool(
                name: tool,
                arguments: arguments,
                client: context.scenarioStack.validationClient,
                mcpSessionID: context.runID.rawValue
            )
        }
    }

    private func jsonObject(from body: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw MCPEPGRewriteFixtureError.invalidResponse
        }
        return object
    }

    private func epgTitles(_ body: [String: Any]) -> [String] {
        epgPrograms(body).compactMap { $0["title"] as? String }
    }

    private func epgRatings(_ body: [String: Any]) -> [String] {
        epgPrograms(body).compactMap { $0["rating"] as? String }
    }

    private func epgPrograms(_ body: [String: Any]) -> [[String: Any]] {
        (body["channels"] as? [[String: Any]] ?? []).flatMap {
            $0["programs"] as? [[String: Any]] ?? []
        }
    }

    private func require<T>(_ value: T?, named name: String) throws -> T {
        guard let value else {
            throw MCPEPGRewriteFixtureError.missingValue(name)
        }
        return value
    }
}

@MainActor
final class MCPEPGRewriteFixtureViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case succeeded(MCPEPGRewriteFixtureResult)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func run() async {
        guard state == .idle else { return }
        state = .running
        do {
            state = .succeeded(try await MCPEPGRewriteFixtureRunner().run())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct MCPEPGRewriteFixtureClientView: View {
    @StateObject private var viewModel = MCPEPGRewriteFixtureViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EPG Rewrite Fixture")
                .font(.title2)

            switch viewModel.state {
            case .idle, .running:
                ProgressView("Running isolated proxy workflow")
                    .accessibilityIdentifier("epgFixture.status")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("epgFixture.error")
            case .succeeded(let result):
                Text("Passed")
                    .accessibilityLabel("Passed")
                    .accessibilityValue("Passed")
                    .accessibilityIdentifier("epgFixture.status")
                titleSection("Transformed titles", titles: result.transformedTitles, prefix: "epgFixture.transformedTitle")
                titleSection("Post-cleanup titles", titles: result.restoredTitles, prefix: "epgFixture.restoredTitle")
                Text(result.unrelatedResponseWasUnchanged ? "Unrelated response preserved" : "Unrelated response changed")
                    .accessibilityLabel(result.unrelatedResponseWasUnchanged ? "Unrelated response preserved" : "Unrelated response changed")
                    .accessibilityValue(result.unrelatedResponseWasUnchanged ? "Unrelated response preserved" : "Unrelated response changed")
                    .accessibilityIdentifier("epgFixture.unrelatedResponse")
                Text(result.attributionWasRecorded ? "Attribution recorded" : "Attribution missing")
                    .accessibilityLabel(result.attributionWasRecorded ? "Attribution recorded" : "Attribution missing")
                    .accessibilityValue(result.attributionWasRecorded ? "Attribution recorded" : "Attribution missing")
                    .accessibilityIdentifier("epgFixture.attribution")
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420, alignment: .topLeading)
        .task {
            await viewModel.run()
        }
    }

    private func titleSection(_ heading: String, titles: [String], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline)
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .accessibilityLabel(title)
                    .accessibilityValue(title)
                    .accessibilityIdentifier("\(prefix).\(index)")
            }
        }
    }
}
