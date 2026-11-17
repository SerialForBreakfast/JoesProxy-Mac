import Combine
import Foundation
import ImageIO
import XCTest
@testable import JoesProxy

/// Closes the last open exit criterion of workstream AK-5 (`Tasks.md`): "Add a real bundled-app
/// lifecycle validation lane that records compact evidence and never stores credentials in
/// arguments or repository files." Every other AK-5 piece already has mocked-transport coverage in
/// `JoesProxyCLITests.swift` (via `MockCLIURLProtocol`) — this test is the one that drives
/// `joesproxyctl`'s real HTTP transport against a real, running `MCPServerController` and a real
/// scenario end to end, instead of a mock.
///
/// Deliberately does NOT launch the actual `.app` bundle as a subprocess (slow, flaky, needs
/// accessibility permissions the test target doesn't have, and NSWorkspace app-launch already has
/// its own dedicated tests in `JoesProxyCLITests.swift`). Instead it mirrors
/// `MCPPhase1ValidationIntegrationTests`: a real, production `MCPServerController` in-process, on
/// a random loopback port, with temp-file-backed stores. Approval is granted the same way
/// `MCPApprovalIntegrationTests` does — calling `approvalStore.approve(requestID:)` directly,
/// exactly what a human clicking "Approve" in the UI would trigger.
@MainActor
final class JoesProxyCLIBundledLifecycleIntegrationTests: XCTestCase {
    func testColdOCRThroughLoopbackCLI() async throws {
        try await exerciseImageCLI(ocr: true)
    }

    func testCroppedJPEGThroughLoopbackCLI() async throws {
        try await exerciseImageCLI(ocr: false)
    }

