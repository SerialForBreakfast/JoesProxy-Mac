import Foundation

final class CLIApplication {
    /// Poll interval while waiting for in-app approval. Kept short so interactive approve→apply
    /// feels immediate once `approval_status` reports `approved_awaiting_retry`.
    private static let mcpPollingIntervalNanoseconds: UInt64 = 250_000_000

    private let credentialStore: any CLICredentialStoring
    private let sessionStore: any CLISessionStoring
    private let writeResult: (Data) -> Void
    private let appLauncher: any CLIAppLaunching
    private let sleep: (UInt64) async throws -> Void
    private let clientFactory: (URL, String, any CLISessionStoring, TimeInterval) -> MCPCLIClient
    private var receiptRecorder: CLIReceiptRecorder?

    init(
        credentialStore: any CLICredentialStoring = CLIKeychainCredentialStore(),
        sessionStore: any CLISessionStoring = CLIFileSessionStore(),
        writeResult: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
        appLauncher: any CLIAppLaunching = CLIWorkspaceAppLauncher(),
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        clientFactory: @escaping (URL, String, any CLISessionStoring, TimeInterval) -> MCPCLIClient = {
            MCPCLIClient(endpoint: $0, credential: $1, sessionStore: $2, timeout: $3)
        }
    ) {
        self.credentialStore = credentialStore
        self.sessionStore = sessionStore
        self.writeResult = writeResult
        self.appLauncher = appLauncher
        self.sleep = sleep
        self.clientFactory = clientFactory
    }

    func run(arguments: [String]) async -> CLIExitCode {
        defer {
            if let recorder = receiptRecorder {
                do { try recorder.write() }
                catch { FileHandle.standardError.write(Data("joesproxyctl: Receipt export failed; original operation was not retried and its exit status is unchanged.\n".utf8)) }
            }
            receiptRecorder = nil
        }
        do {
            let invocation = try CLIInvocation.parse(arguments)
            receiptRecorder = try CLIReceiptRecorder(invocation: invocation)
            if invocation.flags.contains("integrations") {
                FileHandle.standardOutput.write(Data((CLIIntegrations.listMarkdown + "\n").utf8))
                return .success
            }
            if invocation.command.isEmpty || invocation.command == ["help"] || invocation.flags.contains("help") {
                print(Self.help)
                return .success
            }
            let result = try await execute(invocation)
            if invocation.command.first == "integrations",
               invocation.outputMode == .human,
               let payload = result.result as? [String: Any],
               let text = payload["markdown"] as? String {
                FileHandle.standardOutput.write(Data((text + "\n").utf8))
                return .success
            }
            if invocation.command.first == "docs", invocation.outputMode == .human,
               invocation.options["format"] != "json",
               let payload = result.result as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let page = try? JSONDecoder().decode(DocumentationCatalog.Page.self, from: data) {
                FileHandle.standardOutput.write(Data((page.markdown + "\n").utf8))
                return .success
            }
            if invocation.command == ["setup", "guide"],
               invocation.options["format"] == "markdown",
               invocation.outputMode == .human,
               let payload = result.result as? [String: Any],
               let guide = payload["guide"] as? String {
                FileHandle.standardOutput.write(Data((guide + "\n").utf8))
                return .success
            }
            let documentationJSON = invocation.command.first == "docs" && invocation.options["format"] == "json"
                && invocation.outputMode == .human
            try emit(result: result, mode: documentationJSON ? .json : invocation.outputMode)
            if !result.success, invocation.command.first == "artifact" || invocation.command == ["capture", "calculate"] {
                return .partialResult
            }
            if invocation.command == ["doctor"],
               let doctor = result.result as? [String: Any],
               doctor["ready"] as? Bool != true {
                return .partialResult
            }
            return .success
        } catch let error as CLIError {
            let parsed = try? CLIInvocation.parse(arguments)
            let command: String
            if arguments.contains("--literal") || arguments.contains("--literal-stdin") {
                command = "artifact search"
            } else {
                command = parsed?.command.joined(separator: " ") ?? "joesproxyctl"
            }
            let envelope = CLIResultEnvelope(
                command: command,
                success: false,
                result: approvalResult(error, command: command),
                warnings: [],
                errorCode: String(describing: error.exitCode),
                errorMessage: error.message
            )
            let requestedJSON = arguments.contains("--json") || arguments.contains("--ndjson")
                || (parsed?.command.first == "docs" && parsed?.options["format"] == "json")
            if requestedJSON, let text = try? CLIJSON.string(envelope.jsonObject(), pretty: !arguments.contains("--ndjson")) {
                FileHandle.standardError.write(Data((text + "\n").utf8))
            } else if !arguments.contains("--quiet") {
                FileHandle.standardError.write(Data(("joesproxyctl: \(error.message)\n").utf8))
                if case .approvalRequired(let requestID, _) = error, let requestID {
                    FileHandle.standardError.write(Data(("Approval request: \(requestID)\n").utf8))
                }
            }
            return error.exitCode
        } catch {
            FileHandle.standardError.write(Data(("joesproxyctl: \(error.localizedDescription)\n").utf8))
            return .internalFailure
        }
    }

