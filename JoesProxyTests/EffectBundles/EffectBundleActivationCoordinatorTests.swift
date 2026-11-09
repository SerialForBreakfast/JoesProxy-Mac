import CryptoKit
import Network
import XCTest
@testable import JoesProxy

private final class WindowTestCredentialStore: CLICredentialStoring {
    private var credential: String?
    init(_ credential: String) { self.credential = credential }
    func load(endpoint: URL) throws -> String? { credential }
    func save(_ credential: String, endpoint: URL) throws { self.credential = credential }
    func delete(endpoint: URL) throws { credential = nil }
}

private final class WindowTestAppLauncher: CLIAppLaunching {
    private(set) var launchCount = 0
    func applicationURL() throws -> URL { throw CLIError.serverUnavailable("No app launch in this fixture") }
    func requestMCPStart(launchArguments: [String]) async throws -> URL {
        launchCount += 1
        throw CLIError.serverUnavailable("No app launch in this fixture")
    }
}

private final class AgentLoopTransportMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transactions = 0
    private var sent: Int64 = 0
    private var received: Int64 = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            transactions += metrics.transactionMetrics.count
            for transaction in metrics.transactionMetrics {
                sent += transaction.countOfRequestBodyBytesSent
                received += transaction.countOfResponseBodyBytesReceived
            }
        }
    }

    var snapshot: (transactions: Int, sent: Int64, received: Int64) {
        lock.withLock { (transactions, sent, received) }
    }
}