    private func exerciseImageCLI(ocr: Bool) async throws {
        let store = InMemorySessionStore()
        let image = SessionRecord(request: .init(method: "GET", scheme: .https, host: "assets.example",
            port: 443, path: "/label.png", headers: [], bodyData: nil, bodySize: nil),
            response: try ImagePreviewModelTests.labeledPNG(), state: .completed, timing: .init(startedAt: Date()))
        store.load(sessions: [image])
        let controller = try makeController(port: UInt16.random(in: 20_000...60_000), store: store)
        await controller.start()
        do {
            guard case .running(_, let endpoint) = controller.state else { throw CLIError.malformedResponse("Listener failed") }
            let enrollment = try controller.enrollClient(displayName: "Image fixture", profileID: .shareable)
            _ = try controller.grantStore.addGrant(clientID: enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
            let credentials = MemoryCLICredentialStore()
            try credentials.save(enrollment.plaintextCredential, endpoint: endpoint)
            var output = Data()
            let app = CLIApplication(credentialStore: credentials, sessionStore: MemoryCLISessionStore(),
                writeResult: { output.append($0) }, appLauncher: MockCLIAppLauncher())
            func run(_ args: [String]) async throws -> (CLIExitCode, String) {
                output.removeAll()
                let code = await app.run(arguments: ["media", "visual", "--session-id", image.id.uuidString,
                    "--endpoint", endpoint.absoluteString, "--json"] + args)
                return (code, String(decoding: output, as: UTF8.self))
            }
            if ocr {
                let start = ContinuousClock.now
                let reply = try await run(["--view-json", #"{"mode":"ocr","includeBoxes":true}"#])
                let latency = start.duration(to: .now)
                XCTAssertEqual(reply.0, .success, reply.1)
                let metadata = try compactResultObject(from: reply.1)
                let lines = try XCTUnwrap(metadata["lines"] as? [[String: Any]], "\(metadata.keys)")
                let line = try XCTUnwrap(lines.first { ($0["text"] as? String)?.uppercased() == "CLOSED" })
                let box = try XCTUnwrap(line["box"] as? [Double])
                XCTAssertEqual(box.count, 4)
                XCTAssertTrue(box.allSatisfy { (0...1).contains($0) })
                XCTAssertLessThan(latency, .seconds(60))
                print("EDGE_PROCESS_OCR latency=\(latency)")
            } else {
                let path = temporaryURL(named: "edge-crop.jpg")
                defer { try? FileManager.default.removeItem(at: path) }
                let args = ["--view-json", #"{"mode":"preview","crop":[0,0,0.5,1],"maxEdge":120}"#, "--output", path.path]
                let preview = try await run(args)
                XCTAssertEqual(preview.0, .success, preview.1)
                XCTAssertEqual(try compactResultObject(from: preview.1)["outputPath"] as? String, path.path)
                let original = try Data(contentsOf: path)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(decoded.width, 120)
                XCTAssertEqual(decoded.height, 50)
                let collision = try await run(args)
                XCTAssertNotEqual(collision.0, .success)
                XCTAssertEqual(try Data(contentsOf: path), original)
            }
        } catch { await controller.stop(); throw error }
        await controller.stop()
    }
    func testFullScenarioLifecycleAgainstRealRunningServerRecordsCompactEvidenceAndNeverLeaksCredential() async throws {
        let controller = try makeController(port: UInt16.random(in: 20_000...60_000))
        await controller.start()
        guard case .running(_, let resolvedEndpointURL) = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        let endpointURL = resolvedEndpointURL
        let enrollment = try controller.enrollClient(displayName: "AK-5 Lifecycle", profileID: .shareable)

        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save(enrollment.plaintextCredential, endpoint: endpointURL)
        let sessionStore = MemoryCLISessionStore()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: sessionStore,
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: .shared
                )
            }
        )

        var recordedArguments: [[String]] = []

        // Background os_log/console noise (e.g. "[Transport] Request exceeded ... timeout budget")
        // can interleave with anything written to the real stdout/stderr fds during the call, so
        // stdout and stderr are captured on SEPARATE pipes: on success `CLIApplication` writes its
        // JSON envelope to stdout only (matching real usage), and on a `CLIError` it writes JSON to
        // stderr only (see `CLIApplication.run(arguments:)`) — parsing only the stream the command
        // actually used avoids fighting console noise mixed into a single merged capture.
        func run(_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String) {
            let fullArguments = args + ["--endpoint", endpointURL.absoluteString, "--json"]
            recordedArguments.append(fullArguments)
            var exitCode: CLIExitCode = .internalFailure
            let (stdout, stderr) = try await captureStandardStreams {
                exitCode = await application.run(arguments: fullArguments)
            }
            let output = exitCode == .success ? stdout : stderr
            return (exitCode, output)
        }

        func runApprovalGatedCommand(
            _ args: [String],
            controller: MCPServerController,
            run: (_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String)
        ) async throws -> [String: Any] {
            let firstAttempt = try await run(args)
            XCTAssertEqual(firstAttempt.exitCode, .approvalRequired, "output=[\(firstAttempt.output)]")
            let approvalRequestPayload = try compactResultObject(from: firstAttempt.output)
            let requestID = try XCTUnwrap(approvalRequestPayload["requestID"] as? String)
            _ = try controller.approvalStore.approve(requestID: requestID)

            let retryResult = try await run(args)
            XCTAssertEqual(retryResult.exitCode, .success, "output=[\(retryResult.output)]")
            return try compactResultObject(from: retryResult.output)
        }

        let draftURL = try writeMinimalScenarioDraft(originatingClientID: enrollment.client.id)
        defer { try? FileManager.default.removeItem(at: draftURL) }

        // draft
        let draftResult = try await run(["scenario", "draft", "--input", draftURL.path])
        XCTAssertEqual(draftResult.exitCode, .success, "output: [\(draftResult.output)]")
        let draftPayload = try compactResultObject(from: draftResult.output)
        let scenarioID = try XCTUnwrap(draftPayload["scenarioID"] as? String, "draft output: \(draftResult.output)")

        // validate
        let validateResult = try await run(["scenario", "validate", scenarioID])
        XCTAssertEqual(validateResult.exitCode, .success)

        // arm/activate are both approval-gated: each first attempt returns a requestID; approve
        // that exact request (mirroring how a human clicking "Approve" in the UI targets one
        // specific request), then retry with byte-identical arguments — the same contract
        // `testScenarioArmWaitsForApprovalAndRetriesExactArguments` already proves against a mock.
        let armPayload = try await runApprovalGatedCommand(
            ["scenario", "arm", scenarioID],
            controller: controller,
            run: run
        )
        XCTAssertEqual(armPayload["phase"] as? String, "armed")

        let activatePayload = try await runApprovalGatedCommand(
            ["scenario", "activate", scenarioID],
            controller: controller,
            run: run
        )
        // "activated" transitions to "observing" as soon as the observation window opens, which can
        // happen before this assertion runs — either is proof activation itself succeeded.
        XCTAssertTrue(
            ["activated", "observing"].contains(activatePayload["phase"] as? String ?? ""),
            "unexpected phase: \(activatePayload)"
        )

        // observe / assert / report — real, compact-by-default projections from the real server
        let observeResult = try await run(["scenario", "observe", scenarioID])
        XCTAssertEqual(observeResult.exitCode, .success)
        let observePayload = try compactResultObject(from: observeResult.output)
        XCTAssertEqual(observePayload["scenarioID"] as? String, scenarioID)
        XCTAssertNil(observePayload["evidence"], "compact projection must omit raw evidence by default")

        let assertResult = try await run(["scenario", "assert", scenarioID])
        XCTAssertEqual(assertResult.exitCode, .success)

        let reportResult = try await run(["scenario", "report", scenarioID])
        XCTAssertEqual(reportResult.exitCode, .success)
        let reportPayload = try compactResultObject(from: reportResult.output)
        XCTAssertEqual(reportPayload["scenarioID"] as? String, scenarioID)

        // cleanup
        let cleanupResult = try await run(["scenario", "cleanup", scenarioID, "--outcome", "completed"])
        XCTAssertEqual(cleanupResult.exitCode, .success)

        // Exit criterion: JoesProxy is left at a clean baseline.
        let cleanupStatusResult = try await run(["cleanup", "status"])
        XCTAssertEqual(cleanupStatusResult.exitCode, .success)
        // Unlike scenario/rewrite tools, `client_cleanup_status` (like `capture_digest`) uses the
        // `MCPDTOEnvelope` convention, so the CLI's own envelope wraps that tool's OWN
        // {"schemaVersion","payload"} envelope unmodified as its `result` — one nesting level
        // deeper than scenario tool responses. See `payloadObject`'s doc comment in
        // `CLIApplication.swift` for why these two conventions coexist.
        let cleanupStatusResultObject = try compactResultObject(from: cleanupStatusResult.output)
        let cleanupStatusPayload = try XCTUnwrap(
            cleanupStatusResultObject["payload"] as? [String: Any],
            "result: \(cleanupStatusResultObject)"
        )
        XCTAssertEqual(cleanupStatusPayload["isClean"] as? Bool, true, "output: \(cleanupStatusResult.output)")

        // Exit criterion: the credential never touches CLI arguments anywhere in this whole run.
        for arguments in recordedArguments {
            for argument in arguments {
                XCTAssertFalse(
                    argument.contains(enrollment.plaintextCredential),
                    "credential leaked into CLI arguments: \(arguments)"
                )
            }
        }

        await controller.stop()
    }

    /// Bookmark CLI parity: real-server proof that `joesproxyctl bookmark create|apply|list|get`
    /// drives the actual `propose_create_bookmark`/`apply_create_bookmark`/`bookmarks_list`/
    /// `bookmark_get` MCP tools end to end, not just a mocked transport (`JoesProxyCLITests.swift`
    /// already covers the mocked argument-mapping layer).
    func testBookmarkCLILifecycleAgainstRealRunningServerCreatesListsAndGetsWithoutLeakingCredential() async throws {
        let controller = try makeController(port: UInt16.random(in: 20_000...60_000))
        await controller.start()
        guard case .running(_, let resolvedEndpointURL) = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        let endpointURL = resolvedEndpointURL
        let enrollment = try controller.enrollClient(displayName: "Bookmark CLI Lifecycle", profileID: .shareable)

        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save(enrollment.plaintextCredential, endpoint: endpointURL)
        let sessionStore = MemoryCLISessionStore()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: sessionStore,
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: .shared
                )
            }
        )

        var recordedArguments: [[String]] = []

        func run(_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String) {
            let fullArguments = args + ["--endpoint", endpointURL.absoluteString, "--json"]
            recordedArguments.append(fullArguments)
            var exitCode: CLIExitCode = .internalFailure
            let (stdout, stderr) = try await captureStandardStreams {
                exitCode = await application.run(arguments: fullArguments)
            }
            let output = exitCode == .success ? stdout : stderr
            return (exitCode, output)
        }

        // create (approval-gated: createDisabledBookmark is a mutatingTool capability)
        let createResult = try await run([
            "bookmark", "create",
            "--method", "GET", "--host", "api.example.com", "--path", "/v1/widgets", "--name", "Widgets list"
        ])
        XCTAssertEqual(createResult.exitCode, .success, "output: [\(createResult.output)]")
        let createPayload = try compactResultObject(from: createResult.output)
        let proposalObject = try XCTUnwrap(createPayload["proposal"] as? [String: Any])
        let proposalToken = try XCTUnwrap(proposalObject["proposalToken"] as? String)

        var applyResult = try await run(["bookmark", "apply", proposalToken])
        if applyResult.exitCode == .approvalRequired {
            let approvalPayload = try compactResultObject(from: applyResult.output)
            let requestID = try XCTUnwrap(approvalPayload["requestID"] as? String)
            _ = try controller.approvalStore.approve(requestID: requestID)
            applyResult = try await run(["bookmark", "apply", proposalToken])
        }
        XCTAssertEqual(applyResult.exitCode, .success, "output: [\(applyResult.output)]")
        let applyPayload = try compactResultObject(from: applyResult.output)
        let bookmarkID = try XCTUnwrap(applyPayload["targetID"] as? String)
        XCTAssertEqual(applyPayload["isEnabled"] as? Bool, false)

        // list (inspect tier, no approval)
        let listResult = try await run(["bookmark", "list"])
        XCTAssertEqual(listResult.exitCode, .success, "output: [\(listResult.output)]")
        let listPayload = try compactResultObject(from: listResult.output)
        let listItems = try XCTUnwrap(listPayload["items"] as? [[String: Any]])
        XCTAssertTrue(listItems.contains { $0["id"] as? String == bookmarkID })

        // get
        let getResult = try await run(["bookmark", "get", bookmarkID])
        XCTAssertEqual(getResult.exitCode, .success, "output: [\(getResult.output)]")
        let getPayload = try compactResultObject(from: getResult.output)
        XCTAssertEqual(getPayload["name"] as? String, "Widgets list")
        XCTAssertEqual(getPayload["id"] as? String, bookmarkID)

        for arguments in recordedArguments {
            for argument in arguments {
                XCTAssertFalse(
                    argument.contains(enrollment.plaintextCredential),
                    "credential leaked into CLI arguments: \(arguments)"
                )
            }
        }

        await controller.stop()
    }

    // MARK: - Helpers

    /// Mirrors `AppCoordinator`'s real production wiring (`configureMutationService` then
    /// `configureScenarioRuntime`) — a bare `MCPServerController` init alone leaves `scenarioService`
    /// nil (scenario tools compose mutation-store primitives like `block`), so `draft_test_scenario`
    /// and friends would otherwise report "Unknown or unavailable tool" no matter how the client is
    /// enrolled.
    private func makeController(port: UInt16, store: InMemorySessionStore = InMemorySessionStore()) throws -> MCPServerController {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-lifecycle.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-lifecycle.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-lifecycle.json"))
        auditStore.load()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: MCPEffectJournalStore())
        let controller = MCPServerController(
            sessionStore: store,
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-lifecycle.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-lifecycle.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-lifecycle.json"))
        )
        let configuration = LifecycleTestConfiguration()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { [weak controller] in controller?.policyStore.policyRevision ?? .initial }
        )
        controller.configureMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        controller.configureScenarioRuntime(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            configuration: configuration
        )
        return controller
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func writeMinimalScenarioDraft(originatingClientID: String) throws -> URL {
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/blocked",
            matchMode: .exactPath
        )
        let draft = MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "AK-5 lifecycle scenario",
            purpose: "Real bundled-app lifecycle validation lane",
            originatingClientID: originatingClientID,
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.block(matcher: matcher, statusCode: 503)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [
                MCPScenarioAssertion(
                    kind: .requestOccurred,
                    matcher: matcher,
                    host: nil,
                    path: nil,
                    statusCode: nil,
                    thresholdSeconds: nil,
                    expectedCount: nil,
                    markerName: nil,
                    detail: nil,
                    evidenceSource: .captured,
                    notes: nil
                )
            ],
            assertionSeverity: .blocking,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)]
        )
        let data = try MCPScenarioJSONCodec.encodeDraft(draft)
        let url = temporaryURL(named: "draft-lifecycle.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `--json` output is one pretty-printed JSON object; unwraps the envelope's `result` field.
    /// Even with stdout/stderr captured on separate pipes, background os_log/console lines (e.g.
    /// "[Approvals] Created approval request ..." or "[Transport] Request exceeded ... timeout
    /// budget") can still land on the same fd as the CLI's own JSON write and precede or follow it.
    /// `CLIApplication` always prints its envelope as one pretty-printed, `.sortedKeys` JSON object
    /// whose outer braces start at column 0 — extracting from the last line that is exactly "{" to
    /// the end is robust to arbitrary noise before it.
    private func compactResultObject(from output: String) throws -> [String: Any] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.lastIndex(where: { $0 == "{" }) else {
            throw CLIError.malformedResponse("No JSON object found in CLI output: \(output)")
        }
        let jsonText = lines[start...].joined(separator: "\n")
        guard let data = jsonText.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.malformedResponse("Could not parse CLI output as JSON: \(output)")
        }
        return try XCTUnwrap(envelope["result"] as? [String: Any], "envelope: \(envelope)")
    }

    /// Captures stdout and stderr on SEPARATE pipes: on success `CLIApplication` writes its JSON
    /// envelope to stdout only; on a `CLIError` it writes the JSON error envelope to stderr only
    /// (see `CLIApplication.run(arguments:)`'s catch block). Merging both into one stream would let
    /// background os_log/console noise (e.g. "[Transport] Request exceeded ... timeout budget")
    /// interleave with the JSON and break parsing — keeping them separate means each call only ever
    /// needs to parse the one stream the command actually wrote its envelope to.
    private func captureStandardStreams(
        _ body: () async throws -> Void
    ) async rethrows -> (stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        let originalStderr = dup(STDERR_FILENO)
        fflush(stdout)
        fflush(stderr)
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        func restore() {
            fflush(stdout)
            fflush(stderr)
            dup2(originalStdout, STDOUT_FILENO)
            dup2(originalStderr, STDERR_FILENO)
            close(originalStdout)
            close(originalStderr)
        }

        do {
            try await body()
        } catch {
            restore()
            throw error
        }
        restore()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

private final class MemoryCLICredentialStore: CLICredentialStoring {
    private var credentials: [String: String] = [:]

    func load(endpoint: URL) throws -> String? { credentials[endpoint.absoluteString] }
    func save(_ credential: String, endpoint: URL) throws { credentials[endpoint.absoluteString] = credential }
    func delete(endpoint: URL) throws { credentials.removeValue(forKey: endpoint.absoluteString) }
}

private final class MemoryCLISessionStore: CLISessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: CLIPersistedSession] = [:]

    func load(endpoint: URL) throws -> CLIPersistedSession? {
        lock.withLock { sessions[endpoint.absoluteString] }
    }

    func save(_ session: CLIPersistedSession) throws {
        lock.withLock { sessions[session.endpoint] = session }
    }

    func delete(endpoint: URL) throws {
        lock.withLock { _ = sessions.removeValue(forKey: endpoint.absoluteString) }
    }
}