    private func execute(_ invocation: CLIInvocation) async throws -> CLIResultEnvelope {
        let commandName = invocation.command.joined(separator: " ")
        if invocation.command.first == "efficiency" {
            return try CLIWorkflowCostReport.execute(invocation)
        }
        if invocation.command.first == "docs" {
            return try await documentation(invocation)
        }
        if invocation.command.first == "integrations" {
            return try CLIIntegrations.execute(invocation: invocation)
        }
        switch invocation.command {
        case ["version"]:
            return success(commandName, [
                "name": "joesproxyctl",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                "schemaVersion": CLIResultEnvelope.schemaVersion
            ])
        case ["auth", "login"]:
            let credential = try CLITerminalCredentialReader.read(prompt: "JoesProxy CLI enrollment credential: ")
            try credentialStore.save(credential, endpoint: invocation.endpointURL)
            try sessionStore.delete(endpoint: invocation.endpointURL)
            return success(commandName, ["state": "stored", "endpoint": invocation.endpointURL.absoluteString])
        case ["auth", "logout"]:
            try credentialStore.delete(endpoint: invocation.endpointURL)
            try sessionStore.delete(endpoint: invocation.endpointURL)
            return success(commandName, ["state": "removed", "endpoint": invocation.endpointURL.absoluteString])
        case ["auth", "status"]:
            let configured = try credentialStore.load(endpoint: invocation.endpointURL) != nil
            return success(commandName, ["configured": configured, "endpoint": invocation.endpointURL.absoluteString])
        case ["setup", "guide"]:
            let format = invocation.options["format"] ?? "markdown"
            guard format == "markdown" || format == "json" else {
                throw CLIError.invalidArguments("setup guide --format must be markdown or json.")
            }
            return success(commandName, [
                "format": format,
                "guide": CLISetupGuide.markdown,
                "portable": true,
                "containsCredentials": false,
                "containsLiveEndpoint": false
            ])
        case ["doctor"]:
            return await doctor(invocation: invocation)
        case ["app", "launch"]:
            try requireCredential(invocation)
            let appURL = try await appLauncher.requestMCPStart(launchArguments: invocation.launchArguments)
            return success(commandName, [
                "state": "launch_requested",
                "appPath": appURL.path,
                "mcpStartRequested": true,
                "launchArguments": invocation.launchArguments
            ])
        case ["mcp", "start"]:
            try requireCredential(invocation)
            _ = try await appLauncher.requestMCPStart(launchArguments: invocation.launchArguments)
            return success(commandName, try await waitForMCP(invocation: invocation))
        case ["mcp", "wait"]:
            return success(commandName, try await waitForMCP(invocation: invocation))
        default:
            break
        }

        let client = try makeClient(invocation)
        // Bound each async command dispatcher so compiler coroutine cleanup stays manageable.
        switch invocation.command.first {
        case "status", "toolset", "proxy", "mcp", "capture", "artifact", "https", "cache", "investigate", "evidence", "read", "sessions", "device", "session", "wait", "watch":
            return try await executeCaptureCommands(invocation, client: client)
        case "hls", "media":
            return try await executeMediaCommands(invocation, client: client)
        case "openapi", "mocker", "mock", "effect":
            return try await executeAuthoringCommands(invocation, client: client)
        case "block", "bookmark", "rule", "throttle", "operation", "rewrite", "collection-mock":
            return try await executeEffectsCommands(invocation, client: client)
        case "response":
            return try await executeResponseCommands(invocation, client: client)
        case "run", "scenario", "cleanup", "approvals", "repro", "certificate":
            return try await executeScenarioCommands(invocation, client: client)
        case "hypothesis", "llm", "fuzz", "resilience", "trajectory", "semantic", "contract", "lineage", "localization", "stateful", "isolate", "synthetic", "instruments":
            return try await executeAnalysisCommands(invocation, client: client)
        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeCaptureCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case ["status"]:
            return success(commandName, try await client.ping())
        case ["toolset", "status"]:
            return success(commandName, try await runTool(
                client,
                name: "agent_toolset_status",
                arguments: [:],
                invocation: invocation
            ))
        case ["toolset", "select"]:
            guard let toolset = invocation.options["name"] else {
                throw CLIError.invalidArguments(
                    "toolset select requires --name core|capture|mocking|media|reproduction|advanced|all."
                )
            }
            return success(commandName, try await runTool(
                client,
                name: "agent_toolset_select",
                arguments: ["toolset": toolset],
                invocation: invocation
            ))
        case ["proxy", "start"]:
            return success(commandName, try await runTool(client, name: "proxy_start", arguments: [:], invocation: invocation))
        case ["proxy", "stop"]:
            return success(commandName, try await runTool(client, name: "proxy_stop", arguments: [:], invocation: invocation))
        case ["mcp", "stop"]:
            return success(commandName, try await runTool(
                client,
                name: "mcp_stop",
                arguments: [:],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["capture", "digest"]:
            return success(commandName, try await runTool(client, name: "capture_digest", arguments: captureDigestArguments(invocation), invocation: invocation))
        case ["capture", "status"]:
            return success(commandName, try await runTool(client, name: "capture_status", arguments: [:], invocation: invocation))
        case ["https", "rules", "get"], ["https", "rules", "set"], ["https", "rules", "restore"]:
            guard let host = invocation.options["host"] else {
                throw CLIError.invalidArguments("Use https rules get --host media.example.test, then https rules set --host media.example.test --mode tunnel --expected-revision <revision> --scope host_and_subdomains_all_clients --wait-for-approval.")
            }
            var arguments: [String: Any] = ["host": host]
            if let recoveryID = invocation.options["recovery-id"] { arguments["recoveryID"] = recoveryID }
            if command.last == "restore" {
                guard let recoveryID = invocation.options["recovery-id"],
                      let revision = invocation.options["expected-revision"], let scope = invocation.options["scope"] else {
                    throw CLIError.invalidArguments("HTTPS restore requires --host, --recovery-id, --expected-revision and --scope host_and_subdomains_all_clients. Inspect the receipt before requesting separate local approval.")
                }
                arguments["recoveryID"] = recoveryID
                arguments["expectedRevision"] = revision
                arguments["scope"] = scope
            }
            if command.last == "set" {
                guard let mode = invocation.options["mode"], let revision = invocation.options["expected-revision"],
                      let scope = invocation.options["scope"] else {
                    throw CLIError.invalidArguments("HTTPS set requires --mode tunnel|inspect|remove, --expected-revision from get, and --scope host_and_subdomains_all_clients.")
                }
                arguments["mode"] = mode
                arguments["expectedRevision"] = revision
                arguments["scope"] = scope
            }
            return success(commandName, try await runTool(client, name: "https_rules_" + (command.last ?? "get"),
                arguments: arguments, invocation: invocation, retryOnStaleSession: command.last == "get"))
        case ["capture", "resume"]:
            return success(commandName, try await runTool(client, name: "capture_resume", arguments: [:], invocation: invocation))
        case ["cache", "audit"]:
            return success(commandName, try await runTool(client, name: "audit_cache_efficiency", arguments: [:], invocation: invocation))
        case ["investigate", "snapshot"]:
            var arguments: [String: Any] = [:]
            if let limit = invocation.options["limit"], let value = Int(limit) {
                arguments["limit"] = value
            }
            if let sequence = invocation.options["since-sequence"], let value = UInt64(sequence) {
                arguments["sinceSequence"] = value
            }
            if let stateToken = invocation.options["if-state-token"] {
                arguments["ifStateToken"] = stateToken
            }
            return success(commandName, try await runTool(
                client,
                name: "investigation_snapshot",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "evidence" && command[1] == "get":
            return success(commandName, try await runTool(
                client,
                name: "evidence_get",
                arguments: ["evidenceRef": command[2]],
                invocation: invocation
            ))
        case ["read", "batch"]:
            return success(commandName, try await runTool(
                client,
                name: "read_batch",
                arguments: try readBatchArguments(invocation),
                invocation: invocation
            ))
        case ["capture", "rolling-status"]:
            let digest = try await runTool(client, name: "capture_digest", arguments: [:], invocation: invocation)
            let payload = payloadObject(digest) ?? [:]
            return success(commandName, [
                "rollingCaptureAvailable": payload["rollingCaptureAvailable"] as Any,
                "rollingCaptureSavedAt": payload["rollingCaptureSavedAt"] as Any,
                "rollingCaptureSessionCount": payload["rollingCaptureSessionCount"] as Any,
                "captureEpoch": payload["captureEpoch"] as Any,
                "lastEpochChangeReason": payload["lastEpochChangeReason"] as Any,
                "lastEpochChangeAt": payload["lastEpochChangeAt"] as Any,
                "previousCaptureEpoch": payload["previousCaptureEpoch"] as Any,
                "sessionCount": payload["sessionCount"] as Any,
                "latestSequence": payload["latestSequence"] as Any
            ])
        case ["capture", "restore-rolling"]:
            return success(commandName, try await runTool(
                client,
                name: "capture_restore_rolling",
                arguments: [:],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["capture", "marker"]:
            guard let name = invocation.options["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.invalidArguments("capture marker requires --name <marker-name>.")
            }
            var arguments: [String: Any] = ["name": name]
            if let detail = invocation.options["detail"] { arguments["detail"] = detail }
            if let label = invocation.options["label"] { arguments["label"] = label }
            return success(commandName, try await runTool(client, name: "capture_marker_create", arguments: arguments, invocation: invocation))
        case ["capture", "activity"]:
            guard let markerSessionID = invocation.options["since-marker"], !markerSessionID.isEmpty else {
                throw CLIError.invalidArguments(
                    "capture activity requires --since-marker <session-id> (from `capture marker`'s own result)."
                )
            }
            var activityArguments: [String: Any] = ["markerSessionID": markerSessionID]
            if let overrideID = invocation.options["rule"], !overrideID.isEmpty {
                activityArguments["overrideID"] = overrideID
            }
            if let limit = invocation.options["limit"], let limitValue = Int(limit) {
                activityArguments["limit"] = limitValue
            }
            return success(commandName, try await runTool(
                client,
                name: "capture_activity_since_marker",
                arguments: activityArguments,
                invocation: invocation
            ))
        case ["sessions", "list"]:
            return success(commandName, try await runTool(client, name: "sessions_list", arguments: sessionPageArguments(invocation), invocation: invocation))
        case ["sessions", "search"]:
            return success(commandName, try await runTool(client, name: "sessions_search", arguments: sessionSearchArguments(invocation), invocation: invocation))
        case ["artifact", "compare"]:
            return artifactResult(commandName, try await runTool(client, name: "artifact_compare_responses",
                arguments: CLIArtifactArguments.compare(invocation), invocation: invocation, retryOnStaleSession: false))
        case ["artifact", "brief"]:
            return artifactResult(commandName, try await runTool(client, name: "artifact_response_brief",
                arguments: CLIArtifactArguments.brief(invocation), invocation: invocation, retryOnStaleSession: false))
        case ["artifact", "inventory"], ["artifact", "search"]:
            let arguments = try CLIArtifactArguments.search(invocation, inventory: command[1] == "inventory")
            return artifactResult(commandName, try await runTool(client, name: "artifact_" + command[1], arguments: arguments, invocation: invocation, retryOnStaleSession: false))
        case ["capture", "calculate"], ["artifact", "calculate"]:
            let live = command[0] == "capture"
            let arguments = try CLIArtifactArguments.calculation(invocation, live: live)
            return artifactResult(commandName, try await runTool(client, name: live ? "capture_calculate" : "artifact_calculate", arguments: arguments, invocation: invocation))
        case ["artifact", "source", "register"], ["artifact", "source", "status"], ["artifact", "source", "inspect"], ["artifact", "source", "release"]:
            let arguments = try CLIArtifactArguments.source(invocation, action: command[2])
            return artifactResult(commandName, try await runTool(client, name: "artifact_source_" + command[2], arguments: arguments, invocation: invocation))
        case ["device", "list"]:
            return success(commandName, try await runTool(
                client,
                name: "list_discovered_devices",
                arguments: [:],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "device" && command[1] == "alias":
            let ipAddress = command[2]
            let alias = invocation.flags.contains("clear") ? nil : invocation.options["name"]
            if !invocation.flags.contains("clear"), alias == nil {
                throw CLIError.invalidArguments("device alias <ip-address> requires --name <friendly-name> or --clear.")
            }
            var arguments: [String: Any] = ["ipAddress": ipAddress]
            if let alias { arguments["alias"] = alias }
            return success(commandName, try await runTool(
                client,
                name: "set_device_alias",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "session" && command[1] == "brief":
            var arguments: [String: Any] = ["sessionID": command[2]]
            if let pointer = invocation.options["selection-pointer"] { arguments["selectionPointer"] = pointer }
            if invocation.flags.contains("include-structure") { arguments["includeStructure"] = true }
            if let digest = invocation.options["if-brief-digest"] { arguments["ifBriefDigest"] = digest }
            return success(commandName, try await runTool(client, name: "response_evidence_brief", arguments: arguments, invocation: invocation))
        case ["investigate", "compare"]:
            guard let baseline = invocation.options["baseline-sessions"], let candidate = invocation.options["candidate-sessions"] else {
                throw CLIError.invalidArguments("investigate compare requires --baseline-sessions and --candidate-sessions.")
            }
            var arguments: [String: Any] = [
                "baselineSessionIDs": baseline.split(separator: ",", omittingEmptySubsequences: false).map(String.init),
                "candidateSessionIDs": candidate.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            ]
            if let pointer = invocation.options["selection-pointer"] { arguments["selectionPointer"] = pointer }
            if let digest = invocation.options["if-brief-digest"] { arguments["ifBriefDigest"] = digest }
            return success(commandName, try await runTool(client, name: "investigation_compare_brief", arguments: arguments, invocation: invocation))
        case _ where command.count == 3 && command[0] == "session" && command[1] == "show":
            let sessionID = command[2]
            var arguments: [String: Any] = ["sessionID": sessionID]
            if invocation.flags.contains("include-headers") || invocation.flags.contains("include-response-headers") {
                arguments["includeHeaders"] = true
            }
            if invocation.flags.contains("include-query") { arguments["includeQuery"] = true }
            if invocation.flags.contains("include-body") { arguments["includeBody"] = true }
            if let source = invocation.options["body-source"] { arguments["bodySource"] = source }
            if let headerSource = invocation.options["header-source"] {
                arguments["headerSource"] = headerSource
            } else if invocation.flags.contains("include-response-headers") {
                arguments["headerSource"] = "both"
            }
            return success(commandName, try await runTool(client, name: "session_summary", arguments: arguments, invocation: invocation))
        case ["session", "end"]:
            let cleanup = try await runTool(client, name: "client_cleanup_status", arguments: [:], invocation: invocation)
            let payload = payloadObject(cleanup)
            guard payload?["isClean"] as? Bool == true else {
                throw CLIError.policyDenied("CLI cleanup is still required. Run `joesproxyctl cleanup status` and resolve the reported state before ending the session.")
            }
            try await client.endSession()
            return success(commandName, ["state": "terminated", "cleanupVerified": true])
        case ["sessions", "export"]:
            return try await exportSessions(client: client, invocation: invocation)
        case ["wait", "capture"]:
            return success(commandName, try await waitForCapture(client: client, invocation: invocation))
        case ["wait", "session"]:
            return success(commandName, try await waitForSession(client: client, invocation: invocation))
        case _ where command.count == 3 && command[0] == "wait" && command[1] == "operation":
            let operationID = command[2]
            return success(commandName, try await waitForOperation(client: client, operationID: operationID, invocation: invocation))
        case ["watch", "capture"]:
            try await watchCapture(client: client, invocation: invocation)
            return success(commandName, ["state": "ended"])
        case ["watch", "sessions"]:
            try await watchSessions(client: client, invocation: invocation)
            return success(commandName, ["state": "ended"])

        // MARK: - Advanced agentic diagnostics (AG-1..AG-6) and related tool families

        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeMediaCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case _ where command.count == 3 && command[0] == "media" && command[1] == "readiness":
            let sessionID = command[2]
            return success(commandName, try await runTool(client, name: "media_readiness", arguments: ["sessionID": sessionID], invocation: invocation))
        case _ where command.count == 3 && command[0] == "media" && command[1] == "summary":
            let sessionID = command[2]
            return success(commandName, try await runTool(client, name: "media_summary", arguments: ["sessionID": sessionID], invocation: invocation))
        case _ where command.count == 3 && command[0] == "media" && command[1] == "manifest":
            let sessionID = command[2]
            return success(commandName, try await runTool(client, name: "media_manifest_structure", arguments: ["sessionID": sessionID], invocation: invocation))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "codecs" && command[2] == "context":
            return success(commandName, try await runTool(
                client,
                name: "media_manifest_structure",
                arguments: ["sessionID": command[3]],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "codecs" && command[2] == "preview":
            // Compatibility alias: still calls the HLS CODECS adapter preview tool.
            var arguments: [String: Any] = [
                "sessionID": command[3],
                "edits": try CLIHLSCodecsArguments.edits(invocation: invocation),
                "matchMode": try CLIHLSCodecsArguments.matchMode(invocation: invocation)
            ]
            if let path = invocation.options["path"] {
                arguments["path"] = path
            }
            return success(commandName, try await runTool(
                client,
                name: "preview_hls_codecs_edit",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "hls" && command[1] == "codecs" && command[2] == "prepare-map-local":
            guard let previewDigest = invocation.options["preview-digest"], !previewDigest.isEmpty else {
                throw CLIError.invalidArguments("hls codecs prepare-map-local requires --preview-digest <digest>.")
            }
            var arguments: [String: Any] = ["hlsPreviewDigest": previewDigest]
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            let proposal = try await runTool(
                client,
                name: "propose_create_map_local",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl hls codecs apply-map-local <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "codecs" && command[2] == "apply-map-local":
            var arguments: [String: Any] = ["proposalToken": command[3]]
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            return success(commandName, try await runTool(
                client,
                name: "apply_create_map_local",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["hls", "fixture", "capabilities"]:
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_capabilities",
                arguments: [:],
                invocation: invocation
            ))
        case ["hls", "fixture", "profiles"]:
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_profiles_list",
                arguments: [:],
                invocation: invocation
            ))
        case ["hls", "fixture", "status"]:
            var arguments: [String: Any] = [:]
            if let runID = invocation.options["run-id"], !runID.isEmpty {
                arguments["runID"] = runID
            }
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_status",
                arguments: arguments,
                invocation: invocation
            ))
        case ["hls", "fixture", "window-preview"]:
            guard let runID = invocation.options["run-id"], !runID.isEmpty else {
                throw CLIError.invalidArguments("hls fixture window-preview requires --run-id <uuid>.")
            }
            guard let path = invocation.options["path"], !path.isEmpty else {
                throw CLIError.invalidArguments("hls fixture window-preview requires --path <rendition/stream.m3u8>.")
            }
            var arguments: [String: Any] = [
                "runID": runID,
                "path": path
            ]
            if let at = invocation.options["at"], !at.isEmpty {
                guard let elapsed = Double(at), elapsed >= 0 else {
                    throw CLIError.invalidArguments("hls fixture window-preview --at must be a non-negative number of seconds.")
                }
                arguments["elapsedSeconds"] = elapsed
            }
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_window_preview",
                arguments: arguments,
                invocation: invocation
            ))
        case ["hls", "fixture", "prepare-start"]:
            guard let profileID = invocation.options["profile-id"], !profileID.isEmpty else {
                throw CLIError.invalidArguments("hls fixture prepare-start requires --profile-id <id>.")
            }
            var arguments: [String: Any] = ["profileID": profileID]
            var playbackConfiguration: [String: Any] = [:]
            if let presentationMode = invocation.options["presentation-mode"] {
                playbackConfiguration["presentationMode"] = presentationMode
            }
            if let timeShiftMode = invocation.options["time-shift-mode"] {
                playbackConfiguration["timeShiftMode"] = timeShiftMode
            }
            if let value = invocation.options["window-segments"] {
                guard let count = Int(value) else {
                    throw CLIError.invalidArguments("--window-segments must be an integer from 2 through 30.")
                }
                playbackConfiguration["windowSegmentCount"] = count
            }
            if !playbackConfiguration.isEmpty {
                arguments["playbackConfiguration"] = playbackConfiguration
            }
            let proposal = try await runTool(
                client,
                name: "propose_hls_fixture_start",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            let proposalPayload = payloadObject(proposal) ?? [:]
            var prepareResult: [String: Any] = [
                "proposal": proposalPayload,
                "nextCommand": "joesproxyctl hls fixture apply-start <proposal-token> --wait-for-approval"
            ]
            if let baseURL = proposalPayload["baseURL"] {
                prepareResult["baseURL"] = baseURL
            }
            if let reservedHost = proposalPayload["reservedHost"] {
                prepareResult["reservedHost"] = reservedHost
            }
            return success(commandName, prepareResult)
        case ["hls", "substitute", "profiles"]:
            return success(commandName, try await runTool(
                client,
                name: "hls_substitution_profiles_list",
                arguments: [:],
                invocation: invocation
            ))
        case ["hls", "substitute", "prepare"]:
            guard let profileID = invocation.options["profile-id"], !profileID.isEmpty else {
                throw CLIError.invalidArguments("hls substitute prepare requires --profile-id <id>.")
            }
            let cliScope = invocation.options["scope"] ?? "selected"
            guard cliScope == "selected" || cliScope == "host" else {
                throw CLIError.invalidArguments("hls substitute prepare --scope must be selected or host.")
            }
            let scope = cliScope == "selected" ? "selectedPlaylist" : "host"
            var arguments: [String: Any] = [
                "profileID": profileID,
                "scope": scope,
                "conflictStrategy": invocation.flags.contains("replace-conflicts") ? "replaceExisting" : "cancel"
            ]
            var playbackConfiguration: [String: Any] = [:]
            if let value = invocation.options["presentation-mode"] {
                playbackConfiguration["presentationMode"] = value
            }
            if let value = invocation.options["time-shift-mode"] {
                playbackConfiguration["timeShiftMode"] = value
            }
            if let value = invocation.options["intent"] { playbackConfiguration["intent"] = value }
            if let value = invocation.options["window-segments"] {
                guard let count = Int(value) else {
                    throw CLIError.invalidArguments("--window-segments must be an integer from 2 through 30.")
                }
                playbackConfiguration["windowSegmentCount"] = count
            }
            if let value = invocation.options["loop-boundary"] {
                playbackConfiguration["loopBoundaryTreatment"] = value
            }
            if let value = invocation.options["segment-uri-identity"] {
                playbackConfiguration["segmentURIIdentity"] = value
            }
            if let value = invocation.options["target-duration"] {
                playbackConfiguration["targetDurationTreatment"] = value
            }
            if let value = invocation.options["program-date-time"] {
                playbackConfiguration["programDateTimeTreatment"] = value
            }
            if let value = invocation.options["playlist-cache"] {
                playbackConfiguration["playlistCachePolicy"] = value
            }
            if let value = invocation.options["playlist-max-age"] {
                guard let seconds = Int(value) else {
                    throw CLIError.invalidArguments("--playlist-max-age must be an integer from 0 through 60.")
                }
                playbackConfiguration["playlistMaxAgeSeconds"] = seconds
            }
            if !playbackConfiguration.isEmpty {
                arguments["playbackConfiguration"] = playbackConfiguration
            }
            if let ttl = invocation.options["ttl"], let ttlValue = Int(ttl) {
                arguments["ttlSeconds"] = ttlValue
            }
            if let sessionID = invocation.options["session-id"], !sessionID.isEmpty {
                arguments["sessionID"] = sessionID
            } else {
                guard let host = invocation.options["host"], !host.isEmpty else {
                    throw CLIError.invalidArguments("hls substitute prepare requires --session-id or --host.")
                }
                arguments["host"] = host
                arguments["scheme"] = invocation.options["scheme"] ?? "https"
                if let port = invocation.options["port"], let parsed = Int(port) {
                    arguments["port"] = parsed
                }
                if scope == "selectedPlaylist" {
                    guard let path = invocation.options["path"], !path.isEmpty else {
                        throw CLIError.invalidArguments("selectedPlaylist scope requires --path when --session-id is omitted.")
                    }
                    arguments["path"] = path
                }
            }
            let proposal = try await runTool(
                client,
                name: "propose_hls_substitution_start",
                arguments: arguments.merging([
                    "sourceClientAddress": invocation.options["source-client-address"],
                    "missingTextTrackID": invocation.options["missing-text-track-id"]
                ].compactMapValues { $0 }) { _, new in new },
                invocation: invocation,
                retryOnStaleSession: false
            )
            let proposalPayload = payloadObject(proposal) ?? [:]
            return success(commandName, [
                "proposal": proposalPayload,
                "nextCommand": "joesproxyctl hls substitute apply <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "substitute" && command[2] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_hls_substitution_start",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["hls", "substitute", "status"]:
            var arguments: [String: Any] = [:]
            if let experimentID = invocation.options["experiment-id"], !experimentID.isEmpty {
                arguments["experimentID"] = experimentID
            }
            return success(commandName, try await runTool(
                client,
                name: "hls_substitution_status",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "substitute" && command[2] == "status":
            return success(commandName, try await runTool(
                client,
                name: "hls_substitution_status",
                arguments: ["experimentID": command[3]],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "substitute" && command[2] == "stop":
            return success(commandName, try await runTool(
                client,
                name: "hls_substitution_stop",
                arguments: ["experimentID": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "substitute" && command[2] == "extend":
            var arguments: [String: Any] = ["experimentID": command[3]]
            if let ttl = invocation.options["ttl"], let ttlValue = Int(ttl) {
                arguments["ttlSeconds"] = ttlValue
            }
            return success(commandName, try await runTool(
                client,
                name: "hls_substitution_extend",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "fixture" && command[2] == "apply-start":
            return success(commandName, try await runTool(
                client,
                name: "apply_hls_fixture_start",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "hls" && command[1] == "fixture" && command[2] == "stop":
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_stop",
                arguments: ["runID": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["hls", "fixture", "stop"]:
            guard let runID = invocation.options["run-id"], !runID.isEmpty else {
                throw CLIError.invalidArguments("hls fixture stop requires --run-id <uuid> or hls fixture stop <run-id>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "hls_fixture_stop",
                arguments: ["runID": runID],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "media" && command[1] == "related":
            let sessionID = command[2]
            var arguments: [String: Any] = ["sessionID": sessionID]
            addPagination(invocation, to: &arguments)
            return success(commandName, try await runTool(client, name: "media_related_sessions", arguments: arguments, invocation: invocation))
        case _ where command.count == 3 && command[0] == "media" && command[1] == "inspect":
            let sessionID = command[2]
            guard let analysis = invocation.options["analysis"] else {
                throw CLIError.invalidArguments("media inspect requires --analysis <kind[,kind]>.")
            }
            var arguments: [String: Any] = [
                "sessionID": sessionID,
                "analyses": analysis.split(separator: ",").map(String.init)
            ]
            if let sample = invocation.options["sample-time"], let value = Double(sample) {
                arguments["sampleTimeSeconds"] = value
            }
            return success(commandName, try await runTool(
                client,
                name: "media_inspection_start",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["media", "cmcd"]:
            guard let ids = invocation.options["session-ids"] else {
                throw CLIError.invalidArguments("media cmcd requires --session-ids <id,id,...>.")
            }
            return success(commandName, try await runTool(
                client, name: "cmcd_telemetry_inspection", arguments: ["sessionIDs": ids.split(separator: ",").map(String.init)], invocation: invocation
            ))
        case ["media", "webvtt"]:
            guard let sessionID = invocation.options["session-id"] else {
                throw CLIError.invalidArguments("media webvtt requires --session-id <uuid>.")
            }
            var arguments: [String: Any] = ["sessionID": sessionID]
            if let reference = invocation.options["reference-session"] { arguments["referenceVideoSessionID"] = reference }
            return success(commandName, try await runTool(client, name: "webvtt_subtitle_inspection", arguments: arguments, invocation: invocation))
        case ["media", "drm"]:
            var arguments: [String: Any] = [:]
            if let manifest = invocation.options["manifest-session"] { arguments["manifestSessionID"] = manifest }
            if let licenses = invocation.options["license-sessions"] {
                arguments["licenseSessionIDs"] = licenses.split(separator: ",").map(String.init)
            }
            if let media = invocation.options["media-sessions"] {
                arguments["mediaSessionIDs"] = media.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "drm_handshake_inspection", arguments: arguments, invocation: invocation))
        case ["media", "byte-range"]:
            var arguments: [String: Any] = [:]
            if let ids = invocation.options["session-ids"] {
                arguments["sessionIDs"] = ids.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "byte_range_efficiency_inspection", arguments: arguments, invocation: invocation))
        case ["media", "waterfall"]:
            guard let sessionID = invocation.options["session-id"] else {
                throw CLIError.invalidArguments("media waterfall requires --session-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "streaming_waterfall_inspection", arguments: ["sessionID": sessionID], invocation: invocation))
        case ["media", "visual"]:
            guard let sessionID = invocation.options["session-id"] else {
                throw CLIError.invalidArguments("media visual requires --session-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "visual_asset_inspection", arguments: ["sessionID": sessionID], invocation: invocation))
        case ["media", "scte35"]:
            guard let masterSession = invocation.options["master-session"] else {
                throw CLIError.invalidArguments("media scte35 requires --master-session <uuid>.")
            }
            var arguments: [String: Any] = ["masterManifestSessionID": masterSession]
            if let variants = invocation.options["variant-sessions"] {
                arguments["variantSessionIDs"] = variants.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "scte35_ad_break_inspection", arguments: arguments, invocation: invocation))

        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeAuthoringCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case ["openapi", "pack", "import"]:
            let arguments = try openAPIPackArguments(from: invocation, requireHost: false)
            return success(commandName, try await runTool(
                client,
                name: "openapi_pack_preview",
                arguments: arguments,
                invocation: invocation
            ))
        case ["openapi", "pack", "prepare"]:
            let arguments = try openAPIPackArguments(from: invocation, requireHost: true)
            let proposal = try await runTool(
                client,
                name: "propose_openapi_pack_start",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            let proposalPayload = payloadObject(proposal) ?? [:]
            return success(commandName, [
                "proposal": proposalPayload,
                "nextCommand": "joesproxyctl openapi pack apply <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "openapi" && command[1] == "pack" && command[2] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_openapi_pack_start",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["openapi", "pack", "status"]:
            var arguments: [String: Any] = [:]
            if let packID = invocation.options["pack-id"], !packID.isEmpty {
                arguments["packID"] = packID
            }
            return success(commandName, try await runTool(
                client,
                name: "openapi_pack_status",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "openapi" && command[1] == "pack" && command[2] == "status":
            return success(commandName, try await runTool(
                client,
                name: "openapi_pack_status",
                arguments: ["packID": command[3]],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "openapi" && command[1] == "pack" && command[2] == "stop":
            return success(commandName, try await runTool(
                client,
                name: "openapi_pack_stop",
                arguments: ["packID": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where (command.count == 3 && command[0] == "openapi" && command[1] == "validate") || (command.count == 2 && command[0] == "openapi" && command[1] == "validate"):
            let sessionID = command.count == 3 ? command[2] : (invocation.options["session-id"] ?? invocation.options["id"])
            guard let validID = sessionID, !validID.isEmpty else {
                throw CLIError.invalidArguments("openapi validate requires a session UUID: joesproxyctl openapi validate <session-id>")
            }
            return success(commandName, try await runTool(
                client,
                name: "openapi_validate_session",
                arguments: ["sessionID": validID],
                invocation: invocation
            ))
        case ["openapi", "mock"]:
            guard let pathTemplate = invocation.options["path"] ?? invocation.options["path-template"] else {
                throw CLIError.invalidArguments("openapi mock requires --path <template> (e.g. --path /users/{id})")
            }
            var args: [String: Any] = ["pathTemplate": pathTemplate]
            if let method = invocation.options["method"] { args["method"] = method }
            if let status = invocation.options["status"] ?? invocation.options["status-code"] { args["statusCode"] = status }
            if let mode = invocation.options["mode"] { args["mode"] = mode }
            return success(commandName, try await runTool(
                client,
                name: "openapi_generate_mock",
                arguments: args,
                invocation: invocation
            ))
        case ["openapi", "import"]:
            guard let filePath = invocation.options["file"] else {
                throw CLIError.invalidArguments("openapi import requires --file <path>")
            }
            let fileURL = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            let fileData = try Data(contentsOf: fileURL)
            return success(commandName, try await runTool(
                client,
                name: "openapi_import_spec",
                arguments: ["specBase64": fileData.base64EncodedString()],
                invocation: invocation
            ))
        case _ where command.count >= 2 && command[0] == "mocker" && command[1] == "export":
            var args: [String: Any] = [:]
            if command.count > 2 {
                args["sessionID"] = command[2]
            } else if let sessionID = invocation.options["session"] ?? invocation.options["id"] {
                args["sessionID"] = sessionID
            }
            if let framework = invocation.options["framework"] { args["framework"] = framework }
            if let fixtureMode = invocation.options["fixture-mode"] { args["fixtureMode"] = fixtureMode }
            if let className = invocation.options["class-name"] { args["testClassName"] = className }
            let toolResult = try await runTool(
                client,
                name: "mocker_export_suite",
                arguments: args,
                invocation: invocation
            )
            if let outputPath = invocation.options["output"], let payload = toolResult as? [String: Any], let swiftCode = payload["swiftSourceCode"] as? String {
                let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
                try swiftCode.write(to: outputURL, atomically: true, encoding: .utf8)
            }
            return success(commandName, toolResult)
        case _ where command.count >= 2 && command[0] == "mocker" && command[1] == "validate":
            guard let fixturePath = invocation.options["fixture"] else {
                throw CLIError.invalidArguments("mocker validate requires --fixture <path>")
            }
            let sessionID: String
            if command.count > 2 {
                sessionID = command[2]
            } else if let optSession = invocation.options["session"] ?? invocation.options["id"] {
                sessionID = optSession
            } else {
                throw CLIError.invalidArguments("mocker validate requires <session-id> or --session <id>")
            }
            let fixtureURL = URL(fileURLWithPath: (fixturePath as NSString).expandingTildeInPath)
            let fixtureData = try Data(contentsOf: fixtureURL)
            return success(commandName, try await runTool(
                client,
                name: "mocker_validate_fixture",
                arguments: [
                    "sessionID": sessionID,
                    "fixtureBase64": fixtureData.base64EncodedString()
                ],
                invocation: invocation
            ))
        case ["mock", "start"]:
            guard let configPath = invocation.options["config"] else {
                throw CLIError.invalidArguments("mock start requires --config <path>")
            }
            let configURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir), isDir.boolValue {
                return success(commandName, ["state": "active", "directory": configURL.path, "mode": "localDirectory"])
            } else {
                let configData = try Data(contentsOf: configURL)
                let json = (try? JSONSerialization.jsonObject(with: configData) as? [String: Any]) ?? [:]
                return success(commandName, ["state": "active", "file": configURL.path, "rulesCount": (json["rules"] as? [Any])?.count ?? 1])
            }
        case ["mock", "stop"]:
            return success(commandName, try await runTool(
                client,
                name: "clear_active_mutations",
                arguments: [:],
                invocation: invocation
            ))
        case ["effect", "bundle", "compare"]:
            guard let baseline = invocation.options["baseline-window-id"], let modified = invocation.options["modified-window-id"] else {
                throw CLIError.invalidArguments("effect bundle compare --baseline-window-id <UUID> --modified-window-id <UUID>")
            }
            return success(commandName, try await runTool(client, name: "effect_bundle_compare",
                arguments: ["baselineWindowID": baseline, "modifiedWindowID": modified], invocation: invocation))
        case _ where command.count == 3 && command[0] == "effect" && command[1] == "bundle" && command[2] == "list":
            return success(commandName, try await runTool(
                client,
                name: "effect_bundle_list",
                arguments: [:],
                invocation: invocation
            ))

        case _ where command.count >= 3 && command[0] == "effect" && command[1] == "bundle" && command[2] == "inspect":
            var args: [String: Any] = [:]
            if let revisionID = invocation.options["revision-id"] {
                guard command.count == 3, invocation.options["file"] == nil,
                      invocation.options["package"] == nil, invocation.options["bundle-id"] == nil,
                      UUID(uuidString: revisionID) != nil else {
                    throw CLIError.invalidArguments("Use effect bundle inspect --revision-id <UUID> without another target.")
                }
                args["revisionID"] = revisionID
            } else if command.count == 4 {
                args["bundleID"] = command[3]
            } else if let bundleID = invocation.options["bundle-id"] {
                args["bundleID"] = bundleID
            } else if let file = invocation.options["file"] ?? invocation.options["package"] {
                args["packagePath"] = file
            } else {
                throw CLIError.invalidArguments("effect bundle inspect requires --file <path> or <bundle-id>.")
            }
            if let marker = invocation.options["after-marker"] {
                guard args["bundleID"] != nil, UInt64(marker) != nil else {
                    throw CLIError.invalidArguments("Use --after-marker <unsigned decimal> with a retained bundle ID.")
                }
                args["afterMarker"] = marker
            }
            return success(commandName, try await runTool(
                client,
                name: "effect_bundle_inspect",
                arguments: args,
                invocation: invocation
            ))

        case ["effect", "bundle", "retire-preparation"]:
            guard let id = invocation.options["revision-id"], UUID(uuidString: id) != nil else {
                throw CLIError.invalidArguments("effect bundle retire-preparation requires --revision-id <UUID>.")
            }
            return success(commandName, try await runTool(client, name: "effect_bundle_retire_preparation",
                arguments: ["revisionID": id], invocation: invocation))

        case ["effect", "bundle", "prepare"]:
            guard let sessionID = invocation.options["session-id"], UUID(uuidString: sessionID) != nil,
                  let name = invocation.options["name"], let key = invocation.options["idempotency-key"],
                  let address = invocation.options["client-address"], let draft = invocation.options["draft"] else {
                throw CLIError.invalidArguments("effect bundle prepare requires --session-id <UUID> --name <name> --idempotency-key <key> --client-address <address> --draft <JSON>.")
            }
            var preparationArguments: [String: Any] = [
                "sessionID": sessionID, "name": name, "idempotencyKey": key,
                "clientAddress": address, "draftJSON": draft
            ]
            if let related = invocation.options["related-responses"] {
                guard related.utf8.count <= 65_536 else {
                    throw CLIError.invalidArguments("--related-responses must not exceed 64 KiB.")
                }
                preparationArguments["relatedResponsesJSON"] = related
            }
            if let images = invocation.options["images"] {
                guard !["image-file", "image-pointer", "retain-image-url", "image-delivery-url", "image-reference"]
                    .contains(where: { invocation.options[$0] != nil }) else {
                    throw CLIError.invalidArguments("Use --images or the single-image options, not both.")
                }
                preparationArguments["images"] = try CLIImageBindings.prepare(images)
            } else if let file = invocation.options["image-file"] {
                guard let pointer = invocation.options["image-pointer"] else {
                    throw CLIError.invalidArguments("--image-file requires --image-pointer <JSON Pointer>.")
                }
                let url = URL(fileURLWithPath: file)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CLIError.invalidArguments("--image-file must select a regular, non-symlink file.")
                }
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                var binding: [String: Any] = ["itemPointer": pointer, "localFileBookmarkRef": bookmark.base64EncodedString()]
                if let original = invocation.options["retain-image-url"] { binding["originalURL"] = original }
                if invocation.options["image-delivery-url"] != nil || invocation.options["image-reference"] != nil {
                    guard let delivery = invocation.options["image-delivery-url"],
                          let reference = invocation.options["image-reference"], binding["originalURL"] == nil else {
                        throw CLIError.invalidArguments("Use --image-delivery-url <absolute HTTP(S) URL> and --image-reference <relative JSON value> together, without --retain-image-url.")
                    }
                    binding["deliveryURL"] = delivery
                    binding["imageReference"] = reference
                }
                preparationArguments["images"] = [binding]
            } else if ["image-pointer", "retain-image-url", "image-delivery-url", "image-reference"].contains(where: { invocation.options[$0] != nil }) {
                throw CLIError.invalidArguments("Image options require --image-file.")
            }
            return success(commandName, try await runTool(client, name: "effect_bundle_prepare",
                arguments: preparationArguments, invocation: invocation))

        case _ where command.count >= 3 && command[0] == "effect" && command[1] == "bundle" && command[2] == "import":
            if let revisionID = invocation.options["revision-id"] {
                guard command.count == 3, invocation.options["file"] == nil,
                      invocation.options["package"] == nil, UUID(uuidString: revisionID) != nil else {
                    throw CLIError.invalidArguments("Use effect bundle import --revision-id <UUID> without a package path.")
                }
                return success(commandName, try await runTool(client, name: "effect_bundle_import",
                    arguments: ["revisionID": revisionID], invocation: invocation))
            }
            let file: String
            if command.count == 4 {
                file = command[3]
            } else if let optFile = invocation.options["file"] ?? invocation.options["package"] {
                file = optFile
            } else {
                throw CLIError.invalidArguments("effect bundle import requires --file <path> or <path>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "effect_bundle_import",
                arguments: ["packagePath": file],
                invocation: invocation
            ))

        case _ where command.count >= 4 && command[0] == "effect" && command[1] == "bundle" && command[2] == "activate" && command[3] == "prepare":
            let bundleID: String
            if command.count == 5 {
                bundleID = command[4]
            } else if let optID = invocation.options["bundle-id"] {
                bundleID = optID
            } else {
                throw CLIError.invalidArguments("effect bundle activate prepare requires <bundle-id>.")
            }
            var args: [String: Any] = ["bundleID": bundleID]
            if let ttl = invocation.options["ttl"], let ttlVal = Double(ttl) {
                args["ttlSeconds"] = ttlVal
            }
            if invocation.options["replace-conflicts"] != nil {
                args["replaceConflicts"] = true
            }
            return success(commandName, try await runTool(
                client,
                name: "propose_activate_effect_bundle",
                arguments: args,
                invocation: invocation
            ))

        case _ where command.count >= 4 && command[0] == "effect" && command[1] == "bundle" && command[2] == "activate" && command[3] == "apply":
            let token: String
            if command.count == 5 {
                token = command[4]
            } else if let optToken = invocation.options["token"] {
                token = optToken
            } else {
                throw CLIError.invalidArguments("effect bundle activate apply requires <proposal-token>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "apply_activate_effect_bundle",
                arguments: ["proposalToken": token],
                invocation: invocation
            ))

        case _ where command.count >= 3 && command[0] == "effect" && command[1] == "bundle" && command[2] == "advance":
            guard command.count == 4, UUID(uuidString: command[3]) != nil,
                  let activation = invocation.options["activation-id"], UUID(uuidString: activation) != nil,
                  let phase = invocation.options["expected-phase-id"], UUID(uuidString: phase) != nil else {
                throw CLIError.invalidArguments("effect bundle advance <bundle-id> --activation-id <UUID> --expected-phase-id <UUID>; inspect the active bundle first.")
            }
            return success(commandName, try await runTool(client, name: "effect_bundle_advance",
                arguments: ["bundleID": command[3], "activationID": activation, "expectedPhaseID": phase], invocation: invocation))

        case _ where command.count >= 3 && command[0] == "effect" && command[1] == "bundle" && command[2] == "stop":
            let bundleID: String
            if command.count == 4 {
                bundleID = command[3]
            } else if let optID = invocation.options["bundle-id"] {
                bundleID = optID
            } else {
                throw CLIError.invalidArguments("effect bundle stop requires <bundle-id>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "effect_bundle_stop",
                arguments: ["bundleID": bundleID],
                invocation: invocation
            ))

        case _ where command.count >= 4 && command[0] == "effect" && command[1] == "bundle" && command[2] == "discard" && command[3] == "prepare":
            let bundleID: String
            if command.count == 5 {
                bundleID = command[4]
            } else if let optID = invocation.options["bundle-id"] {
                bundleID = optID
            } else {
                throw CLIError.invalidArguments("effect bundle discard prepare requires <bundle-id>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "propose_discard_effect_bundle",
                arguments: ["bundleID": bundleID],
                invocation: invocation
            ))

        case _ where command.count >= 4 && command[0] == "effect" && command[1] == "bundle" && command[2] == "discard" && command[3] == "apply":
            let token: String
            if command.count == 5 {
                token = command[4]
            } else if let optToken = invocation.options["token"] {
                token = optToken
            } else {
                throw CLIError.invalidArguments("effect bundle discard apply requires <proposal-token>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "apply_discard_effect_bundle",
                arguments: ["proposalToken": token],
                invocation: invocation
            ))

        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeEffectsCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case ["block", "prepare"]:
            guard let method = invocation.options["method"], !method.isEmpty,
                  let host = invocation.options["host"], !host.isEmpty,
                  let path = invocation.options["path"], !path.isEmpty else {
                throw CLIError.invalidArguments("block prepare requires --method, --host, and --path.")
            }
            var blockArguments: [String: Any] = [
                "method": method,
                "host": host,
                "path": path,
                "matchMode": invocation.options["match-mode"] ?? "pathPrefix"
            ]
            if let scheme = invocation.options["scheme"] { blockArguments["scheme"] = scheme }
            if let port = invocation.options["port"], let value = Int(port) { blockArguments["port"] = value }
            if let statusCode = invocation.options["status-code"], let value = Int(statusCode) {
                blockArguments["statusCode"] = value
            }
            if invocation.flags.contains("drop-connection") {
                blockArguments["dropConnection"] = true
            }
            if let opName = invocation.options["graphql-operation-name"] {
                blockArguments["graphqlOperationName"] = opName
            }
            if let queryKey = invocation.options["match-query-key"] {
                blockArguments["matchQueryKey"] = queryKey
            }
            if let queryValue = invocation.options["match-query-value"] {
                blockArguments["matchQueryValue"] = queryValue
            }
            if let sourceClientAddress = invocation.options["source-client-address"] {
                blockArguments["sourceClientAddress"] = sourceClientAddress
            }
            let proposal = try await runTool(
                client,
                name: "propose_create_block",
                arguments: blockArguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl block apply <proposal-token> [--enable-after] [--wait-for-approval]"
            ])
        case _ where command.count == 3 && command[0] == "block" && command[1] == "apply":
            var applyArguments: [String: Any] = ["proposalToken": command[2]]
            if invocation.flags.contains("enable-after") {
                applyArguments["enableAfterApply"] = true
            }
            return success(commandName, try await runTool(
                client,
                name: "apply_create_block",
                arguments: applyArguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["bookmark", "create"]:
            guard let method = invocation.options["method"], !method.isEmpty,
                  let host = invocation.options["host"], !host.isEmpty,
                  let path = invocation.options["path"], !path.isEmpty,
                  let name = invocation.options["name"], !name.isEmpty else {
                throw CLIError.invalidArguments("bookmark create requires --method, --host, --path, and --name.")
            }
            var bookmarkArguments: [String: Any] = [
                "method": method,
                "host": host,
                "path": path,
                "name": name
            ]
            if let scheme = invocation.options["scheme"] { bookmarkArguments["scheme"] = scheme }
            if let port = invocation.options["port"], let value = Int(port) { bookmarkArguments["port"] = value }
            if let matchMode = invocation.options["match-mode"] { bookmarkArguments["matchMode"] = matchMode }
            let bookmarkProposal = try await runTool(
                client,
                name: "propose_create_bookmark",
                arguments: bookmarkArguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(bookmarkProposal) ?? [:],
                "nextCommand": "joesproxyctl bookmark apply <proposal-token> [--wait-for-approval]"
            ])
        case _ where command.count == 3 && command[0] == "bookmark" && command[1] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_create_bookmark",
                arguments: ["proposalToken": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["bookmark", "list"]:
            var bookmarkListArguments: [String: Any] = [:]
            addPagination(invocation, to: &bookmarkListArguments)
            bookmarkListArguments["projection"] = invocation.options["projection"] ?? "minimal"
            return success(commandName, try await runTool(
                client,
                name: "bookmarks_list",
                arguments: bookmarkListArguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "bookmark" && command[1] == "get":
            return success(commandName, try await runTool(
                client,
                name: "bookmark_get",
                arguments: ["bookmarkID": command[2]],
                invocation: invocation
            ))
        case ["rule", "list"]:
            var ruleListArguments: [String: Any] = [:]
            addPagination(invocation, to: &ruleListArguments)
            ruleListArguments["projection"] = invocation.options["projection"] ?? "minimal"
            if let sourceKind = invocation.options["source-kind"], !sourceKind.isEmpty {
                ruleListArguments["sourceKind"] = sourceKind
            }
            return success(commandName, try await runTool(
                client,
                name: "overrides_list",
                arguments: ruleListArguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "get":
            return success(commandName, try await runTool(
                client,
                name: "override_get",
                arguments: ["overrideID": command[2]],
                invocation: invocation
            ))
        case ["throttle", "prepare"]:
            var throttleArguments: [String: Any] = ["isEnabled": true]
            if let presetID = invocation.options["preset-id"], !presetID.isEmpty {
                throttleArguments["selectedPresetID"] = presetID
            }
            let proposal = try await runTool(
                client,
                name: "propose_change_throttle",
                arguments: throttleArguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl throttle apply <proposal-token> [--wait-for-approval]"
            ])
        case _ where command.count == 3 && command[0] == "throttle" && command[1] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_change_throttle",
                arguments: ["proposalToken": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["throttle", "disable"]:
            let proposal = try await runTool(
                client,
                name: "propose_change_throttle",
                arguments: ["isEnabled": false],
                invocation: invocation,
                retryOnStaleSession: false
            )
            let proposalPayload = payloadObject(proposal) ?? [:]
            guard let proposalToken = proposalPayload["proposalToken"] as? String, !proposalToken.isEmpty else {
                throw CLIError.malformedResponse("throttle disable did not return a proposalToken.")
            }
            return success(commandName, try await runTool(
                client,
                name: "apply_change_throttle",
                arguments: ["proposalToken": proposalToken],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "enable":
            var arguments: [String: Any] = ["overrideID": command[2]]
            if invocation.flags.contains("accept-confounder") {
                arguments["acceptConfounder"] = true
            }
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            let proposal = try await runTool(
                client,
                name: "propose_enable_rule",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl rule apply-enable <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "apply-enable":
            var arguments: [String: Any] = ["proposalToken": command[2]]
            if invocation.flags.contains("accept-confounder") {
                arguments["acceptConfounder"] = true
            }
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            return success(commandName, try await runTool(
                client,
                name: "apply_enable_rule",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "disable":
            let proposal = try await runTool(
                client,
                name: "propose_disable_rule",
                arguments: ["overrideID": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl rule apply-disable <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "apply-disable":
            return success(commandName, try await runTool(
                client,
                name: "apply_disable_rule",
                arguments: ["proposalToken": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "delete":
            let proposal = try await runTool(
                client,
                name: "propose_delete_rule",
                arguments: ["overrideID": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl rule apply-delete <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 3 && command[0] == "rule" && command[1] == "apply-delete":
            return success(commandName, try await runTool(
                client,
                name: "apply_delete_rule",
                arguments: ["proposalToken": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "operation" && command[1] == "status":
            let operationID = command[2]
            var arguments: [String: Any] = ["operationID": operationID]
            arguments["projection"] = invocation.options["projection"] ?? "minimal"
            if invocation.flags.contains("include-result") { arguments["includeResult"] = true }
            return success(commandName, try await runTool(client, name: "operation_status", arguments: arguments, invocation: invocation))
        case _ where command.count == 3 && command[0] == "operation" && command[1] == "cancel":
            let operationID = command[2]
            return success(commandName, try await runTool(
                client,
                name: "operation_cancel",
                arguments: ["operationID": operationID],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "rewrite" && command[1] == "preview":
            let arguments = try CLILiveRewriteArguments.preview(invocation: invocation, sessionID: command[2])
            return success(commandName, try await runTool(
                client,
                name: "preview_live_rewrite",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "rewrite" && command[1] == "prepare":
            return success(commandName, try await prepareLiveRewrite(
                client: client,
                sessionID: command[2],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "rewrite" && command[1] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_create_live_rewrite",
                arguments: CLILiveRewriteArguments.apply(proposalToken: command[2], invocation: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "rewrite" && command[1] == "activate":
            var arguments: [String: Any] = ["overrideID": command[2]]
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            return success(commandName, try await runTool(
                client,
                name: "activate_live_rewrite",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "rewrite" && command[1] == "disable" && command[2] == "prepare":
            var arguments: [String: Any] = ["overrideID": command[3]]
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            return success(commandName, try await runTool(
                client,
                name: "propose_disable_rule",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "rewrite" && command[1] == "disable" && command[2] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_disable_rule",
                arguments: CLILiveRewriteArguments.apply(proposalToken: command[3], invocation: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "collection-mock" && command[1] == "preview":
            let arguments = try CLICollectionMockArguments.preview(invocation: invocation, sessionID: command[2])
            return success(commandName, try await runTool(
                client,
                name: "preview_collection_mock",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "collection-mock" && command[1] == "prepare":
            return success(commandName, try await prepareCollectionMock(
                client: client,
                sessionID: command[2],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "collection-mock" && command[1] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_create_collection_mock",
                arguments: CLICollectionMockArguments.apply(proposalToken: command[2], invocation: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "collection-mock" && command[1] == "activate":
            var arguments: [String: Any] = ["overrideID": command[2]]
            if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
            return success(commandName, try await runTool(
                client,
                name: "activate_collection_mock",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeResponseCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case _ where command.count == 3 && command[0] == "response" && command[1] == "context":
            return success(commandName, try await runTool(
                client,
                name: "response_context",
                arguments: ["sessionID": command[2]],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "response" && command[1] == "search":
            guard let text = invocation.options["text"], !text.isEmpty else {
                throw CLIError.invalidArguments("response search requires --text <literal>.")
            }
            var searchArgs: [String: Any] = ["sessionID": command[2], "find": text]
            if invocation.flags.contains("include-context") {
                searchArgs["includeContext"] = true
            }
            return success(commandName, try await runTool(
                client,
                name: "response_text_search",
                arguments: searchArgs,
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "response" && command[1] == "read":
            var readArgs: [String: Any] = ["sessionID": command[2]]
            if let offset = invocation.options["offset"], let value = Int(offset) {
                readArgs["byteOffset"] = value
            }
            if let length = invocation.options["length"], let value = Int(length) {
                readArgs["byteLength"] = value
            }
            return success(commandName, try await runTool(
                client,
                name: "response_text_read",
                arguments: readArgs,
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "response" && command[1] == "edit" && command[2] == "preview":
            var arguments: [String: Any] = [
                "sessionID": command[3],
                "edits": try CLIResponseEditArguments.edits(invocation: invocation),
                "matchMode": invocation.options["match-mode"] ?? "ignoreQuery"
            ]
            if let path = invocation.options["path"] {
                arguments["path"] = path
            }
            return success(commandName, try await runTool(
                client,
                name: "preview_response_edit",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 4 && command[0] == "response" && command[1] == "draft" && command[2] == "save":
            var arguments: [String: Any] = ["sessionID": command[3]]
            if let label = invocation.options["label"] {
                arguments["label"] = label
            }
            let proposal = try await runTool(
                client,
                name: "propose_create_response_draft",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl response draft apply-save <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "response" && command[1] == "draft" && command[2] == "apply-save":
            return success(commandName, try await runTool(
                client,
                name: "apply_create_response_draft",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "response" && command[1] == "draft" && command[2] == "list":
            return success(commandName, try await runTool(
                client,
                name: "response_drafts_list",
                arguments: [:],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "response" && command[1] == "draft" && command[2] == "get":
            return success(commandName, try await runTool(
                client,
                name: "response_draft_get",
                arguments: ["draftID": command[3]],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "response" && command[1] == "edit" && command[2] == "commit":
            guard let previewDigest = invocation.options["preview-digest"], !previewDigest.isEmpty else {
                throw CLIError.invalidArguments("response edit commit requires --preview-digest <digest>.")
            }
            guard let draftID = invocation.options["draft"], !draftID.isEmpty else {
                throw CLIError.invalidArguments("response edit commit requires --draft <draft-id>.")
            }
            let proposal = try await runTool(
                client,
                name: "propose_commit_response_edit",
                arguments: [
                    "draftID": draftID,
                    "responseEditPreviewDigest": previewDigest
                ],
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl response edit apply-commit <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "response" && command[1] == "edit" && command[2] == "apply-commit":
            return success(commandName, try await runTool(
                client,
                name: "apply_commit_response_edit",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "response" && command[1] == "map-local" && command[2] == "prepare":
            var arguments: [String: Any] = [:]
            if let sourceClientAddress = invocation.options["source-client-address"] {
                arguments["sourceClientAddress"] = sourceClientAddress
            }
            if let queryKey = invocation.options["match-query-key"] {
                arguments["matchQueryKey"] = queryKey
            }
            if let queryValue = invocation.options["match-query-value"] {
                arguments["matchQueryValue"] = queryValue
            }
            if let previewDigest = invocation.options["preview-digest"], !previewDigest.isEmpty {
                arguments["responseEditPreviewDigest"] = previewDigest
            }
            if let revision = invocation.options["revision"], !revision.isEmpty {
                arguments["responseRevisionID"] = revision
            }
            if let fixtureRunID = invocation.options["fixture-run-id"], !fixtureRunID.isEmpty {
                arguments["fixtureRunID"] = fixtureRunID
                // A fixture run has no captured session to derive a matcher from — the matcher
                // must be supplied directly (mirrors the MCP-facing propose_create_map_local
                // contract for this source kind: ADR-Streaming-Source-Redirect-To-Fixture.md).
                guard let method = invocation.options["method"], !method.isEmpty,
                      let host = invocation.options["host"], !host.isEmpty,
                      let path = invocation.options["path"], !path.isEmpty else {
                    throw CLIError.invalidArguments(
                        "response map-local prepare --fixture-run-id requires --method, --host, and --path."
                    )
                }
                arguments["method"] = method
                arguments["host"] = host
                arguments["path"] = path
                arguments["scheme"] = invocation.options["scheme"] ?? "https"
                arguments["matchMode"] = invocation.options["match-mode"] ?? "pathPrefix"
                if let port = invocation.options["port"], let portValue = Int(port) {
                    arguments["port"] = portValue
                }
                if let opName = invocation.options["graphql-operation-name"] {
                    arguments["graphqlOperationName"] = opName
                }
            }
            if let directoryPath = invocation.options["directory"], !directoryPath.isEmpty {
                // Mint an opaque bookmark on this Mac; MCP never receives a raw path. Plain (not
                // `.withSecurityScope`) is deliberate: JoesProxy.entitlements has no
                // `com.apple.security.app-sandbox` key, so neither this CLI binary nor the app
                // process is sandboxed, and a security-scoped bookmark minted here failed to
                // resolve across the CLI→app process boundary ("The file couldn't be opened
                // because it isn't in the correct format") — confirmed live 2026-08-10. A plain
                // bookmark still survives the directory being moved/renamed between propose and
                // apply, which is the actual reason to use a bookmark over a raw path at all.
                let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw CLIError.invalidArguments(
                        "response map-local prepare --directory must point at an existing directory."
                    )
                }
                let bookmarkData: Data
                do {
                    bookmarkData = try directoryURL.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    throw CLIError.invalidArguments(
                        "Could not create a bookmark for --directory: \(error.localizedDescription)"
                    )
                }
                arguments["localDirectoryBookmarkRef"] = bookmarkData.base64EncodedString()
                guard let method = invocation.options["method"], !method.isEmpty,
                      let host = invocation.options["host"], !host.isEmpty,
                      let path = invocation.options["path"], !path.isEmpty else {
                    throw CLIError.invalidArguments(
                        "response map-local prepare --directory requires --method, --host, and --path."
                    )
                }
                arguments["method"] = method
                arguments["host"] = host
                arguments["path"] = path
                arguments["scheme"] = invocation.options["scheme"] ?? "https"
                arguments["matchMode"] = invocation.options["match-mode"] ?? "pathPrefix"
                if let port = invocation.options["port"], let portValue = Int(port) {
                    arguments["port"] = portValue
                }
                if let notFound = invocation.options["not-found"], !notFound.isEmpty {
                    arguments["notFoundRelativePath"] = notFound
                }
                if invocation.flags.contains("force-no-cache") {
                    arguments["forceNoCache"] = true
                }
                if let missingFilePolicy = invocation.options["missing-file-policy"], !missingFilePolicy.isEmpty {
                    arguments["missingFilePolicy"] = missingFilePolicy
                }
                if let opName = invocation.options["graphql-operation-name"] {
                    arguments["graphqlOperationName"] = opName
                }
            }
            if let filePath = invocation.options["file"], !filePath.isEmpty {
                // Same plain-bookmark rationale as --directory above — see that comment.
                let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw CLIError.invalidArguments(
                        "response map-local prepare --file must point at an existing regular file."
                    )
                }
                let bookmarkData: Data
                do {
                    bookmarkData = try fileURL.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    throw CLIError.invalidArguments(
                        "Could not create a bookmark for --file: \(error.localizedDescription)"
                    )
                }
                arguments["localFileBookmarkRef"] = bookmarkData.base64EncodedString()
                guard let method = invocation.options["method"], !method.isEmpty,
                      let host = invocation.options["host"], !host.isEmpty,
                      let path = invocation.options["path"], !path.isEmpty else {
                    throw CLIError.invalidArguments(
                        "response map-local prepare --file requires --method, --host, and --path."
                    )
                }
                arguments["method"] = method
                arguments["host"] = host
                arguments["path"] = path
                arguments["scheme"] = invocation.options["scheme"] ?? "https"
                arguments["matchMode"] = invocation.options["match-mode"] ?? "exactPath"
                if let port = invocation.options["port"], let portValue = Int(port) {
                    arguments["port"] = portValue
                }
                if let statusCode = invocation.options["status-code"], let statusCodeValue = Int(statusCode) {
                    arguments["statusCode"] = statusCodeValue
                }
                if let contentType = invocation.options["content-type"], !contentType.isEmpty {
                    arguments["contentType"] = contentType
                }
                if invocation.flags.contains("force-no-cache") {
                    arguments["forceNoCache"] = true
                }
                if let opName = invocation.options["graphql-operation-name"] {
                    arguments["graphqlOperationName"] = opName
                }
            }
            guard arguments["responseEditPreviewDigest"] != nil
                || arguments["responseRevisionID"] != nil
                || arguments["fixtureRunID"] != nil
                || arguments["localDirectoryBookmarkRef"] != nil
                || arguments["localFileBookmarkRef"] != nil else {
                throw CLIError.invalidArguments(
                    "response map-local prepare requires --preview-digest <digest>, --revision <revision-id>, --fixture-run-id <uuid>, --directory <path>, or --file <path>."
                )
            }
            let proposal = try await runTool(
                client,
                name: "propose_create_map_local",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            let proposalPayload = payloadObject(proposal) ?? [:]
            var prepareResult: [String: Any] = [
                "proposal": proposalPayload,
                "nextCommand": invocation.flags.contains("enable-after")
                    ? "joesproxyctl response map-local apply <proposal-token> --enable-after --wait-for-approval"
                    : "joesproxyctl response map-local apply <proposal-token> --wait-for-approval"
            ]
            if let reloadURL = reloadURLHint(from: proposalPayload["matchScope"] as? [String: Any]) {
                prepareResult["reloadURL"] = reloadURL
                prepareResult["reloadHint"] = "Reload with \(reloadURL) after the rule is enabled (scheme/host/path must match)."
            }
            return success(commandName, prepareResult)
        case _ where command.count == 4 && command[0] == "response" && command[1] == "map-local" && command[2] == "apply":
            var applyArguments: [String: Any] = ["proposalToken": command[3]]
            if invocation.flags.contains("enable-after") {
                applyArguments["enableAfterApply"] = true
            }
            let created = try await runTool(
                client,
                name: "apply_create_map_local",
                arguments: applyArguments,
                invocation: invocation,
                retryOnStaleSession: false
            )
            let createPayload = payloadObject(created) ?? [:]
            guard invocation.flags.contains("enable-after") else {
                var applyResult: [String: Any] = createPayload
                applyResult["nextCommand"] = "joesproxyctl rule enable <override-id> then joesproxyctl rule apply-enable <proposal-token> --wait-for-approval"
                if let targetID = createPayload["targetID"] as? String {
                    applyResult["nextCommand"] = "joesproxyctl rule enable \(targetID) ; joesproxyctl rule apply-enable <proposal-token> --wait-for-approval"
                }
                return success(commandName, applyResult)
            }
            guard let overrideID = createPayload["targetID"] as? String, !overrideID.isEmpty else {
                throw CLIError.malformedResponse("apply_create_map_local did not return targetID for --enable-after.")
            }
            var guided: [String: Any] = createPayload
            guided["overrideID"] = overrideID
            guided["isEnabled"] = createPayload["isEnabled"] as? Bool ?? true
            // Reload hint previously came from propose_enable_rule's matchScope; fetch matcher via
            // read-only override_get so operators still get a concrete URL after the single apply.
            if let overridePayload = try? await runTool(
                client,
                name: "override_get",
                arguments: ["overrideID": overrideID],
                invocation: invocation,
                retryOnStaleSession: false
            ) {
                let summary = payloadObject(overridePayload) ?? [:]
                let matchScope: [String: Any] = [
                    "method": summary["method"] as Any,
                    "scheme": "https",
                    "host": summary["host"] as Any,
                    "path": summary["path"] as Any,
                    "matchMode": summary["matchMode"] as Any
                ]
                if let reloadURL = reloadURLHint(from: matchScope) {
                    guided["reloadURL"] = reloadURL
                    guided["reloadHint"] = "Reload with \(reloadURL) to verify the Map Local hit (scheme/host/path must match)."
                }
            }
            return success(commandName, guided)
        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeScenarioCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case ["run", "list"]:
            var arguments: [String: Any] = [:]
            if let limit = invocation.options["limit"], let value = Int(limit) {
                arguments["limit"] = value
            }
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_list",
                arguments: arguments,
                invocation: invocation
            ))
        case ["run", "create"]:
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_create",
                arguments: try diagnosticRunCreateArguments(from: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "start":
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_start",
                arguments: ["runID": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "brief":
            guard let baseline = invocation.options["baseline-window-id"], let modified = invocation.options["modified-window-id"] else {
                throw CLIError.invalidArguments("run brief requires --baseline-window-id and --modified-window-id.")
            }
            var arguments: [String: Any] = ["runID": command[2], "baselineWindowID": baseline, "modifiedWindowID": modified]
            if let digest = invocation.options["if-brief-digest"] { arguments["ifBriefDigest"] = digest }
            return success(commandName, try await runTool(client, name: "diagnostic_run_brief", arguments: arguments, invocation: invocation))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "status":
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_status",
                arguments: ["runID": command[2]],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "observations":
            var arguments: [String: Any] = ["runID": command[2]]
            if let limit = invocation.options["limit"], let value = Int(limit) {
                arguments["limit"] = value
            }
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_observations",
                arguments: arguments,
                invocation: invocation
            ))
        case _ where command.count == 4 && Array(command.prefix(3)) == ["run", "window", "begin"]:
            guard let bundle = invocation.options["bundle-id"], let mode = invocation.options["mode"], ["baseline", "modified"].contains(mode) else {
                throw CLIError.invalidArguments("run window begin <run-id> --bundle-id <UUID> --mode baseline|modified")
            }
            return success(commandName, try await runTool(client, name: "diagnostic_run_window_begin",
                arguments: ["runID": command[3], "bundleID": bundle, "mode": mode], invocation: invocation, retryOnStaleSession: false))
        case _ where command.count == 4 && Array(command.prefix(3)) == ["run", "window", "end"]:
            var arguments: [String: Any] = ["windowID": command[3]]
            arguments["targetOutcome"] = invocation.options["target-outcome"]
            arguments["outcomeSource"] = invocation.options["outcome-source"]
            return success(commandName, try await runTool(client, name: "diagnostic_run_window_end",
                arguments: arguments, invocation: invocation, retryOnStaleSession: false))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "close":
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_close",
                arguments: try diagnosticRunCloseArguments(runID: command[2], from: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "retry-cleanup":
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_retry_cleanup",
                arguments: ["runID": command[2]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["run", "evidence", "list"]:
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_evidence_list",
                arguments: [:],
                invocation: invocation
            ))
        case _ where command.count == 4 && command[0] == "run" && command[1] == "evidence" && command[2] == "get":
            return success(commandName, try await runTool(
                client,
                name: "diagnostic_run_evidence_get",
                arguments: ["evidenceID": command[3]],
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "run" && command[1] == "recheck" && command[2] == "prepare":
            guard let evidenceID = invocation.options["evidence-id"], !evidenceID.isEmpty else {
                throw CLIError.invalidArguments("run recheck prepare requires --evidence-id.")
            }
            let proposal = try await runTool(
                client,
                name: "propose_diagnostic_run_recheck",
                arguments: ["evidenceID": evidenceID],
                invocation: invocation,
                retryOnStaleSession: false
            )
            return success(commandName, [
                "proposal": payloadObject(proposal) ?? [:],
                "nextCommand": "joesproxyctl run recheck apply <proposal-token> --wait-for-approval"
            ])
        case _ where command.count == 4 && command[0] == "run" && command[1] == "recheck" && command[2] == "apply":
            return success(commandName, try await runTool(
                client,
                name: "apply_diagnostic_run_recheck",
                arguments: ["proposalToken": command[3]],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["scenario", "preview"]:
            return success(commandName, try await runScenarioTool(
                client,
                name: "preview_test_scenario",
                arguments: CLIScenarioArguments.draft(invocation: invocation),
                invocation: invocation
            ))
        case ["scenario", "draft"]:
            return success(commandName, try await runScenarioTool(
                client,
                name: "draft_test_scenario",
                arguments: CLIScenarioArguments.draft(invocation: invocation),
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "scenario" && command[1] == "validate":
            return success(commandName, try await runScenarioTool(
                client,
                name: "validate_test_scenario",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "scenario"
            && ["approve", "arm"].contains(command[1]):
            return success(commandName, try await runScenarioTool(
                client,
                name: "arm_test_scenario",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "scenario" && command[1] == "activate":
            return success(commandName, try await runScenarioTool(
                client,
                name: "activate_test_scenario",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "scenario"
            && ["observe", "observations"].contains(command[1]):
            return success(commandName, try await runScenarioTool(
                client,
                name: "get_test_observations",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "scenario"
            && ["assert", "evaluate"].contains(command[1]):
            return success(commandName, try await runScenarioTool(
                client,
                name: "evaluate_test_assertions",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "scenario" && command[1] == "report":
            return success(commandName, try await runScenarioTool(
                client,
                name: "get_test_report",
                arguments: try CLIScenarioArguments.identified(command[2], invocation: invocation),
                invocation: invocation
            ))
        case _ where command.count == 3 && command[0] == "scenario" && command[1] == "stop":
            return success(commandName, try await runScenarioTool(
                client,
                name: "stop_test_scenario",
                arguments: try CLIScenarioArguments.identified(
                    command[2],
                    invocation: invocation,
                    allowsOutcome: true
                ),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case _ where command.count == 3 && command[0] == "scenario" && command[1] == "cleanup":
            return success(commandName, try await runScenarioTool(
                client,
                name: "cleanup_test_scenario",
                arguments: try CLIScenarioArguments.identified(
                    command[2],
                    invocation: invocation,
                    allowsOutcome: true
                ),
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["certificate", "status"]:
            return success(commandName, try await runTool(client, name: "certificate_status", arguments: [:], invocation: invocation))
        case ["certificate", "identity"]:
            return success(commandName, try await runTool(client, name: "certificate_identity", arguments: [:], invocation: invocation))
        case ["certificate", "export"]:
            return try await exportCertificate(client: client, invocation: invocation)
        case ["certificate", "artifacts", "list"]:
            var arguments: [String: Any] = [:]
            if let fingerprint = invocation.options["fingerprint"] { arguments["fingerprint"] = fingerprint }
            return success(commandName, try await runTool(client, name: "certificate_artifacts_list", arguments: arguments, invocation: invocation))
        case ["certificate", "compare"]:
            guard let fingerprint = invocation.options["fingerprint"],
                  let other = invocation.options["other-fingerprint"] ?? invocation.options["with"] else {
                throw CLIError.invalidArguments("certificate compare requires --fingerprint <sha256> --other-fingerprint <sha256>.")
            }
            return success(commandName, try await runTool(
                client,
                name: "certificate_compare",
                arguments: ["fingerprint": fingerprint, "otherFingerprint": other],
                invocation: invocation
            ))
        case ["certificate", "cleanup", "prepare"]:
            guard let fingerprint = invocation.options["fingerprint"] else {
                throw CLIError.invalidArguments("certificate cleanup prepare requires --fingerprint <sha256>.")
            }
            var arguments: [String: Any] = ["fingerprint": fingerprint]
            if invocation.flags.contains("allow-current-root") { arguments["allowCurrentRoot"] = true }
            return success(commandName, try await runTool(
                client,
                name: "propose_certificate_cleanup",
                arguments: arguments,
                invocation: invocation
            ))
        case ["certificate", "cleanup", "apply"]:
            // The token carries the target fingerprint and the allowCurrentRoot decision made at
            // propose time; re-passing them here would not match the proposal's argument digest.
            guard let proposalToken = invocation.options["proposal-token"] else {
                throw CLIError.invalidArguments(
                    "certificate cleanup apply requires --proposal-token <token> from certificate cleanup prepare."
                )
            }
            return success(commandName, try await runTool(
                client,
                name: "apply_certificate_cleanup",
                arguments: ["proposalToken": proposalToken],
                invocation: invocation,
                retryOnStaleSession: false
            ))
        case ["cleanup", "status"]:
            return success(commandName, try await runTool(client, name: "client_cleanup_status", arguments: [:], invocation: invocation))
        case ["approvals", "list"]:
            return success(commandName, try await runTool(client, name: "approvals_list", arguments: [:], invocation: invocation))
        case ["repro", "export"]:
            return try await exportReproPackage(client: client, invocation: invocation)
        case ["repro", "inspect"]:
            return try await inspectReproPackage(client: client, invocation: invocation)
        case ["repro", "replay"]:
            return try await replayReproPackage(client: client, invocation: invocation)
        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func executeAnalysisCommands(_ invocation: CLIInvocation, client: MCPCLIClient) async throws -> CLIResultEnvelope {
        let command = invocation.command
        let commandName = command.joined(separator: " ")
        switch command {
        case ["hypothesis", "propose"]:
            guard let name = invocation.options["name"] else {
                throw CLIError.invalidArguments("hypothesis propose requires --name <text>.")
            }
            guard let targetBug = invocation.options["target-bug"] else {
                throw CLIError.invalidArguments("hypothesis propose requires --target-bug <text>.")
            }
            let nodeInputs = try CLIJSONArrayFileArguments.array(invocation: invocation, flag: "nodes", commandDescription: "hypothesis propose")
            return success(commandName, try await runTool(
                client, name: "propose_hypothesis_dag",
                arguments: ["name": name, "targetBug": targetBug, "nodeInputs": nodeInputs],
                invocation: invocation
            ))
        case ["hypothesis", "step"]:
            guard let graphID = invocation.options["graph-id"] else {
                throw CLIError.invalidArguments("hypothesis step requires --graph-id <uuid>.")
            }
            guard let summary = invocation.options["evidence-summary"] else {
                throw CLIError.invalidArguments("hypothesis step requires --evidence-summary <text>.")
            }
            return success(commandName, try await runTool(
                client, name: "step_hypothesis_graph",
                arguments: [
                    "graphID": graphID,
                    "evidenceMatches": invocation.flags.contains("evidence-matches"),
                    "evidenceSummary": summary
                ],
                invocation: invocation
            ))
        case ["hypothesis", "report"]:
            guard let graphID = invocation.options["graph-id"] else {
                throw CLIError.invalidArguments("hypothesis report requires --graph-id <uuid>.")
            }
            return success(commandName, try await runTool(
                client, name: "get_fault_bisection_report", arguments: ["graphID": graphID], invocation: invocation
            ))

        case ["llm", "stream", "inspect"]:
            var arguments: [String: Any] = [:]
            if let ids = invocation.options["session-ids"] {
                arguments["sessionIDs"] = ids.split(separator: ",").map(String.init)
            }
            if let canaries = invocation.options["canaries"] {
                arguments["configuredCanaries"] = canaries.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "llm_stream_inspection", arguments: arguments, invocation: invocation))
        case ["llm", "stream", "fault", "propose"]:
            guard let name = invocation.options["name"],
                  let urlPattern = invocation.options["url-pattern"],
                  let faultKind = invocation.options["fault-kind"] else {
                throw CLIError.invalidArguments("llm stream fault propose requires --name, --url-pattern, and --fault-kind.")
            }
            var arguments: [String: Any] = ["name": name, "urlPattern": urlPattern, "faultKind": faultKind]
            if let delay = invocation.options["delay-ms"] { arguments["delayMs"] = Int(delay) }
            if let index = invocation.options["target-token-index"] { arguments["targetTokenIndex"] = Int(index) }
            return success(commandName, try await runTool(client, name: "propose_llm_stream_fault", arguments: arguments, invocation: invocation))

        case ["fuzz", "permutation", "propose"]:
            guard let name = invocation.options["name"], let batch = invocation.options["target-batch"] else {
                throw CLIError.invalidArguments("fuzz permutation propose requires --name and --target-batch.")
            }
            let endpoints = try CLIJSONArrayFileArguments.array(invocation: invocation, flag: "endpoints", commandDescription: "fuzz permutation propose")
            var arguments: [String: Any] = ["name": name, "targetBatch": batch, "endpoints": endpoints]
            if let spacing = invocation.options["spacing-ms"] { arguments["spacingMs"] = Int(spacing) }
            return success(commandName, try await runTool(client, name: "propose_temporal_permutation_plan", arguments: arguments, invocation: invocation))
        case ["fuzz", "permutation", "step"]:
            guard let planID = invocation.options["plan-id"], let summary = invocation.options["outcome-summary"] else {
                throw CLIError.invalidArguments("fuzz permutation step requires --plan-id and --outcome-summary.")
            }
            return success(commandName, try await runTool(
                client, name: "step_temporal_permutation_plan",
                arguments: ["planID": planID, "errorDetected": invocation.flags.contains("error-detected"), "outcomeSummary": summary],
                invocation: invocation
            ))
        case ["fuzz", "permutation", "report"]:
            guard let planID = invocation.options["plan-id"] else {
                throw CLIError.invalidArguments("fuzz permutation report requires --plan-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "get_race_condition_fuzz_report", arguments: ["planID": planID], invocation: invocation))

        case ["resilience", "propose"]:
            guard let sessionID = invocation.options["session-id"] else {
                throw CLIError.invalidArguments("resilience propose requires --session-id <uuid>.")
            }
            var arguments: [String: Any] = ["sessionID": sessionID]
            if let name = invocation.options["name"] { arguments["name"] = name }
            return success(commandName, try await runTool(client, name: "propose_resilience_bisection_plan", arguments: arguments, invocation: invocation))
        case ["resilience", "step"]:
            guard let planID = invocation.options["plan-id"] else {
                throw CLIError.invalidArguments("resilience step requires --plan-id <uuid>.")
            }
            var arguments: [String: Any] = ["planID": planID, "clientCrashed": invocation.flags.contains("client-crashed")]
            if let observedError = invocation.options["observed-error"] { arguments["observedError"] = observedError }
            return success(commandName, try await runTool(client, name: "step_resilience_bisection_plan", arguments: arguments, invocation: invocation))
        case ["resilience", "report"]:
            guard let planID = invocation.options["plan-id"] else {
                throw CLIError.invalidArguments("resilience report requires --plan-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "get_resilience_matrix_report", arguments: ["planID": planID], invocation: invocation))

        case ["trajectory", "diff"]:
            guard let baseline = invocation.options["baseline-sessions"], let candidate = invocation.options["candidate-sessions"] else {
                throw CLIError.invalidArguments("trajectory diff requires --baseline-sessions and --candidate-sessions (comma-separated session IDs).")
            }
            var arguments: [String: Any] = [
                "baselineSessionIDs": baseline.split(separator: ",").map(String.init),
                "candidateSessionIDs": candidate.split(separator: ",").map(String.init)
            ]
            if let name = invocation.options["baseline-name"] { arguments["baselineName"] = name }
            if let name = invocation.options["candidate-name"] { arguments["candidateName"] = name }
            return success(commandName, try await runTool(client, name: "diff_session_trajectories", arguments: arguments, invocation: invocation))

        case ["semantic", "mock", "propose"]:
            guard let name = invocation.options["name"], let urlPattern = invocation.options["url-pattern"],
                  let intentLabel = invocation.options["intent-label"], let body = invocation.options["response-body"],
                  let queries = invocation.options["example-queries"] else {
                throw CLIError.invalidArguments("semantic mock propose requires --name, --url-pattern, --intent-label, --example-queries, and --response-body.")
            }
            var arguments: [String: Any] = [
                "name": name, "urlPattern": urlPattern, "intentLabel": intentLabel,
                "exampleQueries": queries.split(separator: ",").map(String.init), "mockResponseBody": body
            ]
            if let statusCode = invocation.options["status-code"] { arguments["mockStatusCode"] = Int(statusCode) }
            if let threshold = invocation.options["confidence-threshold"] { arguments["confidenceThreshold"] = Double(threshold) }
            return success(commandName, try await runTool(client, name: "propose_semantic_mock_rule", arguments: arguments, invocation: invocation))
        case ["semantic", "mock", "list"]:
            return success(commandName, try await runTool(client, name: "list_semantic_mock_rules", arguments: [:], invocation: invocation))
        case ["semantic", "mock", "test"]:
            guard let query = invocation.options["query"] else {
                throw CLIError.invalidArguments("semantic mock test requires --query <text>.")
            }
            var arguments: [String: Any] = ["query": query]
            if let targetURL = invocation.options["target-url"] { arguments["targetURL"] = targetURL }
            return success(commandName, try await runTool(client, name: "test_semantic_query_match", arguments: arguments, invocation: invocation))
        case ["semantic", "mock", "delete"]:
            guard let ruleID = invocation.options["rule-id"] else {
                throw CLIError.invalidArguments("semantic mock delete requires --rule-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "delete_semantic_mock_rule", arguments: ["ruleID": ruleID], invocation: invocation))

        case ["contract", "diff"]:
            guard let live = invocation.options["live-session"], let baseline = invocation.options["baseline-session"] else {
                throw CLIError.invalidArguments("contract diff requires --live-session and --baseline-session.")
            }
            return success(commandName, try await runTool(
                client, name: "contract_diff_sessions",
                arguments: ["liveSessionID": live, "baselineSessionID": baseline],
                invocation: invocation
            ))
        case ["contract", "regression"]:
            guard let live = invocation.options["live-sessions"], let baseline = invocation.options["baseline-sessions"] else {
                throw CLIError.invalidArguments("contract regression requires --live-sessions and --baseline-sessions (comma-separated).")
            }
            return success(commandName, try await runTool(
                client, name: "contract_regression_suite",
                arguments: [
                    "liveSessionIDs": live.split(separator: ",").map(String.init),
                    "baselineSessionIDs": baseline.split(separator: ",").map(String.init)
                ],
                invocation: invocation
            ))

        case ["lineage", "trace"]:
            guard let targetValue = invocation.options["target-value"] else {
                throw CLIError.invalidArguments("lineage trace requires --target-value <text>.")
            }
            var arguments: [String: Any] = ["targetValue": targetValue]
            if let candidates = invocation.options["candidate-sessions"] {
                arguments["candidateSessionIDs"] = candidates.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "trace_data_lineage", arguments: arguments, invocation: invocation))
        case ["lineage", "attribution"]:
            guard let sinkSession = invocation.options["sink-session"] else {
                throw CLIError.invalidArguments("lineage attribution requires --sink-session <uuid>.")
            }
            var arguments: [String: Any] = ["sinkSessionID": sinkSession]
            if let candidates = invocation.options["candidate-sessions"] {
                arguments["candidateSourceSessionIDs"] = candidates.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "audit_analytics_attribution", arguments: arguments, invocation: invocation))
        case ["lineage", "watermark", "propose"]:
            guard let name = invocation.options["name"], let urlPattern = invocation.options["url-pattern"],
                  let strategy = invocation.options["strategy"] else {
                throw CLIError.invalidArguments("lineage watermark propose requires --name, --url-pattern, and --strategy.")
            }
            var arguments: [String: Any] = ["name": name, "urlPattern": urlPattern, "strategy": strategy]
            if let keypaths = invocation.options["target-keypaths"] {
                arguments["targetKeypaths"] = keypaths.split(separator: ",").map(String.init)
            }
            return success(commandName, try await runTool(client, name: "propose_provenance_watermark", arguments: arguments, invocation: invocation))

        case ["localization", "presets"]:
            return success(commandName, try await runTool(client, name: "localization_mock_list_presets", arguments: [:], invocation: invocation))
        case ["localization", "preview"]:
            guard let sessionID = invocation.options["session-id"], let presetID = invocation.options["preset-id"] else {
                throw CLIError.invalidArguments("localization preview requires --session-id and --preset-id.")
            }
            var arguments: [String: Any] = ["sessionID": sessionID, "presetID": presetID]
            if invocation.flags.contains("no-preserve-urls") { arguments["preserveURLs"] = false }
            if invocation.flags.contains("no-preserve-ids") { arguments["preserveIDs"] = false }
            return success(commandName, try await runTool(client, name: "localization_mock_preview", arguments: arguments, invocation: invocation))

        case ["stateful", "backends"]:
            return success(commandName, try await runTool(client, name: "stateful_mock_list_backends", arguments: [:], invocation: invocation))
        case ["stateful", "presets"]:
            return success(commandName, try await runTool(client, name: "stateful_mock_list_presets", arguments: [:], invocation: invocation))
        case ["stateful", "install"]:
            guard let presetID = invocation.options["preset-id"] else {
                throw CLIError.invalidArguments("stateful install requires --preset-id <id>.")
            }
            var arguments: [String: Any] = ["presetID": presetID]
            if let host = invocation.options["custom-host"] { arguments["customHost"] = host }
            return success(commandName, try await runTool(client, name: "stateful_mock_install_preset", arguments: arguments, invocation: invocation))
        case ["stateful", "set-state"]:
            guard let backendID = invocation.options["backend-id"], let state = invocation.options["state"] else {
                throw CLIError.invalidArguments("stateful set-state requires --backend-id and --state.")
            }
            return success(commandName, try await runTool(
                client, name: "stateful_mock_set_state", arguments: ["backendID": backendID, "state": state], invocation: invocation
            ))
        case ["stateful", "entities"]:
            guard let backendID = invocation.options["backend-id"], let collection = invocation.options["collection"] else {
                throw CLIError.invalidArguments("stateful entities requires --backend-id and --collection.")
            }
            return success(commandName, try await runTool(
                client, name: "stateful_mock_query_entities", arguments: ["backendID": backendID, "collection": collection], invocation: invocation
            ))
        case ["stateful", "reset"]:
            guard let backendID = invocation.options["backend-id"] else {
                throw CLIError.invalidArguments("stateful reset requires --backend-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "stateful_mock_reset_backend", arguments: ["backendID": backendID], invocation: invocation))

        case ["isolate", "start"]:
            guard let sessionID = invocation.options["session-id"] else {
                throw CLIError.invalidArguments("isolate start requires --session-id <uuid>.")
            }
            var arguments: [String: Any] = ["sessionID": sessionID]
            if let window = invocation.options["window-seconds"] { arguments["windowSeconds"] = Double(window) }
            return success(commandName, try await runTool(client, name: "fault_isolation_start", arguments: arguments, invocation: invocation))
        case ["isolate", "step"]:
            guard let outcome = invocation.options["outcome"] else {
                throw CLIError.invalidArguments("isolate step requires --outcome <crashed|failed_assertion|succeeded|empty|unknown>.")
            }
            var arguments: [String: Any] = ["outcome": outcome]
            if let logSnippet = invocation.options["log-snippet"] { arguments["logSnippet"] = logSnippet }
            return success(commandName, try await runTool(client, name: "fault_isolation_record_step", arguments: arguments, invocation: invocation))
        case ["isolate", "report"]:
            return success(commandName, try await runTool(client, name: "fault_isolation_report", arguments: [:], invocation: invocation))
        case ["isolate", "cancel"]:
            return success(commandName, try await runTool(client, name: "fault_isolation_cancel", arguments: [:], invocation: invocation))

        case ["synthetic", "assets"]:
            return success(commandName, try await runTool(client, name: "list_synthetic_assets", arguments: [:], invocation: invocation))
        case ["synthetic", "inject"]:
            guard let name = invocation.options["name"], let urlPattern = invocation.options["url-pattern"] else {
                throw CLIError.invalidArguments("synthetic inject requires --name and --url-pattern.")
            }
            var arguments: [String: Any] = ["name": name, "urlPattern": urlPattern]
            if let keypath = invocation.options["collection-keypath"] { arguments["collectionKeypath"] = keypath }
            if let position = invocation.options["position"] { arguments["position"] = position }
            if let kind = invocation.options["bound-asset-kind"] { arguments["boundAssetKind"] = kind }
            if let customURL = invocation.options["custom-asset-url"] { arguments["customAssetURL"] = customURL }
            if let scope = invocation.options["client-scope"] { arguments["clientScope"] = scope }
            return success(commandName, try await runTool(client, name: "propose_inject_synthetic_item", arguments: arguments, invocation: invocation))
        case ["synthetic", "plans"]:
            return success(commandName, try await runTool(client, name: "list_synthetic_injection_plans", arguments: [:], invocation: invocation))
        case ["synthetic", "remove"]:
            guard let planID = invocation.options["plan-id"] else {
                throw CLIError.invalidArguments("synthetic remove requires --plan-id <uuid>.")
            }
            return success(commandName, try await runTool(client, name: "remove_synthetic_injection_plan", arguments: ["planID": planID], invocation: invocation))

        case ["instruments", "templates"], ["instruments", "list-templates"]:
            return success(commandName, try await runTool(
                client,
                name: "instruments_list_templates",
                arguments: [:],
                invocation: invocation
            ))
        case ["instruments", "record"]:
            var args: [String: Any] = [:]
            if let template = invocation.options["template"] { args["template"] = template }
            if let process = invocation.options["process"] { args["process"] = process }
            if let bundleID = invocation.options["bundle-id"] { args["bundleID"] = bundleID }
            if let device = invocation.options["device"] { args["device"] = device }
            if let duration = invocation.options["duration"], let d = Int(duration) { args["duration"] = d }
            return success(commandName, try await runTool(
                client,
                name: "instruments_record_trace",
                arguments: args,
                invocation: invocation
            ))
        case ["instruments", "analyze"]:
            guard let tracePath = invocation.options["trace"] ?? invocation.options["trace-path"] else {
                throw CLIError.invalidArguments("instruments analyze requires --trace <path>")
            }
            var args: [String: Any] = ["tracePath": tracePath]
            if let template = invocation.options["template"] { args["template"] = template }
            return success(commandName, try await runTool(
                client,
                name: "instruments_analyze_trace",
                arguments: args,
                invocation: invocation
            ))
        case ["instruments", "audit"]:
            var args: [String: Any] = [:]
            if let process = invocation.options["process"] { args["process"] = process }
            if let template = invocation.options["template"] { args["template"] = template }
            if let duration = invocation.options["duration"], let d = Int(duration) { args["duration"] = d }
            if let trace = invocation.options["trace"] ?? invocation.options["trace-path"] { args["tracePath"] = trace }
            return success(commandName, try await runTool(
                client,
                name: "instruments_correlated_audit",
                arguments: args,
                invocation: invocation
            ))

        // MARK: - Effect Bundle Commands
        default:
            throw CLIError.invalidArguments("Unknown command. Run `joesproxyctl help` for available commands.")
        }
    }

    private func makeClient(_ invocation: CLIInvocation) throws -> MCPCLIClient {
        guard let credential = try credentialStore.load(endpoint: invocation.endpointURL) else {
            throw CLIError.authenticationFailed("No CLI credential is stored. Enroll a JoesProxy CLI client, then run `joesproxyctl auth login`.")
        }
        let client = clientFactory(invocation.endpointURL, credential, sessionStore, invocation.timeout)
        client.receiptRecorder = receiptRecorder
        return client
    }

    private func requireCredential(_ invocation: CLIInvocation) throws {
        guard try credentialStore.load(endpoint: invocation.endpointURL) != nil else {
            throw CLIError.authenticationFailed(
                "No CLI credential is stored. Enroll a JoesProxy CLI client, then run `joesproxyctl auth login`."
            )
        }
    }

    private func doctor(invocation: CLIInvocation) async -> CLIResultEnvelope {
        var checks: [[String: Any]] = []
        var recommendations: [String] = []
        do {
            let appURL = try appLauncher.applicationURL()
            checks.append(["id": "app_bundle", "state": "pass", "detail": appURL.path])
        } catch let error as CLIError {
            checks.append(["id": "app_bundle", "state": "action_required", "detail": error.message])
            recommendations.append("Use joesproxyctl from JoesProxy.app/Contents/MacOS.")
        } catch {
            checks.append(["id": "app_bundle", "state": "action_required", "detail": error.localizedDescription])
        }

        let hasCredential = (try? credentialStore.load(endpoint: invocation.endpointURL)) != nil
        checks.append([
            "id": "credential",
            "state": hasCredential ? "pass" : "action_required",
            "detail": hasCredential ? "A CLI credential is stored." : "No CLI credential is stored."
        ])
        guard hasCredential else {
            recommendations.append("joesproxyctl auth login")
            checks.append([
                "id": "mcp",
                "state": "not_observable",
                "detail": "MCP was not contacted because no credential is stored."
            ])
            return success("doctor", [
                "ready": false,
                "state": "bootstrap_only",
                "bootstrapOnly": true,
                "endpoint": invocation.endpointURL.absoluteString,
                "checks": checks,
                "recommendedNextCommands": recommendations
            ])
        }

        do {
            let client = try makeClient(invocation)
            let structured = try await client.callTool(
                name: "runtime_status",
                arguments: ["expectedRuntime": CLIRuntimeIdentity.expectation()]
            )
            guard let runtime = payloadObject(structured) else {
                throw CLIError.malformedResponse("runtime_status did not return a payload.")
            }
            checks.append(["id": "mcp", "state": "pass", "detail": "Authenticated MCP connection is available."])
            checks.append(contentsOf: runtime["checks"] as? [[String: Any]] ?? [])
            recommendations.append(contentsOf: runtime["recommendedNextCommands"] as? [String] ?? [])
            if let compatibility = runtime["compatibility"] as? [String: Any] {
                recommendations.append(contentsOf: compatibility["recommendedActions"] as? [String] ?? [])
            }
            return success("doctor", [
                "ready": runtime["readyForUnattendedControl"] as? Bool == true,
                "state": runtime["state"] as? String ?? "unknown",
                "endpoint": invocation.endpointURL.absoluteString,
                "checks": checks,
                "runtime": runtime,
                "recommendedNextCommands": Array(recommendations.prefix(4))
            ])
        } catch let error as CLIError {
            checks.append(["id": "mcp", "state": "action_required", "detail": error.message])
            let failure = doctorFailure(for: error)
            recommendations.append(failure.recommendedCommand)
            return success("doctor", [
                "ready": false,
                "state": failure.state,
                "endpoint": invocation.endpointURL.absoluteString,
                "checks": checks,
                "recommendedNextCommands": Array(recommendations.prefix(4))
            ])
        } catch {
            checks.append(["id": "mcp", "state": "action_required", "detail": error.localizedDescription])
            return success("doctor", [
                "ready": false,
                "state": "diagnostic_failed",
                "endpoint": invocation.endpointURL.absoluteString,
                "checks": checks,
                "recommendedNextCommands": recommendations
            ])
        }
    }

    private func waitForMCP(invocation: CLIInvocation) async throws -> [String: Any] {
        try requireCredential(invocation)
        let deadline = Date().addingTimeInterval(invocation.timeout)
        let client = try makeClient(invocation)
        var lastError: CLIError?
        while Date() < deadline {
            do {
                let result = try await client.ping()
                return [
                    "state": "running",
                    "endpoint": invocation.endpointURL.absoluteString,
                    "server": result
                ]
            } catch let error as CLIError {
                switch error {
                case .serverUnavailable, .staleSession:
                    lastError = error
                    try await sleep(1_000_000_000)
                case .rateLimited:
                    lastError = error
                    try await sleep(2_000_000_000)
                default:
                    throw error
                }
            }
        }
        throw CLIError.timedOut(
            "JoesProxy MCP did not become ready before the timeout. Ensure 'Allow JoesProxy CLI to start MCP' is enabled. Last error: \(lastError?.message ?? "unavailable")."
        )
    }

    private func doctorFailure(for error: CLIError) -> (state: String, recommendedCommand: String) {
        switch error {
        case .authenticationFailed:
            return ("authentication_required", "joesproxyctl auth login")
        case .policyDenied:
            return ("policy_action_required", "Review this CLI client in JoesProxy MCP Management.")
        case .rateLimited:
            return ("rate_limited", "Wait for the reported interval, then run joesproxyctl doctor.")
        case .staleSession:
            return ("session_reinitialization_required", "joesproxyctl session end")
        default:
            return ("mcp_unavailable", "joesproxyctl mcp start --timeout 30")
        }
    }

    private func runTool(
        _ client: MCPCLIClient,
        name: String,
        arguments: [String: Any],
        invocation: CLIInvocation,
        retryOnStaleSession: Bool = true
    ) async throws -> [String: Any] {
        do {
            return try await client.callTool(
                name: name,
                arguments: arguments,
                retryOnStaleSession: retryOnStaleSession
            )
        } catch let error as CLIError {
            guard case .approvalRequired(let requestID, _) = error,
                  invocation.flags.contains("wait-for-approval"), let requestID else {
                throw error
            }
            let receiptRetryOf = client.receiptRecorder?.lastID
            let approvalTimeout = TimeInterval(invocation.options["approval-timeout"] ?? "120") ?? 120
            let artifactRegistration = name == "artifact_source_register"
            let deadline = Date().addingTimeInterval(min(max(approvalTimeout, 1), artifactRegistration ? 120 : 600))
            while Date() < deadline {
                let status = try await client.callTool(
                    name: "approval_status",
                    arguments: ["requestID": requestID]
                )
                // `MCPApprovalStatusDTO` encodes `status` (not `state`). Accept both so a stale
                // field name cannot strand `--wait-for-approval` until timeout after the human
                // already approved — see memlog/Research/Live-NOBLENDER-Milestone-Lessons.md.
                let payload = payloadObject(status) ?? [:]
                let state = (payload["status"] as? String) ?? (payload["state"] as? String)
                if state == "approved_awaiting_retry" {
                    return try await client.callTool(name: name, arguments: arguments, retryOnStaleSession: false, receiptRetryOf: receiptRetryOf)
                }
                if ["denied", "expired", "invalidated", "consumed"].contains(state ?? "") {
                    throw CLIError.policyDenied("Approval ended in state \(state ?? "unknown").")
                }
                try await sleep(artifactRegistration ? 1_000_000_000 : Self.mcpPollingIntervalNanoseconds)
            }
            throw CLIError.timedOut("Timed out waiting for approval \(requestID).")
        }
    }

    private func runScenarioTool(
        _ client: MCPCLIClient,
        name: String,
        arguments: [String: Any],
        invocation: CLIInvocation,
        retryOnStaleSession: Bool = true
    ) async throws -> Any {
        let structured = try await runTool(
            client,
            name: name,
            arguments: arguments,
            invocation: invocation,
            retryOnStaleSession: retryOnStaleSession
        )
        guard let payload = payloadObject(structured) else {
            throw CLIError.malformedResponse("\(name) did not return a payload.")
        }
        guard !invocation.flags.contains("include-result") else { return payload }
        return CLIScenarioProjection.compact(payload, toolName: name)
    }

    /// Writes the plain public root CA certificate (DER) to disk — never the private key. Used for
    /// trust stores outside the Apple-platform profile flows, e.g. a Docker container's trust store.
    private func exportCertificate(
        client: MCPCLIClient,
        invocation: CLIInvocation
    ) async throws -> CLIResultEnvelope {
        guard let outputPath = invocation.options["output"], !outputPath.isEmpty else {
            throw CLIError.invalidArguments("certificate export requires --output <path>.")
        }
        let response = try await runTool(client, name: "certificate_export", arguments: [:], invocation: invocation)
        guard let payload = payloadObject(response),
              let base64 = payload["certificateDataBase64"] as? String,
              let certificateData = Data(base64Encoded: base64) else {
            throw CLIError.malformedResponse("certificate_export did not return certificate data.")
        }
        let url = URL(fileURLWithPath: outputPath)
        try certificateData.write(to: url, options: .atomic)
        return success("certificate export", [
            "output": url.path,
            "bytes": certificateData.count,
            "certificateSHA256Fingerprint": payload["certificateSHA256Fingerprint"] as Any
        ])
    }

    private func exportSessions(
        client: MCPCLIClient,
        invocation: CLIInvocation
    ) async throws -> CLIResultEnvelope {
        let format = invocation.options["format"] ?? "ndjson"
        guard ["json", "ndjson", "har"].contains(format) else {
            throw CLIError.invalidArguments("Session export supports --format json, ndjson, or har.")
        }
        let requestsBodyOrHeaders = invocation.flags.contains("include-body") || invocation.flags.contains("include-headers")
        if format == "har" || requestsBodyOrHeaders {
            return try await exportSessionsBulk(client: client, invocation: invocation, format: format)
        }
        return try await exportSessionsMetadataOnly(client: client, invocation: invocation, format: format)
    }

    /// Today's original path: metadata-only, no body/header disclosure request, so it never needs
    /// approval. Kept exactly as-is for backward compatibility with existing scripts.
    private func exportSessionsMetadataOnly(
        client: MCPCLIClient,
        invocation: CLIInvocation,
        format: String
    ) async throws -> CLIResultEnvelope {
        var arguments = sessionSearchArguments(invocation)
        arguments["projection"] = invocation.options["projection"] ?? "minimal"
        arguments["limit"] = min(Int(invocation.options["limit"] ?? "100") ?? 100, 100)
        var exported: [[String: Any]] = []
        var cursor: String?
        repeat {
            if let cursor { arguments["cursor"] = cursor }
            let response = try await client.callTool(name: "sessions_search", arguments: arguments)
            guard let page = payloadObject(response) else {
                throw CLIError.malformedResponse("The session export page was malformed.")
            }
            exported.append(contentsOf: page["items"] as? [[String: Any]] ?? [])
            cursor = page["hasMore"] as? Bool == true ? page["nextCursor"] as? String : nil
        } while cursor != nil

        let output: String
        if format == "ndjson" {
            output = try exported.map { try CLIJSON.string($0, pretty: false) }.joined(separator: "\n") + (exported.isEmpty ? "" : "\n")
        } else {
            output = try CLIJSON.string(exported, pretty: true) + "\n"
        }
        return try writeExportOutput(output, invocation: invocation, format: format, itemCount: exported.count)
    }

    /// Full export path: routes through the bulk `sessions_export` MCP tool (one approval covers
    /// the whole call), used for `--format har` or whenever body/header disclosure is requested.
    ///
    /// When `--output` is set or the format is `har`, requests `deliverFile` so the server walks
    /// the full matching capture (GUI Export All parity) and returns a managed file path instead
    /// of inlining a 1 MB-capped JSON-RPC payload.
    private func exportSessionsBulk(
        client: MCPCLIClient,
        invocation: CLIInvocation,
        format: String
    ) async throws -> CLIResultEnvelope {
        var arguments = sessionSearchArguments(invocation)
        arguments["format"] = format
        if invocation.flags.contains("include-headers") { arguments["includeHeaders"] = true }
        if invocation.flags.contains("include-body") { arguments["includeBody"] = true }
        let wantsFileDelivery = invocation.options["output"] != nil || format == "har"
        if wantsFileDelivery {
            arguments["deliverFile"] = true
        }
        if let maxSessions = invocation.options["max-sessions"], let value = Int(maxSessions) {
            arguments["maxSessions"] = value
        }
        let structured = try await runTool(client, name: "sessions_export", arguments: arguments, invocation: invocation)
        guard let payload = payloadObject(structured) else {
            throw CLIError.malformedResponse("sessions_export did not return a payload.")
        }
        let itemCount = (payload["sessionCount"] as? NSNumber)?.intValue ?? 0
        let truncated = payload["truncated"] as? Bool ?? false
        var warnings = truncated
            ? ["Export was truncated at the maxSessions bound; narrow filters or raise --max-sessions."]
            : []
        let contentByteCount = (payload["contentByteCount"] as? NSNumber)?.intValue

        if let outputPath = payload["outputPath"] as? String, !outputPath.isEmpty {
            let spilledURL = URL(fileURLWithPath: outputPath)
            guard FileManager.default.fileExists(atPath: spilledURL.path) else {
                throw CLIError.malformedResponse("sessions_export returned outputPath that does not exist: \(outputPath)")
            }
            if let destination = invocation.options["output"] {
                let destinationURL = URL(fileURLWithPath: destination)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: spilledURL, to: destinationURL)
                var result: [String: Any] = [
                    "format": format,
                    "itemCount": itemCount,
                    "output": destinationURL.path
                ]
                if let contentByteCount { result["contentByteCount"] = contentByteCount }
                return success("sessions export", result, warnings: warnings)
            }
            let data = try Data(contentsOf: spilledURL)
            FileHandle.standardOutput.write(data)
            if !data.isEmpty, data.last != UInt8(ascii: "\n") {
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            warnings.append("Export was delivered via a managed file and emitted to stdout.")
            var result: [String: Any] = [
                "format": format,
                "itemCount": itemCount,
                "writtenTo": "stdout",
                "managedOutputPath": spilledURL.path
            ]
            if let contentByteCount { result["contentByteCount"] = contentByteCount }
            return success("sessions export", result, warnings: warnings)
        }

        guard let content = payload["content"] as? String else {
            throw CLIError.malformedResponse("sessions_export did not return export content or outputPath.")
        }
        let normalizedContent = content.hasSuffix("\n") ? content : content + "\n"
        return try writeExportOutput(normalizedContent, invocation: invocation, format: format, itemCount: itemCount, extraWarnings: warnings)
    }

    private func exportReproPackage(
        client: MCPCLIClient,
        invocation: CLIInvocation
    ) async throws -> CLIResultEnvelope {
        guard let destination = invocation.options["output"] else {
            throw CLIError.invalidArguments("repro export requires --output <path>.")
        }
        var arguments: [String: Any] = [:]
        if let title = invocation.options["name"] { arguments["title"] = title }
        if let notes = invocation.options["detail"] { arguments["notes"] = notes }
        if let limit = invocation.options["max-sessions"], let value = Int(limit) {
            arguments["maxSessions"] = value
        }
        let structured = try await runTool(
            client,
            name: "repro_export_package",
            arguments: arguments,
            invocation: invocation
        )
        guard let payload = payloadObject(structured),
              let outputPath = payload["outputPath"] as? String else {
            throw CLIError.malformedResponse("repro_export_package did not return outputPath.")
        }
        let sourceURL = URL(fileURLWithPath: outputPath)
        let destinationURL = URL(fileURLWithPath: destination)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.malformedResponse("The managed reproduction package was not found.")
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        var result: [String: Any] = ["output": destinationURL.path]
        if let byteCount = payload["contentByteCount"] { result["contentByteCount"] = byteCount }
        return success("repro export", result)
    }

    private func inspectReproPackage(
        client: MCPCLIClient,
        invocation: CLIInvocation
    ) async throws -> CLIResultEnvelope {
        let data = try reproPackageData(invocation)
        // Base64 and JSON-RPC framing must remain below the server's 1 MiB request-body limit.
        guard data.count <= 700_000 else {
            throw CLIError.invalidArguments("The package exceeds the MCP request budget; open it in the app for inspection.")
        }
        let result = try await runTool(
            client,
            name: "repro_inspect_package",
            arguments: ["packageBase64": data.base64EncodedString()],
            invocation: invocation
        )
        return success("repro inspect", result)
    }

    private func replayReproPackage(
        client: MCPCLIClient,
        invocation: CLIInvocation
    ) async throws -> CLIResultEnvelope {
        let package = try JSONDecoder().decode(CLIReproPackage.self, from: reproPackageData(invocation))
        let requestedID = invocation.options["session-id"]
        let session = requestedID.flatMap { id in package.sessions.first(where: { $0.id == id }) }
            ?? package.sessions.first(where: {
                ["GET", "HEAD", "OPTIONS"].contains($0.request.method.uppercased())
                    && $0.request.host != "private-host.invalid"
                    && !$0.request.path.contains("<redacted>")
            })
        guard let session else {
            throw CLIError.invalidArguments("The package does not contain a sanitized read request that is safe to replay.")
        }
        if let requestedID, session.id != requestedID {
            throw CLIError.invalidArguments("No replayable package session matched --session-id \(requestedID).")
        }
        var arguments: [String: Any] = [
            "packageSessionID": session.id,
            "method": session.request.method.uppercased(),
            "scheme": session.request.scheme,
            "host": session.request.host,
            "path": session.request.path
        ]
        if let port = session.request.port { arguments["port"] = port }
        if let status = session.expectedOutcome.statusCode { arguments["expectedStatusCode"] = status }
        return success(
            "repro replay",
            try await runTool(
                client,
                name: "repro_replay_request",
                arguments: arguments,
                invocation: invocation,
                retryOnStaleSession: false
            ),
            warnings: ["A matching wire response does not prove the original client state was reproduced."]
        )
    }

    private func reproPackageData(_ invocation: CLIInvocation) throws -> Data {
        guard let path = invocation.options["file"] else {
            throw CLIError.invalidArguments("This command requires --file <package.jproxy-repro>.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.invalidArguments("Reproduction package not found: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }

    private func writeExportOutput(
        _ output: String,
        invocation: CLIInvocation,
        format: String,
        itemCount: Int,
        extraWarnings: [String] = []
    ) throws -> CLIResultEnvelope {
        if let path = invocation.options["output"] {
            let url = URL(fileURLWithPath: path)
            try Data(output.utf8).write(to: url, options: .atomic)
            return success("sessions export", ["format": format, "itemCount": itemCount, "output": url.path], warnings: extraWarnings)
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        return success(
            "sessions export",
            ["format": format, "itemCount": itemCount, "writtenTo": "stdout"],
            warnings: ["Session data was already emitted to stdout."] + extraWarnings
        )
    }

    private func prepareLiveRewrite(
        client: MCPCLIClient,
        sessionID: String,
        invocation: CLIInvocation
    ) async throws -> [String: Any] {
        let preview = try await runTool(
            client,
            name: "preview_live_rewrite",
            arguments: try CLILiveRewriteArguments.preview(invocation: invocation, sessionID: sessionID),
            invocation: invocation
        )
        guard let previewPayload = payloadObject(preview),
              let previewDigest = previewPayload["previewDigest"] as? String else {
            throw CLIError.malformedResponse("preview_live_rewrite did not return a previewDigest.")
        }
        let proposal = try await runTool(
            client,
            name: "propose_create_live_rewrite",
            arguments: try CLILiveRewriteArguments.proposal(
                invocation: invocation,
                previewDigest: previewDigest
            ),
            invocation: invocation,
            retryOnStaleSession: false
        )
        guard let proposalPayload = payloadObject(proposal) else {
            throw CLIError.malformedResponse("propose_create_live_rewrite did not return a payload.")
        }
        return [
            "preview": compactRewritePreview(previewPayload),
            "proposal": proposalPayload,
            "nextCommand": "joesproxyctl rewrite apply <proposal-token> --wait-for-approval"
        ]
    }

    private func compactRewritePreview(_ payload: [String: Any]) -> [String: Any] {
        let keys = [
            "eligibleCount", "ineligibleCount", "transformedCount", "zeroMatches",
            "selectorResults", "byteGrowth", "warnings", "captureEpoch", "policyRevision",
            "sampledHighWaterSequence", "expiresAt", "previewDigest"
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            payload[key].map { (key, $0) }
        })
    }

    private func prepareCollectionMock(
        client: MCPCLIClient,
        sessionID: String,
        invocation: CLIInvocation
    ) async throws -> [String: Any] {
        let preview = try await runTool(
            client,
            name: "preview_collection_mock",
            arguments: try CLICollectionMockArguments.preview(invocation: invocation, sessionID: sessionID),
            invocation: invocation
        )
        guard let previewPayload = payloadObject(preview),
              let revisionID = previewPayload["revisionID"] as? String else {
            throw CLIError.malformedResponse("preview_collection_mock did not return a revisionID.")
        }
        let proposal = try await runTool(
            client,
            name: "propose_create_collection_mock",
            arguments: try CLICollectionMockArguments.proposal(invocation: invocation, revisionID: revisionID),
            invocation: invocation,
            retryOnStaleSession: false
        )
        guard let proposalPayload = payloadObject(proposal) else {
            throw CLIError.malformedResponse("propose_create_collection_mock did not return a payload.")
        }
        return [
            "preview": previewPayload,
            "proposal": proposalPayload,
            "nextCommand": "joesproxyctl collection-mock apply <proposal-token> --wait-for-approval"
        ]
    }

    private func watchCapture(client: MCPCLIClient, invocation: CLIInvocation) async throws {
        try await client.watch(resourceURI: "joesproxy://capture/summary", duration: invocation.timeout) { event in
            guard invocation.outputMode != .quiet else { return }
            let output = try CLIJSON.string(event, pretty: invocation.outputMode == .human)
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        }
    }

    /// Subscribes to capture changes and fetches only sessions newer than the last emitted sequence.
    /// The first fetch runs after subscription, closing the baseline-to-stream race without polling.
    private func watchSessions(client: MCPCLIClient, invocation: CLIInvocation) async throws {
        var sinceSequence: UInt64 = 0
        if let value = invocation.options["since-sequence"], let parsed = UInt64(value) {
            sinceSequence = parsed
        } else {
            let digest = try await client.callTool(name: "capture_digest", arguments: [:])
            sinceSequence = (payloadObject(digest)?["latestSequence"] as? NSNumber)?.uint64Value ?? 0
        }
        let pageLimit = invocation.options["limit"].flatMap(Int.init) ?? 50

        func emitNewSessions() async throws {
            while true {
                let previousSequence = sinceSequence
                var arguments = sessionPageArguments(invocation)
                arguments["sinceSequence"] = sinceSequence
                arguments["limit"] = pageLimit
                let page = try await client.callTool(name: "sessions_list", arguments: arguments)
                let payload = payloadObject(page) ?? [:]
                let items = payload["items"] as? [[String: Any]] ?? []
                for item in items {
                    if let sequence = (item["captureSequence"] as? NSNumber)?.uint64Value {
                        sinceSequence = max(sinceSequence, sequence)
                    }
                    guard invocation.outputMode != .quiet else { continue }
                    let pretty = invocation.outputMode == .human
                    let output = try CLIJSON.string(item, pretty: pretty)
                    FileHandle.standardOutput.write(Data((output + "\n").utf8))
                }
                let hasMore = payload["hasMore"] as? Bool ?? false
                guard hasMore, sinceSequence > previousSequence else { return }
            }
        }

        try await client.watch(
            resourceURI: "joesproxy://capture/summary",
            duration: invocation.timeout,
            onSubscribed: { try await emitNewSessions() }
        ) { event in
            guard event["method"] as? String == "notifications/resources/updated",
                  let params = event["params"] as? [String: Any],
                  params["uri"] as? String == "joesproxy://capture/summary" else {
                return
            }
            if let advertisedHighWater = (params["captureHighWaterSequence"] as? NSNumber)?.uint64Value,
               advertisedHighWater <= sinceSequence {
                return
            }
            try await emitNewSessions()
        }
    }

    private func waitForCapture(client: MCPCLIClient, invocation: CLIInvocation) async throws -> [String: Any] {
        let baseline: UInt64
        if let value = invocation.options["since-sequence"], let parsed = UInt64(value) {
            baseline = parsed
        } else {
            let current = try await client.callTool(name: "capture_digest", arguments: [:])
            baseline = (payloadObject(current)?["latestSequence"] as? NSNumber)?.uint64Value ?? 0
        }
        let deadline = Date().addingTimeInterval(invocation.timeout)
        while Date() < deadline {
            let digest = try await client.callTool(name: "capture_digest", arguments: ["knownLatestSequence": baseline])
            if let payload = payloadObject(digest),
               (payload["latestSequence"] as? NSNumber)?.uint64Value ?? 0 > baseline {
                return digest
            }
            try await sleep(Self.mcpPollingIntervalNanoseconds)
        }
        throw CLIError.timedOut("No capture change occurred before the timeout.")
    }

    private func waitForSession(client: MCPCLIClient, invocation: CLIInvocation) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(invocation.timeout)
        var arguments = sessionSearchArguments(invocation)
        arguments["limit"] = 1
        while Date() < deadline {
            let result = try await client.callTool(name: "sessions_search", arguments: arguments)
            if let items = payloadObject(result)?["items"] as? [[String: Any]], !items.isEmpty {
                return result
            }
            try await sleep(Self.mcpPollingIntervalNanoseconds)
        }
        throw CLIError.timedOut("No matching session appeared before the timeout.")
    }

    private func waitForOperation(client: MCPCLIClient, operationID: String, invocation: CLIInvocation) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(invocation.timeout)
        while Date() < deadline {
            let result = try await client.callTool(
                name: "operation_status",
                arguments: ["operationID": operationID, "projection": "minimal"]
            )
            let status = payloadObject(result)?["status"] as? String
            if ["completed", "partial", "failed", "cancelled", "expired"].contains(status ?? "") {
                return result
            }
            try await sleep(Self.mcpPollingIntervalNanoseconds)
        }
        throw CLIError.timedOut("Operation \(operationID) did not finish before the timeout.")
    }

    /// Mints a plain bookmark from `--file` and never sends the filesystem path over MCP.
    private func diagnosticRunCreateArguments(from invocation: CLIInvocation) throws -> [String: Any] {
        guard let summary = invocation.options["hypothesis"], !summary.isEmpty else {
            throw CLIError.invalidArguments("run create requires --hypothesis.")
        }
        guard let expected = invocation.options["expected"], !expected.isEmpty else {
            throw CLIError.invalidArguments("run create requires --expected.")
        }
        var arguments: [String: Any] = [
            "hypothesisSummary": summary,
            "expectedObservation": expected
        ]
        if let lifetime = invocation.options["lifetime"], let value = Double(lifetime) {
            arguments["lifetimeSeconds"] = value
        }
        var scopes: [[String: Any]] = []
        if let host = invocation.options["host"], !host.isEmpty,
           let path = invocation.options["path"], !path.isEmpty {
            var scope: [String: Any] = [
                "kind": "http",
                "method": invocation.options["method"] ?? "GET",
                "scheme": invocation.options["scheme"] ?? "https",
                "host": host,
                "path": path.hasPrefix("/") ? path : "/\(path)",
                "pathMatch": invocation.options["path-match"] ?? "exact"
            ]
            if let port = invocation.options["port"], let value = Int(port) {
                scope["port"] = value
            }
            scopes.append(scope)
        }
        if let sessionID = invocation.options["session-id"], !sessionID.isEmpty {
            scopes.append([
                "kind": "capturedSession",
                "sessionID": sessionID,
                "captureEpoch": invocation.options["capture-epoch"] ?? "capture-epoch-0",
                "requestFingerprint": invocation.options["fingerprint"] ?? "cli-\(sessionID)"
            ])
        }
        if !scopes.isEmpty {
            arguments["scopes"] = scopes
        }
        return arguments
    }

    private func diagnosticRunCloseArguments(runID: String, from invocation: CLIInvocation) throws -> [String: Any] {
        guard let terminal = invocation.options["terminal"], !terminal.isEmpty else {
            throw CLIError.invalidArguments("run close requires --terminal passed|failed|inconclusive|expired.")
        }
        var arguments: [String: Any] = [
            "runID": runID,
            "requestedTerminal": terminal
        ]
        if terminal != "expired" {
            guard let outcome = invocation.options["outcome"], !outcome.isEmpty,
                  let reason = invocation.options["reason"], !reason.isEmpty,
                  let summary = invocation.options["summary"], !summary.isEmpty else {
                throw CLIError.invalidArguments(
                    "run close requires --outcome, --reason, and --summary unless --terminal expired."
                )
            }
            arguments["conclusionOutcome"] = outcome
            arguments["conclusionReasonCode"] = reason
            arguments["conclusionSummary"] = summary
            if let confidence = invocation.options["confidence"] {
                arguments["conclusionConfidence"] = confidence
            }
        }
        return arguments
    }

    private func openAPIPackArguments(from invocation: CLIInvocation, requireHost: Bool) throws -> [String: Any] {
        guard let filePath = invocation.options["file"], !filePath.isEmpty else {
            throw CLIError.invalidArguments("openapi pack requires --file <path>.")
        }
        let fileURL = URL(fileURLWithPath: filePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CLIError.invalidArguments("openapi pack --file must point at an existing OpenAPI JSON file.")
        }
        let bookmarkData: Data
        do {
            bookmarkData = try fileURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw CLIError.invalidArguments("Could not create a bookmark for --file: \(error.localizedDescription)")
        }
        var arguments: [String: Any] = [
            "openapiDocumentBookmarkRef": bookmarkData.base64EncodedString()
        ]
        if let host = invocation.options["host"], !host.isEmpty {
            arguments["host"] = host
            arguments["scheme"] = invocation.options["scheme"] ?? "https"
            if let port = invocation.options["port"], let portValue = Int(port) {
                arguments["port"] = portValue
            }
        } else if requireHost {
            throw CLIError.invalidArguments("openapi pack prepare requires --host.")
        }
        if let ttl = invocation.options["ttl"], let ttlValue = Int(ttl) {
            arguments["ttlSeconds"] = ttlValue
        }
        arguments["conflictStrategy"] = invocation.flags.contains("replace-conflicts") ? "replaceConflicts" : "refuse"
        return arguments
    }

    private func captureDigestArguments(_ invocation: CLIInvocation) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let sequence = invocation.options["since-sequence"], let value = UInt64(sequence) {
            arguments["knownLatestSequence"] = value
        }
        if let stateToken = invocation.options["if-state-token"] {
            arguments["ifStateToken"] = stateToken
        }
        return arguments
    }

    private func readBatchArguments(_ invocation: CLIInvocation) throws -> [String: Any] {
        guard let path = invocation.options["file"], !path.isEmpty else {
            throw CLIError.invalidArguments("read batch requires --file <requests.json>.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.invalidArguments("Batch request file not found: \(url.lastPathComponent)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch {
            throw CLIError.invalidArguments("Batch request file must contain valid JSON.")
        }
        if let requests = object as? [[String: Any]] {
            return ["requests": requests]
        }
        if let dictionary = object as? [String: Any], dictionary["requests"] is [[String: Any]] {
            return dictionary
        }
        throw CLIError.invalidArguments("Batch request JSON must be an array or an object containing requests.")
    }

    private func sessionPageArguments(_ invocation: CLIInvocation) -> [String: Any] {
        var arguments: [String: Any] = [:]
        addPagination(invocation, to: &arguments)
        arguments["projection"] = invocation.options["projection"] ?? "minimal"
        if let sequence = invocation.options["since-sequence"], let value = UInt64(sequence) {
            arguments["sinceSequence"] = value
        }
        return arguments
    }

    private func sessionSearchArguments(_ invocation: CLIInvocation) -> [String: Any] {
        var arguments = sessionPageArguments(invocation)
        if let method = invocation.options["method"] { arguments["method"] = method }
        if let category = invocation.options["host-category"] { arguments["hostCategory"] = category }
        if let prefix = invocation.options["session-id-prefix"] { arguments["sessionIDPrefix"] = prefix }
        if let domain = invocation.options["domain"] { arguments["domain"] = domain }
        if let path = invocation.options["path"] { arguments["path"] = path }
        if let since = invocation.options["since"] { arguments["startedAfter"] = since }
        if let until = invocation.options["until"] { arguments["startedBefore"] = until }
        return arguments
    }

    private func addPagination(_ invocation: CLIInvocation, to arguments: inout [String: Any]) {
        if let limit = invocation.options["limit"], let value = Int(limit) { arguments["limit"] = value }
        if let cursor = invocation.options["cursor"] { arguments["cursor"] = cursor }
    }

    /// MCP tool responses use two conventions: tools built on `MCPDTOEnvelope`/`encodedToolResult`
    /// (e.g. `capture_digest`, `sessions_list`) wrap their DTO as `{"schemaVersion":Int,
    /// "payload":{...}}`; scenario and mutation/rewrite tools instead return their DTO flat via a
    /// plain `payloadDictionary` encode, with no wrapper at all. Treating every response as the
    /// enveloped shape silently broke every `scenario`/`rewrite` command against a real server —
    /// this only surfaced via a real-transport integration test, since every existing mocked unit
    /// test happened to hand-construct the enveloped shape regardless of which tool it exercised.
    private func payloadObject(_ structured: [String: Any]) -> [String: Any]? {
        if structured["schemaVersion"] != nil, let payload = structured["payload"] as? [String: Any] {
            return payload
        }
        return structured
    }

    /// Builds a concrete reload URL from Map Local `matchScope` so operators do not guess HTTPS when
    /// the capture/matcher is plain HTTP (or a non-default port).
    private func reloadURLHint(from matchScope: [String: Any]?) -> String? {
        guard let matchScope,
              let host = matchScope["host"] as? String, !host.isEmpty,
              let path = matchScope["path"] as? String else {
            return nil
        }
        let scheme = (matchScope["scheme"] as? String)?.lowercased() ?? "https"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let port = matchScope["port"] as? Int
        let omitPort = port == nil
            || (scheme == "http" && port == 80)
            || (scheme == "https" && port == 443)
        if let port, !omitPort {
            return "\(scheme)://\(host):\(port)\(normalizedPath)"
        }
        return "\(scheme)://\(host)\(normalizedPath)"
    }

    private func success(_ command: String, _ result: Any, warnings: [String] = []) -> CLIResultEnvelope {
        CLIResultEnvelope(command: command, success: true, result: result, warnings: warnings, errorCode: nil, errorMessage: nil)
    }

    private func artifactResult(_ command: String, _ result: [String: Any]) -> CLIResultEnvelope {
        if result["status"] as? String == "incomplete" {
            return CLIResultEnvelope(command: command, success: false, result: result, warnings: [],
                errorCode: "incomplete_coverage", errorMessage: "Selected evidence is incomplete. Inspect coverage and observedCount.")
        }
        let unavailable = result["status"] as? String == "unavailable"
        return CLIResultEnvelope(command: command, success: !unavailable, result: result, warnings: [],
            errorCode: unavailable ? result["reason"] as? String ?? "analysis_unavailable" : nil,
            errorMessage: unavailable ? "No result was produced; inspect the bounded reason before choosing another read." : nil)
    }

    private func emit(result: CLIResultEnvelope, mode: CLIOutputMode) throws {
        guard mode != .quiet else { return }
        if result.command == "sessions export", result.warnings.contains("Session data was already emitted to stdout.") {
            return
        }
        let object = mode == .human ? (result.result ?? [:]) : result.jsonObject()
        let text = try CLIJSON.string(object, pretty: mode != .ndjson)
        writeResult(Data((text + "\n").utf8))
    }

    private func approvalResult(_ error: CLIError, command: String = "") -> Any? {
        if case .documentation(let reason, let recovery) = error {
            return ["reason": reason, "recommendedAction": recovery, "documentationTopic": "agent-documentation"]
        }
        if case .invalidPreparation(_, let details) = error { return details }
        if case .approvalRequired(let requestID, _) = error, let requestID {
            return ["requestID": requestID, "recommendedAction": "Approve in JoesProxy, then retry the identical command or use --wait-for-approval."]
        }
        let recommendedAction: String
        switch error {
        case .serverUnavailable:
            recommendedAction = "Run joesproxyctl doctor with the same endpoint. Start MCP only if stopped. If an apply was interrupted, inspect its status before retrying; do not assume it failed or create a replacement proposal."
        case .authenticationFailed:
            recommendedAction = "Rotate or reenroll the JoesProxy CLI client, then run joesproxyctl auth login."
        case .policyDenied:
            recommendedAction = "Review the client profile, Runtime Control grant, and cleanup state in MCP Management."
        case .rateLimited:
            recommendedAction = "Wait for the server rate-limit interval, then retry once."
        case .timedOut:
            recommendedAction = "Run joesproxyctl doctor with the same endpoint. A timed-out apply may have succeeded: inspect its status first, then use the original request and idempotency key if a retry is appropriate."
        case .staleSession:
            recommendedAction = "Retry once so the CLI can initialize a fresh logical MCP session."
        case .staleProposal(let message):
            if command.contains("hls codecs")
                || message.localizedCaseInsensitiveContains("HLS CODECS") {
                recommendedAction = "The HLS CODECS preview or proposal is stale, consumed, or expired — "
                    + "re-run `joesproxyctl hls codecs preview <session-id> --edits <json-file>`, then "
                    + "`hls codecs prepare-map-local --preview-digest <digest>` with the new digest. "
                    + "A fresh MCP session will not fix this."
            } else {
                recommendedAction = "The referenced proposal, preview, or revision is stale, consumed, or no longer exists — re-run the step that produced it (e.g. response edit preview, or the propose call) to get a fresh reference, then retry. A fresh MCP session will not fix this."
            }
        case .invalidArguments, .invalidPreparation, .documentation, .malformedResponse, .internalFailure, .approvalRequired:
            return nil
        }
        return ["recommendedAction": recommendedAction, "documentationTopic": "workflow-evidence"]
    }

    private func documentation(_ invocation: CLIInvocation) async throws -> CLIResultEnvelope {
        guard invocation.command.count == 2, ["list", "search", "read"].contains(invocation.command[1]) else {
            throw CLIError.invalidArguments("Use docs list, docs search --query <text>, or docs read --topic <id>.")
        }
        let source = invocation.options["source"] ?? "offline"
        let allowedOptions: Set<String> = ["source", "format", "query", "topic", "section", "category", "cursor", "limit", "max-response-bytes", "endpoint", "timeout"]
        guard Set(invocation.options.keys).isSubset(of: allowedOptions) else {
            throw CLIError.invalidArguments("Unsupported docs option. Use --source, --format, --query, --topic, --section, --category, --cursor, --limit or --max-response-bytes; live queries also accept --endpoint and --timeout.")
        }
        guard ["offline", "live"].contains(source), ["markdown", "json"].contains(invocation.options["format"] ?? "markdown") else {
            throw CLIError.invalidArguments("Use --source offline|live and --format markdown|json.")
        }
        var arguments: [String: Any] = [:]
        for key in ["query", "topic", "section", "category", "cursor"] { arguments[key] = invocation.options[key] }
        for (option, key) in [("limit", "limit"), ("max-response-bytes", "maxResponseBytes")] {
            if let raw = invocation.options[option] {
                guard let value = Int(raw) else { throw CLIError.invalidArguments("\(option) must be an integer.") }
                arguments[key] = value
            }
        }
        do {
            let query = try DocumentationCatalog.Query(operation: invocation.command[1], arguments: arguments)
            if source == "live" {
                let client = try makeClient(invocation)
                let result = try await client.callTool(name: "documentation_\(query.operation)", arguments: arguments)
                return success(invocation.command.joined(separator: " "), result["payload"] ?? result)
            }
            let version = CLIRuntimeIdentity.expectation()["marketingVersion"] as? String ?? "development"
            let page = try await DocumentationService.shared.query(query, source: "installed", appVersion: version)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
            return success(invocation.command.joined(separator: " "), object)
        } catch let failure as DocumentationCatalog.Failure {
            throw CLIError.documentation(reason: failure.reason, recovery: failure.recovery)
        }
    }

    static let help = """
    Documentation (offline by default; no credentials or app startup):
      joesproxyctl docs list --format markdown|json
      joesproxyctl docs search --query "missing body" --format markdown|json
      joesproxyctl efficiency report --file <workflow.json> [--json]
      joesproxyctl efficiency compare --baseline-receipt <file> --candidate-receipt <file> [--json]
      joesproxyctl docs read --topic requestInspector --section context --format markdown|json
      Options: --source offline|live --category <category> --cursor <cursor> --limit 1..20 --max-response-bytes 2048..32768

    joesproxyctl - deterministic JoesProxy capture and media inspection

    Optional content-free HTTP receipt (finite commands only; new file, no overwrite):
      --receipt-output <file> --receipt-workflow <synthetic-label> --receipt-version <version> --receipt-environment <label>
      Unknown server analyses/provider usage remain unknown. Export failure preserves the original exit status.

    Usage:
      joesproxyctl auth login|status|logout
      joesproxyctl doctor [--json]
      joesproxyctl setup guide --format markdown|json
      joesproxyctl integrations list [--json]
      joesproxyctl integrations show tvtestrig|viewlens|instruments
      joesproxyctl integrations recipe truncation-audit [--target-url <url>] [--field <name>]
      joesproxyctl app launch [-- <app launch arguments>]
      joesproxyctl mcp start [-- <app launch arguments>] | wait | stop
      joesproxyctl proxy start|stop
      joesproxyctl status
      joesproxyctl toolset status
      joesproxyctl toolset select --name core|capture|mocking|media|reproduction|advanced|all
      joesproxyctl capture digest
      joesproxyctl capture status
      joesproxyctl https rules get --host media.example.test [--recovery-id <uuid>]
      joesproxyctl https rules set --host media.example.test --mode tunnel|inspect|remove --expected-revision <revision> --scope host_and_subdomains_all_clients [--recovery-id <uuid>] [--wait-for-approval]
      joesproxyctl https rules restore --host media.example.test --recovery-id <uuid> --expected-revision <revision> --scope host_and_subdomains_all_clients [--wait-for-approval]
      joesproxyctl capture resume [--wait-for-approval]
      joesproxyctl cache audit
      joesproxyctl investigate snapshot [--limit <1...25>] [--since-sequence <n>] [--if-state-token <token>]
      joesproxyctl evidence get <evidence-ref>
      joesproxyctl read batch --file <requests.json>
      joesproxyctl capture rolling-status
      joesproxyctl capture restore-rolling
      joesproxyctl capture marker --name <marker-name> [--detail <text>] [--label <text>]
      joesproxyctl capture activity --since-marker <session-id> [--rule <override-id>] [--limit <n>]
      joesproxyctl sessions list|search [filters]
      joesproxyctl device list
      joesproxyctl device alias <ip-address> (--name <friendly-name> | --clear)
      joesproxyctl session show <session-id>
        [--include-headers] [--include-response-headers] [--include-body]
        [--body-source response|request] [--header-source both|request|response]
      joesproxyctl session brief <session-id> [--selection-pointer /items] [--include-structure]
      joesproxyctl capture calculate --session-ids <id,id> --dataset sessionMetadata --operation groupCount --field-pointer /statusCode
      joesproxyctl capture calculate --session-ids <id> --dataset responseJSON --selection-pointer /items --operation numericSummary --field-pointer /price
      joesproxyctl artifact brief --handle <handle> --snapshot-revision <revision> --record-index <ordinal> [--selection-pointer /items] [--include-structure]
      joesproxyctl artifact compare --baseline-handle <id> --baseline-revision <id> --baseline-record <n> --candidate-handle <id> --candidate-revision <id> --candidate-record <n> [--selection-pointer /items] [--wait-for-approval]
      joesproxyctl artifact inventory --handle <handle> --snapshot-revision <revision> [--method GET] [--status-code 503]
      joesproxyctl artifact search --handle <handle> --snapshot-revision <revision> --dataset sourceUTF8|responseJSON --literal-stdin [--limit 20] [--cursor <cursor>]
      joesproxyctl artifact source register --request-key <uuid> --kind json --scope metadata-v1,calculations-v1 [--ttl-seconds 1800] [--wait-for-approval]
      joesproxyctl artifact source status --request-key <uuid>
      joesproxyctl artifact source inspect --handle <handle>
      joesproxyctl artifact source release --handle <handle>
      joesproxyctl artifact calculate --handle <handle> --snapshot-revision <revision> --dataset json --selection-pointer /items --operation rowCount
      joesproxyctl investigate compare --baseline-sessions <id,id> --candidate-sessions <id,id> [--selection-pointer /items]
      joesproxyctl media readiness|summary|manifest|related <session-id>
      joesproxyctl response context|search|read <session-id>
        search: --text <literal> [--include-context]
        read: [--offset <n>] [--length <n>]
      joesproxyctl response edit preview <session-id> --edits <json-file>
      joesproxyctl response draft save <session-id> [--label <label>]
      joesproxyctl response draft apply-save <proposal-token>
      joesproxyctl response draft list|get <draft-id>
      joesproxyctl response edit commit --draft <draft-id> --preview-digest <digest>
      joesproxyctl response edit apply-commit <proposal-token>
      joesproxyctl response map-local prepare (--preview-digest <digest> | --revision <revision-id> |
        --fixture-run-id <uuid> --method <verb> --host <host> --path <path> [--scheme http|https]
        [--match-mode pathPrefix] [--port <n>] [--graphql-operation-name <name>] |
        --directory <path> --method <verb> --host <host> --path <path> [--scheme http|https]
        [--match-mode pathPrefix] [--port <n>] [--not-found <relative>] [--force-no-cache]
        [--missing-file-policy strictLocal|overlayFailOpen|configuredFallback]
        [--graphql-operation-name <name>] |
        --file <path> --method <verb> --host <host> --path <path> [--scheme http|https]
        [--match-mode exactPath|pathPrefix|pathSuffix|ignoreQuery|filename] [--port <n>]
        [--status-code <code>] [--content-type <type>] [--force-no-cache]
        [--graphql-operation-name <name>]) [--source-client-address <ip>]
        [--match-query-key <key> --match-query-value <value>] [--enable-after]
      joesproxyctl response map-local apply <proposal-token> [--enable-after] [--wait-for-approval]
      joesproxyctl rule list [--limit <n>] [--cursor <token>] [--projection minimal|summary|full] [--source-kind <kind>]
      joesproxyctl rule get <override-id>
      joesproxyctl rule enable|disable|delete <override-id>
        enable: [--accept-confounder] [--idempotency-key <key>]
      joesproxyctl rule apply-enable|apply-disable|apply-delete <proposal-token>
        apply-enable: [--accept-confounder] [--wait-for-approval] [--idempotency-key <key>]
        apply-delete: [--wait-for-approval]
      joesproxyctl hls codecs context|preview <session-id>
        preview: --edits <json-file> [--match-mode ignoreQuery|exactPath|pathSuffix] [--path <suffix>]
      joesproxyctl hls codecs prepare-map-local --preview-digest <digest> [--idempotency-key <key>]
      joesproxyctl hls codecs apply-map-local <proposal-token> [--wait-for-approval] [--idempotency-key <key>]
      joesproxyctl hls fixture capabilities|profiles|status
        status: [--run-id <uuid>]
      joesproxyctl hls fixture window-preview --run-id <uuid> --path <rendition/stream.m3u8> [--at <seconds>]
      joesproxyctl hls fixture prepare-start --profile-id <id> [--presentation-mode vodStatic|liveLoop]
        [--time-shift-mode off|warmDVR|coldDVR] [--window-segments 2...30]
      joesproxyctl hls fixture apply-start <proposal-token> [--wait-for-approval]
      joesproxyctl hls fixture stop <run-id> | --run-id <uuid>
      joesproxyctl hls substitute profiles
      joesproxyctl hls substitute prepare --profile-id <id> --scope selected|host
        (--session-id <uuid> | --host <host> [--scheme http|https] [--port <n>] [--path <playlist.m3u8>])
        [--source-client-address <ip>] [--missing-text-track-id <reviewed-track-id>]
        Client-scoped routes require selected scope and match the entry query exactly.
        Missing-text faults require client scope. Omitted client scope retains legacy all-client matching.
        [--replace-conflicts]
        [--presentation-mode vodStatic|liveLoop]
        [--time-shift-mode off|warmDVR|coldDVR]
        [--intent conformant|deliberateFault] [--window-segments 2...30]
        [--loop-boundary declareDiscontinuity|omitDiscontinuity]
        [--segment-uri-identity uniquePerMediaSequence|reuseAssetURI]
        [--target-duration source|underreportByOneSecond] [--program-date-time include|omit]
        [--playlist-cache noCache|noStore|maxAge] [--playlist-max-age 0...60]
        [--ttl <seconds>]
      joesproxyctl hls substitute apply <proposal-token> [--wait-for-approval]
      joesproxyctl hls substitute status [<experiment-id> | --experiment-id <uuid>]
      joesproxyctl hls substitute stop <experiment-id>
      joesproxyctl hls substitute extend <experiment-id> [--ttl <seconds>]
      joesproxyctl openapi pack import --file <path> [--host <host>] [--scheme http|https] [--port <n>] [--ttl <seconds>]
      joesproxyctl openapi pack prepare --file <path> --host <host> [--scheme http|https] [--port <n>] [--ttl <seconds>] [--replace-conflicts]
      joesproxyctl openapi pack apply <proposal-token> [--wait-for-approval]
      joesproxyctl openapi pack status [<pack-id> | --pack-id <uuid>]
      joesproxyctl openapi pack stop <pack-id>
      joesproxyctl openapi import --file <path>
      joesproxyctl openapi validate <session-id>
      joesproxyctl openapi mock --path <template> [--method <GET|POST>] [--status <code>] [--mode validDefault|boundaryEdge|nullFields|emptyCollections]
      joesproxyctl run list [--limit <n>]
      joesproxyctl run create --hypothesis <text> --expected <text>
        [--host <host> --path <path> [--method GET] [--scheme https] [--port <n>] [--path-match exact|prefix|suffix]]
        [--session-id <uuid> [--fingerprint <token>] [--capture-epoch <id>]] [--lifetime <seconds>]
      joesproxyctl run start <run-id>
      joesproxyctl run status <run-id>
      joesproxyctl run brief <run-id> --baseline-window-id <UUID> --modified-window-id <UUID> [--if-brief-digest <digest>]
      joesproxyctl run observations <run-id> [--limit <n>]
      joesproxyctl run close <run-id> --terminal passed|failed|inconclusive|expired
        [--outcome passed|failed|inconclusive --reason <code> --summary <text> [--confidence medium]]
      joesproxyctl run retry-cleanup <run-id>
      joesproxyctl run evidence list
      joesproxyctl run evidence get <evidence-id>
      joesproxyctl run recheck prepare --evidence-id <uuid>
      joesproxyctl run recheck apply <proposal-token> [--wait-for-approval]
      joesproxyctl block prepare --method <verb> --host <host> --path <path>
        [--match-mode pathPrefix|pathSuffix|exactPath|ignoreQuery|filename] [--scheme http|https] [--port <n>]
        [--status-code <code>] [--drop-connection] [--graphql-operation-name <name>]
        [--match-query-key <key> --match-query-value <value>] [--source-client-address <ip>]
      joesproxyctl block apply <proposal-token> [--enable-after] [--wait-for-approval]
      joesproxyctl bookmark create --method <verb> --host <host> --path <path> --name <name>
        [--scheme http|https] [--port <n>] [--match-mode exactPath|pathPrefix|pathSuffix|ignoreQuery|filename]
      joesproxyctl bookmark apply <proposal-token> [--wait-for-approval]
      joesproxyctl bookmark list [--limit <n>] [--cursor <token>] [--projection minimal|summary|full]
      joesproxyctl bookmark get <bookmark-id>
      joesproxyctl throttle prepare [--preset-id mobile-3g|56k-modem|isdn|t1|mobile-lte|custom]
      joesproxyctl throttle apply <proposal-token> [--wait-for-approval]
      joesproxyctl throttle disable [--wait-for-approval]
      joesproxyctl media inspect <session-id> --analysis <kind[,kind]>
      joesproxyctl operation status|cancel <operation-id>
      joesproxyctl rewrite preview|prepare <session-id> [rewrite options]
      joesproxyctl rewrite apply|activate <proposal-token-or-override-id>
      joesproxyctl rewrite disable prepare <override-id>
      joesproxyctl rewrite disable apply <proposal-token>
      joesproxyctl collection-mock preview|prepare <session-id> [collection-mock options]
      joesproxyctl collection-mock apply|activate <proposal-token-or-override-id>
      joesproxyctl scenario preview|draft --input <json-file>
      joesproxyctl scenario validate|approve|arm|activate <scenario-id>
      joesproxyctl scenario observe|assert|report <scenario-id>
      joesproxyctl scenario stop|cleanup <scenario-id> [--outcome <phase>]
      joesproxyctl certificate status|identity
      joesproxyctl certificate export --output <path>
      joesproxyctl certificate artifacts list [--fingerprint <sha256>]
      joesproxyctl certificate compare --fingerprint <sha256> --other-fingerprint <sha256>
      joesproxyctl certificate cleanup prepare --fingerprint <sha256> [--allow-current-root]
      joesproxyctl certificate cleanup apply --proposal-token <token>
      joesproxyctl watch capture
      joesproxyctl watch sessions [--since-sequence <n>] [--ndjson]
      joesproxyctl wait capture|session|operation [id]
      joesproxyctl sessions export --format json|ndjson|har [--output path]
        [--domain <substring>] [--path <substring>] [--since <ISO8601>] [--until <ISO8601>]
        [--include-headers] [--include-body] [--max-sessions <count>] [--wait-for-approval]
      joesproxyctl repro export --output <package.jproxy-repro> [--name <title>] [--detail <notes>]
        [--max-sessions <count>]
      joesproxyctl repro inspect --file <package.jproxy-repro>
      joesproxyctl repro replay --file <package.jproxy-repro> [--session-id <package-session-id>]
        [--wait-for-approval]
      joesproxyctl cleanup status
      joesproxyctl approvals list
      joesproxyctl session end

    Common options:
      --json | --ndjson | --quiet | --integrations
      --endpoint http://127.0.0.1:9091/mcp
      --timeout <seconds>
      --projection minimal|summary|full
      --limit <count> --cursor <opaque-cursor> --since-sequence <number> --if-state-token <token>
      --method <method> --host-category <category> --session-id-prefix <prefix>
      --domain <substring> --path <substring> --since <ISO8601> --until <ISO8601>
      --wait-for-approval [--approval-timeout <seconds>]

    Export options:
      --format json|ndjson|har (har and any --include-* flag route through a single
        approval-gated bulk export; plain json/ndjson without those flags stays metadata-only
        and needs no approval, as before)
      --include-headers / --include-body: request full headers/bodies in the export
      --output <path>: write the full matching capture to disk (GUI Export All parity for HAR;
        uses MCP deliverFile — not limited by the 1 MB inline MCP budget or the default 500
        session inline cap unless --max-sessions is set)
      --max-sessions <count>: optional safety valve; inline delivery defaults to 500; with
        --output / HAR file delivery, omit to export the entire matching capture

    Rewrite options:
      --method <method> --scheme http|https --host <host> [--port <port>] --path <path>
      --match-mode <mode> --json-path <locator> --operation <operation>
      --value <literal> [--value-type string|number|bool|null]
      --repeat-policy always|ifMissingSuffix [--label <label>] [--idempotency-key <key>]
      [--graphql-operation-name <name>] [--match-query-key <key> --match-query-value <value>]
      [--source-client-address <ip>]
      (pass the same matcher values to preview and prepare — a mismatch invalidates the preview
        digest)

    Scenario options:
      --input <json-file> (UTF-8 object, 256 KiB maximum)
      --outcome completed|failed|inconclusive|canceled
      --include-result (include bounded evidence/report details; compact summaries are default)
      `approve` is an alias for `arm`; use --wait-for-approval for one-command approval polling.

    `doctor` is non-mutating and returns exit 23 when unattended control is not ready.
    `app launch` and `mcp start` require a stored credential and the opt-in automation toggle
    in JoesProxy MCP Management. Proxy and MCP stop/start controls remain approval-gated.
    A trailing `-- <arguments>` on `app launch`/`mcp start` is forwarded verbatim as the launched
    app's own command-line arguments (e.g. `joesproxyctl app launch -- --compact-mode
    --ui-test-suppress-launch-recovery`) — only takes effect on a genuine cold launch; if JoesProxy
    is already running, these are silently ignored, since macOS has no way to inject new argv into
    an already-running process.

    Advanced agentic diagnostics:
      joesproxyctl hypothesis propose --name <text> --target-bug <text> --nodes <json-file>
      joesproxyctl hypothesis step --graph-id <uuid> [--evidence-matches] --evidence-summary <text>
      joesproxyctl hypothesis report --graph-id <uuid>
      joesproxyctl llm stream inspect [--session-ids <id,id,...>] [--canaries <s1,s2,...>]
      joesproxyctl llm stream fault propose --name <text> --url-pattern <pattern> --fault-kind <kind>
        [--delay-ms <n>] [--target-token-index <n>]
      joesproxyctl fuzz permutation propose --name <text> --target-batch <text> --endpoints <json-file>
        [--spacing-ms <n>]
      joesproxyctl fuzz permutation step --plan-id <uuid> [--error-detected] --outcome-summary <text>
      joesproxyctl fuzz permutation report --plan-id <uuid>
      joesproxyctl resilience propose --session-id <uuid> [--name <text>]
      joesproxyctl resilience step --plan-id <uuid> [--client-crashed] [--observed-error <text>]
      joesproxyctl resilience report --plan-id <uuid>
      joesproxyctl trajectory diff --baseline-sessions <id,id> --candidate-sessions <id,id>
        [--baseline-name <text>] [--candidate-name <text>]
      joesproxyctl semantic mock propose --name <text> --url-pattern <pattern> --intent-label <text>
        --example-queries <q1,q2,...> --response-body <text> [--status-code <n>]
        [--confidence-threshold <0-1>]
      joesproxyctl semantic mock list|test|delete
        test: --query <text> [--target-url <url>]  delete: --rule-id <uuid>
      joesproxyctl contract diff --live-session <uuid> --baseline-session <uuid>
      joesproxyctl contract regression --live-sessions <id,id> --baseline-sessions <id,id>
      joesproxyctl lineage trace --target-value <text> [--candidate-sessions <id,id>]
      joesproxyctl lineage attribution --sink-session <uuid> [--candidate-sessions <id,id>]
      joesproxyctl lineage watermark propose --name <text> --url-pattern <pattern> --strategy <text>
        [--target-keypaths <k1,k2>] (preview only — nothing is registered or persisted)
      joesproxyctl localization presets
      joesproxyctl localization preview --session-id <uuid> --preset-id <id>
        [--no-preserve-urls] [--no-preserve-ids] (preview only — no live rule is installed)
      joesproxyctl stateful backends|presets
      joesproxyctl stateful install --preset-id <id> [--custom-host <host>]
      joesproxyctl stateful set-state --backend-id <uuid> --state <name>
      joesproxyctl stateful entities --backend-id <uuid> --collection <name>
      joesproxyctl stateful reset --backend-id <uuid>
      joesproxyctl isolate start --session-id <uuid> [--window-seconds <n>]
      joesproxyctl isolate step --outcome crashed|failed_assertion|succeeded|empty|unknown
        [--log-snippet <text>]
      joesproxyctl isolate report|cancel
      joesproxyctl media cmcd --session-ids <id,id,...>
      joesproxyctl media webvtt --session-id <uuid> [--reference-session <uuid>]
      joesproxyctl media drm [--manifest-session <uuid>] [--license-sessions <id,id>]
        [--media-sessions <id,id>]
      joesproxyctl media byte-range [--session-ids <id,id,...>]
      joesproxyctl media waterfall --session-id <uuid>
      joesproxyctl media visual --session-id <uuid>
      joesproxyctl media scte35 --master-session <uuid> [--variant-sessions <id,id>]
      joesproxyctl synthetic assets
      joesproxyctl synthetic inject --name <text> --url-pattern <pattern>
        [--collection-keypath <path>] [--position prepend|append|replace]
        [--bound-asset-kind clearLiveHLS|clearVODHLS|testPatternImage|syntheticVASTAd]
        [--custom-asset-url <url>] [--client-scope simulatorOnly|allClients]
      joesproxyctl synthetic plans
      joesproxyctl synthetic remove --plan-id <uuid>
      joesproxyctl instruments templates
      joesproxyctl instruments record [--template <name>] [--process <target>] [--duration <sec>]
      joesproxyctl instruments analyze --trace <path> [--template <name>]
      joesproxyctl instruments audit [--process <target>] [--template <name>] [--duration <sec>] [--trace <path>]
      joesproxyctl effect bundle list
      joesproxyctl effect bundle inspect (--file <path> | --bundle-id <uuid>)
      joesproxyctl effect bundle inspect --revision-id <prepared-revision-uuid>
      joesproxyctl effect bundle inspect <bundle-id> [--after-marker <observation-marker>]
      joesproxyctl effect bundle import --file <path>
      joesproxyctl effect bundle prepare --session-id <UUID> --name <name> --idempotency-key <key> --client-address <address> --draft <JSON>
        Frozen batches: draft.templateIndex plus expansionItems (1–100 entries), each with typed edits and optional images [{pointer,assetID}]. Unique identities required; image-N IDs follow --images order. Inspect the prepared revision before importing; activation is separate.
      joesproxyctl effect bundle retire-preparation --revision-id <UUID>
        Releases only the process-local prepared handle. Imported bundles remain unchanged. Retry retirement safely; use a new preparation key after retirement.
        [--image-file <path> --image-pointer <JSON Pointer> [--retain-image-url <URL>]]
        [--image-delivery-url <absolute URL> --image-reference <relative JSON value>]
        [--images <JSON array: optional itemPointer, file or localFileBookmarkRef, optional originalURL or deliveryURL + imageReference>]
        [--related-responses <JSON array: sessionID, optional targetSessionID or targetPath, edits [{pointer,value}], images [{pointer,assetID}], identityLinks [{pointer,primaryPointer}], optional ignoredQueryNames for observed targets>]
        Omit itemPointer only for related-only artwork explicitly bound by image-N asset ID (zero-based images array order).
        Each related source needs a complete captured GET body. targetSessionID selects an observed GET destination.
        targetPath authors an unobserved root-relative path on the source origin (4096 UTF-8 bytes maximum), with exact query matching; do not combine it with targetSessionID or ignoredQueryNames.
        Preparation stays inactive. Inspect source/target IDs, hashes, scopes and identity links before import and approval-gated activation.
      joesproxyctl effect bundle import --revision-id <prepared-revision-uuid>
      joesproxyctl effect bundle activate prepare <bundle-id> [--ttl <sec>] [--replace-conflicts]
      joesproxyctl effect bundle activate apply <token>
      joesproxyctl effect bundle stop <bundle-id>
      joesproxyctl effect bundle advance <bundle-id> --activation-id <UUID> --expected-phase-id <UUID>
      joesproxyctl run window begin <run-id> --bundle-id <UUID> --mode baseline|modified
      joesproxyctl run window end <window-id> [--target-outcome confirmed|rejected|unknown --outcome-source <source>]
      joesproxyctl effect bundle compare --baseline-window-id <UUID> --modified-window-id <UUID>
      joesproxyctl effect bundle discard prepare <bundle-id>
      joesproxyctl effect bundle discard apply <token>
    """
}
