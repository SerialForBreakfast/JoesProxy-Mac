import Combine
import Foundation
import XCTest
@testable import JoesProxy

/// P1-11: real-server `joesproxyctl` HLS CODECS → Map Local lifecycle against an in-process
/// `MCPServerController` (same pattern as `JoesProxyCLIBundledLifecycleIntegrationTests`).
///
/// Covers context → preview → prepare → approval-gated apply → enable → disable → cleanup,
/// consumed-digest `staleProposal` guidance, and privacy scans over argv / stdout / stderr.
@MainActor
final class JoesProxyCLIHLSCodecsLifecycleIntegrationTests: XCTestCase {
    func testHLSCodecsMapLocalLifecycleAgainstRealRunningServerNeverLeaksBodiesOrCredentials() async throws {
        let sessionStore = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-cli-journal.json"))
        journalStore.load()
        let controller = try makeController(
            port: UInt16.random(in: 20_000...60_000),
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            journalStore: journalStore
        )
        await controller.start()
        guard case .running(_, let resolvedEndpointURL) = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        let endpointURL = resolvedEndpointURL
        let enrollment = try controller.enrollClient(displayName: "P1-11 HLS CODECS Lifecycle", profileID: .shareable)

        let masterBody = hlsMasterBody()
        let session = makeSession(bodyData: masterBody)
        sessionStore.append(session)

        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save(enrollment.plaintextCredential, endpoint: endpointURL)
        let cliSessionStore = MemoryCLISessionStore()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: cliSessionStore,
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
        var recordedStdout: [String] = []
        var recordedStderr: [String] = []

        func run(_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String) {
            let fullArguments = args + ["--endpoint", endpointURL.absoluteString, "--json"]
            recordedArguments.append(fullArguments)
            var exitCode: CLIExitCode = .internalFailure
            let (stdout, stderr) = try await captureStandardStreams {
                exitCode = await application.run(arguments: fullArguments)
            }
            recordedStdout.append(stdout)
            recordedStderr.append(stderr)
            let output = exitCode == .success ? stdout : stderr
            return (exitCode, output)
        }

        /// Apply tools may or may not require approval depending on capability policy.
        /// Accept success on the first attempt, or approve + retry when gated.
        func runMaybeApprovalGatedCommand(
            _ args: [String],
            controller: MCPServerController,
            run: (_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String)
        ) async throws -> [String: Any] {
            let firstAttempt = try await run(args)
            if firstAttempt.exitCode == .success {
                return try compactResultObject(from: firstAttempt.output)
            }
            XCTAssertEqual(firstAttempt.exitCode, .approvalRequired, "output=[\(firstAttempt.output)]")
            let approvalRequestPayload = try compactResultObject(from: firstAttempt.output)
            let requestID = try XCTUnwrap(approvalRequestPayload["requestID"] as? String)
            _ = try controller.approvalStore.approve(requestID: requestID)

            let retryResult = try await run(args)
            XCTAssertEqual(retryResult.exitCode, .success, "output=[\(retryResult.output)]")
            return try compactResultObject(from: retryResult.output)
        }

        // context → opaque variantRef
        let contextResult = try await run(["hls", "codecs", "context", session.id.uuidString])
        XCTAssertEqual(contextResult.exitCode, .success, "output: [\(contextResult.output)]")
        let contextPayload = toolPayload(from: try compactResultObject(from: contextResult.output))
        let variants = try XCTUnwrap(contextPayload["hlsVariants"] as? [[String: Any]])
        let variantRef = try XCTUnwrap(variants.first?["variantRef"] as? String)
        XCTAssertFalse(variantRef.isEmpty)

        let editsURL = temporaryURL(named: "hls-codecs-edits.json")
        defer { try? FileManager.default.removeItem(at: editsURL) }
        let editsData = try JSONSerialization.data(
            withJSONObject: [["variantRef": variantRef, "codecs": "avc1.640028,mp4a.40.2"]],
            options: [.sortedKeys]
        )
        try editsData.write(to: editsURL, options: .atomic)

        // preview
        let previewResult = try await run([
            "hls", "codecs", "preview", session.id.uuidString,
            "--edits", editsURL.path
        ])
        XCTAssertEqual(previewResult.exitCode, .success, "output: [\(previewResult.output)]")
        let previewPayload = toolPayload(from: try compactResultObject(from: previewResult.output))
        let previewDigest = try XCTUnwrap(previewPayload["previewDigest"] as? String)
        XCTAssertTrue(previewDigest.hasPrefix("hls-codecs-preview-"))

        // prepare (consumes digest)
        let prepareResult = try await run([
            "hls", "codecs", "prepare-map-local",
            "--preview-digest", previewDigest
        ])
        XCTAssertEqual(prepareResult.exitCode, .success, "output: [\(prepareResult.output)]")
        let preparePayload = try compactResultObject(from: prepareResult.output)
        let proposalObject = try XCTUnwrap(preparePayload["proposal"] as? [String: Any])
        let proposalToken = try XCTUnwrap(proposalObject["proposalToken"] as? String)

        // stale digest after consume/prepare
        let stalePrepare = try await run([
            "hls", "codecs", "prepare-map-local",
            "--preview-digest", previewDigest
        ])
        XCTAssertEqual(stalePrepare.exitCode, .staleProposal, "output: [\(stalePrepare.output)]")
        let stalePayload = try compactResultObject(from: stalePrepare.output)
        let recommendedAction = try XCTUnwrap(stalePayload["recommendedAction"] as? String)
        XCTAssertTrue(
            recommendedAction.localizedCaseInsensitiveContains("hls codecs preview")
                || recommendedAction.localizedCaseInsensitiveContains("HLS CODECS"),
            "expected HLS-oriented guidance, got: \(recommendedAction)"
        )

        // apply (approval-gated); rule starts disabled
        let applyPayload = try await runMaybeApprovalGatedCommand(
            ["hls", "codecs", "apply-map-local", proposalToken],
            controller: controller,
            run: run
        )
        let applyFields = toolPayload(from: applyPayload)
        let overrideID = try XCTUnwrap(applyFields["targetID"] as? String)
        XCTAssertEqual(applyFields["isEnabled"] as? Bool, false)

        // enable (approval-gated); no confounders on this fixture
        let enablePropose = try await run(["rule", "enable", overrideID])
        XCTAssertEqual(enablePropose.exitCode, .success, "output: [\(enablePropose.output)]")
        let enableProposePayload = try compactResultObject(from: enablePropose.output)
        let enableProposal = try XCTUnwrap(enableProposePayload["proposal"] as? [String: Any])
        let enableToken = try XCTUnwrap(enableProposal["proposalToken"] as? String)
        _ = try await runMaybeApprovalGatedCommand(
            ["rule", "apply-enable", enableToken],
            controller: controller,
            run: run
        )

        let cleanupWhileLive = try await run(["cleanup", "status"])
        XCTAssertEqual(cleanupWhileLive.exitCode, .success, "output: [\(cleanupWhileLive.output)]")
        let liveCleanup = try unwrapCleanupPayload(from: cleanupWhileLive.output)
        XCTAssertEqual(liveCleanup["isClean"] as? Bool, false)
        let liveActiveCount = (liveCleanup["activeEffectCount"] as? NSNumber)?.intValue
            ?? (liveCleanup["activeEffectCount"] as? Int)
            ?? 0
        XCTAssertGreaterThan(liveActiveCount, 0)

        // disable (approval-gated)
        let disablePropose = try await run(["rule", "disable", overrideID])
        XCTAssertEqual(disablePropose.exitCode, .success, "output: [\(disablePropose.output)]")
        let disableProposePayload = try compactResultObject(from: disablePropose.output)
        let disableProposal = try XCTUnwrap(disableProposePayload["proposal"] as? [String: Any])
        let disableToken = try XCTUnwrap(disableProposal["proposalToken"] as? String)
        _ = try await runMaybeApprovalGatedCommand(
            ["rule", "apply-disable", disableToken],
            controller: controller,
            run: run
        )

        let cleanupAfterDisable = try await run(["cleanup", "status"])
        XCTAssertEqual(cleanupAfterDisable.exitCode, .success, "output: [\(cleanupAfterDisable.output)]")
        let cleanPayload = try unwrapCleanupPayload(from: cleanupAfterDisable.output)
        XCTAssertEqual(cleanPayload["isClean"] as? Bool, true, "output: \(cleanupAfterDisable.output)")
        let cleanActiveCount = (cleanPayload["activeEffectCount"] as? NSNumber)?.intValue
            ?? (cleanPayload["activeEffectCount"] as? Int)
            ?? -1
        XCTAssertEqual(cleanActiveCount, 0)

        // Disabled inert rule may remain in the override store; it must not count as an active effect.
        let remainingRules = await responseOverrideStore.rules()
        XCTAssertEqual(remainingRules.filter { $0.id.uuidString == overrideID }.count, 1)
        XCTAssertEqual(remainingRules.first(where: { $0.id.uuidString == overrideID })?.isEnabled, false)

        assertNoPrivacyLeaks(
            credential: enrollment.plaintextCredential,
            recordedArguments: recordedArguments,
            recordedStdout: recordedStdout,
            recordedStderr: recordedStderr
        )

        await controller.stop()
    }