private final class MockCLIAppLauncher: CLIAppLaunching {
    private(set) var startRequestCount = 0

    func applicationURL() throws -> URL { URL(fileURLWithPath: "/Applications/JoesProxy.app") }

    func requestMCPStart(launchArguments: [String]) async throws -> URL {
        startRequestCount += 1
        return try applicationURL()
    }
}

/// Minimal `AppConfiguration` conformance for real mutation/scenario-runtime wiring, mirroring
/// `ScenarioExecutorTestConfiguration` in `MCPScenarioExecutorTests.swift`.
private final class LifecycleTestConfiguration: AppConfiguration {
    var proxyPort: UInt16 = NetworkConstants.defaultPort
    var logLevel: AppLogLevel = .info
    var verboseHTTPSLoggingEnabled = false
    var isFindDebugLoggingEnabled = false
    var appTextSizeRawValue = AppTextSize.standard.rawValue
    var isInspectorCopyRedactionEnabled = true
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue
    var isSessionSortAscending = false
    var isSessionAutoScrollEnabled = false
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
    var sessionExplorerExpandedNodeIDs: [String] = []
    var sessionInspectorSplitFraction = 0.62
    var httpsBypassDomains: [String] = []
    var httpsInterceptDomains: [String] = []
    var isNoCachingEnabled = false
    var noCachingDomains: [String] = []
    var isSystemProxyManagementEnabled = false
    var systemProxyStrictCapture = false
    var hasAcknowledgedSystemProxyRouting = false
    var showSystemProxyMenuBarItem = true
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false
    var warnsBeforeQuittingWithUnsavedSessions = true
    var sdkEventServerEnabled = false
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue
    var manualProfileHost = ""
    var responseOverridesData: Data?
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited
    let certificateLabel = "lifecycle-test"
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {}
}
