import Combine
import Foundation
import XCTest
@testable import JoesProxy

/// AP residual gap: `hls_fixture_window_preview` had only in-process MCP coverage
/// (`MCPHLSFixtureLifecycleTests`) — no test drove it through the real `joesproxyctl` subprocess
/// path over a real running `MCPServerController`, the way `JoesProxyCLIHLSCodecsLifecycleIntegrationTests`
/// already does for HLS CODECS Map Local. This closes that gap: prepare-start → approval-gated
/// apply-start → window-preview → stop, against a real running server, with a privacy scan.
@MainActor
final class JoesProxyCLIHLSFixtureLifecycleIntegrationTests: XCTestCase {
    private func baselineProfileDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
    }

    private func profilesRoot() -> URL {
        baselineProfileDirectory().deletingLastPathComponent()
    }

    func testHLSFixtureLifecycleAgainstRealRunningServerWindowPreviewMatchesLiveComputation() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: baselineProfileDirectory().path),
            "Fixtures/HLS/baseline-aligned-codecs not present."
        )

        let sessionStore = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-journal.json"))
        journalStore.load()
        let fixtureRunStore = HLSFixtureRunStore(
            persistenceURL: temporaryURL(named: "hls-fixture-cli-runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: HLSFixtureOriginRegistry()
        )
        let controller = try makeController(
            port: UInt16.random(in: 20_000...60_000),
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            journalStore: journalStore,
            fixtureRunStore: fixtureRunStore
        )
        await controller.start()
        guard case .running(_, let resolvedEndpointURL) = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        let endpointURL = resolvedEndpointURL
        let enrollment = try controller.enrollClient(displayName: "AP HLS Fixture CLI Lifecycle", profileID: .shareable)

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

        func runMaybeApprovalGatedCommand(_ args: [String]) async throws -> [String: Any] {
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

        // prepare-start (propose)
        let textProposal = try await run(["hls", "fixture", "prepare-start", "--profile-id", "multilingual-text-vod-v1"])
        XCTAssertEqual(textProposal.exitCode, .success, textProposal.output)
        let textPreparation = try compactResultObject(from: textProposal.output)
        let textToken = try XCTUnwrap((textPreparation["proposal"] as? [String: Any])?["proposalToken"] as? String)
        let textApply = toolPayload(from: try await runMaybeApprovalGatedCommand(["hls", "fixture", "apply-start", textToken]))
        let textRunID = try XCTUnwrap(textApply["runID"] as? String)
        XCTAssertEqual((textApply["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String, "vodStatic")
        let textPreview = try await run(["hls", "fixture", "window-preview", "--run-id", textRunID, "--path", "text/es/stream.m3u8"])
        XCTAssertEqual(textPreview.exitCode, .success, textPreview.output)
        let textFields = toolPayload(from: try compactResultObject(from: textPreview.output))
        XCTAssertEqual(textFields["clockDependent"] as? Bool, false)
        XCTAssertTrue((textFields["playlistText"] as? String)?.contains("#EXT-X-ENDLIST") == true)
        let textStop = try await run(["hls", "fixture", "stop", "--run-id", textRunID])
        XCTAssertEqual(textStop.exitCode, .success, textStop.output)

        let liveText = try await run(["hls", "fixture", "prepare-start", "--profile-id", "multilingual-text-vod-v1",
            "--presentation-mode", "liveLoop", "--time-shift-mode", "warmDVR", "--window-segments", "4"])
        XCTAssertEqual(liveText.exitCode, .success, liveText.output)
        let liveTextPreparation = try compactResultObject(from: liveText.output)
        let liveTextToken = try XCTUnwrap((liveTextPreparation["proposal"] as? [String: Any])?["proposalToken"] as? String)
        let liveTextApply = toolPayload(from: try await runMaybeApprovalGatedCommand(["hls", "fixture", "apply-start", liveTextToken]))
        let liveTextID = try XCTUnwrap(liveTextApply["runID"] as? String)
        let liveTextPreview = try await run(["hls", "fixture", "window-preview", "--run-id", liveTextID, "--path", "text/es/stream.m3u8"])
        XCTAssertEqual(liveTextPreview.exitCode, .success, liveTextPreview.output)
        let liveFields = toolPayload(from: try compactResultObject(from: liveTextPreview.output))
        XCTAssertEqual(liveFields["presentationMode"] as? String, "liveLoop")
        XCTAssertTrue((liveFields["playlistText"] as? String)?.contains("#EXT-X-VERSION:6") == true)
        XCTAssertFalse((liveFields["playlistText"] as? String)?.contains("#EXT-X-ENDLIST") == true)
        let liveStop = try await run(["hls", "fixture", "stop", "--run-id", liveTextID])
        XCTAssertEqual(liveStop.exitCode, .success, liveStop.output)

        let prepareResult = try await run([
            "hls", "fixture", "prepare-start", "--profile-id", "baseline-aligned-codecs",
            "--presentation-mode", "liveLoop", "--time-shift-mode", "warmDVR",
            "--window-segments", "15"
        ])
        XCTAssertEqual(prepareResult.exitCode, .success, "output: [\(prepareResult.output)]")
        let preparePayload = try compactResultObject(from: prepareResult.output)
        let proposalObject = try XCTUnwrap(preparePayload["proposal"] as? [String: Any])
        let proposalToken = try XCTUnwrap(proposalObject["proposalToken"] as? String)

        // apply-start (approval-gated)
        let applyPayload = try await runMaybeApprovalGatedCommand(["hls", "fixture", "apply-start", proposalToken])
        let applyFields = toolPayload(from: applyPayload)
        let runID = try XCTUnwrap(applyFields["runID"] as? String)
        XCTAssertEqual(applyFields["isActive"] as? Bool, true)
        XCTAssertEqual(
            (applyFields["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String,
            "liveLoop"
        )
        XCTAssertEqual(
            (applyFields["playbackConfiguration"] as? [String: Any])?["timeShiftMode"] as? String,
            "warmDVR"
        )
        XCTAssertEqual(
            (applyFields["playbackConfiguration"] as? [String: Any])?["windowSegmentCount"] as? Int,
            15
        )

        // status confirms the real run is registered
        let statusResult = try await run(["hls", "fixture", "status", "--run-id", runID])
        XCTAssertEqual(statusResult.exitCode, .success, "output: [\(statusResult.output)]")

        // window-preview against a fixed simulated offset
        let previewResult = try await run([
            "hls", "fixture", "window-preview",
            "--run-id", runID, "--path", "video-lo/stream.m3u8", "--at", "12"
        ])
        XCTAssertEqual(previewResult.exitCode, .success, "output: [\(previewResult.output)]")
        let previewPayload = toolPayload(from: try compactResultObject(from: previewResult.output))
        let playlistText = try XCTUnwrap(previewPayload["playlistText"] as? String)
        XCTAssertEqual(previewPayload["elapsedSeconds"] as? Double, 12)
        XCTAssertEqual(previewPayload["presentationMode"] as? String, "liveLoop")
        XCTAssertEqual(previewPayload["timeShiftMode"] as? String, "warmDVR")
        XCTAssertEqual(previewPayload["clockDependent"] as? Bool, true)
        XCTAssertEqual(previewPayload["advertisedDurationSeconds"] as? Double, 60)
        XCTAssertEqual(previewPayload["oldestRetainedButEvictedSequence"] as? Int, 0)

        // Parity: the CLI-driven preview must match the same live-window computation the unit-level
        // MCP test (`MCPHLSFixtureLifecycleTests`) already proves against `response(forPath:)`.
        let runUUID = try XCTUnwrap(UUID(uuidString: runID))
        let liveServer = try XCTUnwrap(fixtureRunStore.liveServer(id: runUUID))
        let at = liveServer.startedAt.addingTimeInterval(12)
        let expectedWindow = try XCTUnwrap(liveServer.slidingWindow(forPath: "video-lo/stream.m3u8", now: at))
        XCTAssertEqual(playlistText, HLSSlidingPlaylistComputer.render(expectedWindow))
        XCTAssertEqual(previewPayload["mediaSequence"] as? Int, expectedWindow.mediaSequence)

        // stop cleans up the run
        let stopResult = try await run(["hls", "fixture", "stop", "--run-id", runID])
        XCTAssertEqual(stopResult.exitCode, .success, "output: [\(stopResult.output)]")

        assertNoPrivacyLeaks(
            credential: enrollment.plaintextCredential,
            recordedArguments: recordedArguments,
            recordedStdout: recordedStdout,
            recordedStderr: recordedStderr
        )

        await controller.stop()
    }

    /// Regression test for a real bug (confirmed live, fixed 2026-08-12): `MCPHLSFixtureService`'s
    /// approval-gating hardcoded `mcpSessionID: nil` when creating a pending approval, but
    /// `approval_status` (what `--wait-for-approval` polls) always looks one up by the caller's
    /// real MCP session ID — so the poll could never find its own approval and failed with
    /// "Approval request not found" even though the approval genuinely existed. This drives the
    /// real CLI over a real running server (same session both calls are made on) and asserts
    /// `approval_status` finds the pending request it just created, rather than reproducing the
    /// full `--wait-for-approval` polling loop.
    func testApprovalStatusFindsPendingRequestUnderTheSameSession() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: baselineProfileDirectory().path),
            "Fixtures/HLS/baseline-aligned-codecs not present."
        )

        let sessionStore = InMemorySessionStore()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-approval-journal.json"))
        journalStore.load()
        let fixtureRunStore = HLSFixtureRunStore(
            persistenceURL: temporaryURL(named: "hls-fixture-cli-approval-runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: HLSFixtureOriginRegistry()
        )
        let controller = try makeController(
            port: UInt16.random(in: 20_000...60_000),
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            journalStore: journalStore,
            fixtureRunStore: fixtureRunStore
        )
        await controller.start()
        guard case .running(_, let resolvedEndpointURL) = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        let endpointURL = resolvedEndpointURL
        let enrollment = try controller.enrollClient(displayName: "AP HLS Fixture Approval Session", profileID: .shareable)

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

        func run(_ args: [String]) async throws -> (exitCode: CLIExitCode, output: String) {
            let fullArguments = args + ["--endpoint", endpointURL.absoluteString, "--json"]
            var exitCode: CLIExitCode = .internalFailure
            let (stdout, stderr) = try await captureStandardStreams {
                exitCode = await application.run(arguments: fullArguments)
            }
            return (exitCode, exitCode == .success ? stdout : stderr)
        }

        // prepare-start (propose)
        let prepareResult = try await run(["hls", "fixture", "prepare-start", "--profile-id", "baseline-aligned-codecs"])
        XCTAssertEqual(prepareResult.exitCode, .success, "output: [\(prepareResult.output)]")
        let preparePayload = try compactResultObject(from: prepareResult.output)
        let proposalObject = try XCTUnwrap(preparePayload["proposal"] as? [String: Any])
        let proposalToken = try XCTUnwrap(proposalObject["proposalToken"] as? String)

        // apply-start (first attempt) mints a real pending approval under this client's real session.
        let applyAttempt = try await run(["hls", "fixture", "apply-start", proposalToken])
        XCTAssertEqual(applyAttempt.exitCode, .approvalRequired, "output=[\(applyAttempt.output)]")
        let approvalRequestPayload = try compactResultObject(from: applyAttempt.output)
        let requestID = try XCTUnwrap(approvalRequestPayload["requestID"] as? String)

        // The same CLI session (same MCPCLIClient/session ID) polls approval_status for the
        // request it just triggered — this is exactly what `--wait-for-approval` does internally.
        // Before the fix this failed with "Approval request not found" (mcpSessionID mismatch).
        let statusClient = MCPCLIClient(
            endpoint: endpointURL,
            credential: enrollment.plaintextCredential,
            sessionStore: cliSessionStore,
            timeout: 10,
            urlSession: .shared
        )
        let statusResult = try await statusClient.callTool(
            name: "approval_status",
            arguments: ["requestID": requestID]
        )
        // `approval_status`'s structuredContent is the status DTO's fields directly (no nested
        // "payload" envelope) — matching `MCPApprovalStatusDTO`'s own encoding.
        XCTAssertEqual(statusResult["status"] as? String, "pending")
        XCTAssertEqual(statusResult["requestID"] as? String, requestID)

        await controller.stop()
    }

    // MARK: - Controller bootstrap

    private func makeController(
        port: UInt16,
        sessionStore: InMemorySessionStore,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: InMemoryBookmarkStore,
        journalStore: MCPEffectJournalStore,
        fixtureRunStore: HLSFixtureRunStore
    ) throws -> MCPServerController {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-policy.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "hls-fixture-cli-clients.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-audit.json"))
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
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-scenarios.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "hls-fixture-cli-response-drafts.json")),
            fixtureRunStore: fixtureRunStore
        )
        let configuration = HLSFixtureLifecycleTestConfiguration()
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
        controller.configureHLSFixtureService(proposalCoordinator: proposalCoordinator)
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

    private func toolPayload(from result: [String: Any]) -> [String: Any] {
        if result["schemaVersion"] != nil, let payload = result["payload"] as? [String: Any] {
            return payload
        }
        return result
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
            }
        }
        for stream in streams {
            XCTAssertFalse(stream.contains(credential), "credential leaked into CLI stream")
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

// MARK: - Test doubles (file-local; mirrors HLS CODECS lifecycle test helpers)

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

/// Minimal `AppConfiguration` for mutation/recovery wiring in the HLS fixture CLI lifecycle lane.
private final class HLSFixtureLifecycleTestConfiguration: AppConfiguration {
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
    let certificateLabel = "hls-fixture-lifecycle-test"
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {}
}