    // MARK: - Fixtures

    /// Tiny synthetic HLS master (same style as unit-test fixtures); includes a sensitive query
    /// token that must never appear in CLI argv or captured streams.
    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
        https://cdn.example.com/video/one.m3u8?sid=secret
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,AUDIO="main"
        https://cdn.example.com/video/two.m3u8?sid=secret
        """.utf8)
    }

    private func makeSession(bodyData: Data) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: "/master.m3u8?sid=secret",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: bodyData,
                bodySize: bodyData.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    // MARK: - Controller bootstrap

    /// Mirrors production wiring for mutation + recovery so cleanup `activeEffectCount` reflects
    /// enabled MCP Map Local rules (not only scenario lifecycle).
    private func makeController(
        port: UInt16,
        sessionStore: InMemorySessionStore,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: InMemoryBookmarkStore,
        journalStore: MCPEffectJournalStore
    ) throws -> MCPServerController {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "hls-cli-policy.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "hls-cli-clients.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "hls-cli-audit.json"))
        auditStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let controller = MCPServerController(
            sessionStore: sessionStore,
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "hls-cli-scenarios.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "hls-cli-response-drafts.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-cli-fixture-runs.json"))
        )
        let configuration = HLSCodecsLifecycleTestConfiguration()
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
        controller.configureRecoveryService(
            journalStore: journalStore,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        return controller
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    // MARK: - Output helpers

    /// Unwraps `schemaVersion`/`payload` tool envelopes when present.
    private func toolPayload(from result: [String: Any]) -> [String: Any] {
        if result["schemaVersion"] != nil, let payload = result["payload"] as? [String: Any] {
            return payload
        }
        return result
    }

    private func unwrapCleanupPayload(from output: String) throws -> [String: Any] {
        let resultObject = try compactResultObject(from: output)
        return toolPayload(from: resultObject)
    }

    /// `--json` output is one pretty-printed JSON object; unwraps the envelope's `result` field.
    /// Extracts from the last line that is exactly "{" to tolerate os_log noise on the same fd.
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

    private func assertNoPrivacyLeaks(
        credential: String,
        recordedArguments: [[String]],
        recordedStdout: [String],
        recordedStderr: [String]
    ) {
        let streams = recordedStdout + recordedStderr
        for arguments in recordedArguments {
            for argument in arguments {
                XCTAssertFalse(argument.contains(credential), "credential leaked into CLI arguments: \(arguments)")
                XCTAssertFalse(argument.contains("#EXTM3U"), "manifest body leaked into CLI arguments: \(arguments)")
                XCTAssertFalse(argument.contains("sid=secret"), "signed query leaked into CLI arguments: \(arguments)")
            }
        }
        for stream in streams {
            XCTAssertFalse(stream.contains(credential), "credential leaked into CLI stream")
            XCTAssertFalse(stream.contains("#EXTM3U"), "manifest body leaked into CLI stream")
            XCTAssertFalse(stream.contains("sid=secret"), "signed query leaked into CLI stream")
        }
    }

    /// Captures stdout and stderr on separate pipes (same contract as the bundled lifecycle test).
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

// MARK: - Test doubles (file-local; mirrors bundled lifecycle helpers)

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

/// Minimal `AppConfiguration` for mutation/recovery wiring in the HLS CODECS CLI lifecycle lane.
private final class HLSCodecsLifecycleTestConfiguration: AppConfiguration {
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
    let certificateLabel = "hls-codecs-lifecycle-test"
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {}
}