@MainActor
final class EffectBundleActivationCoordinatorTests: XCTestCase {
    func testBundleApprovalRejectsChangedReviewAndProtectsDiscard() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let policy = MCPPolicyStore(persistenceURL: fixture.root.appendingPathComponent("policy.json"))
        let approvals = MCPApprovalStore()
        let grants = MCPClientGrantStore(persistenceURL: fixture.root.appendingPathComponent("grants.json"))
        let recovery = MCPRecoveryCoordinator(journalStore: MCPEffectJournalStore(
            persistenceURL: fixture.root.appendingPathComponent("journal.json")))
        recovery.bootstrap()
        let proposals = MCPProposalCoordinator(recoveryCoordinator: recovery, policyRevisionProvider: { policy.policyRevision })
        let service = MCPEffectBundleService(repository: fixture.repository, activationCoordinator: fixture.coordinator,
            proposalCoordinator: proposals, approvalStore: approvals, policyStore: policy, grantStore: grants,
            auditStore: MCPAuditStore(persistenceURL: fixture.root.appendingPathComponent("audit.json")))
        let owner = MCPClientRecord(id: "synthetic-owner", displayName: "Synthetic", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        let body = Data("{}".utf8), manifest = makeManifest(body: Data("{}".utf8))
        let path = fixture.root.appendingPathComponent("review.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: path)
        _ = try fixture.repository.importPackage(at: path, owner: .mcpClient(id: owner.id, displayName: owner.displayName))
        func propose(_ tool: String) async throws -> [String: Any] {
            let result = try await service.handleTool(name: tool, arguments: ["bundleID": manifest.id.uuidString], client: owner)
            let payload = try XCTUnwrap(result["payload"] as? [String: Any])
            return ["proposalToken": try XCTUnwrap(payload["proposalToken"] as? String)]
        }
        func requiresApproval(_ tool: String, _ args: [String: Any]) async throws -> String {
            do {
                _ = try await service.handleTool(name: tool, arguments: args, client: owner)
                XCTFail("Must not mutate without approval")
                return ""
            } catch let error as MCPStructuredError {
                XCTAssertEqual(error.code, .approvalRequired)
                return try XCTUnwrap(error.details?["requestID"])
            }
        }
        let activation = try await propose("propose_activate_effect_bundle")
        let requestID = try await requiresApproval("apply_activate_effect_bundle", activation)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        _ = try approvals.approve(requestID: requestID)
        _ = try fixture.repository.markStopped(id: manifest.id, at: Date())
        do {
            _ = try await service.handleTool(name: "apply_activate_effect_bundle", arguments: activation, client: owner)
            XCTFail("An approved stale review must not activate")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.code, .staleTargetRevision) }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        let fresh = try await propose("propose_activate_effect_bundle")
        let freshRequest = try await requiresApproval("apply_activate_effect_bundle", fresh)
        _ = try approvals.approve(requestID: freshRequest)
        let foreign = MCPClientRecord(id: "other-owner", displayName: "Other", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        do {
            _ = try await service.handleTool(name: "apply_activate_effect_bundle", arguments: fresh, client: foreign)
            XCTFail("Another owner cannot use the approval")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.code, .staleProposal) }
        _ = grants.addDenial(clientID: owner.id, capability: .enableRule)
        do {
            _ = try await service.handleTool(name: "apply_activate_effect_bundle", arguments: fresh, client: owner)
            XCTFail("An earlier approval cannot override current denial")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.code, .policyDenied) }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        grants.clearGrantsAndDenials(clientID: owner.id)
        _ = try await service.handleTool(name: "apply_activate_effect_bundle", arguments: fresh, client: owner)
        XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id))
        do {
            _ = try await service.handleTool(name: "apply_activate_effect_bundle", arguments: fresh, client: owner)
            XCTFail("Consumed proposal cannot activate again")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.code, .staleProposal) }
        _ = try await service.handleTool(name: "effect_bundle_stop", arguments: ["bundleID": manifest.id.uuidString], client: owner)
        let discard = try await propose("propose_discard_effect_bundle")
        let discardRequest = try await requiresApproval("apply_discard_effect_bundle", discard)
        XCTAssertNotNil(fixture.repository.record(id: manifest.id))
        try approvals.deny(requestID: discardRequest)
        let replacementRequest = try await requiresApproval("apply_discard_effect_bundle", discard)
        XCTAssertNotNil(fixture.repository.record(id: manifest.id))
        _ = try approvals.approve(requestID: replacementRequest)
        _ = try await service.handleTool(name: "apply_discard_effect_bundle", arguments: discard, client: owner)
        XCTAssertNil(fixture.repository.record(id: manifest.id))
        XCTAssertEqual(approvals.pendingCount, 0)
    }

    func testAgentExperimentLoopThroughAuthenticatedTransportAndProxyDelivery() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false, gate: .shared)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessions = InMemorySessionStore()
        func captured(_ path: String, _ body: String) -> SessionRecord {
            SessionRecord(request: CapturedRequest(method: "GET", scheme: .http,
                host: "api.example.invalid", port: 80, path: path, headers: [], bodyData: nil,
                bodySize: nil, clientAddress: "127.0.0.1"), response: CapturedResponse(statusCode: 200,
                headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: Data(body.utf8), bodySize: body.utf8.count), timing: .init(startedAt: Date()))
        }
        let listing = captured("/catalog", #"{"items":[{"id":"original"}]}"#)
        let detail = captured("/details/original", #"{"id":"original","title":"Original"}"#)
        sessions.append(listing)
        sessions.append(detail)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for:
            request(host: SyntheticAssetOriginServer.defaultHost, path: "/fixtures/images/test_pattern.png"))?.bodyData)
        let imageURL = fixture.root.appendingPathComponent("poster.png")
        try png.write(to: imageURL)
        let bookmark = try imageURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let authoring = CollectionMockAuthoringService()
        let controller = MCPServerController(sessionStore: sessions, port: UInt16.random(in: 20_000...60_000),
            credentialStore: MCPInMemoryCredentialStore(),
            storageScope: RuntimeStorageScope(root: fixture.root, defaults: UserDefaults()))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: controller.recoveryCoordinator,
            policyRevisionProvider: { controller.policyStore.policyRevision })
        controller.configureMutationService(bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: fixture.responseStore, proposalCoordinator: proposals,
            configuration: MCPSelfValidationAppConfiguration())
        let store = DiagnosticRunStore(persistenceURL: fixture.root.appendingPathComponent("runs.json"))
        let observationIndex = DiagnosticRunObservationIndex()
        let watches = DiagnosticRunObservationWatchInstaller(index: observationIndex, sessionStore: sessions,
            effectScopeResolver: OverrideRuleEffectScopeResolver(store: fixture.responseStore))
        let diagnostics = DiagnosticRunCoordinator(store: store, watchInstaller: watches, observationIndex: observationIndex)
        await diagnostics.bootstrap()
        diagnostics.configureExperiments(repository: fixture.repository, bundles: fixture.coordinator)
        fixture.coordinator.diagnosticRuns = diagnostics
        controller.configureDiagnosticRunService(runCoordinator: diagnostics,
            recheckService: DiagnosticRunRegressionRecheckService(store: store), proposalCoordinator: proposals)
        controller.configureEffectBundleService(repository: fixture.repository, activationCoordinator: fixture.coordinator,
            proposalCoordinator: proposals, authoringService: authoring, sessionStore: sessions)
        let bridge = DiagnosticRunCaptureBridge(sessionStore: sessions,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessions),
            index: observationIndex, coordinator: diagnostics)
        let recorder = ProxySessionRecorder(sessionStore: sessions)
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", sessionRecorder: recorder,
            responseOverrideStore: fixture.responseStore)
        await controller.start()
        var ownedBundle: UUID?
        var ownerID: String?
        do {
            guard case .running(_, let endpoint) = controller.state else {
                XCTFail("Isolated MCP server did not start")
                await controller.stop()
                return
            }
            try await proxy.start()
            let enrollment = try controller.enrollClient(displayName: "Synthetic loop", profileID: .shareable)
            ownerID = enrollment.client.id
            _ = try controller.grantStore.addGrant(clientID: enrollment.client.id,
                capability: .diagnosticRunLifecycle, mode: .durablePolicy)
            _ = try controller.grantStore.addGrant(clientID: enrollment.client.id,
                capability: .bodyRead, mode: .durablePolicy)
            let sessionStore = CLIFileSessionStore(persistenceURL: fixture.root.appendingPathComponent("cli.json"))
            let metrics = AgentLoopTransportMetrics()
            let transport = URLSession(configuration: .ephemeral, delegate: metrics, delegateQueue: nil)
            defer { transport.invalidateAndCancel() }
            let client = MCPCLIClient(endpoint: endpoint, credential: enrollment.plaintextCredential,
                sessionStore: sessionStore, timeout: 10, urlSession: transport)
            var calls = 0, responseBytes = 0, rejectedCalls = 0
            func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
                calls += 1
                do {
                    let result = try await client.callTool(name: name, arguments: arguments, retryOnStaleSession: false)
                    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).count
                    responseBytes += bytes
                    XCTAssertLessThan(bytes, MCPResourceBudget.maxResponseBytes)
                    return result["payload"] as? [String: Any] ?? result
                } catch { rejectedCalls += 1; throw error }
            }
            let draft = #"{"collectionPointer":"/items","item":{"id":"joe","poster":"pending"},"identityPointers":["/id"],"position":"prepend"}"#
            let related = """
            [{"sessionID":"\(detail.id)","targetPath":"/details/joe","edits":[{"pointer":"/id","value":"joe"},{"pointer":"/title","value":"JoesProxy"}],"identityLinks":[{"pointer":"/id","primaryPointer":"/items/0/id"}]}]
            """
            let preparation: [String: Any] = ["sessionID": listing.id.uuidString, "name": "Synthetic loop",
                "clientAddress": "127.0.0.1", "idempotencyKey": "whole-loop", "draftJSON": draft,
                "relatedResponsesJSON": related, "images": [["itemPointer": "/poster",
                    "localFileBookmarkRef": bookmark.base64EncodedString(),
                    "deliveryURL": "http://api.example.invalid/art/poster.png?revision=one", "imageReference": "art/poster.png?revision=one"]]]
            let prepared = try await call("effect_bundle_prepare", preparation)
            let revision = try XCTUnwrap(prepared["revisionID"] as? String)
            let revisionID = try XCTUnwrap(UUID(uuidString: revision))
            let retried = try await call("effect_bundle_prepare", preparation)
            XCTAssertEqual(retried["revisionID"] as? String, revision)
            let reviewed = try await call("effect_bundle_inspect", ["revisionID": revision])
            XCTAssertEqual(reviewed["isServing"] as? Bool, false)
            XCTAssertEqual((reviewed["workflow"] as? [String: Any])?["stage"] as? String, "review")
            _ = try await call("effect_bundle_import", ["revisionID": revision])
            ownedBundle = revisionID
            let inactive = try await call("effect_bundle_inspect", ["bundleID": revision])
            XCTAssertEqual((inactive["workflow"] as? [String: Any])?["stage"] as? String, "review")
            XCTAssertFalse(fixture.gate.allows(bundleID: revisionID))
            let run = try await call("diagnostic_run_create", ["hypothesisSummary": "Coordinated synthetic resources",
                "expectedObservation": "Listing, detail and poster delivered; target outcome separately reported",
                "scopes": [["kind": "http", "method": "GET", "scheme": "http", "host": "api.example.invalid",
                    "port": 80, "path": "/catalog", "pathMatch": "exact"]]])
            let runID = try XCTUnwrap(run["runID"] as? String)
            _ = try await call("diagnostic_run_start", ["runID": runID])
            let baseline = try await call("diagnostic_run_window_begin", ["runID": runID, "bundleID": revision, "mode": "baseline"])
            let baselineID = try XCTUnwrap(baseline["id"] as? String)
            _ = try await call("diagnostic_run_window_end", ["windowID": baselineID])
            let proposal = try await call("propose_activate_effect_bundle", ["bundleID": revision, "ttlSeconds": 60])
            let apply: [String: Any] = ["proposalToken": try XCTUnwrap(proposal["proposalToken"] as? String)]
            do {
                _ = try await call("apply_activate_effect_bundle", apply)
                XCTFail("Activation must wait for approval")
            } catch CLIError.approvalRequired(let requestID, _) {
                XCTAssertFalse(fixture.gate.allows(bundleID: revisionID))
                // Isolated policy mechanics only: this is not a person approving live traffic.
                _ = try controller.approvalStore.approve(requestID: try XCTUnwrap(requestID))
            }
            _ = try await call("apply_activate_effect_bundle", apply)
            let modified = try await call("diagnostic_run_window_begin", ["runID": runID, "bundleID": revision, "mode": "modified"])
            let modifiedID = try XCTUnwrap(modified["id"] as? String)
            func fetch(_ path: String) async throws -> Data {
                let connection = NWConnection(host: "127.0.0.1",
                    port: try XCTUnwrap(NWEndpoint.Port(rawValue: proxy.port)), using: .tcp)
                defer { connection.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { connection.cancel() }
                try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "synthetic.agent-loop"))
                try await NetworkConnectionIO.send(Data(("GET http://api.example.invalid\(path) HTTP/1.1\r\n"
                    + "Host: api.example.invalid\r\nConnection: close\r\n\r\n").utf8), on: connection)
                var response = Data()
                while response.count < 1_048_576 {
                    do {
                        let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
                        response.append(bytes)
                        if complete { break }
                    } catch NetworkConnectionIOError.connectionClosed where !response.isEmpty {
                        break
                    }
                }
                let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
                let headers = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
                XCTAssertEqual(headers.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init), "200")
                let length = try XCTUnwrap(headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }?
                    .split(separator: ":", maxSplits: 1).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
                let body = Data(response[separator.upperBound...])
                XCTAssertEqual(body.count, length, "EOF cannot turn a truncated body into a successful response")
                return body
            }
            let listingBytes = try await fetch("/catalog")
            let listingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: listingBytes) as? [String: Any])
            let items = try XCTUnwrap(listingObject["items"] as? [[String: Any]])
            XCTAssertEqual(items.map { $0["id"] as? String }, ["joe", "original"])
            XCTAssertEqual(items.first?["poster"] as? String, "art/poster.png?revision=one")
            let missingImage = try await call("effect_bundle_inspect", ["bundleID": revision])
            XCTAssertEqual((missingImage["workflow"] as? [String: Any])?["targetOutcome"] as? String, "unknown")
            let beforeImage = fixture.gate.evidence(bundleID: revisionID)
            XCTAssertFalse(beforeImage.receipts.contains { $0.resource.assetID == "image-0" && $0.evaluation == .responseResolved })
            let detailBytes = try await fetch("/details/joe")
            XCTAssertEqual((try JSONSerialization.jsonObject(with: detailBytes) as? [String: Any])?["title"] as? String, "JoesProxy")
            let imageBytes = try await fetch("/art/poster.png?revision=one")
            XCTAssertEqual(imageBytes, png)
            await recorder.waitForPendingStoreFlush()
            // Poll bounded metadata until downstream completions, not a guessed sleep.
            for _ in 0..<100 {
                if fixture.gate.evidence(bundleID: revisionID).receipts.filter({ $0.delivery == .downstreamWriteSucceeded }).count == 3 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let delivered = fixture.gate.evidence(bundleID: revisionID).receipts.filter { $0.evaluation == .responseResolved }
            XCTAssertEqual(delivered.count, 3)
            XCTAssertTrue(delivered.allSatisfy { $0.delivery == .downstreamWriteSucceeded && $0.matchesExpectedDelivery == true })
            let wrongClient = CapturedRequest(method: "GET", scheme: .http, host: "api.example.invalid", port: 80,
                path: "/catalog", headers: [], bodyData: nil, bodySize: nil, clientAddress: "192.0.2.2")
            assertNoMatch(try await fixture.responseStore.ruleDecision(for: wrongClient))
            _ = try await call("diagnostic_run_window_end", ["windowID": modifiedID,
                "targetOutcome": "rejected", "outcomeSource": "Synthetic test observer; no real target interaction"])
            let comparisonArgs = ["baselineWindowID": baselineID, "modifiedWindowID": modifiedID]
            let comparison = try await call("effect_bundle_compare", comparisonArgs)
            XCTAssertEqual((comparison["modified"] as? [String: Any])?["targetOutcome"] as? String, "rejected")
            let actual = try diagnostics.compareExperimentWindows(baselineID: XCTUnwrap(UUID(uuidString: baselineID)),
                modifiedID: XCTUnwrap(UUID(uuidString: modifiedID)), requestingOwnerID: enrollment.client.id)
            XCTAssertEqual(actual.resources.reduce(0) { $0 + $1.modified.delivered }, 3)
            let launcher = WindowTestAppLauncher()
            let cli = CLIApplication(credentialStore: WindowTestCredentialStore(enrollment.plaintextCredential),
                sessionStore: sessionStore, appLauncher: launcher, clientFactory: {
                    MCPCLIClient(endpoint: $0, credential: $1, sessionStore: $2, timeout: $3, urlSession: transport)
                })
            let cliInspect = await cli.run(arguments: ["effect", "bundle", "inspect", revision,
                "--endpoint", endpoint.absoluteString, "--quiet"])
            XCTAssertEqual(cliInspect, .success)
            let cliCompare = await cli.run(arguments: ["effect", "bundle", "compare", "--baseline-window-id", baselineID,
                "--modified-window-id", modifiedID, "--endpoint", endpoint.absoluteString, "--quiet"])
            XCTAssertEqual(cliCompare, .success)
            do {
                _ = try await call("effect_bundle_inspect", ["revisionID": UUID().uuidString])
                XCTFail("Unknown reviewed revision cannot select another bundle")
            } catch is CLIError { }
            _ = try await call("effect_bundle_stop", ["bundleID": revision])
            // Inject a retained partial-cleanup state; recovery must remain owned and explicit.
            try fixture.repository.setCleanupRequired(id: revisionID, message: "Synthetic cleanup interruption")
            let partial = try await call("effect_bundle_inspect", ["bundleID": revision])
            XCTAssertEqual((partial["workflow"] as? [String: Any])?["stage"] as? String, "cleanup")
            _ = try await call("effect_bundle_stop", ["bundleID": revision])
            let stopped = try await call("effect_bundle_inspect", ["bundleID": revision])
            XCTAssertEqual(stopped["state"] as? String, "stopped")
            XCTAssertEqual(stopped["isServing"] as? Bool, false)
            XCTAssertFalse(fixture.gate.allows(bundleID: revisionID))
            let rules = await fixture.responseStore.rules()
            XCTAssertTrue(rules.isEmpty)
            XCTAssertEqual(launcher.launchCount, 0)
            XCTAssertEqual(controller.approvalStore.pendingCount, 0)
            let closed = try await call("diagnostic_run_close", ["runID": runID, "requestedTerminal": "inconclusive",
                "conclusionOutcome": "inconclusive", "conclusionReasonCode": "insufficient_evidence",
                "conclusionSummary": "Wire bytes verified; synthetic target rejection is not real target acceptance."])
            XCTAssertEqual(closed["status"] as? String, "inconclusive")
            XCTAssertEqual((closed["workflow"] as? [String: Any])?["stage"] as? String, "report")
            for _ in 0..<100 {
                if metrics.snapshot.transactions >= calls + 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let network = metrics.snapshot
            XCTAssertGreaterThanOrEqual(network.transactions, calls + 2)
            XCTAssertGreaterThan(network.received, 0)
            XCTAssertGreaterThan(network.sent, 0)
            let measurement: [String: Any] = ["mcpToolAttempts": calls, "rejectedToolAttempts": rejectedCalls,
                "successfulPayloadJSONBytes": responseBytes, "quietCLICommands": 2, "idempotencyRetries": 1,
                "approvalRetries": 1, "byteCheckedProxyResponses": 3, "remainingRules": rules.count,
                "httpTransactions": network.transactions, "httpRequestBodyBytesSent": network.sent,
                "httpResponseBodyBytesReceived": network.received,
                "limits": "URLSession HTTP body metrics include initialization, errors, retries and both CLI calls, not HTTP headers or target image bytes. Payload JSON count covers successful MCP tool responses only. Tokens unmeasured. Empty explicit baseline; synthetic target rejection and cleanup fault."]
            let receipt = try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys, .prettyPrinted])
            let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
            attachment.name = "R182-agent-loop-measurements"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("R182 agent loop: \(String(decoding: receipt, as: UTF8.self))")
            withExtendedLifetime(bridge) { }
            await proxy.stop()
            await controller.stop()
        } catch {
            if let ownedBundle { _ = try? await fixture.coordinator.stop(id: ownedBundle, requestingOwnerID: ownerID) }
            await proxy.stop()
            await controller.stop()
            throw error
        }
    }

    func testExplicitLocalControlPreservesAgentOwnershipAndRemoteIsolation() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        var second = manifest.responseEffects[0]
        second.id = UUID()
        manifest.responseEffects.append(second)
        manifest.phases = [
            .init(id: UUID(), label: "First", durationSeconds: 60, responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [], timestampBindings: []),
            .init(id: UUID(), label: "Second", durationSeconds: 60, responseEffectIDs: [second.id], hlsSubstitutionIDs: [], timestampBindings: [])
        ]
        let source = fixture.root.appendingPathComponent("local-control.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        let owner = EffectBundleOwner.mcpClient(id: "agent-owner", displayName: "Synthetic agent")
        let reviewed = try fixture.repository.importPackage(at: source, owner: owner)
        do {
            _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: "other-agent")
            XCTFail("Another agent cannot activate the bundle")
        } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
        var staleReview = reviewed
        staleReview.manifest.name = "Unreviewed change"
        do {
            _ = try await fixture.coordinator.activateFromLocalUI(reviewed: staleReview)
            XCTFail("Local authority must not bypass revision review")
        } catch { XCTAssertEqual(error as? EffectBundleError, .activationConflict) }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        _ = try await fixture.coordinator.activateFromLocalUI(reviewed: reviewed, ttl: 120)
        let first = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.owner, owner)
        let policy = MCPPolicyStore(persistenceURL: fixture.root.appendingPathComponent("policy.json"))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: MCPRecoveryCoordinator(journalStore:
            MCPEffectJournalStore(persistenceURL: fixture.root.appendingPathComponent("journal.json"))),
            policyRevisionProvider: { policy.policyRevision })
        let service = MCPEffectBundleService(repository: fixture.repository, activationCoordinator: fixture.coordinator,
            proposalCoordinator: proposals, approvalStore: MCPApprovalStore(), policyStore: policy,
            grantStore: MCPClientGrantStore(persistenceURL: fixture.root.appendingPathComponent("grants.json")),
            auditStore: MCPAuditStore(persistenceURL: fixture.root.appendingPathComponent("audit.json")))
        let intruder = MCPClientRecord(id: "other-agent", displayName: "Other", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        for tool in ["effect_bundle_stop", "effect_bundle_advance"] {
            do {
                _ = try await service.handleTool(name: tool, arguments: ["bundleID": manifest.id.uuidString,
                    "activationID": first.activationID.uuidString, "expectedPhaseID": first.phaseID.uuidString,
                    "localUI": true, "requestingOwnerID": owner.ownerID], client: intruder)
                XCTFail("Remote arguments cannot impersonate local UI or another owner")
            } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
        }
        for requester in ["other-agent", EffectBundleOwner.localUser.ownerID] {
            do {
                _ = try await fixture.coordinator.advance(id: manifest.id, requestingOwnerID: requester,
                    activationID: first.activationID, expectedPhaseID: first.phaseID)
                XCTFail("An owner ID is not local UI authority")
            } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
            do {
                _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: requester)
                XCTFail("Remote Stop remains owner restricted")
            } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
        }
        let next = try await fixture.coordinator.advanceFromLocalUI(id: manifest.id,
            activationID: first.activationID, expectedPhaseID: first.phaseID)
        XCTAssertEqual(next?.phaseIndex, 1)
        XCTAssertEqual(next?.expiresAt, first.expiresAt)
        do {
            _ = try await fixture.coordinator.advanceFromLocalUI(id: manifest.id,
                activationID: first.activationID, expectedPhaseID: first.phaseID)
            XCTFail("Local retry must not skip a phase")
        } catch { XCTAssertEqual(error as? EffectBundleError, .stalePhase) }
        let stopped = try await fixture.coordinator.stopFromLocalUI(id: manifest.id)
        XCTAssertEqual(stopped.owner, owner)
        XCTAssertFalse(stopped.isServing)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        XCTAssertNil(fixture.coordinator.phaseSnapshots[manifest.id])
        _ = try fixture.repository.metadataRecord(id: manifest.id, requestingOwnerID: owner.ownerID)
        XCTAssertThrowsError(try fixture.repository.metadataRecord(id: manifest.id, requestingOwnerID: "other-agent"))
    }

    func testReviewedLiveCompletionPreservesRouteAndMediaUntilOwningStop() async throws {
        var instant = Date()
        let fixture = try makeCoordinatorFixture(schedulesTimers: false, clock: { instant })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mediaID = UUID()
        let sourceFiles: [String: Data] = [
            "master.m3u8": Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nvideo/stream.m3u8\n".utf8),
            "video/stream.m3u8": Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n".utf8),
            "video/seg.ts": Data([0x47, 1, 2, 3])
        ]
        var data: [String: Data] = [:]
        for (path, bytes) in sourceFiles {
            data["primary/\(path)"] = bytes
            data["replacement/\(path)"] = path.hasSuffix(".ts") ? Data([0x47, 4, 5, 6]) : bytes
        }
        var manifest = makeManifest(body: Data())
        manifest.responseEffects = []
        manifest.assets = data.keys.sorted().map { path in
            .init(id: path, role: .hlsProfileFile, logicalPath: path,
                  sha256: EffectBundleValidator.sha256Hex(data[path]!), byteCount: data[path]!.count, contentType: nil)
        }
        var config = HLSPlaybackConfiguration.conformant
        config.presentationMode = .liveLoop
        config.timeShiftMode = .warmDVR
        manifest.hlsSubstitutions = [.init(id: mediaID, profileID: "synthetic", profileVersion: "1",
            profileAssetIDs: manifest.assets.filter { $0.id.hasPrefix("primary/") }.map(\.id), profileRootLogicalPath: "primary",
            origin: .init(scheme: .https, host: "media.example.invalid"),
            scope: .selectedPlaylist(path: "/live.m3u8"), playbackConfiguration: config,
            requestPolicy: .init(clientAddress: "192.0.2.1", missingTextTrackID: nil))]
        var replacement = manifest.hlsSubstitutions[0]
        replacement.id = UUID()
        replacement.replacesSubstitutionID = mediaID
        replacement.profileRootLogicalPath = "replacement"
        replacement.profileAssetIDs = manifest.assets.filter { $0.id.hasPrefix("replacement/") }.map(\.id)
        manifest.hlsSubstitutions.append(replacement)
        manifest.phases = [
            .init(id: UUID(), label: "Live", durationSeconds: 30, responseEffectIDs: [], hlsSubstitutionIDs: [mediaID], timestampBindings: []),
            .init(id: UUID(), label: "Switch", durationSeconds: 30, responseEffectIDs: [], hlsSubstitutionIDs: [replacement.id], timestampBindings: []),
            .init(id: UUID(), label: "Complete", durationSeconds: 30, responseEffectIDs: [], hlsSubstitutionIDs: [], timestampBindings: [], completeHLSSubstitutionIDs: [mediaID])
        ]
        var oldSchema = manifest
        oldSchema.schemaVersion = 5
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(oldSchema))
        var invalid = manifest
        try EffectBundleValidator.validateManifest(manifest)
        invalid.hlsSubstitutions[1].requestPolicy = nil
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalid), "Replacement must not widen scope")
        invalid = manifest
        invalid.hlsSubstitutions[1].requestPolicy = .init(clientAddress: "192.0.2.2", missingTextTrackID: nil)
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalid), "Replacement must retain the reviewed client")
        invalid = manifest
        invalid.phases![0].completeHLSSubstitutionIDs = [mediaID]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalid), "Cannot complete before first publication")
        invalid = manifest
        invalid.phases![1].completeHLSSubstitutionIDs = [mediaID]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalid), "One completion action per fixture")
        let source = fixture.root.appendingPathComponent("media.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: data, to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let route = await fixture.hlsRoutes.decision(for: request(host: "media.example.invalid", path: "/live.m3u8"))
        let decision = try XCTUnwrap(route)
        let server = try XCTUnwrap(fixture.hlsRuns.liveServer(id: decision.fixtureRunID))
        let original = server.response(forPath: "video/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertFalse(String(decoding: original.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        var phase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        _ = try await fixture.coordinator.advance(id: manifest.id, activationID: phase.activationID, expectedPhaseID: phase.phaseID)
        XCTAssertNil(server.completionTime, "Continuation does not restart or freeze the media clock")
        XCTAssertTrue(fixture.hlsRuns.liveServer(id: decision.fixtureRunID) === server)
        XCTAssertEqual(server.activePreparedMediaID, replacement.id)
        instant = instant.addingTimeInterval(12)
        phase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        _ = try await fixture.coordinator.advance(id: manifest.id, activationID: phase.activationID, expectedPhaseID: phase.phaseID)
        let completed = server.response(forPath: "video/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertTrue(String(decoding: completed.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        let state = try fixture.coordinator.supervision(id: manifest.id)
        XCTAssertTrue(state.routingOpen)
        XCTAssertEqual(state.media.first?.completedAt, server.completionTime)
        XCTAssertTrue(state.media.first?.active == true)
        XCTAssertTrue(state.media.first?.scope.contains("192.0.2.1") == true)
        XCTAssertEqual(state.labReadiness?.compatibility, "scopedMediaConfigured")
        XCTAssertEqual(state.media.first?.activePreparedMediaID, replacement.id)
        let mediaPlan = MCPEffectBundleService.mediaPlanSummary(manifest)
        let planPhases = try XCTUnwrap(mediaPlan["phases"] as? [[String: Any]])
        XCTAssertEqual(planPhases[2]["completeIDs"] as? [String], [mediaID.uuidString])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: mediaPlan).count, 4096)
        let finalWindow = try XCTUnwrap(server.slidingWindow(forPath: "video/stream.m3u8", now: .distantFuture))
        XCTAssertTrue(finalWindow.isComplete)
        for entry in finalWindow.entries {
            let switched = entry.segment.uri.contains("__jp_media")
            let path = switched ? "__jp_media/\(replacement.id.uuidString)/video/seg.ts" : "video/seg.ts"
            let segment = server.response(forPath: "\(path)?jp_hls_sequence=\(entry.virtualIndex)", method: "GET", rangeHeader: nil)
            XCTAssertEqual(segment.body, data[switched ? "replacement/video/seg.ts" : "primary/video/seg.ts"])
        }
        _ = try await fixture.coordinator.stop(id: manifest.id)
        XCTAssertNil(fixture.hlsRuns.liveServer(id: decision.fixtureRunID))
        let afterStop = await fixture.hlsRoutes.decision(for: request(host: "media.example.invalid", path: "/live.m3u8"))
        XCTAssertNil(afterStop)
        XCTAssertFalse(try fixture.coordinator.supervision(id: manifest.id).media[0].active)

        // An incompatible prepared master must roll back the run before opening any route.
        var incompatible = data
        incompatible["replacement/master.m3u8"] = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nvideo/stream.m3u8\n".utf8)
        var invalidMedia = manifest
        invalidMedia.id = UUID()
        invalidMedia.assets = manifest.assets.map { original in
            var asset = original
            asset.sha256 = EffectBundleValidator.sha256Hex(incompatible[asset.id]!)
            asset.byteCount = incompatible[asset.id]!.count
            return asset
        }
        let badSource = fixture.root.appendingPathComponent("incompatible.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: invalidMedia, assetDataByID: incompatible, to: badSource)
        _ = try fixture.repository.importPackage(at: badSource, owner: .localUser)
        do {
            _ = try await fixture.coordinator.activate(id: invalidMedia.id)
            XCTFail("Changed master topology must not activate")
        } catch HLSFixtureServer.FixtureServerError.completionRequiresLiveLoop { }
        XCTAssertFalse(fixture.gate.allows(bundleID: invalidMedia.id))
        XCTAssertNil(fixture.hlsRuns.liveServer(id: decision.fixtureRunID))
        let afterFailure = await fixture.hlsRoutes.decision(for: request(host: "media.example.invalid", path: "/live.m3u8"))
        XCTAssertNil(afterFailure)

        // A separately stopped/restarted fixture is not silently adopted into the reviewed run.
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let newRoute = await fixture.hlsRoutes.decision(for: request(host: "media.example.invalid", path: "/live.m3u8"))
        let runID = try XCTUnwrap(newRoute?.fixtureRunID)
        _ = try await fixture.hlsRuns.stopRun(id: runID, clientID: EffectBundleOwner.localUser.ownerID)
        let restarted = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        do {
            _ = try await fixture.coordinator.advance(id: manifest.id, activationID: restarted.activationID, expectedPhaseID: restarted.phaseID)
            XCTFail("A changed media run must fail closed")
        } catch EffectBundleError.activationConflict { }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
    }

    func testCollectionPhasesSelectPlansPreserveAdmittedWorkAndRestartWithNewIdentity() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        var manifest = makeManifest(body: body)
        manifest.responseEffects = try ["first", "second"].map { name in
            var effect = manifest.responseEffects[0]
            effect.id = UUID()
            effect.sourceKind = .collectionMock
            effect.statusCode = 200
            effect.headers = []
            effect.bodySource = .none
            effect.forceNoCache = false
            effect.collectionMockPlan = try CollectionMockCompiler.prepare(source: body,
                draft: .init(collectionPointer: "/items", item: .object(["id": .string(name)]), templateIndex: nil,
                    edits: [], identityPointers: ["/id"], countPointers: ["/total"], position: .append))
            return effect
        }
        manifest.phases = manifest.responseEffects.enumerated().map { index, effect in
            .init(id: UUID(), label: "Live \(index)", durationSeconds: 30,
                  responseEffectIDs: [effect.id], hlsSubstitutionIDs: [], timestampBindings: [])
        }
        let source = fixture.root.appendingPathComponent("live-phases.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let firstPhase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        let request = request(host: "api.example.invalid", path: "/catalog")
        let decision = try await fixture.responseStore.ruleDecision(for: request)
        guard case .liveCollectionMock(let firstID, _, let description, let revision) = decision else {
            return XCTFail("The selected phase must expose its live plan")
        }
        let old = try XCTUnwrap(revision)
        XCTAssertEqual(old.phase?.phaseID, firstPhase.phaseID)
        XCTAssertEqual(old.phase?.activationID, firstPhase.activationID)
        XCTAssertTrue(description.contains(firstPhase.phaseID.uuidString))
        let fields = [HTTPHeaderField(name: "Content-Type", value: "application/json")]
        let first = await fixture.executor.transform(revision: old, method: "GET", statusCode: 200, headers: fields, body: body)
        XCTAssertEqual(first.outcome, .applied(beforeCount: 1, afterCount: 2))
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: manifest.responseEffects[1].id, now: .distantPast)
        XCTAssertTrue(LiveTransformationActivationTracker.shared.isExpired(ruleID: manifest.responseEffects[1].id))
        _ = try await fixture.coordinator.advance(id: manifest.id, activationID: firstPhase.activationID, expectedPhaseID: firstPhase.phaseID)
        XCTAssertFalse(LiveTransformationActivationTracker.shared.isExpired(ruleID: manifest.responseEffects[1].id),
            "A staged rule's live lifetime starts when its phase enters, not at bundle staging")
        XCTAssertTrue(fixture.executor.isCurrent(old), "Advance preserves already-admitted work under its original phase")
        let stale = await fixture.executor.transform(revision: old, method: "GET", statusCode: 200, headers: fields, body: body)
        XCTAssertEqual(stale.outcome, .applied(beforeCount: 1, afterCount: 2))
        XCTAssertTrue(String(decoding: stale.body, as: UTF8.self).contains("first"))
        XCTAssertEqual(old.phase?.phaseID, firstPhase.phaseID)
        let nextDecision = try await fixture.responseStore.ruleDecision(for: request)
        guard case .liveCollectionMock(let secondID, _, _, let nextRevision) = nextDecision else {
            return XCTFail("Next phase must retain live transformation support")
        }
        XCTAssertNotEqual(firstID, secondID)
        let next = try XCTUnwrap(nextRevision)
        let transformed = await fixture.executor.transform(revision: next, method: "GET", statusCode: 200, headers: fields, body: body)
        XCTAssertEqual(transformed.outcome, .applied(beforeCount: 1, afterCount: 2))
        XCTAssertTrue(String(decoding: transformed.body, as: UTF8.self).contains("second"))
        XCTAssertFalse(String(decoding: transformed.body, as: UTF8.self).contains("first"))
        _ = try await fixture.coordinator.stop(id: manifest.id)
        XCTAssertFalse(fixture.executor.isCurrent(next))
        _ = try await fixture.coordinator.activate(id: manifest.id)
        XCTAssertNotEqual(fixture.coordinator.phaseSnapshots[manifest.id]?.activationID, firstPhase.activationID)
        XCTAssertFalse(fixture.executor.isCurrent(old))
        _ = try await fixture.coordinator.stop(id: manifest.id)
    }

    func testISOBindingsServeDistinctPhaseBodiesWithoutChangingReviewedAsset() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data(#"{"time":"placeholder","count":3,"enabled":true}"#.utf8)
        var manifest = makeManifest(body: body)
        manifest.responseEffects[0].headers += [
            .init(name: "ETag", value: "old"), .init(name: "Content-Length", value: "1"),
            .init(name: "Content-Encoding", value: "identity")
        ]
        var second = manifest.responseEffects[0]
        second.id = UUID()
        second.sourceKind = .localFile
        second.bodySource.kind = .file
        manifest.responseEffects.append(second)
        manifest.phases = manifest.responseEffects.enumerated().map { index, effect in
            .init(id: UUID(), label: "Phase \(index)", durationSeconds: 20,
                  responseEffectIDs: [effect.id], hlsSubstitutionIDs: [], timestampBindings: [
                    .init(id: UUID(), responseEffectID: effect.id, jsonPointer: "/time", offsetSeconds: Double(index * 30))
                  ])
        }
        let source = fixture.root.appendingPathComponent("iso.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        let receipt = try await fixture.coordinator.activate(id: manifest.id)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = CapturedRequest(method: "GET", scheme: .https, host: "api.example.invalid", port: 443,
            path: "/catalog", headers: [], bodyData: nil, bodySize: nil)
        for index in 0..<2 {
            let decision = try await fixture.responseStore.ruleDecision(for: request)
            guard case .mapLocal(let response) = decision else { return XCTFail("Bound response must be served") }
            let delivered = try XCTUnwrap(response.bodyData)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: delivered) as? [String: Any])
            XCTAssertEqual(json["time"] as? String, formatter.string(from: receipt.activatedAt.addingTimeInterval(Double(index * 30))))
            XCTAssertEqual(json["count"] as? Int, 3)
            XCTAssertEqual(json["enabled"] as? Bool, true)
            let identity = try XCTUnwrap(fixture.gate.resource(ruleID: manifest.responseEffects[index].id))
            XCTAssertEqual(identity.expectedSHA256, manifest.assets[0].sha256)
            XCTAssertEqual(identity.materializedSHA256, EffectBundleValidator.sha256Hex(delivered))
            XCTAssertNotEqual(identity.expectedSHA256, identity.materializedSHA256)
            XCTAssertEqual(try fixture.repository.recoveryAssetTarget(identity).asset.id, "body",
                "A phase-owned static asset without collection authoring metadata remains inspectable")
            XCTAssertFalse(response.headers.contains { ["etag", "content-length", "content-encoding"].contains($0.name.lowercased()) })
            _ = fixture.gate.observe(resource: identity, servedSHA256: EffectBundleValidator.sha256Hex(delivered))
            if index == 0 {
                let phase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
                _ = try await fixture.coordinator.advance(id: manifest.id, activationID: phase.activationID, expectedPhaseID: phase.phaseID)
            }
        }
        let retained = try fixture.repository.manifestAndPackageURL(id: manifest.id)
        let evidence = try fixture.coordinator.deliveryEvidence(id: manifest.id)
        XCTAssertEqual(evidence.receipts.count, 2)
        XCTAssertTrue(evidence.receipts.allSatisfy { $0.matchesReviewedAsset == false && $0.matchesMaterializedAsset == true })
        XCTAssertEqual(retained.manifest, manifest)
        XCTAssertEqual(try Data(contentsOf: retained.packageURL.appendingPathComponent(manifest.assets[0].packageRelativePath)), body)
        try await fixture.coordinator.stop(id: manifest.id)
    }

    func testISOTimestampTypedPointersBoundsAndDeliveryComparison() throws {
        let id = UUID()
        let binding = EffectBundleTimestampBinding(id: UUID(), responseEffectID: id,
                                                   jsonPointer: "/a~1b/0/~0time", offsetSeconds: -1)
        let data = Data(#"{"a/b":[{"~time":"old"}],"untouched":null}"#.utf8)
        let rendered = try EffectBundleTimestampRenderer.render(data, bindings: [binding], anchor: Date(timeIntervalSince1970: 1))
        let value = try CollectionMockCompiler.value(at: ["a/b", "0", "~time"], in: CollectionMockCompiler.parse(rendered))
        XCTAssertEqual(value, .string("1970-01-01T00:00:00.000Z"))
        XCTAssertThrowsError(try EffectBundleTimestampRenderer.render(data, bindings: [binding, binding], anchor: Date()))
        var wrong = binding
        wrong.jsonPointer = "/untouched"
        XCTAssertThrowsError(try EffectBundleTimestampRenderer.render(data, bindings: [wrong], anchor: Date()))
        wrong.jsonPointer = "/missing"
        XCTAssertThrowsError(try EffectBundleTimestampRenderer.render(data, bindings: [wrong], anchor: Date()))
        XCTAssertThrowsError(try EffectBundleTimestampRenderer.render(Data(repeating: 32, count: CollectionMockCompiler.maximumBodyBytes + 1), bindings: [binding], anchor: Date()))
        let nearLimit = Data(("{\"time\":\"\",\"padding\":\"" + String(repeating: "a", count: CollectionMockCompiler.maximumBodyBytes - 25) + "\"}").utf8)
        wrong.jsonPointer = "/time"
        XCTAssertLessThanOrEqual(nearLimit.count, CollectionMockCompiler.maximumBodyBytes)
        XCTAssertThrowsError(try EffectBundleTimestampRenderer.render(nearLimit, bindings: [wrong], anchor: Date())) { error in
            XCTAssertEqual(error as? CollectionMockError, .sizeLimit)
        }
        let resource = EffectBundleResourceIdentity(bundleID: UUID(), revisionID: UUID(), activationID: UUID(),
            resourceID: id, assetID: "body", expectedSHA256: "template", materializedSHA256: "rendered")
        var receipt = EffectBundleDeliveryReceipt(id: UUID(), marker: 1, resource: resource, servedSHA256: "rendered",
            matchesReviewedAsset: false, observedAt: Date())
        receipt.matchesMaterializedAsset = true
        XCTAssertEqual(receipt.matchesExpectedDelivery, true)
        receipt.matchesMaterializedAsset = false
        XCTAssertEqual(receipt.matchesExpectedDelivery, false)
    }

    func testPhasedRoutingAdvanceRetryExpiryAndOwnerBoundaries() async throws {
        var elapsed: TimeInterval = 100
        let fixture = try makeCoordinatorFixture(uptime: { elapsed }, schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        var second = manifest.responseEffects[0]
        second.id = UUID()
        second.statusCode = 200
        manifest.responseEffects.append(second)
        manifest.phases = [
            .init(id: UUID(), label: "Unavailable", durationSeconds: 20,
                  responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [], timestampBindings: []),
            .init(id: UUID(), label: "Recovered", durationSeconds: 60,
                  responseEffectIDs: [second.id], hlsSubstitutionIDs: [], timestampBindings: [])
        ]
        let source = fixture.root.appendingPathComponent("phases.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .mcpClient(id: "owner", displayName: "Owner"))
        _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: "owner")
        let first = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        XCTAssertTrue(fixture.gate.allows(responseRuleID: manifest.responseEffects[0].id))
        XCTAssertFalse(fixture.gate.allows(responseRuleID: second.id))
        let request = CapturedRequest(method: "GET", scheme: .https, host: "api.example.invalid", port: 443,
            path: "/catalog", headers: [], bodyData: nil, bodySize: nil)
        let firstDecision = try await fixture.responseStore.ruleDecision(for: request)
        guard case .mapLocal(let firstResponse) = firstDecision else { return XCTFail("First phase must serve a response") }
        XCTAssertEqual(firstResponse.statusCode, 503)
        XCTAssertEqual(fixture.gate.resource(ruleID: manifest.responseEffects[0].id)?.phaseID, first.phaseID)
        do {
            _ = try await fixture.coordinator.advance(id: manifest.id, requestingOwnerID: "intruder",
                activationID: first.activationID, expectedPhaseID: first.phaseID)
            XCTFail("Wrong owner must not advance")
        } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
        elapsed = 110
        let next = try await fixture.coordinator.advance(id: manifest.id, requestingOwnerID: "owner",
            activationID: first.activationID, expectedPhaseID: first.phaseID)
        let current = try XCTUnwrap(next)
        XCTAssertEqual(current.expiresAt, first.expiresAt)
        XCTAssertEqual(current.phaseDeadline, first.expiresAt, "Manual Advance cannot extend lifetime")
        XCTAssertFalse(fixture.gate.allows(responseRuleID: manifest.responseEffects[0].id))
        XCTAssertTrue(fixture.gate.allows(responseRuleID: second.id))
        let secondDecision = try await fixture.responseStore.ruleDecision(for: request)
        guard case .mapLocal(let secondResponse) = secondDecision else { return XCTFail("Second phase must serve a response") }
        XCTAssertEqual(secondResponse.statusCode, 200)
        do {
            _ = try await fixture.coordinator.advance(id: manifest.id, requestingOwnerID: "owner",
                activationID: first.activationID, expectedPhaseID: first.phaseID)
            XCTFail("Retried commands must not skip a phase")
        } catch { XCTAssertEqual(error as? EffectBundleError, .stalePhase) }
        elapsed = 161
        let terminal = try await fixture.coordinator.advance(id: manifest.id, requestingOwnerID: "owner",
            activationID: current.activationID, expectedPhaseID: current.phaseID)
        XCTAssertNil(terminal)
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.terminationReason, .expired)
        XCTAssertNil(fixture.coordinator.phaseSnapshots[manifest.id])
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        let remaining = await fixture.responseStore.rules()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAutomaticDeadlineAndRestartRejectOldCallbacks() async throws {
        var elapsed: TimeInterval = 100
        let fixture = try makeCoordinatorFixture(uptime: { elapsed }, schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        manifest.phases = [.init(id: UUID(), label: "Finite", durationSeconds: 10,
            responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [], timestampBindings: [])]
        let source = fixture.root.appendingPathComponent("finite.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let initial = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        elapsed = 109
        await fixture.coordinator.advanceIfDue(id: manifest.id, activationID: initial.activationID, expectedPhaseID: initial.phaseID)
        XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id))
        elapsed = 110
        await fixture.coordinator.advanceIfDue(id: manifest.id, activationID: initial.activationID, expectedPhaseID: initial.phaseID)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.terminationReason, .completed)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let restarted = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        XCTAssertNotEqual(initial.activationID, restarted.activationID)
        await fixture.coordinator.advanceIfDue(id: manifest.id, activationID: initial.activationID, expectedPhaseID: initial.phaseID)
        XCTAssertEqual(fixture.coordinator.phaseSnapshots[manifest.id], restarted)
        await fixture.coordinator.handleSleepState(isSleeping: true)
        do {
            _ = try await fixture.coordinator.activate(id: manifest.id)
            XCTFail("Sleep must prevent a new timed activation")
        } catch EffectBundleError.unsupportedPhaseFeature { }
        await fixture.coordinator.handleSleepState(isSleeping: false)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id), "Wake never resumes a run")
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.terminationReason, .sleep)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id), "A newly requested run is allowed after wake")
        _ = try await fixture.coordinator.stop(id: manifest.id)
    }

    func testLateTransitionConflictStopsOwnedRulesAndPreservesUnrelatedRule() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        var nextEffect = manifest.responseEffects[0]
        nextEffect.id = UUID()
        nextEffect.path = "/next"
        manifest.responseEffects.append(nextEffect)
        manifest.phases = manifest.responseEffects.map {
            .init(id: UUID(), label: $0.path, durationSeconds: 20,
                  responseEffectIDs: [$0.id], hlsSubstitutionIDs: [], timestampBindings: [])
        }
        let source = fixture.root.appendingPathComponent("conflict.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let phase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        let unrelated = ResponseOverrideRule(requestMethod: "GET", requestScheme: .https,
            host: "api.example.invalid", port: 443, path: "/next", sourceKind: .inlineText,
            sourceDescription: "Independent synthetic rule", statusCode: 201, headers: [], bodySource: .inline(body))
        try await fixture.responseStore.addRule(unrelated)
        do {
            _ = try await fixture.coordinator.advance(id: manifest.id,
                activationID: phase.activationID, expectedPhaseID: phase.phaseID)
            XCTFail("A newly conflicting rule must prevent phase publication")
        } catch { XCTAssertEqual(error as? EffectBundleError, .activationConflict) }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        let remaining = await fixture.responseStore.rules()
        XCTAssertEqual(remaining.map(\.id), [unrelated.id])
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.terminationReason, .transitionConflict)
    }

    func testMissingTimestampFieldFailsBeforeInstallingAndSleepCleansTimedRun() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        manifest.phases = [.init(id: UUID(), label: "Test", durationSeconds: 20,
            responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [],
            timestampBindings: [.init(id: UUID(), responseEffectID: manifest.responseEffects[0].id,
                                     jsonPointer: "/time", offsetSeconds: 0)])]
        let source = fixture.root.appendingPathComponent("binding.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        do {
            _ = try await fixture.coordinator.activate(id: manifest.id)
            XCTFail("Missing timestamp targets must not silently activate unmodified data")
        } catch CollectionMockError.missingValue { }
        let rules = await fixture.responseStore.rules()
        XCTAssertTrue(rules.isEmpty)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        try fixture.repository.discard(id: manifest.id)
        manifest.phases?[0].timestampBindings = []
        let readySource = fixture.root.appendingPathComponent("ready.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: readySource)
        _ = try fixture.repository.importPackage(at: readySource, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        await fixture.coordinator.stopTimedRunsForSleep()
        XCTAssertNil(fixture.coordinator.phaseSnapshots[manifest.id])
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        let afterSleep = await fixture.responseStore.rules()
        XCTAssertTrue(afterSleep.isEmpty)
    }

    func testDisablingStagedRulePreventsLaterPhasePublication() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        var manifest = makeManifest(body: body)
        manifest.phases = [
            .init(id: UUID(), label: "Baseline", durationSeconds: 10,
                  responseEffectIDs: [], hlsSubstitutionIDs: [], timestampBindings: []),
            .init(id: UUID(), label: "Fault", durationSeconds: 10,
                  responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [], timestampBindings: [])
        ]
        let source = fixture.root.appendingPathComponent("staged.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id)
        let phase = try XCTUnwrap(fixture.coordinator.phaseSnapshots[manifest.id])
        try await fixture.responseStore.disableRules(ids: [manifest.responseEffects[0].id])
        do {
            _ = try await fixture.coordinator.advance(id: manifest.id,
                activationID: phase.activationID, expectedPhaseID: phase.phaseID)
            XCTFail("Advance cannot reactivate altered staged effects")
        } catch { XCTAssertEqual(error as? EffectBundleError, .activationConflict) }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.terminationReason, .transitionConflict)
    }

    func testJoinedInspectionThroughAuthenticatedCLITransport() async throws {
        let budget = CaptureAdmissionBudget(byteLimit: 1, countLimit: 1)
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessions = InMemorySessionStore()
        let controller = MCPServerController(sessionStore: sessions, port: UInt16.random(in: 20_000...60_000),
            credentialStore: MCPInMemoryCredentialStore(),
            storageScope: RuntimeStorageScope(root: fixture.root, defaults: UserDefaults()))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: controller.recoveryCoordinator,
            policyRevisionProvider: { controller.policyStore.policyRevision })
        controller.configureMutationService(bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: fixture.responseStore, proposalCoordinator: proposals,
            configuration: MCPSelfValidationAppConfiguration())
        controller.configureEffectBundleService(repository: fixture.repository,
            activationCoordinator: fixture.coordinator, proposalCoordinator: proposals, sessionStore: sessions,
            admissionSnapshot: { budget.snapshot })
        XCTAssertNil(budget.reserve(bytes: 2))
        await controller.start()
        do {
            guard case .running(_, let endpoint) = controller.state else {
                XCTFail("Synthetic server did not start")
                await controller.stop()
                return
            }
            let enrollment = try controller.enrollClient(displayName: "Joined evidence test", profileID: .shareable)
            let body = Data(#"{"time":"placeholder"}"#.utf8)
            var manifest = makeManifest(body: body)
            manifest.phases = [.init(id: UUID(), label: "Transport phase", durationSeconds: 60,
                responseEffectIDs: [manifest.responseEffects[0].id], hlsSubstitutionIDs: [], timestampBindings: [
                    .init(id: UUID(), responseEffectID: manifest.responseEffects[0].id, jsonPointer: "/time", offsetSeconds: 0)
                ])]
            let source = fixture.root.appendingPathComponent("transport.jproxy-effects")
            try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
            _ = try fixture.repository.importPackage(at: source,
                owner: .mcpClient(id: enrollment.client.id, displayName: "Joined evidence test"))
            let sessionStore = CLIFileSessionStore(persistenceURL: fixture.root.appendingPathComponent("cli-session.json"))
            let client = MCPCLIClient(endpoint: endpoint, credential: enrollment.plaintextCredential,
                sessionStore: sessionStore, timeout: 10)
            let result = try await client.callTool(name: "effect_bundle_inspect", arguments: ["bundleID": manifest.id.uuidString])
            let payload = result // The protocol publishes service payload as structuredContent.
            let joined = try XCTUnwrap(payload["joinedEvidence"] as? [String: Any])
            XCTAssertEqual(joined["bundleID"] as? String, manifest.id.uuidString)
            XCTAssertEqual(joined["deliveryState"] as? String, "available")
            XCTAssertNotNil(payload["preflight"])
            XCTAssertNotNil(payload["deliveryEvidence"])
            let timestamps = try XCTUnwrap(payload["timestampBindings"] as? [String: Any])
            XCTAssertEqual(timestamps["format"] as? String, "ISO-8601 UTC milliseconds")
            XCTAssertEqual(timestamps["count"] as? Int, 1)
            let supervision = try XCTUnwrap(payload["supervision"] as? [String: Any])
            XCTAssertEqual(supervision["routingOpen"] as? Bool, false)
            XCTAssertEqual(supervision["nextActions"] as? [String], ["propose_activate_effect_bundle"])
            let coverage = try XCTUnwrap(joined["admissionCoverage"] as? [String: Any])
            XCTAssertEqual(coverage["historyState"] as? String, "admissionGapsInWindow")
            XCTAssertEqual(coverage["overlappingRejectedCapturesUpperBound"] as? Int, 1)
            XCTAssertNotNil(coverage["window"])
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: result).count, MCPResourceBudget.maxResponseBytes)
            XCTAssertEqual(controller.approvalStore.pendingCount, 0)
            // Synthetic coordinator activation establishes ownership without impersonating a
            // person's live approval. The authenticated tool may only advance that existing run.
            _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: enrollment.client.id)
            let active = try await client.callTool(name: "effect_bundle_inspect", arguments: ["bundleID": manifest.id.uuidString])
            let phase = try XCTUnwrap(active["phase"] as? [String: Any])
            let activeSupervision = try XCTUnwrap(active["supervision"] as? [String: Any])
            XCTAssertNotNil(active["mediaPlan"] as? [String: Any])
            XCTAssertEqual(activeSupervision["routingOpen"] as? Bool, true)
            XCTAssertTrue((activeSupervision["nextActions"] as? [String])?.contains("effect_bundle_advance") == true)
            let advanced = try await client.callTool(name: "effect_bundle_advance", arguments: [
                "bundleID": manifest.id.uuidString,
                "activationID": try XCTUnwrap(phase["activationID"] as? String),
                "expectedPhaseID": try XCTUnwrap(phase["phaseID"] as? String)])
            XCTAssertEqual(advanced["isServing"] as? Bool, false)
            XCTAssertNil(fixture.coordinator.phaseSnapshots[manifest.id])
            let originalSession = try XCTUnwrap(sessionStore.load(endpoint: endpoint))
            // Rotate only this synthetic fixture's credential. A rejected old token must
            // not silently reenroll, replay a write, or erase the retained local session.
            let rotated = try controller.rotateClient(clientID: enrollment.client.id)
            do {
                _ = try await client.callTool(name: "effect_bundle_inspect", arguments: ["bundleID": manifest.id.uuidString])
                XCTFail("Rotated credential must be rejected")
            } catch let error as CLIError {
                XCTAssertEqual(error.exitCode, .authenticationFailed)
                XCTAssertFalse(error.message.contains(enrollment.plaintextCredential))
            }
            XCTAssertEqual(try sessionStore.load(endpoint: endpoint)?.sessionID, originalSession.sessionID)
            let recovered = MCPCLIClient(endpoint: endpoint, credential: rotated.plaintextCredential,
                sessionStore: sessionStore, timeout: 10)
            // An explicit write with the stale session cannot be replayed automatically.
            do {
                _ = try await recovered.callTool(name: "effect_bundle_advance", arguments: [
                    "bundleID": manifest.id.uuidString,
                    "activationID": try XCTUnwrap(phase["activationID"] as? String),
                    "expectedPhaseID": try XCTUnwrap(phase["phaseID"] as? String)], retryOnStaleSession: false)
                XCTFail("Stale write must require caller recovery")
            } catch let error as CLIError { XCTAssertEqual(error.exitCode, .staleSession) }
            XCTAssertEqual(try sessionStore.load(endpoint: endpoint)?.sessionID, originalSession.sessionID)
            // A read can establish a new authenticated session without reactivating effects.
            let recoveredPayload = try await recovered.callTool(name: "effect_bundle_inspect",
                arguments: ["bundleID": manifest.id.uuidString])
            XCTAssertEqual((recoveredPayload["joinedEvidence"] as? [String: Any])?["bundleID"] as? String, manifest.id.uuidString)
            XCTAssertNotEqual(try sessionStore.load(endpoint: endpoint)?.sessionID, originalSession.sessionID)
            XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
            XCTAssertEqual(controller.approvalStore.pendingCount, 0)
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: recoveredPayload).count, MCPResourceBudget.maxResponseBytes)
            try controller.revokeClient(clientID: enrollment.client.id)
            do {
                _ = try await recovered.callTool(name: "effect_bundle_inspect", arguments: ["bundleID": manifest.id.uuidString])
                XCTFail("Revocation must not be bypassed by session recovery")
            } catch let error as CLIError { XCTAssertEqual(error.exitCode, .authenticationFailed) }
            XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
            // No runtime-control service/effects are installed in this read-only fixture.
            // Stop its owned server; DELETE-session runtime cleanup is a separate contract.
            await controller.stop()
        } catch {
            await controller.stop()
            throw error
        }
    }

    func testExplicitWindowsThroughCLIAndAuthenticatedTransportPreserveScopeAndCleanup() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessions = InMemorySessionStore()
        let controller = MCPServerController(sessionStore: sessions, port: UInt16.random(in: 20_000...60_000),
            credentialStore: MCPInMemoryCredentialStore(),
            storageScope: RuntimeStorageScope(root: fixture.root, defaults: UserDefaults()))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: controller.recoveryCoordinator,
            policyRevisionProvider: { controller.policyStore.policyRevision })
        let store = DiagnosticRunStore(persistenceURL: fixture.root.appendingPathComponent("window-runs.json"))
        controller.configureMutationService(bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: fixture.responseStore, proposalCoordinator: proposals,
            configuration: MCPSelfValidationAppConfiguration())
        let index = DiagnosticExperimentWindowIndex()
        let diagnostics = DiagnosticRunCoordinator(store: store, experimentIndex: index)
        await diagnostics.bootstrap()
        diagnostics.configureExperiments(repository: fixture.repository, bundles: fixture.coordinator)
        fixture.coordinator.diagnosticRuns = diagnostics
        controller.configureDiagnosticRunService(runCoordinator: diagnostics,
            recheckService: DiagnosticRunRegressionRecheckService(store: store), proposalCoordinator: proposals)
        controller.configureEffectBundleService(repository: fixture.repository,
            activationCoordinator: fixture.coordinator, proposalCoordinator: proposals, sessionStore: sessions)
        await controller.start()
        do {
            guard case .running(_, let endpoint) = controller.state else {
                XCTFail("Synthetic window server did not start")
                await controller.stop()
                return
            }
            let enrollment = try controller.enrollClient(displayName: "Window transport test", profileID: .shareable)
            _ = try controller.grantStore.addGrant(clientID: enrollment.client.id,
                capability: .diagnosticRunLifecycle, mode: .durablePolicy)
            let body = Data("{}".utf8), manifest = makeManifest(body: Data("{}".utf8))
            let source = fixture.root.appendingPathComponent("window-transport.jproxy-effects")
            try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
            _ = try fixture.repository.importPackage(at: source,
                owner: .mcpClient(id: enrollment.client.id, displayName: "Window transport test"))
            let run = try diagnostics.createDraft(owner: .mcpClient(id: enrollment.client.id, displayNameSnapshot: "Synthetic agent"),
                hypothesis: .init(summary: "Explicit windows", expectedObservation: "One delivered mutation", source: .mcpClient))
            let sessionStore = CLIFileSessionStore(persistenceURL: fixture.root.appendingPathComponent("window-cli-session.json"))
            let launcher = WindowTestAppLauncher()
            let application = CLIApplication(credentialStore: WindowTestCredentialStore(enrollment.plaintextCredential),
                sessionStore: sessionStore, appLauncher: launcher)
            var commandCount = 0
            func command(_ arguments: [String]) async -> CLIExitCode {
                commandCount += 1
                return await application.run(arguments: arguments + ["--endpoint", endpoint.absoluteString, "--quiet"])
            }
            let beginBaseline = await command(["run", "window", "begin", run.id.rawValue.uuidString,
                "--bundle-id", manifest.id.uuidString, "--mode", "baseline"])
            XCTAssertEqual(beginBaseline, .success)
            let baseline = try XCTUnwrap(diagnostics.experimentWindows(bundleID: manifest.id,
                requestingOwnerID: enrollment.client.id).first { $0.mode == .baseline })
            XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
            let endBaseline = await command(["run", "window", "end", baseline.id.uuidString])
            XCTAssertEqual(endBaseline, .success)
            // Synthetic owner activation is fixture setup, not evidence of a human approval.
            _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: enrollment.client.id)
            let beginModified = await command(["run", "window", "begin", run.id.rawValue.uuidString,
                "--bundle-id", manifest.id.uuidString, "--mode", "modified"])
            XCTAssertEqual(beginModified, .success)
            let modified = try XCTUnwrap(diagnostics.experimentWindows(bundleID: manifest.id,
                requestingOwnerID: enrollment.client.id).first { $0.mode == .modified })
            let tickets = index.admit(request(host: "api.example.invalid", path: "/catalog"))
            let sessionID = UUID()
            index.attach(tickets, sessionID: sessionID)
            index.complete(sessionID: sessionID, status: 200, duration: 0.02)
            let identity = try XCTUnwrap(fixture.gate.observationIdentity(resourceID: manifest.responseEffects[0].id))
            let receipt = fixture.gate.observe(identity: identity, kind: .authoredResponse, outcome: "applied")
            fixture.gate.completeReceipt(id: receipt, succeeded: true, sessionID: sessionID)
            let endModified = await command(["run", "window", "end", modified.id.uuidString])
            XCTAssertEqual(endModified, .success)
            let compare = await command(["effect", "bundle", "compare", "--baseline-window-id", baseline.id.uuidString,
                "--modified-window-id", modified.id.uuidString])
            XCTAssertEqual(compare, .success)
            XCTAssertEqual(commandCount, 5)
            XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id), "Observation/compare cannot stop effects")
            let arguments = ["baselineWindowID": baseline.id.uuidString, "modifiedWindowID": modified.id.uuidString]
            let client = MCPCLIClient(endpoint: endpoint, credential: enrollment.plaintextCredential,
                sessionStore: sessionStore, timeout: 10)
            let response = try await client.callTool(name: "effect_bundle_compare", arguments: arguments)
            for forbiddenKey in ["requestingOwnerID", "__mcpInternalSessionID"] {
                do {
                    _ = try await client.callTool(name: "diagnostic_run_window_begin", arguments: [
                        "runID": run.id.rawValue.uuidString, "bundleID": manifest.id.uuidString,
                        "mode": "modified", forbiddenKey: "forged"], retryOnStaleSession: false)
                    XCTFail("Caller authority metadata must be rejected")
                } catch let error as CLIError {
                    XCTAssertTrue(error.message.contains("Allowed arguments"))
                    XCTAssertEqual(error.exitCode, .invalidArguments)
                }
            }
            XCTAssertEqual(try diagnostics.experimentWindows(bundleID: manifest.id,
                requestingOwnerID: enrollment.client.id).count, 2)
            let direct = try diagnostics.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id,
                requestingOwnerID: enrollment.client.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let expected = try JSONSerialization.jsonObject(with: encoder.encode(direct)) as? [String: Any]
            XCTAssertEqual(response as NSDictionary, try XCTUnwrap(expected) as NSDictionary)
            XCTAssertEqual(direct.resources.first?.modified.delivered, 1)
            let bytes = try JSONSerialization.data(withJSONObject: response).count
            XCTAssertLessThan(bytes, 65_536)
            let other = try controller.enrollClient(displayName: "Other synthetic owner", profileID: .shareable)
            let otherClient = MCPCLIClient(endpoint: endpoint, credential: other.plaintextCredential,
                sessionStore: CLIFileSessionStore(persistenceURL: fixture.root.appendingPathComponent("other-session.json")), timeout: 10)
            do {
                _ = try await otherClient.callTool(name: "effect_bundle_compare", arguments: arguments)
                XCTFail("Other client must not read owned windows")
            } catch is CLIError { }
            XCTAssertEqual(launcher.launchCount, 0)
            XCTAssertEqual(controller.approvalStore.pendingCount, 0)
            _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: enrollment.client.id)
            XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
            let stopped = try await client.callTool(name: "effect_bundle_compare", arguments: arguments)
            XCTAssertEqual(stopped["cleanupState"] as? String,
                try diagnostics.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id,
                    requestingOwnerID: enrollment.client.id).cleanupState)
            print("R181 authenticated window workflow: \(commandCount) window/comparison CLI commands; comparison \(bytes) bytes; setup/cleanup excluded")
            await controller.stop()
        } catch {
            await controller.stop()
            throw error
        }
    }

    func testJoinedRetainedInspectionUsesMetadataAfterPackageDisappears() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let authoring = CollectionMockAuthoringService()
        let package = try await authoring.prepareCapturedPackage(ownerID: "reader", idempotencyKey: "joined",
            name: "Synthetic", source: Data(#"{"items":[]}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .number("2")]), templateIndex: nil,
                edits: [], identityPointers: ["/id"], countPointers: [], position: .prepend),
            scope: .init(host: "example.test", scheme: .https, port: 443, path: "/items", clients: .address("192.0.2.1")),
            images: [], appVersion: "test", createdAt: Date())
        let record = try await fixture.repository.importPreparedRevision(id: package.manifest.id,
            owner: .mcpClient(id: "reader", displayName: "Reader"), authoringService: authoring)
        let budget = CaptureAdmissionBudget(byteLimit: 1, countLimit: 1)
        XCTAssertNil(budget.reserve(bytes: 2))
        let service = EffectBundleInspectionService(repository: fixture.repository, coordinator: fixture.coordinator,
            admissionSnapshot: { budget.snapshot })
        // This fixture owns this exact package. Reads must continue without opening it again.
        let packageURL = fixture.root.appendingPathComponent("packages").appendingPathComponent(record.managedPackagePath)
        try FileManager.default.removeItem(at: packageURL)
        let sessions = InMemorySessionStore()
        let result = try await service.inspect(manifest: record.manifest, ownerID: "reader", retained: true,
            snapshot: { CapturedMockPreflightSnapshot.capture(from: sessions) })
        XCTAssertEqual(result.bundleID, record.id)
        XCTAssertEqual(result.deliveryState, "available")
        XCTAssertEqual(result.deliveryEvidence?.observationState, "noRetainedObservation")
        XCTAssertEqual(result.coverageQualification, "captureWideAdmissionGaps")
        XCTAssertEqual(result.admissionCoverage?.rejectedCaptures, 1)
        XCTAssertEqual(result.preflight?.resources.count, 1)
        XCTAssertEqual(result.assets.first?.sha256, record.manifest.assets.first?.sha256)
        XCTAssertFalse(result.lifecycleChangedDuringRead)
        XCTAssertThrowsError(try fixture.repository.inspect(id: record.id, requestingOwnerID: "reader"),
            "Activation/package validation remains distinct from metadata evidence")

        var snapshotCalls = 0
        do {
            _ = try await service.inspect(manifest: record.manifest, ownerID: "intruder", retained: true,
                snapshot: { snapshotCalls += 1; return nil })
            XCTFail("Wrong owner must fail before reading capture")
        } catch { XCTAssertEqual(error as? EffectBundleError, .notOwner) }
        XCTAssertEqual(snapshotCalls, 0)
        var altered = record.manifest
        altered.name = "Different revision"
        do {
            _ = try await service.inspect(manifest: altered, ownerID: "reader", retained: true,
                snapshot: { snapshotCalls += 1; return nil })
            XCTFail("Caller metadata cannot replace the retained revision")
        } catch EffectBundleJoinedInspection.InspectionError.revisionMismatch { }
        XCTAssertEqual(snapshotCalls, 0)
        let cancelled = Task { @MainActor in
            try await service.inspect(manifest: record.manifest, ownerID: "reader", retained: true,
                snapshot: { snapshotCalls += 1; return nil })
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled reads must not capture metadata")
        } catch is CancellationError { }
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testJoinedInspectionRechecksLifecycleAfterMatcherSuspension() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8)
        let manifest = makeManifest(body: body)
        let source = fixture.root.appendingPathComponent("race.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        let service = EffectBundleInspectionService(repository: fixture.repository, coordinator: fixture.coordinator)
        let sessions = InMemorySessionStore()
        let result = try await service.inspect(manifest: manifest, ownerID: EffectBundleOwner.localUser.ownerID,
            retained: true, snapshot: {
                _ = try? fixture.repository.markStopped(id: manifest.id, at: Date())
                return CapturedMockPreflightSnapshot.capture(from: sessions)
            })
        XCTAssertTrue(result.lifecycleChangedDuringRead)
        XCTAssertEqual(result.revisionID, manifest.id)
    }

    func testJoinedBudgetRetainsContinuationAndRejectsOversizedSingleReceipt() throws {
        let id = UUID()
        let receipts = (1...32).map { index in
            EffectBundleDeliveryReceipt(id: UUID(), marker: UInt64(index),
                resource: .init(bundleID: id, revisionID: id, activationID: UUID(), resourceID: UUID(),
                    assetID: String(repeating: "x", count: 4_000), expectedSHA256: "digest"),
                servedSHA256: "digest", matchesReviewedAsset: true, observedAt: Date())
        }
        let projection = EffectBundleJoinedInspection(bundleID: id, revisionID: id, observedAt: Date(),
            preflight: nil, preflightState: "unavailable", deliveryState: "available",
            coverageQualification: "admissionCoverageUnavailable", admissionCoverage: nil, assets: [], assetsTruncated: false,
            deliveryEvidence: .init(receipts: receipts, nextMarker: 99, retentionGap: true, hasMore: false, observationState: "observed"),
            resources: [], resourcesTruncated: false, lifecycleChangedDuringRead: false)
        let bounded = try projection.bounded()
        let page = try XCTUnwrap(bounded.deliveryEvidence)
        XCTAssertTrue(page.hasMore)
        XCTAssertTrue(page.retentionGap)
        XCTAssertEqual(page.nextMarker, page.receipts.last?.marker)
        XCTAssertEqual(page.receipts.map(\.id), Array(receipts.prefix(page.receipts.count)).map(\.id))
        XCTAssertLessThan(try JSONEncoder().encode(bounded).count, EffectBundleJoinedInspection.maximumBytes)
        var typedProjection = projection
        typedProjection.deliveryEvidence = .init(receipts: receipts, nextMarker: 99, retentionGap: false,
            hasMore: false, observationState: "observed",
            window: .init(timelineID: UUID(), afterMarker: 0, throughMarker: 99, start: .now(), end: .now(), startState: "available"),
            observations: receipts.map { receipt in
                .init(id: receipt.id, marker: receipt.marker,
                    identity: .init(bundleID: id, revisionID: id, activationID: receipt.resource.activationID,
                        resourceID: receipt.resource.resourceID), kind: .authoredResponse,
                    observedAt: receipt.observedAt, outcome: "responseResolved", authored: receipt)
            })
        let typed = try typedProjection.bounded()
        let typedPage = try XCTUnwrap(typed.deliveryEvidence)
        XCTAssertEqual(typedPage.nextMarker, typedPage.observations.last?.marker)
        XCTAssertEqual(typedPage.receipts.map(\.id), typedPage.observations.map(\.id))
        XCTAssertTrue(typedPage.hasMore)
        XCTAssertNil(typedPage.window, "A shortened page cannot claim the original larger time interval")
        XCTAssertEqual(typed.coverageQualification, "responseBudgetTruncatedWindowUnavailable")
        var oversized = projection
        oversized.deliveryEvidence = .init(receipts: [.init(id: UUID(), marker: 1,
            resource: .init(bundleID: id, revisionID: id, activationID: UUID(), resourceID: UUID(),
                assetID: String(repeating: "x", count: 70_000), expectedSHA256: "digest"),
            servedSHA256: nil, matchesReviewedAsset: nil, observedAt: Date())],
            nextMarker: 1, retentionGap: false, hasMore: false, observationState: "observed")
        XCTAssertThrowsError(try oversized.bounded())
    }

    func testMCPPreparationAndInspectionExposePreflightWithoutActivation() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let policy = MCPPolicyStore(persistenceURL: fixture.root.appendingPathComponent("policy.json"))
        let approvals = MCPApprovalStore()
        let recovery = MCPRecoveryCoordinator(journalStore: MCPEffectJournalStore(
            persistenceURL: fixture.root.appendingPathComponent("journal.json")))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: recovery, policyRevisionProvider: { policy.policyRevision })
        let sessions = InMemorySessionStore()
        let source = SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
            host: "example.test", port: 443, path: "/items", headers: [], bodyData: nil, bodySize: nil,
            clientAddress: "192.0.2.1"), response: CapturedResponse(statusCode: 200, headers: [],
                bodyData: Data(#"{"items":[]}"#.utf8), bodySize: 12), timing: SessionTiming(startedAt: Date()))
        sessions.append(source)
        let service = MCPEffectBundleService(repository: fixture.repository, activationCoordinator: fixture.coordinator,
            proposalCoordinator: proposals, approvalStore: approvals, policyStore: policy,
            grantStore: MCPClientGrantStore(persistenceURL: fixture.root.appendingPathComponent("grants.json")),
            auditStore: MCPAuditStore(persistenceURL: fixture.root.appendingPathComponent("audit.json")),
            authoringService: CollectionMockAuthoringService(), sessionStore: sessions)
        let client = MCPClientRecord(id: "synthetic-client", displayName: "Synthetic", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        let arguments: [String: Any] = ["sessionID": source.id.uuidString, "name": "Synthetic",
            "clientAddress": "192.0.2.1", "idempotencyKey": "request",
            "draftJSON": #"{"collectionPointer":"/items","item":{"id":"new"},"identityPointers":["/id"]}"#]
        let result = try await service.handleTool(name: "effect_bundle_prepare", arguments: arguments, client: client)
        let payload = try XCTUnwrap(result["payload"] as? [String: Any])
        let id = try XCTUnwrap(payload["revisionID"] as? String)
        XCTAssertEqual(payload["isServing"] as? Bool, false)
        let preflight = try XCTUnwrap(payload["preflight"] as? [String: Any])
        XCTAssertEqual(preflight["revisionID"] as? String, id)
        XCTAssertEqual(preflight["inspectedCount"] as? Int, 1)
        let retry = try await service.handleTool(name: "effect_bundle_prepare", arguments: arguments, client: client)
        XCTAssertEqual((retry["payload"] as? [String: Any])?["revisionID"] as? String, id)
        let inspected = try await service.handleTool(name: "effect_bundle_inspect", arguments: ["revisionID": id], client: client)
        XCTAssertNotNil((inspected["payload"] as? [String: Any])?["preflight"])
        let joined = try XCTUnwrap((inspected["payload"] as? [String: Any])?["joinedEvidence"] as? [String: Any])
        XCTAssertEqual(joined["deliveryState"] as? String, "notApplicable")
        XCTAssertEqual(joined["preflightState"] as? String, "available")
        XCTAssertEqual(joined["coverageQualification"] as? String, "admissionCoverageUnavailable")
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: joined).count, 65_536)
        XCTAssertEqual(approvals.pendingCount, 0)
        let rules = await fixture.responseStore.rules()
        XCTAssertTrue(rules.isEmpty)
        XCTAssertNil(fixture.repository.record(id: try XCTUnwrap(UUID(uuidString: id))))

        let batchBody = Data(#"{"items":[{"id":"template"}]}"#.utf8)
        let batchSource = SessionRecord(request: source.request,
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: batchBody, bodySize: batchBody.count),
            timing: SessionTiming(startedAt: Date()))
        sessions.append(batchSource)
        var batchArguments = arguments
        batchArguments["sessionID"] = batchSource.id.uuidString
        batchArguments["idempotencyKey"] = "batch"
        batchArguments["draftJSON"] = #"{"collectionPointer":"/items","templateIndex":0,"identityPointers":["/id"],"expansionItems":[{"edits":[{"pointer":"/id","value":"first"}]},{"edits":[{"pointer":"/id","value":"second"}]}]}"#
        let batchResult = try await service.handleTool(name: "effect_bundle_prepare", arguments: batchArguments, client: client)
        let batchPayload = try XCTUnwrap(batchResult["payload"] as? [String: Any])
        XCTAssertEqual(batchPayload["beforeCount"] as? Int, 1)
        XCTAssertEqual(batchPayload["afterCount"] as? Int, 3)
        XCTAssertEqual(batchPayload["isServing"] as? Bool, false)
        let batchID = try XCTUnwrap(batchPayload["revisionID"] as? String)
        let batchRetry = try await service.handleTool(name: "effect_bundle_prepare", arguments: batchArguments, client: client)
        XCTAssertEqual((batchRetry["payload"] as? [String: Any])?["revisionID"] as? String, batchID)
        let batchInspection = try await service.handleTool(name: "effect_bundle_inspect", arguments: ["revisionID": batchID], client: client)
        let batchChanges = try XCTUnwrap((batchInspection["payload"] as? [String: Any])?["reviewedChanges"] as? [String])
        XCTAssertTrue(batchChanges.contains("Insert reviewed item at /items/2"))
        _ = try await service.handleTool(name: "effect_bundle_import", arguments: ["revisionID": batchID], client: client)
        let retainedBatch = try XCTUnwrap(fixture.repository.record(id: XCTUnwrap(UUID(uuidString: batchID))))
        XCTAssertEqual(retainedBatch.manifest.authoring?.afterCount, 3)
        for alreadyRetired in [false, true] {
            let retired = try await service.handleTool(name: "effect_bundle_retire_preparation",
                arguments: ["revisionID": batchID], client: client)
            XCTAssertEqual((retired["payload"] as? [String: Any])?["alreadyRetired"] as? Bool, alreadyRetired)
        }
        for tool in ["effect_bundle_inspect", "effect_bundle_import"] {
            do {
                _ = try await service.handleTool(name: tool, arguments: ["revisionID": batchID], client: client)
                XCTFail("Retired preparation must not be read or imported again")
            } catch let error as MCPStructuredError { XCTAssertEqual(error.details?["reason"], "revisionRetired") }
        }
        do {
            _ = try await service.handleTool(name: "effect_bundle_prepare", arguments: batchArguments, client: client)
            XCTFail("A delayed identical request must not recreate retired content")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.details?["reason"], "revisionRetired") }
        let importedAfterRetirement = try await service.handleTool(name: "effect_bundle_inspect",
            arguments: ["bundleID": batchID], client: client)
        XCTAssertEqual((importedAfterRetirement["payload"] as? [String: Any])?["state"] as? String, "inactive")
        XCTAssertEqual(fixture.repository.record(id: retainedBatch.id), retainedBatch,
                       "Retirement must leave imported bytes and lifecycle unchanged")
        let stranger = MCPClientRecord(id: "other-client", displayName: "Other", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        do {
            _ = try await service.handleTool(name: "effect_bundle_retire_preparation",
                arguments: ["revisionID": batchID], client: stranger)
            XCTFail("Retired handle existence is owner-scoped")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.details?["reason"], "revisionNotFound") }
        XCTAssertEqual(approvals.pendingCount, 0)
        let batchRules = await fixture.responseStore.rules()
        XCTAssertTrue(batchRules.isEmpty)

        var invalid = arguments
        invalid["images"] = [["localFileBookmarkRef": "opaque", "imageReference": "synthetic-secret"]]
        do {
            _ = try await service.handleTool(name: "effect_bundle_prepare", arguments: invalid, client: client)
            XCTFail("Invalid delivery pair must fail before file access")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.details?["field"], "images[0]")
            XCTAssertEqual(error.details?["nextTool"], "effect_bundle_prepare")
            XCTAssertFalse(error.message.contains("synthetic-secret"))
        }
        invalid = arguments
        invalid["relatedResponsesJSON"] = "[{\"sessionID\":\"\(UUID().uuidString)\"}]"
        do {
            _ = try await service.handleTool(name: "effect_bundle_prepare", arguments: invalid, client: client)
            XCTFail("Missing related source must remain indexed")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.details?["field"], "relatedResponses[0].sessionID")
            XCTAssertEqual(error.details?["reason"], "sourceUnavailable")
        }
        let detail = SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
            host: "example.test", port: 443, path: "/items/old", headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200, headers: [],
                bodyData: Data(#"{"id":"old","title":"Template"}"#.utf8), bodySize: nil),
            timing: SessionTiming(startedAt: Date()))
        sessions.append(detail)
        var authored = arguments
        authored["idempotencyKey"] = "authored-path"
        authored["relatedResponsesJSON"] = """
        [{"sessionID":"\(detail.id)","targetPath":"/items/new","edits":[{"pointer":"/id","value":"new"}],"identityLinks":[{"pointer":"/id","primaryPointer":"/items/0/id"}]}]
        """
        let authoredResult = try await service.handleTool(name: "effect_bundle_prepare", arguments: authored, client: client)
        let authoredPayload = try XCTUnwrap(authoredResult["payload"] as? [String: Any])
        let resources = try XCTUnwrap(authoredPayload["relatedResponses"] as? [[String: Any]])
        XCTAssertEqual(resources.first?["targetEvidence"] as? String, "unobserved")
        XCTAssertNil(resources.first?["targetSessionID"])
        XCTAssertEqual(authoredPayload["isServing"] as? Bool, false)
        let authoredRetry = try await service.handleTool(name: "effect_bundle_prepare", arguments: authored, client: client)
        XCTAssertEqual((authoredRetry["payload"] as? [String: Any])?["revisionID"] as? String,
                       authoredPayload["revisionID"] as? String)
        authored["relatedResponsesJSON"] = (authored["relatedResponsesJSON"] as? String)?
            .replacingOccurrences(of: "/items/new", with: "/items/another")
        do {
            _ = try await service.handleTool(name: "effect_bundle_prepare", arguments: authored, client: client)
            XCTFail("A changed destination cannot reuse the reviewed idempotency key")
        } catch { }
        XCTAssertEqual(approvals.pendingCount, 0)
        let finalRules = await fixture.responseStore.rules()
        XCTAssertTrue(finalRules.isEmpty)
        _ = try await service.handleTool(name: "effect_bundle_import", arguments: ["revisionID": id], client: client)
        let retainedInspection = try await service.handleTool(name: "effect_bundle_inspect", arguments: ["bundleID": id], client: client)
        let retainedPayload = try XCTUnwrap(retainedInspection["payload"] as? [String: Any])
        let retainedJoined = try XCTUnwrap(retainedPayload["joinedEvidence"] as? [String: Any])
        XCTAssertEqual(retainedJoined["deliveryState"] as? String, "available")
        XCTAssertNotNil(retainedPayload["preflight"])
        XCTAssertNotNil(retainedPayload["deliveryEvidence"], "Legacy evidence field remains available")
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: retainedInspection).count, MCPResourceBudget.maxResponseBytes)
    }
    func testPreparedListDetailAndArtworkActivateAndStopAsOneOwnedBundle() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let authoring = CollectionMockAuthoringService()
        let imageRequest = request(host: SyntheticAssetOriginServer.defaultHost, path: "/fixtures/images/test_pattern.png")
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: imageRequest)?.bodyData)
        let detail = CapturedRelatedResponse(source: Data(#"{"id":1,"logo":"old","title":"Original"}"#.utf8),
            scope: .init(host: "api.example.invalid", scheme: .https, port: 443, path: "/details/2", clients: .address("192.0.2.1")),
            edits: [.init(pointer: "/id", value: .number("2")), .init(pointer: "/title", value: .string("JoesProxy"))],
            images: [.init(pointer: "/logo", assetID: "image-0")],
            identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
        let package = try await authoring.prepareCapturedPackage(ownerID: "local-test", idempotencyKey: "whole-bundle",
            name: "Synthetic detail", source: Data(#"{"items":[{"id":1}]}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .number("2")]), templateIndex: nil,
                edits: [], identityPointers: ["/id"], countPointers: [], position: .prepend),
            scope: .init(host: "api.example.invalid", scheme: .https, port: 443, path: "/catalog", clients: .address("192.0.2.1")),
            images: [.init(itemPointer: nil, bytes: png, originalURL: nil,
                deliveryURL: URL(string: "https://api.example.invalid/art/logo.png?format=webp"), imageReference: "files/logo.png")],
            appVersion: "test", createdAt: Date(), relatedResponses: [detail])
        let packageURL = fixture.root.appendingPathComponent("coordinated.jproxy-effects", isDirectory: true)
        var sources: [String: URL] = [:]
        for (id, bytes) in package.assetDataByID {
            let url = fixture.root.appendingPathComponent(id)
            try bytes.write(to: url)
            sources[id] = url
        }
        try EffectBundlePackageEngine().writePackage(manifest: package.manifest, assetSourcesByID: sources, to: packageURL)
        _ = try fixture.repository.importPackage(at: packageURL, owner: .localUser)
        XCTAssertEqual(fixture.repository.record(id: package.manifest.id)?.isServing, false)
        let metadata = try await EffectBundleInspectionService(repository: fixture.repository,
            coordinator: fixture.coordinator).inspect(manifest: package.manifest,
                ownerID: EffectBundleOwner.localUser.ownerID, retained: true, snapshot: { nil })
        XCTAssertEqual(metadata.dimensionsState, "reviewedMetadata")
        XCTAssertEqual(metadata.artwork.first?.reviewed.imageReference, "files/logo.png")
        XCTAssertEqual(metadata.artwork.first?.referenceState, "reviewedClientMappingRequired")
        XCTAssertGreaterThan(try XCTUnwrap(metadata.artwork.first?.aspectRatio), 0)
        XCTAssertEqual(metadata.artwork.first?.redirectEvidence, "historicalMetadataUnavailable")
        XCTAssertEqual(metadata.artwork.first?.reviewed.sha256, package.images.first?.sha256)
        let history = InMemorySessionStore()
        let redirect = SessionRecord(request: request(host: "api.example.invalid", path: "/art/logo.png?format=webp"),
            response: .init(statusCode: 302, headers: [.init(name: "Location", value: "https://private.invalid/secret")],
                bodyData: nil, bodySize: nil), timing: .init(startedAt: Date()))
        history.append(redirect)
        history.append(SessionRecord(request: .init(method: "GET", scheme: .https, host: "api.example.invalid", port: 443,
            path: "/art/logo.png?format=webp", headers: [], bodyData: nil, bodySize: nil, clientAddress: "192.0.2.2"),
            response: .init(statusCode: 200, headers: [], bodyData: nil, bodySize: nil), timing: .init(startedAt: Date())))
        let observed = try await EffectBundleInspectionService(repository: fixture.repository,
            coordinator: fixture.coordinator).inspect(manifest: package.manifest,
                ownerID: EffectBundleOwner.localUser.ownerID, retained: true, snapshot: { .capture(from: history) })
        let observedImage = try XCTUnwrap(observed.artwork.first)
        XCTAssertEqual(observedImage.historicalMatchedRequestCount, 1)
        XCTAssertEqual(observedImage.otherClientRequestCount, 1)
        XCTAssertEqual(observedImage.redirectSessionIDs, [redirect.id])
        XCTAssertEqual(observedImage.redirectEvidence, "redirectStatusObservedDestinationRequiresAuthorizedHeaders")
        XCTAssertTrue(observedImage.nextAction.contains("headerRead"))
        XCTAssertEqual(observedImage.deliveredReceiptCount, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(observed), as: UTF8.self).contains("private.invalid"))
        var legacy = package.manifest
        legacy.authoring?.artwork = nil
        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(legacy), "Older metadata remains supported")
        var invalidArtwork = package.manifest
        let image = try XCTUnwrap(package.images.first)
        invalidArtwork.authoring?.artwork = [.init(assetID: image.assetID, url: image.url,
            sha256: "incorrect", contentType: image.contentType, width: image.width, height: image.height,
            byteCount: image.byteCount, retainsOriginalURL: false)]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalidArtwork))
        _ = try await fixture.coordinator.activate(id: package.manifest.id, ttl: 60)
        let paths = ["response": "/catalog", "related-0": "/details/2", "image-0": "/art/logo.png?format=webp"]
        for (id, path) in paths {
            let decision = try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: path))
            if case .mapLocal(let resolved) = decision {
                XCTAssertEqual(resolved.statusCode, 200)
                XCTAssertEqual(resolved.bodyData, package.assetDataByID[id])
                XCTAssertEqual(resolved.authoredResource?.revisionID, package.manifest.id)
                XCTAssertEqual(resolved.authoredResource?.expectedSHA256,
                    package.manifest.assets.first { $0.id == id }?.sha256)
                let resource = try XCTUnwrap(resolved.authoredResource)
                let receipt = fixture.gate.observe(resource: resource, servedSHA256: resource.expectedSHA256)
                fixture.gate.completeReceipt(id: receipt, succeeded: true)
            } else { XCTFail("Expected authored resource \(id)") }
        }
        assertNoMatch(try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: "/details/1")))
        assertNoMatch(try await fixture.responseStore.ruleDecision(for: CapturedRequest(method: "GET", scheme: .https,
            host: "api.example.invalid", port: 443, path: "/details/2", headers: [], bodyData: nil,
            bodySize: nil, clientAddress: "192.0.2.2")))
        _ = try await fixture.coordinator.stop(id: package.manifest.id)
        let stoppedEvidence = try await EffectBundleInspectionService(repository: fixture.repository,
            coordinator: fixture.coordinator).inspect(manifest: package.manifest,
                ownerID: EffectBundleOwner.localUser.ownerID, retained: true, snapshot: { nil })
        XCTAssertEqual(stoppedEvidence.resources.filter { $0.deliveredReceiptCount == 1 }.count, 3)
        XCTAssertEqual(stoppedEvidence.artwork.first?.deliveredReceiptCount, 1)
        XCTAssertEqual(stoppedEvidence.artwork.first?.reviewedHashDeliveredCount, 1)
        XCTAssertEqual(stoppedEvidence.targetOutcome, "unknown")
        XCTAssertTrue(stoppedEvidence.deliveryEvidence?.receipts.allSatisfy {
            $0.resource.revisionID == package.manifest.id && $0.targetOutcome == "unknown"
        } == true)
        for path in paths.values {
            assertNoMatch(try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: path)))
        }
        XCTAssertEqual(fixture.repository.record(id: package.manifest.id)?.isServing, false)
    }
    func testGateCommitsResponseAndHLSVisibilityTogether() async throws {
        let gate = EffectBundleActivationGate()
        let responseStore = ResponseOverrideStore(effectBundleGate: gate)
        let hlsRouteStore = HLSSubstitutionRouteStore(effectBundleGate: gate)
        let bundleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let ruleID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let experimentID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        gate.register(
            bundleID: bundleID,
            responseRuleIDs: [ruleID],
            hlsExperimentIDs: [experimentID]
        )
        try await responseStore.addRule(ResponseOverrideRule(
            id: ruleID,
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.invalid",
            port: 443,
            path: "/catalog",
            sourceKind: .block,
            sourceDescription: "Bundle block",
            statusCode: 503,
            headers: [],
            bodySource: .inline(nil),
            effectBundleID: bundleID
        ))
        try await hlsRouteStore.install(HLSSubstitutionExperiment(
            id: experimentID,
            owner: .localUser,
            profileID: "bundle-profile",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.invalid"),
            scope: .selectedPlaylist(path: "/master.m3u8"),
            mountPath: "/.joesproxy/hls-substitution/\(experimentID.uuidString.lowercased())/",
            fixtureRunID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
            state: .active,
            startedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            stoppedAt: nil,
            metrics: HLSSubstitutionMetrics()
        ))
        let responseRequest = request(host: "api.example.invalid", path: "/catalog")
        let hlsRequest = request(host: "media.example.invalid", path: "/master.m3u8")

        assertNoMatch(try await responseStore.ruleDecision(for: responseRequest))
        let initialHlsDecision = await hlsRouteStore.decision(for: hlsRequest)
        XCTAssertNil(initialHlsDecision)

        gate.open(bundleID: bundleID)
        if case .block(let matchedRuleID, _, _, _) = try await responseStore.ruleDecision(for: responseRequest) {
            XCTAssertEqual(matchedRuleID, ruleID)
        } else {
            XCTFail("Expected the response rule after commit.")
        }
        let openHlsDecision = await hlsRouteStore.decision(for: hlsRequest)
        XCTAssertEqual(openHlsDecision?.experimentID, experimentID)

        gate.close(bundleID: bundleID)
        assertNoMatch(try await responseStore.ruleDecision(for: responseRequest))
        let closedHlsDecision = await hlsRouteStore.decision(for: hlsRequest)
        XCTAssertNil(closedHlsDecision)
    }

    func testActivateAndStopRoundTripServesExactInlineBytes() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{\"mode\":\"maintenance\"}".utf8)
        var manifest = makeManifest(body: body)
        manifest.authoring = .init(mode: .capturedFixture, revisionID: manifest.id,
            sourceDigest: manifest.assets[0].sha256, responseAssetID: "body", beforeCount: 0, afterCount: 1)
        manifest.responseEffects[0].sourceClientAddress = "192.0.2.1"
        let sourcePackage = fixture.root.appendingPathComponent("source.jproxy-effects", isDirectory: true)
        let sourceAsset = fixture.root.appendingPathComponent("body.json")
        try body.write(to: sourceAsset)
        try EffectBundlePackageEngine().writePackage(
            manifest: manifest,
            assetSourcesByID: [manifest.assets[0].id: sourceAsset],
            to: sourcePackage
        )
        _ = try fixture.repository.importPackage(at: sourcePackage, owner: .localUser)

        let receipt = try await fixture.coordinator.activate(id: manifest.id, ttl: 60)

        XCTAssertEqual(receipt.bundleID, manifest.id)
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .serving)
        assertNoMatch(try await fixture.responseStore.ruleDecision(
            for: request(host: "api.example.invalid", path: "/sibling")))
        assertNoMatch(try await fixture.responseStore.ruleDecision(for: CapturedRequest(method: "GET", scheme: .https,
            host: "api.example.invalid", port: 443, path: "/catalog", headers: [], bodyData: nil,
            bodySize: nil, clientAddress: "192.0.2.2")))
        let decision = try await fixture.responseStore.ruleDecision(
            for: request(host: "api.example.invalid", path: "/catalog")
        )
        var originalIdentity: EffectBundleResourceIdentity?
        if case .mapLocal(let resolved) = decision {
            XCTAssertEqual(resolved.statusCode, 503)
            XCTAssertEqual(resolved.bodyData, body)
            let identity = try XCTUnwrap(resolved.authoredResource)
            originalIdentity = identity
            XCTAssertEqual(identity.revisionID, manifest.id)
            XCTAssertEqual(identity.expectedSHA256, manifest.assets[0].sha256)
            XCTAssertEqual(ProxyConnectionHandler.applyingNoCachingPolicyIfNeeded(to: resolved,
                requestHost: "api.example.invalid", configuration: nil).authoredResource, identity)
        } else {
            XCTFail("Expected the activated inline response.")
        }

        _ = try await fixture.coordinator.stop(id: manifest.id)
        XCTAssertThrowsError(try fixture.coordinator.deliveryEvidence(id: manifest.id, requestingOwnerID: "other-client"))
        let failures = try fixture.coordinator.deliveryEvidence(id: manifest.id).receipts
        XCTAssertEqual(failures.map(\.evaluation), [.matcherMismatch, .clientScopeMismatch])
        XCTAssertTrue(failures.allSatisfy { $0.delivery == .notApplied && $0.servedSHA256 == nil })
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .stopped)
        assertNoMatch(try await fixture.responseStore.ruleDecision(
            for: request(host: "api.example.invalid", path: "/catalog")
        ))
        _ = try await fixture.coordinator.activate(id: manifest.id, ttl: 60)
        if case .mapLocal(let replacement) = try await fixture.responseStore.ruleDecision(
            for: request(host: "api.example.invalid", path: "/catalog")) {
            XCTAssertEqual(replacement.authoredResource?.revisionID, originalIdentity?.revisionID)
            XCTAssertNotEqual(replacement.authoredResource?.activationID, originalIdentity?.activationID)
        } else { XCTFail("Expected reactivated authored response") }
        _ = try await fixture.coordinator.stop(id: manifest.id, expired: true)
        assertNoMatch(try await fixture.responseStore.ruleDecision(
            for: request(host: "api.example.invalid", path: "/catalog")))
    }

    func testConflictRefusesActivationWithoutLeavingBundleComponents() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("conflict".utf8)
        let manifest = makeManifest(body: body)
        let sourcePackage = fixture.root.appendingPathComponent("source.jproxy-effects", isDirectory: true)
        let sourceAsset = fixture.root.appendingPathComponent("body.json")
        try body.write(to: sourceAsset)
        try EffectBundlePackageEngine().writePackage(
            manifest: manifest,
            assetSourcesByID: [manifest.assets[0].id: sourceAsset],
            to: sourcePackage
        )
        _ = try fixture.repository.importPackage(at: sourcePackage, owner: .localUser)
        try await fixture.responseStore.addRule(ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.invalid",
            port: 443,
            path: "/catalog",
            matchMode: .ignoreQuery,
            sourceKind: .block,
            sourceDescription: "Existing rule",
            statusCode: 500,
            headers: [],
            bodySource: .inline(nil)
        ))

        do {
            _ = try await fixture.coordinator.activate(id: manifest.id)
            XCTFail("Expected activation conflict.")
        } catch let error as EffectBundleError {
            XCTAssertEqual(error, .activationConflict)
        }
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .inactive)
        let bundleRules = await fixture.responseStore.rules().filter { $0.effectBundleID == manifest.id }
        XCTAssertEqual(bundleRules.count, 0)
    }

    func testStopWorksAfterManagedPackageIsMissingAndStillChecksOwnership() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("synthetic".utf8)
        let manifest = makeManifest(body: body)
        let source = fixture.root.appendingPathComponent("missing-after-activation.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        let record = try fixture.repository.importPackage(at: source,
            owner: .mcpClient(id: "owner", displayName: "Synthetic"))
        _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: "owner", ttl: 60)
        let managed = fixture.root.appendingPathComponent("packages").appendingPathComponent(record.managedPackagePath)
        try FileManager.default.removeItem(at: managed)
        do {
            _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: "other")
            XCTFail("Wrong owner must not close routing")
        } catch { }
        XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id))
        _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: "owner")
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .stopped)
        assertNoMatch(try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: "/catalog")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("runtime")
            .appendingPathComponent(manifest.id.uuidString.lowercased()).path))
    }

    func testActivationRejectsChangedRetainedManifestWithSameIdentity() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("synthetic".utf8)
        let manifest = makeManifest(body: body)
        let source = fixture.root.appendingPathComponent("immutable.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        let record = try fixture.repository.importPackage(at: source, owner: .localUser)
        let managed = fixture.root.appendingPathComponent("packages").appendingPathComponent(record.managedPackagePath)
        var changed = manifest
        changed.responseEffects[0].path = "/unreviewed"
        let encoder = JSONEncoder()
        try encoder.encode(changed).write(to: managed.appendingPathComponent("manifest.json"), options: .atomic)
        do {
            _ = try await fixture.coordinator.activate(id: manifest.id)
            XCTFail("Changed scope cannot reuse retained identity")
        } catch let error as EffectBundleError {
            XCTAssertEqual(error, .assetDigestMismatch("manifest-revision"))
        }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .inactive)
        _ = try await fixture.coordinator.stop(id: manifest.id)
        XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .stopped)
    }

    func testConcurrentActivationAndStopDrainBeforeNewActivation() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("synthetic".utf8)
        let manifest = makeManifest(body: body)
        let source = fixture.root.appendingPathComponent("races.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        for _ in 0..<10 {
            let first = Task { try await fixture.coordinator.activate(id: manifest.id, ttl: 60) }
            let duplicate = Task { try await fixture.coordinator.activate(id: manifest.id, ttl: 60) }
            let results = await [first.result, duplicate.result]
            XCTAssertEqual(results.filter { if case .success = $0 { return true }; return false }.count, 1)
            _ = try await fixture.coordinator.stop(id: manifest.id)
            let pending = Task { try await fixture.coordinator.activate(id: manifest.id, ttl: 60) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !fixture.coordinator.activatingBundleIDs.contains(manifest.id)
                    && fixture.repository.record(id: manifest.id)?.isServing != true
                    && ContinuousClock.now < deadline {
                await Task.yield()
            }
            XCTAssertTrue(fixture.coordinator.activatingBundleIDs.contains(manifest.id)
                || fixture.repository.record(id: manifest.id)?.isServing == true)
            _ = try await fixture.coordinator.stop(id: manifest.id)
            _ = await pending.result
            XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
            XCTAssertEqual(fixture.repository.record(id: manifest.id)?.state, .stopped)
            let remaining = await fixture.responseStore.rules().filter { $0.effectBundleID == manifest.id }
            XCTAssertTrue(remaining.isEmpty)
            assertNoMatch(try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: "/catalog")))
        }
    }

    func testSchemaFourCollectionMockBundleActivatesReviewedPlanWithoutCapturedBody() async throws {
        let fixture = try makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("synthetic".utf8)
        var manifest = makeManifest(body: body)
        var effect = try XCTUnwrap(manifest.responseEffects.first)
        let plan = try CollectionMockCompiler.prepare(
            source: Data(#"{"items":[{"id":"original"}],"total":1}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .string("bundle-item")]),
                templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"],
                position: .append)
        )
        effect.sourceKind = .collectionMock
        effect.statusCode = 200
        effect.headers = []
        effect.bodySource = .none
        effect.forceNoCache = false
        effect.collectionMockPlan = plan
        manifest.responseEffects = [effect]

        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(manifest))
        let source = fixture.root.appendingPathComponent("collection-mock.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        _ = try fixture.repository.importPackage(at: source, owner: .localUser)
        _ = try await fixture.coordinator.activate(id: manifest.id, ttl: 60)

        let decision = try await fixture.responseStore.ruleDecision(for: request(host: "api.example.invalid", path: "/catalog"))
        guard case .liveCollectionMock(let ruleID, let decidedPlan, _, _) = decision else {
            XCTFail("Expected activated bundle to expose a live collection mock")
            return
        }
        XCTAssertEqual(ruleID, effect.id)
        XCTAssertEqual(decidedPlan, plan)
        let installedRules = await fixture.responseStore.rules()
        let installed = try XCTUnwrap(installedRules.first)
        let unconfiguredStore = ResponseOverrideStore()
        do {
            _ = try await unconfiguredStore.addRule(installed)
            XCTFail("A bundle must not silently fall back to an unowned executor")
        } catch ResponseOverrideError.liveCollectionExecutorUnavailable { }
        _ = try await fixture.coordinator.stop(id: manifest.id)
        // Exhaust only this synthetic executor, then verify failed activation cannot leave a
        // serving bundle whose transformations were silently omitted.
        for _ in 0..<EffectBundleBudget.maxResponseEffectCount {
            XCTAssertNotNil(fixture.executor.begin(effectID: UUID(), plan: plan))
        }
        do {
            _ = try await fixture.coordinator.activate(id: manifest.id)
            XCTFail("Capacity failure must roll back activation")
        } catch ResponseOverrideError.liveCollectionCapacityExceeded { }
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        let remaining = await fixture.responseStore.rules()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCollectionMockBundleRejectsLegacySchemaAndMissingPlan() throws {
        let body = Data("synthetic".utf8)
        var manifest = makeManifest(body: body)
        var effect = try XCTUnwrap(manifest.responseEffects.first)
        effect.sourceKind = .collectionMock
        effect.bodySource = .none
        manifest.responseEffects = [effect]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))

        effect.collectionMockPlan = try CollectionMockCompiler.prepare(
            source: Data(#"{"items":[],"total":0}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .string("bundle-item")]),
                templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"],
                position: .append)
        )
        manifest.schemaVersion = 3
        manifest.responseEffects = [effect]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
    }

    func testSchemaFivePhasesRequireBoundedCompleteReviewedCoverage() throws {
        let body = Data("synthetic".utf8)
        var manifest = makeManifest(body: body)
        let effectID = try XCTUnwrap(manifest.responseEffects.first?.id)
        let phase = EffectBundlePhase(
            id: UUID(), label: "Initial", durationSeconds: 60,
            responseEffectIDs: [effectID], hlsSubstitutionIDs: [],
            timestampBindings: [EffectBundleTimestampBinding(
                id: UUID(), responseEffectID: effectID, jsonPointer: "/scheduledAt", offsetSeconds: 30
            )]
        )
        manifest.phases = [phase]
        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(manifest))

        manifest.schemaVersion = 4
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))

        manifest.schemaVersion = EffectBundleSchema.currentVersion
        manifest.phases = [EffectBundlePhase(
            id: phase.id, label: phase.label, durationSeconds: phase.durationSeconds,
            responseEffectIDs: [], hlsSubstitutionIDs: [], timestampBindings: []
        )]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
    }

    func testSharedReadinessRejectsUnsupportedPhaseKindsAndLiveTimestampBindings() {
        var manifest = makeManifest(body: Data("{}".utf8))
        let id = manifest.responseEffects[0].id
        manifest.phases = [.init(id: UUID(), label: "Review", durationSeconds: 30,
            responseEffectIDs: [id], hlsSubstitutionIDs: [], timestampBindings: [])]
        XCTAssertEqual(EffectBundlePresentation.phaseBlockers(manifest), [])
        manifest.responseEffects[0].sourceKind = .liveResponseRewrite
        XCTAssertEqual(EffectBundlePresentation.phaseBlockers(manifest), [.phasedSourceKindUnavailable])
        manifest.responseEffects[0].sourceKind = .collectionMock
        XCTAssertEqual(EffectBundlePresentation.phaseBlockers(manifest), [])
        manifest.phases?[0].timestampBindings = [.init(id: UUID(), responseEffectID: id, jsonPointer: "/time", offsetSeconds: 0)]
        XCTAssertEqual(EffectBundlePresentation.phaseBlockers(manifest), [.timestampRequiresStaticJSON])
    }

    private struct CoordinatorFixture {
        var root: URL
        var repository: EffectBundleRepository
        var responseStore: ResponseOverrideStore
        var coordinator: EffectBundleActivationCoordinator
        var gate: EffectBundleActivationGate
        var executor: LiveCollectionTransformationExecutor
        var hlsRuns: HLSFixtureRunStore
        var hlsRoutes: HLSSubstitutionRouteStore
    }

    private func makeCoordinatorFixture(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                        schedulesTimers: Bool = true, clock: @escaping () -> Date = Date.init,
                                        gate: EffectBundleActivationGate = EffectBundleActivationGate()) throws -> CoordinatorFixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
            .appendingPathComponent("effect-bundle-activation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = LiveCollectionTransformationExecutor()
        let responseStore = ResponseOverrideStore(effectBundleGate: gate, liveCollectionTransformationExecutor: executor)
        let hlsRouteStore = HLSSubstitutionRouteStore(effectBundleGate: gate)
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: root.appendingPathComponent("hls-runs.json"),
            profileRootURL: fixtureRoot,
            originRegistry: HLSFixtureOriginRegistry(), clock: clock
        )
        runStore.load()
        let hlsCoordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: hlsRouteStore,
            responseOverrideStore: responseStore,
            persistenceURL: root.appendingPathComponent("hls-substitutions.json"), clock: clock
        )
        let repository = EffectBundleRepository(
            persistenceURL: root.appendingPathComponent("bundles.json"),
            packagesRootURL: root.appendingPathComponent("packages", isDirectory: true)
        )
        let coordinator = EffectBundleActivationCoordinator(
            repository: repository,
            responseOverrideStore: responseStore,
            hlsCoordinator: hlsCoordinator,
            activationGate: gate,
            runtimeRootURL: root.appendingPathComponent("runtime", isDirectory: true),
            clock: clock, uptime: uptime, schedulesTimers: schedulesTimers
        )
        return CoordinatorFixture(
            root: root,
            repository: repository,
            responseStore: responseStore,
            coordinator: coordinator,
            gate: gate, executor: executor, hlsRuns: runStore, hlsRoutes: hlsRouteStore
        )
    }

    func testExplicitWindowFreezesQueryClientAndAdmissionMembership() throws {
        let index = DiagnosticExperimentWindowIndex()
        var manifest = makeManifest(body: Data("{}".utf8))
        manifest.responseEffects[0].sourceClientAddress = "192.0.2.1"
        manifest.responseEffects[0].matchQueryKey = "variant"
        manifest.responseEffects[0].matchQueryValue = "reviewed"
        let activation = UUID(), start = Date()
        let window = DiagnosticExperimentWindow(id: UUID(), runID: DiagnosticRunID(), ownerID: "test",
            bundleID: manifest.id, revisionID: manifest.id, scopeDigest: "scope", mode: .modified,
            activationID: activation, beganAt: start, resources: [.init(id: manifest.responseEffects[0].id)])
        try index.begin(window, manifest: manifest)
        XCTAssertTrue(index.admit(request(host: "api.example.invalid", path: "/catalog?variant=other")).isEmpty)
        let tickets = index.admit(request(host: "api.example.invalid", path: "/catalog?variant=reviewed"))
        XCTAssertEqual(tickets.count, 1)
        let sessionID = UUID()
        index.attach(tickets, sessionID: sessionID)
        index.complete(sessionID: sessionID, status: 200, duration: 0.025)
        let identity = EffectBundleObservation.Identity(bundleID: manifest.id, revisionID: manifest.id,
            activationID: activation, resourceID: manifest.responseEffects[0].id)
        let included = EffectBundleObservation(id: UUID(), marker: 1, identity: identity, kind: .liveCollection,
            observedAt: start, sessionID: sessionID, outcome: "alreadyPresent", delivery: .downstreamWriteSucceeded)
        let unrelated = EffectBundleObservation(id: UUID(), marker: 2, identity: identity, kind: .liveCollection,
            observedAt: start, sessionID: UUID(), outcome: "applied", delivery: .downstreamWriteSucceeded)
        let closed = try index.end(id: window.id, observations: [included, unrelated], at: start.addingTimeInterval(1))
        XCTAssertEqual(closed.resources[0].observed, 1)
        XCTAssertEqual(closed.resources[0].delivered, 1)
        XCTAssertEqual(closed.resources[0].outcomes, ["alreadyPresent": 1])
        XCTAssertEqual(closed.resources[0].latencySamples, 1)
        XCTAssertTrue(index.admit(request(host: "api.example.invalid", path: "/catalog?variant=reviewed")).isEmpty)
        XCTAssertEqual(try index.end(id: window.id, observations: [], at: start.addingTimeInterval(2)), closed)
    }

    func testExplicitComparisonUsesClosedOwnedWindowsAndPreservesRestartEvidence() async throws {
        let fixture = try makeCoordinatorFixture(schedulesTimers: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let body = Data("{}".utf8), manifest = makeManifest(body: Data("{}".utf8))
        let source = fixture.root.appendingPathComponent("comparison.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetDataByID: ["body": body], to: source)
        let owner = "window-agent"
        _ = try fixture.repository.importPackage(at: source, owner: .mcpClient(id: owner, displayName: "Synthetic agent"))
        let store = DiagnosticRunStore(persistenceURL: fixture.root.appendingPathComponent("diagnostics.json"))
        let index = DiagnosticExperimentWindowIndex()
        let diagnostics = DiagnosticRunCoordinator(store: store, experimentIndex: index)
        await diagnostics.bootstrap()
        diagnostics.configureExperiments(repository: fixture.repository, bundles: fixture.coordinator)
        let run = try diagnostics.createDraft(owner: .mcpClient(id: owner, displayNameSnapshot: "Synthetic agent"),
            hypothesis: .init(summary: "Compare synthetic responses", expectedObservation: "One reviewed response is delivered", source: .mcpClient))
        XCTAssertThrowsError(try diagnostics.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .baseline, requestingOwnerID: "other"))
        let baseline = try diagnostics.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .baseline, requestingOwnerID: owner)
        XCTAssertFalse(fixture.gate.allows(bundleID: manifest.id))
        _ = try diagnostics.endExperimentWindow(id: baseline.id, requestingOwnerID: owner)
        _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: owner)
        XCTAssertThrowsError(try diagnostics.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .baseline, requestingOwnerID: owner))
        let modified = try diagnostics.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .modified, requestingOwnerID: owner)
        XCTAssertThrowsError(try diagnostics.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id, requestingOwnerID: owner))
        let tickets = index.admit(request(host: "api.example.invalid", path: "/catalog"))
        let session = UUID()
        index.attach(tickets, sessionID: session)
        index.complete(sessionID: session, status: 503, duration: 0.01)
        let identity = try XCTUnwrap(fixture.gate.observationIdentity(resourceID: manifest.responseEffects[0].id))
        let track = HLSWebVTTFixture.TrackIdentity(id: "es", language: "es", role: "subtitles", sourceRevision: "test-v1")
        let receipt = fixture.gate.observe(identity: identity, kind: .hlsSegment, outcome: "http_503", textTrack: track)
        fixture.gate.completeReceipt(id: receipt, succeeded: true, sessionID: session)
        _ = try diagnostics.endExperimentWindow(id: modified.id, requestingOwnerID: owner,
            targetOutcome: "rejected", outcomeSource: "Synthetic target assertion")
        XCTAssertTrue(fixture.gate.allows(bundleID: manifest.id), "Ending observation must not stop routing")
        let report = try diagnostics.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id, requestingOwnerID: owner)
        XCTAssertEqual(report.resources[0].observedCountDelta, 1)
        XCTAssertEqual(report.resources[0].modified.delivered, 1)
        XCTAssertEqual(report.resources[0].modified.textTracks?.first?.identity, track)
        XCTAssertEqual(report.resources[0].modified.textTracks?.first?.delivered, 1)
        XCTAssertTrue(report.modified.qualifications.contains("textDeliveryNotPlayerSelectionOrRendering"))
        XCTAssertEqual(report.modified.targetOutcome, "rejected")
        XCTAssertEqual(report.modified.targetOutcomeSource, "Synthetic target assertion")
        XCTAssertThrowsError(try diagnostics.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id, requestingOwnerID: "other"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertLessThan(try encoder.encode(report).count, 65_536)
        fixture.coordinator.diagnosticRuns = diagnostics
        let policy = MCPPolicyStore(persistenceURL: fixture.root.appendingPathComponent("compare-policy.json"))
        let proposals = MCPProposalCoordinator(recoveryCoordinator: MCPRecoveryCoordinator(journalStore:
            MCPEffectJournalStore(persistenceURL: fixture.root.appendingPathComponent("compare-journal.json"))),
            policyRevisionProvider: { policy.policyRevision })
        let service = MCPEffectBundleService(repository: fixture.repository, activationCoordinator: fixture.coordinator,
            proposalCoordinator: proposals, approvalStore: MCPApprovalStore(), policyStore: policy,
            grantStore: MCPClientGrantStore(persistenceURL: fixture.root.appendingPathComponent("compare-grants.json")),
            auditStore: MCPAuditStore(persistenceURL: fixture.root.appendingPathComponent("compare-audit.json")))
        let client = MCPClientRecord(id: owner, displayName: "Synthetic agent", assignedProfileID: .shareable,
            credentialState: .active, credentialGeneration: 1, createdAt: Date(), lastSeenAt: nil)
        let arguments: [String: Any] = ["baselineWindowID": baseline.id.uuidString, "modifiedWindowID": modified.id.uuidString]
        let briefGrants = MCPClientGrantStore(persistenceURL: fixture.root.appendingPathComponent("brief-grants.json"))
        _ = try briefGrants.addGrant(clientID: owner, capability: .diagnosticRunInspect, mode: .untilSessionEnd)
        _ = try briefGrants.addGrant(clientID: owner, capability: .overrideInspect, mode: .untilSessionEnd)
        let briefService = MCPDiagnosticRunService(runCoordinator: diagnostics,
            recheckService: DiagnosticRunRegressionRecheckService(store: store), proposalCoordinator: proposals,
            approvalStore: MCPApprovalStore(), policyStore: policy, grantStore: briefGrants,
            auditStore: MCPAuditStore(persistenceURL: fixture.root.appendingPathComponent("brief-audit.json")))
        var briefArguments = arguments
        briefArguments["runID"] = run.id.rawValue.uuidString
        let briefResponse = try await briefService.handleTool(name: "diagnostic_run_brief", arguments: briefArguments, client: client)
        let briefPayload = try XCTUnwrap(briefResponse["payload"] as? [String: Any])
        XCTAssertEqual(briefPayload["targetOutcome"] as? String, "rejected")
        XCTAssertNil(briefPayload["runCleanupProof"])
        XCTAssertEqual(briefPayload["bundleLifecycleState"] as? String, "serving")
        briefArguments["ifBriefDigest"] = try XCTUnwrap(briefPayload["briefDigest"] as? String)
        let repeatResponse = try await briefService.handleTool(name: "diagnostic_run_brief", arguments: briefArguments, client: client)
        let repeatPayload = try XCTUnwrap(repeatResponse["payload"] as? [String: Any])
        XCTAssertEqual(repeatPayload["unchanged"] as? Bool, true)
        XCTAssertEqual(repeatPayload["analysisReused"] as? Bool, false)
        var wrongRunArguments = briefArguments
        wrongRunArguments["runID"] = UUID().uuidString
        do {
            _ = try await briefService.handleTool(name: "diagnostic_run_brief", arguments: wrongRunArguments, client: client)
            XCTFail("An unrelated run must not qualify a digest")
        } catch { XCTAssertTrue(error is MCPStructuredError) }
        let response = try await service.handleTool(name: "effect_bundle_compare", arguments: arguments, client: client)
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(payload["cleanupState"] as? String, report.cleanupState)
        XCTAssertEqual((payload["modified"] as? [String: Any])?["targetOutcome"] as? String, "rejected")
        let reportResources = try XCTUnwrap(payload["resources"] as? [[String: Any]])
        let modifiedResource = try XCTUnwrap(reportResources.first?["modified"] as? [String: Any])
        XCTAssertEqual((modifiedResource["textTracks"] as? [[String: Any]])?.first?["delivered"] as? Int, 1)
        let responseBytes = try JSONSerialization.data(withJSONObject: response).count
        XCTAssertLessThan(responseBytes, 65_536)
        let statusResponse = try await briefService.handleTool(name: "diagnostic_run_status",
            arguments: ["runID": run.id.rawValue.uuidString], client: client)
        let baselineBytes = responseBytes + (try JSONSerialization.data(withJSONObject: statusResponse).count)
        let briefBytes = try JSONSerialization.data(withJSONObject: briefResponse).count
        let repeatBytes = try JSONSerialization.data(withJSONObject: repeatResponse).count
        XCTAssertLessThan(briefBytes, baselineBytes)
        XCTAssertLessThan(briefBytes, 6000)
        XCTAssertLessThan(repeatBytes, 1000)
        let metrics: [String: Any] = ["baselineVersion": 1, "fixture": "closed-run-delivery-v1",
            "measurementLayer": "serviceEnvelope", "baselineResultBytes": baselineBytes,
            "fullBriefResultBytes": briefBytes, "repeatResultBytes": repeatBytes,
            "baselineCalls": 2, "briefCalls": 1, "analysisReused": false, "providerTokens": NSNull()]
        print("EFFICIENCY_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        print("R181 synthetic comparison response bytes: \(responseBytes)")
        var forged = arguments
        forged["requestingOwnerID"] = "joesproxy-local-user"
        do {
            _ = try await service.handleTool(name: "effect_bundle_compare", arguments: forged, client: client)
            XCTFail("Forged authority must be rejected")
        } catch { XCTAssertTrue(error is MCPStructuredError) }
        let interrupted = try diagnostics.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .modified, requestingOwnerID: owner)
        let reopened = DiagnosticRunCoordinator(store: DiagnosticRunStore(persistenceURL: fixture.root.appendingPathComponent("diagnostics.json")), experimentIndex: DiagnosticExperimentWindowIndex())
        await reopened.bootstrap()
        reopened.configureExperiments(repository: fixture.repository, bundles: fixture.coordinator)
        let restored = try reopened.experimentWindows(bundleID: manifest.id, requestingOwnerID: owner)
        XCTAssertTrue(try XCTUnwrap(restored.first { $0.id == interrupted.id }).qualifications.contains("restartInterruptedWindow"))
        XCTAssertEqual(try reopened.compareExperimentWindows(baselineID: baseline.id, modifiedID: modified.id, requestingOwnerID: owner).modified.targetOutcome, "rejected")
        _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: owner)
        let stoppedResponse = try await briefService.handleTool(name: "diagnostic_run_brief", arguments: briefArguments, client: client)
        let stoppedPayload = try XCTUnwrap(stoppedResponse["payload"] as? [String: Any])
        XCTAssertEqual(stoppedPayload["unchanged"] as? Bool, false)
        XCTAssertEqual(stoppedPayload["bundleLifecycleState"] as? String, "stopped")
        try fixture.repository.discard(id: manifest.id, requestingOwnerID: owner)
        _ = try fixture.repository.importPackage(at: source, owner: .mcpClient(id: owner, displayName: "Synthetic agent"))
        _ = try await fixture.coordinator.activate(id: manifest.id, requestingOwnerID: owner)
        let replacement = try reopened.beginExperimentWindow(runID: run.id, bundleID: manifest.id, mode: .modified, requestingOwnerID: owner)
        _ = try reopened.endExperimentWindow(id: replacement.id, requestingOwnerID: owner)
        XCTAssertThrowsError(try reopened.compareExperimentWindows(baselineID: baseline.id, modifiedID: replacement.id, requestingOwnerID: owner),
            "Reusing a package UUID must not reinterpret an earlier import's baseline")
        _ = try await fixture.coordinator.stop(id: manifest.id, requestingOwnerID: owner)
    }

    func testExplicitWindowBoundsStalledRequestsAndDeduplicatesCaptureReset() throws {
        let index = DiagnosticExperimentWindowIndex(), manifest = makeManifest(body: Data("{}".utf8))
        let window = DiagnosticExperimentWindow(id: UUID(), runID: DiagnosticRunID(), ownerID: "test",
            bundleID: manifest.id, revisionID: manifest.id, scopeDigest: "scope", mode: .baseline,
            activationID: nil, beganAt: Date(), resources: [.init(id: manifest.responseEffects[0].id)])
        try index.begin(window, manifest: manifest)
        var count = 0
        for _ in 0..<300 { count += index.admit(request(host: "api.example.invalid", path: "/catalog")).count }
        XCTAssertEqual(count, 256)
        for _ in 0..<300 { index.noteCaptureReset() }
        let closed = try index.end(id: window.id, observations: [], at: Date())
        XCTAssertEqual(closed.resources[0].observed, 300)
        XCTAssertEqual(closed.qualifications.filter { $0 == "captureEpochChanged" }.count, 1)
        XCTAssertTrue(closed.qualifications.contains("pendingObservationLimit"))
        XCTAssertTrue(closed.qualifications.contains("pendingOrUnavailableAtClose"))
        index.remove(id: window.id)
        for _ in 0..<12 {
            try index.begin(window, manifest: manifest)
            var admitted = 0
            for _ in 0..<300 { admitted += index.admit(request(host: "api.example.invalid", path: "/catalog")).count }
            XCTAssertEqual(admitted, 256, "Each drain cycle must release all prior admission tickets")
            _ = try index.end(id: window.id, observations: [], at: Date())
            index.remove(id: window.id)
        }
    }

    func testMediaAdmissionCopiesPhaseBeforeAdvanceAndStop() throws {
        let gate = EffectBundleActivationGate()
        let manifest = makeManifest(body: Data("{}".utf8))
        let resourceID = try XCTUnwrap(manifest.responseEffects.first?.id)
        gate.register(bundleID: manifest.id, responseRuleIDs: [], hlsExperimentIDs: [resourceID])
        gate.registerResources(manifest: manifest)
        XCTAssertFalse(gate.hlsAdmission(experimentID: resourceID).allowed)
        gate.open(bundleID: manifest.id)
        let firstPhase = UUID(), nextPhase = UUID()
        gate.setMediaPhase(bundleID: manifest.id, phaseID: firstPhase)
        let admitted = gate.hlsAdmission(experimentID: resourceID)
        gate.setMediaPhase(bundleID: manifest.id, phaseID: nextPhase)
        XCTAssertTrue(admitted.allowed)
        XCTAssertEqual(admitted.observation?.phaseID, firstPhase)
        XCTAssertEqual(gate.hlsAdmission(experimentID: resourceID).observation?.phaseID, nextPhase)
        gate.close(bundleID: manifest.id)
        XCTAssertFalse(gate.hlsAdmission(experimentID: resourceID).allowed)
        XCTAssertEqual(admitted.observation?.phaseID, firstPhase)
        XCTAssertTrue(gate.hlsAdmission(experimentID: UUID()).allowed, "Standalone media remains supported")
    }

    private func makeManifest(body: Data) -> EffectBundleManifest {
        let asset = EffectBundleAsset(
            id: "body",
            role: .responseBody,
            logicalPath: "responses/body.json",
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            byteCount: body.count,
            contentType: "application/json"
        )
        return EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            name: "Maintenance response",
            notes: "Activation test.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "test",
            privacy: .exactContent,
            defaultTTLSeconds: 60,
            assets: [asset],
            responseEffects: [EffectBundleResponseEffect(
                id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                label: "Maintenance",
                requestMethod: "GET",
                requestScheme: .https,
                host: "api.example.invalid",
                port: 443,
                path: "/catalog",
                matchMode: .ignoreQuery,
                sourceKind: .inlineText,
                statusCode: 503,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodySource: EffectBundleBodySource(kind: .inline, assetIDs: [asset.id], rootLogicalPath: nil),
                mapRemoteHost: nil,
                mapRemotePort: nil,
                mapRemoteScheme: nil,
                mapRemotePath: nil,
                mapRemoteQueryPolicy: .preserve,
                mapRemoteQuery: nil,
                bookmarkRewriteRequest: nil,
                liveResponseRewrites: [],
                expectedSchemaFingerprint: nil,
                dropConnection: false,
                forceNoCache: true,
                notFoundRelativePath: nil,
                missingFilePolicy: .strictLocal,
                graphQLOperationName: nil,
                matchQueryKey: nil,
                matchQueryValue: nil,
                matchHeaderName: nil,
                matchHeaderValue: nil,
                sourceClientAddress: nil
            )],
            hlsSubstitutions: []
        )
    }

    private func request(host: String, path: String) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: host,
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil,
            clientAddress: "192.0.2.1"
        )
    }

    private func assertNoMatch(
        _ decision: ProxyRuleDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .noMatch = decision { return }
        XCTFail("Expected no match.", file: file, line: line)
    }
}
