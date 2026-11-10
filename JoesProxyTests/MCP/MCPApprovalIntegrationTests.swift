import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPApprovalIntegrationTests: XCTestCase {
    func testRecoveryDeniedStaleApprovalAndReconnectedInspectionDoNotMutate() async throws {
        let stack = try await makeStack()
        var rules = TLSInterceptionRules()
        var writes = 0
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { rules = $0; writes += 1 })
        let args: [String: Any] = ["host": "media.example.test", "mode": "tunnel", "recoveryID": UUID().uuidString,
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"]
        let pending = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        try stack.approvalStore.deny(requestID: XCTUnwrap(pending.requestID))
        let denied = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertNotNil(denied.errorData)
        XCTAssertEqual(writes, 0)
        let retry = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(retry.requestID))
        _ = stack.policyStore.bumpRevisionForTightening()
        let stale = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertNotNil(stale.errorData)
        XCTAssertEqual(writes, 0)
        let reviewedSession = try await initializeSession(protocolService: stack.protocolService, bearer: stack.enrollment.plaintextCredential)
        let reviewed = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args, sessionID: reviewedSession)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(reviewed.requestID))
        let applied = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args, sessionID: reviewedSession)
        XCTAssertNil(applied.errorData)
        XCTAssertEqual(writes, 1)
        _ = await stack.protocolService.handleHTTPRequest(method: "DELETE", path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: stack.enrollment.plaintextCredential, sessionID: reviewedSession), body: Data())
        let freshSession = try await initializeSession(protocolService: stack.protocolService, bearer: stack.enrollment.plaintextCredential)
        let read = try await callRuntimeControl(stack: stack, name: "https_rules_get",
            arguments: ["host": "media.example.test", "recoveryID": args["recoveryID"]!], sessionID: freshSession)
        XCTAssertNil(read.errorData)
        let payload = try XCTUnwrap(read.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual((payload["recovery"] as? [String: Any])?["state"] as? String, "applied")
        let duplicate = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args, sessionID: freshSession)
        XCTAssertNil(duplicate.errorData)
        XCTAssertEqual(writes, 1)
        let restore = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: [
            "host": "media.example.test", "recoveryID": args["recoveryID"]!, "expectedRevision": MCPHTTPSRules.revision(rules),
            "scope": "host_and_subdomains_all_clients"], sessionID: freshSession)
        XCTAssertEqual(restore.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertEqual(writes, 1)
    }

    func testRecoveryWriteAheadFailureNeverWritesSettings() async throws {
        let stack = try await makeStack()
        let blocker = temporaryURL(named: "blocked-parent")
        try Data("file not directory".utf8).write(to: blocker)
        let rules = TLSInterceptionRules()
        stack.protocolService.configureHTTPSRules(recoveryURL: blocker.appendingPathComponent("journal.json"),
            reader: { rules }, writer: { _ in XCTFail("Must persist intent before touching settings") })
        let args: [String: Any] = ["host": "media.example.test", "mode": "tunnel", "recoveryID": UUID().uuidString,
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"]
        let pending = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(pending.requestID))
        let failed = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertEqual(failed.errorData?["mcpCode"] as? String, MCPErrorCode.internalFailure.rawValue)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "file not directory")
        let again = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertEqual(again.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
    }


    func testSessionSummaryReportsPendingTransportWithoutReadingBody() async throws {
        let stack = try await makeStack()
        let diagnostics = RequestTransportDiagnostics()
        diagnostics.submitted(bytes: 128)
        stack.protocolService.setTransportEvidenceProvider { id in
            id == stack.session.id ? diagnostics.snapshot() : nil
        }
        let result = try await callRuntimeControl(stack: stack, name: "session_summary",
            arguments: ["sessionID": stack.session.id.uuidString])
        let payload = try XCTUnwrap(result.result?["structuredContent"] as? [String: Any])
        let evidence = try XCTUnwrap(payload["transportEvidence"] as? [String: Any])
        XCTAssertEqual(evidence["pendingWrites"] as? Int, 1)
        XCTAssertEqual(evidence["deliveryState"] as? String, "pending")
        XCTAssertEqual((payload["transportDiagnostic"] as? [String: Any])?["reason"] as? String, "downstream_delivery_pending")
        XCTAssertNil(payload["bodyExcerpt"])
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        diagnostics.completed(bytes: 128, succeeded: true)
        diagnostics.failed(error: HTTPResponseParserError.incompleteResponse)
        let failed = try await callRuntimeControl(stack: stack, name: "session_summary",
            arguments: ["sessionID": stack.session.id.uuidString])
        let failedPayload = try XCTUnwrap(failed.result?["structuredContent"] as? [String: Any])
        let guidance = try XCTUnwrap(failedPayload["transportDiagnostic"] as? [String: Any])
        XCTAssertEqual(guidance["reason"] as? String, "upstream_response_incomplete")
        XCTAssertNil(failedPayload["bodyExcerpt"])
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: failedPayload).count, 8192)
    }

    func testHTTPSRulesRequireExactApprovalAndRejectStaleSettings() async throws {
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id,
            capability: .httpsRulesManage, mode: .durablePolicy)
        var rules = TLSInterceptionRules()
        var writes = 0
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { rules = $0; writes += 1 })
        let arguments: [String: Any] = ["host": "media.example.test", "mode": "tunnel",
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"]
        let first = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        XCTAssertEqual(first.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertEqual(writes, 0)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(first.requestID))
        let result = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        XCTAssertNil(result.errorData)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(rules.bypassDomains, ["media.example.test"])
        let stale = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        XCTAssertEqual(stale.errorData?["mcpCode"] as? String, MCPErrorCode.staleProposal.rawValue)
        XCTAssertEqual(writes, 1)
        let read = try await callRuntimeControl(stack: stack, name: "https_rules_get", arguments: ["host": "media.example.test"])
        let payload = try XCTUnwrap(read.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual(payload["effectiveRuleMode"] as? String, "tunnel")
        XCTAssertEqual(payload["appliesTo"] as? String, "new_connections_only")
    }

    func testHTTPSInspectionIsReadOnlyAndChangeCannotForgeNarrowerScope() async throws {
        let stack = try await makeStack()
        let rules = TLSInterceptionRules()
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { _ in XCTFail("No mutation permitted") })
        let read = try await callRuntimeControl(stack: stack, name: "https_rules_get", arguments: ["host": "media.example.test"])
        XCTAssertNil(read.errorData)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        let result = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: [
            "host": "media.example.test", "mode": "tunnel", "expectedRevision": MCPHTTPSRules.revision(rules),
            "scope": "one_client", "clientAddress": "192.0.2.1"])
        XCTAssertEqual(result.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    func testHTTPSRulesChangedWhileAwaitingApprovalNeverApply() async throws {
        let stack = try await makeStack()
        var rules = TLSInterceptionRules()
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { _ in XCTFail("Must not write") })
        var arguments: [String: Any] = ["host": "media.example.test", "mode": "tunnel",
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"]
        let first = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(first.requestID))
        rules.bypassDomains = ["other.example.test"]
        let stale = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        XCTAssertEqual(stale.errorData?["mcpCode"] as? String, MCPErrorCode.staleProposal.rawValue)
        arguments["expectedRevision"] = MCPHTTPSRules.revision(rules)
        arguments["approved"] = true
        let forged = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: arguments)
        XCTAssertEqual(forged.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
    }

    func testHTTPSRecoveryLostRepliesRestoreAndConflictRequireSeparateReview() async throws {
        let stack = try await makeStack()
        let before = TLSInterceptionRules(bypassDomains: ["other.example.test"], interceptDomains: ["media.example.test"])
        var rules = before
        var writes = 0
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { rules = $0; writes += 1 })
        let recoveryID = UUID().uuidString
        let apply: [String: Any] = ["host": "media.example.test", "mode": "tunnel",
            "expectedRevision": MCPHTTPSRules.revision(before), "scope": "host_and_subdomains_all_clients", "recoveryID": recoveryID]
        let pending = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: apply)
        XCTAssertEqual(writes, 0)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(pending.requestID))
        let applied = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: apply)
        XCTAssertNil(applied.errorData)
        XCTAssertEqual(writes, 1)
        let after = rules
        let inspect = try await callRuntimeControl(stack: stack, name: "https_rules_get", arguments: ["host": "media.example.test"])
        let inspectPayload = try XCTUnwrap(inspect.result?["structuredContent"] as? [String: Any])
        let history = try XCTUnwrap(inspectPayload["recoveryHistory"] as? [String: Any])
        XCTAssertEqual(history["retainedCount"] as? Int, 1)
        XCTAssertEqual((history["receipts"] as? [[String: Any]])?.first?["recoveryID"] as? String, recoveryID)
        // Lost reply: identical retry reconciles without consuming another approval or applying again.
        let retry = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: apply)
        XCTAssertNil(retry.errorData)
        XCTAssertEqual(writes, 1)
        let payload = try XCTUnwrap(retry.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual((payload["recovery"] as? [String: Any])?["state"] as? String, "applied")
        let restore: [String: Any] = ["host": "media.example.test", "recoveryID": recoveryID,
            "expectedRevision": MCPHTTPSRules.revision(after), "scope": "host_and_subdomains_all_clients"]
        let pendingRestore = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: restore)
        XCTAssertEqual(pendingRestore.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertEqual(writes, 1)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(pendingRestore.requestID))
        rules.bypassDomains.append("new.example.test")
        let conflict = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: restore)
        XCTAssertEqual(conflict.errorData?["mcpCode"] as? String, MCPErrorCode.staleProposal.rawValue)
        XCTAssertEqual(writes, 1)
        rules = after
        let restored = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: restore)
        XCTAssertNil(restored.errorData)
        XCTAssertEqual(rules, before)
        XCTAssertEqual(writes, 2)
        let restoreRetry = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: restore)
        XCTAssertNil(restoreRetry.errorData)
        XCTAssertEqual(writes, 2)
        let oldApply = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: apply)
        XCTAssertNil(oldApply.errorData)
        XCTAssertEqual(writes, 2, "An old ID never reopens a restored change")
        let final = try XCTUnwrap(oldApply.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual((final["recovery"] as? [String: Any])?["state"] as? String, "restored")
    }

    func testHTTPSRecoveryRejectsForgedAuthorityChangedIntentAndUnverifiedWrites() async throws {
        let stack = try await makeStack()
        let rules = TLSInterceptionRules()
        var attempts = 0
        stack.protocolService.configureHTTPSRules(reader: { rules }, writer: { _ in attempts += 1 })
        var args: [String: Any] = ["host": "media.example.test", "mode": "tunnel",
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients", "recoveryID": UUID().uuidString]
        args["approved"] = true
        let forged = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertEqual(forged.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        args.removeValue(forKey: "approved")
        let pending = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(pending.requestID))
        let failed = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertEqual(failed.errorData?["mcpCode"] as? String, MCPErrorCode.internalFailure.rawValue)
        let retry = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertNil(retry.errorData)
        XCTAssertEqual(attempts, 1)
        let result = try XCTUnwrap(retry.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual((result["recovery"] as? [String: Any])?["state"] as? String, "not_applied")
        args["mode"] = "inspect"
        let altered = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertEqual(altered.errorData?["mcpCode"] as? String, MCPErrorCode.staleProposal.rawValue)
        XCTAssertEqual(attempts, 1)
        let closed = try await callRuntimeControl(stack: stack, name: "https_rules_restore", arguments: [
            "host": "media.example.test", "recoveryID": args["recoveryID"]!,
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"])
        XCTAssertNil(closed.errorData)
        let closedPayload = try XCTUnwrap(closed.result?["structuredContent"] as? [String: Any])
        XCTAssertEqual((closedPayload["recovery"] as? [String: Any])?["state"] as? String, "not_applied_closed")
        XCTAssertEqual(attempts, 1)
    }

    func testHTTPSRecoveryRestartAndJournalFailureDoNotRepeatSettingsWrite() async throws {
        let stack = try await makeStack()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/TransportDiagnostics/RecoveryTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        var rules = TLSInterceptionRules()
        var writes = 0
        stack.protocolService.configureHTTPSRules(recoveryURL: url, reader: { rules }, writer: { rules = $0; writes += 1 })
        let args: [String: Any] = ["host": "media.example.test", "mode": "tunnel", "recoveryID": UUID().uuidString,
            "expectedRevision": MCPHTTPSRules.revision(rules), "scope": "host_and_subdomains_all_clients"]
        let pending = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(pending.requestID))
        let applied = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertNil(applied.errorData)
        stack.protocolService.configureHTTPSRules(recoveryURL: url, reader: { rules }, writer: { rules = $0; writes += 1 })
        XCTAssertEqual(writes, 1)
        let retry = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: args)
        XCTAssertNil(retry.errorData)
        XCTAssertEqual(writes, 1)
        // A second owner can see ordinary host rules, but never another owner's recovery snapshots.
        let other = try await makeStack()
        other.protocolService.configureHTTPSRules(recoveryURL: url, reader: { rules }, writer: { _ in XCTFail("Foreign write") })
        let foreign = try await callRuntimeControl(stack: other, name: "https_rules_get",
            arguments: ["host": "media.example.test", "recoveryID": args["recoveryID"]!])
        XCTAssertEqual(foreign.errorData?["mcpCode"] as? String, MCPErrorCode.policyDenied.rawValue)
        try Data("broken".utf8).write(to: url)
        stack.protocolService.configureHTTPSRules(recoveryURL: url, reader: { rules }, writer: { _ in XCTFail("Corrupt journal write") })
        var fresh = args
        fresh["recoveryID"] = UUID().uuidString
        fresh["mode"] = "remove"
        fresh["expectedRevision"] = MCPHTTPSRules.revision(rules)
        let unavailable = try await callRuntimeControl(stack: stack, name: "https_rules_set", arguments: fresh)
        XCTAssertEqual(unavailable.errorData?["mcpCode"] as? String, MCPErrorCode.internalFailure.rawValue)
        XCTAssertEqual(writes, 1)
    }

    func testCaptureStatusAndDigestReportPressureWithoutMutationOrApproval() async throws {
        let stack = try await makeStack()
        let admission = CaptureAdmissionBudget()
        stack.protocolService.setCaptureStatusProvider {
            MCPCaptureStatusDTO(proxyState: "running", admission: admission.snapshot,
                perResponseByteLimit: 1_048_576, retainedBodyByteLimit: 250 * 1_048_576)
        }
        func payload(_ response: ToolResponse) throws -> [String: Any] {
            let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
            return try XCTUnwrap(structured["payload"] as? [String: Any])
        }
        let before = try payload(await callRuntimeControl(stack: stack, name: "capture_digest"))
        XCTAssertNil(before["captureWarning"])
        for tool in ["sessions_list", "sessions_search"] {
            let page = try payload(await callRuntimeControl(stack: stack, name: tool))
            XCTAssertNil(page["captureWarning"])
        }
        let reservation = try XCTUnwrap(admission.reserve(bytes: 128 * 1_024 * 1_024))
        defer { admission.release(reservation) }
        XCTAssertNil(admission.reserve(bytes: 1))
        let status = try payload(await callRuntimeControl(stack: stack, name: "capture_status"))
        XCTAssertEqual(status["futureBodyCapture"] as? String, "admission_paused")
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        let after = try payload(await callRuntimeControl(stack: stack, name: "capture_digest",
            arguments: ["ifStateToken": try XCTUnwrap(before["stateToken"] as? String)]))
        XCTAssertEqual(after["unchanged"] as? Bool, false)
        XCTAssertEqual((after["captureStatus"] as? [String: Any])?["admissionPaused"] as? Bool, true)
        XCTAssertNotNil(after["captureWarning"])
        for tool in ["sessions_list", "sessions_search"] {
            let page = try payload(await callRuntimeControl(stack: stack, name: tool))
            XCTAssertNotNil(page["captureWarning"])
        }
    }

    func testResumeRejectsForgedForceArgumentsBeforeApproval() async throws {
        let stack = try await makeStack()
        stack.protocolService.setRuntimeControlHandler { _ in
            XCTFail("Invalid arguments must not execute")
            return [:]
        }
        let response = try await callRuntimeControl(stack: stack, name: "capture_resume", arguments: ["force": true])
        XCTAssertEqual(response.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    func testCaptureResumeRequiresItsOwnApprovalWithoutGrantingBodyRead() async throws {
        let stack = try await makeStack()
        var actions: [MCPRuntimeControlAction] = []
        stack.protocolService.setRuntimeControlHandler { action in
            actions.append(action)
            return ["action": action.rawValue, "state": "running"]
        }
        let first = try await callRuntimeControl(stack: stack, name: "capture_resume")
        XCTAssertEqual(first.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertTrue(actions.isEmpty)
        _ = try stack.approvalStore.approve(requestID: XCTUnwrap(first.requestID))
        let retried = try await callRuntimeControl(stack: stack, name: "capture_resume")
        XCTAssertNil(retried.errorData)
        XCTAssertEqual(actions, [.resumeCapture])
        XCTAssertNil(stack.grantStore.activeGrant(capability: .bodyRead, clientID: stack.enrollment.client.id))
    }

    func testRuntimeControlRequiresApprovalAndOnlyExecutesOnIdenticalRetry() async throws {
        let stack = try await makeStack()
        var actions: [MCPRuntimeControlAction] = []
        stack.protocolService.setRuntimeControlHandler { action in
            actions.append(action)
            return ["action": action.rawValue, "state": "running"]
        }

        let first = try await callRuntimeControl(stack: stack, name: "proxy_start")
        XCTAssertEqual(first.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertTrue(actions.isEmpty)
        let requestID = try XCTUnwrap(first.requestID)
        _ = try stack.approvalStore.approve(requestID: requestID)
        XCTAssertTrue(actions.isEmpty, "approval must never execute runtime control")

        let retry = try await callRuntimeControl(stack: stack, name: "proxy_start")
        XCTAssertNil(retry.errorData)
        XCTAssertEqual(actions, [.startProxy])
    }

    func testRuntimeControlRetryConsumesApprovalAfterDurableGrantIsAdded() async throws {
        let stack = try await makeStack()
        var actions: [MCPRuntimeControlAction] = []
        stack.protocolService.setRuntimeControlHandler { action in
            actions.append(action)
            return ["action": action.rawValue, "state": "running"]
        }

        let first = try await callRuntimeControl(stack: stack, name: "proxy_start")
        let requestID = try XCTUnwrap(first.requestID)
        _ = try stack.approvalStore.approve(requestID: requestID)
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let retry = try await callRuntimeControl(stack: stack, name: "proxy_start")

        XCTAssertNil(retry.errorData)
        XCTAssertEqual(actions, [.startProxy])
        XCTAssertEqual(
            stack.approvalStore.status(
                requestID: requestID,
                clientID: stack.enrollment.client.id,
                mcpSessionID: stack.transportSessionID
            )?.status,
            .consumed
        )
    }

    func testRuntimeControlToolsAreInProductionManifest() {
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.isSuperset(of: [
            "runtime_status", "proxy_start", "proxy_stop", "mcp_stop"
        ]))
        XCTAssertEqual(MCPCapabilityID.runtimeControl.riskTier, .mutatingTool)
    }

    func testRemoteClientCanInspectButCannotResolveApprovals() async throws {
        let stack = try await makeStack()
        let resolutionToolNames = ["approval_approve", "approval_deny"]
        let manifestNames = MCPCapabilitiesManifestBuilder.productionToolNames

        XCTAssertTrue(manifestNames.isSuperset(of: ["approval_status", "approvals_list"]))
        XCTAssertTrue(manifestNames.isDisjoint(with: resolutionToolNames))

        let listBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 40,
            "method": "tools/list",
            "params": [:]
        ])
        let listResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: stack.enrollment.plaintextCredential,
                sessionID: stack.transportSessionID
            ),
            body: listBody
        )
        let listObject = try listResponse.jsonBodyObject()
        let result = try XCTUnwrap(listObject["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let discoveredNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(discoveredNames.isSuperset(of: ["approval_status", "approvals_list"]))
        XCTAssertTrue(discoveredNames.isDisjoint(with: resolutionToolNames))

        for (index, toolName) in resolutionToolNames.enumerated() {
            let callBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 41 + index,
                "method": "tools/call",
                "params": [
                    "name": toolName,
                    "arguments": ["requestID": "request-owned-by-local-ui"]
                ]
            ])
            let callResponse = await stack.protocolService.handleHTTPRequest(
                method: "POST",
                path: MCPNetworkConstants.endpointPath,
                headers: authenticatedHeaders(
                    bearer: stack.enrollment.plaintextCredential,
                    sessionID: stack.transportSessionID
                ),
                body: callBody
            )
            let callObject = try callResponse.jsonBodyObject()
            let error = try XCTUnwrap(callObject["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32601)
            XCTAssertTrue((error["message"] as? String)?.contains("Unknown or unavailable tool") == true)
        }
    }

    func testRuntimeStatusReportsDurableUnattendedReadinessWithoutApproval() async throws {
        let stack = try await makeStack()
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "stopped",
                proxyPort: nil
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(stack: stack, name: "runtime_status")
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])

        XCTAssertEqual(payload["readyForUnattendedControl"] as? Bool, true)
        XCTAssertEqual(payload["state"] as? String, "ready")
        XCTAssertEqual(payload["runtimeControlGrantMode"] as? String, "durablePolicy")
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    func testRuntimeStatusReportsBuildIdentityAndRejectsStaleCapabilityExpectation() async throws {
        let stack = try await makeStack()
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "stopped",
                proxyPort: nil
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(
            stack: stack,
            name: "runtime_status",
            arguments: [
                "expectedRuntime": [
                    "capabilitiesBundleVersion": "1.4.1+\(MCPCapabilitiesRevision.current - 1)"
                ]
            ]
        )
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let identity = try XCTUnwrap(payload["runtimeIdentity"] as? [String: Any])
        let compatibility = try XCTUnwrap(payload["compatibility"] as? [String: Any])

        XCTAssertEqual((identity["appBuildFingerprint"] as? String)?.count, 64)
        XCTAssertEqual((identity["capabilitiesManifestDigest"] as? String)?.count, 64)
        XCTAssertNotNil(identity["marketingVersion"] as? String)
        XCTAssertNotNil(identity["buildVersion"] as? String)
        XCTAssertNotNil(identity["skillVersion"] as? String)
        XCTAssertEqual(compatibility["state"] as? String, "incompatible")
        XCTAssertEqual(payload["readyForUnattendedControl"] as? Bool, false)
    }

    // G6-01: doctor/runtime_status must report every active grant, not a hardcoded subset — a
    // capability outside the old fixed five-item allowlist (createDisabledMapLocal here) must
    // still show up in activeStandingGrants.
    func testRuntimeStatusReportsStandingGrantsOutsideTheOriginalFixedAllowlist() async throws {
        let stack = try await makeStack()
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "stopped",
                proxyPort: nil
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .createDisabledMapLocal,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(stack: stack, name: "runtime_status")
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let activeStandingGrants = try XCTUnwrap(payload["activeStandingGrants"] as? [String])

        XCTAssertTrue(activeStandingGrants.contains(MCPCapabilityID.createDisabledMapLocal.rawValue))
    }

    func testRuntimeStatusBlocksUnattendedStartWhenSystemProxyManagementIsEnabled() async throws {
        let stack = try await makeStack()
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "running",
                proxyPort: 9090,
                systemProxyManagementEnabled: true
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(stack: stack, name: "runtime_status")
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let checks = try XCTUnwrap(payload["checks"] as? [[String: Any]])
        let systemProxyCheck = try XCTUnwrap(checks.first { $0["id"] as? String == "system_proxy_management" })
        XCTAssertEqual(systemProxyCheck["state"] as? String, "action_required")
        XCTAssertEqual(payload["readyForUnattendedControl"] as? Bool, false)
    }

    func testProxyStartCannotActivateArmedSystemProxyRouting() async throws {
        let stack = try await makeStack()
        var actions: [MCPRuntimeControlAction] = []
        stack.protocolService.setRuntimeControlHandler { action in
            actions.append(action)
            return ["action": action.rawValue, "state": "running"]
        }
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "stopped",
                proxyPort: nil,
                systemProxyManagementEnabled: true
            )
        }

        let response = try await callRuntimeControl(stack: stack, name: "proxy_start")

        XCTAssertEqual(response.errorData?["mcpCode"] as? String, MCPErrorCode.policyDenied.rawValue)
        XCTAssertTrue((response.errorData?["message"] as? String ?? "").contains("manually"))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    func testProxyStopRemainsAvailableWhenSystemProxyRoutingIsArmed() async throws {
        let stack = try await makeStack()
        var actions: [MCPRuntimeControlAction] = []
        stack.protocolService.setRuntimeControlHandler { action in
            actions.append(action)
            return ["action": action.rawValue, "state": "stopped"]
        }
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "running",
                proxyPort: 9090,
                systemProxyManagementEnabled: true
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(stack: stack, name: "proxy_stop")

        XCTAssertNil(response.errorData)
        XCTAssertEqual(actions, [.stopProxy])
    }

    /// The manual-action check must not appear when the preference is off (the common/default case) —
    /// otherwise every `doctor` run would show noise unrelated to the client's actual situation.
    func testRuntimeStatusOmitsSystemProxyManualActionWhenDisabled() async throws {
        let stack = try await makeStack()
        stack.protocolService.setManagedRuntimeStatusProvider {
            MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: true,
                proxyState: "running",
                proxyPort: 9090,
                systemProxyManagementEnabled: false
            )
        }
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .runtimeControl,
            mode: .durablePolicy
        )

        let response = try await callRuntimeControl(stack: stack, name: "runtime_status")
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let checks = try XCTUnwrap(payload["checks"] as? [[String: Any]])
        XCTAssertNil(checks.first { $0["id"] as? String == "system_proxy_management" })
    }

    func testSensitiveSessionSummaryRequiresApproval() async throws {
        let stack = try await makeStack()
        let response = try await callSessionSummary(
            stack: stack,
            includeHeaders: true
        )
        let data = try XCTUnwrap(response.errorData)
        XCTAssertEqual(data["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertEqual(stack.approvalStore.pendingCount, 1)
    }

    func testRetryWithValidAuthorizationSucceeds() async throws {
        let stack = try await makeStack()
        let first = try await callSessionSummary(stack: stack, includeHeaders: true)
        let requestID = try XCTUnwrap(first.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)
        let retry = try await callSessionSummary(
            stack: stack,
            includeHeaders: true,
            approval: authObject
        )
        XCTAssertNil(retry.errorData)
        XCTAssertNotNil(retry.result)
    }

    func testApprovalDoesNotExecuteAndIdenticalRetryConsumesAutomaticGrant() async throws {
        let stack = try await makeStack()
        let first = try await callSessionSummary(stack: stack, includeBody: true)
        let requestID = try XCTUnwrap(first.requestID)
        _ = try stack.approvalStore.approve(requestID: requestID)
        let waiting = try XCTUnwrap(stack.approvalStore.status(
            requestID: requestID,
            clientID: stack.enrollment.client.id,
            mcpSessionID: stack.transportSessionID
        ))
        XCTAssertEqual(waiting.status, .approvedAwaitingRetry)
        XCTAssertNil(first.result, "approval must not execute the gated read")

        let retry = try await callSessionSummary(stack: stack, includeBody: true)
        XCTAssertNil(retry.errorData)
        XCTAssertNotNil(retry.result)
        XCTAssertEqual(
            stack.approvalStore.status(
                requestID: requestID,
                clientID: stack.enrollment.client.id,
                mcpSessionID: stack.transportSessionID
            )?.status,
            .consumed
        )
    }

    func testIdenticalPendingApprovalRequestsAreDeduplicated() async throws {
        let stack = try await makeStack()
        let first = try await callSessionSummary(stack: stack, includeHeaders: true)
        let second = try await callSessionSummary(stack: stack, includeHeaders: true)
        XCTAssertEqual(first.requestID, second.requestID)
        XCTAssertEqual(stack.approvalStore.pendingCount, 1)
    }

    func testReplaySameNonceIsRejected() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeBody: true)
        let requestID = try XCTUnwrap(stack.approvalStore.pendingRequests.first?.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)
        _ = try await callSessionSummary(stack: stack, includeBody: true, approval: authObject)
        let replay = try await callSessionSummary(stack: stack, includeBody: true, approval: authObject)
        XCTAssertEqual(replay.errorData?["mcpCode"] as? String, MCPErrorCode.approvalReused.rawValue)
    }

    func testExpiredAuthorizationIsRejected() async throws {
        // The server never trusts a client-echoed `expiresAt` (that would let a client claim its
        // own token is still valid, defeating expiry entirely) — so genuine expiry has to be
        // produced by backdating the grant on the server side, via the store's own `now:` seam,
        // not by mutating the authorization object the test then presents.
        let stack = try await makeStack()
        let arguments: [String: Any] = ["sessionID": stack.session.id.uuidString, "includeQuery": true]
        let digest = MCPArgumentDigest.normalized(arguments)
        let capability = MCPCapabilityRouter.primarySensitiveCapability(from: arguments) ?? .headerRead
        let backdatedCreation = Date().addingTimeInterval(-(MCPApprovalPolicy.defaultLifetime + 80))
        let pending = stack.approvalStore.createPendingRequest(
            clientID: stack.enrollment.client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: stack.policyStore.policyRevision,
            reason: "test",
            now: backdatedCreation
        )
        let authorization = try stack.approvalStore.approve(
            requestID: pending.requestID,
            now: backdatedCreation.addingTimeInterval(1)
        )
        XCTAssertLessThan(authorization.expiresAt, Date(), "authorization must actually be expired by real wall-clock time")
        let authObject = try authorizationJSONObject(authorization)
        let retry = try await callSessionSummary(
            stack: stack,
            includeQuery: true,
            approval: authObject
        )
        XCTAssertEqual(retry.errorData?["mcpCode"] as? String, MCPErrorCode.approvalExpired.rawValue)
    }

    /// Regression test for a confirmed bypass: the retry path used to build its "known-good"
    /// comparison record directly from the client-supplied authorization, so every field-equality
    /// check was tautologically true. A client that never had anything approved could fabricate its
    /// own `MCPApprovalAuthorization` — with a fresh, never-granted nonce echoing back the exact
    /// `requestID`/`argumentDigest`/`policyRevision` values it received in the `approval_required`
    /// error — and self-approve. This must now be rejected the same way as having no approval at
    /// all: a fresh `approval_required`, not an accepted disclosure.
    func testForgedAuthorizationIsRejected() async throws {
        let stack = try await makeStack()
        let first = try await callSessionSummary(stack: stack, includeHeaders: true)
        let requestID = try XCTUnwrap(first.requestID)
        let pending = try XCTUnwrap(stack.approvalStore.pendingRequest(requestID: requestID))

        // Never call approvalStore.approve(requestID:) — this authorization is entirely
        // self-minted by the "client", echoing the real request's fields but with a nonce the
        // server never issued.
        let forged = MCPApprovalAuthorization(
            requestID: pending.requestID,
            clientID: pending.clientID,
            capability: pending.capability,
            argumentDigest: pending.argumentDigest,
            policyRevision: pending.policyRevision,
            targetRevision: pending.targetRevision,
            nonce: UUID().uuidString,
            expiresAt: pending.expiresAt
        )
        let forgedObject = try authorizationJSONObject(forged)
        let retry = try await callSessionSummary(
            stack: stack,
            includeHeaders: true,
            approval: forgedObject
        )
        XCTAssertNil(retry.result, "a forged authorization must never grant disclosure")
        XCTAssertEqual(retry.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
    }

    func testChangedArgumentsFailValidation() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeHeaders: true)
        let requestID = try XCTUnwrap(stack.approvalStore.pendingRequests.first?.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)
        let retry = try await callSessionSummary(
            stack: stack,
            includeHeaders: true,
            includeBody: true,
            approval: authObject
        )
        XCTAssertEqual(retry.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
    }

    func testPolicyTighteningInvalidatesPendingApprovals() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeHeaders: true)
        XCTAssertEqual(stack.approvalStore.pendingCount, 1)
        _ = stack.policyStore.bumpRevisionForTightening()
        stack.protocolService.invalidateSessionsForPolicyChange()
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    func testDeniedApprovalRequiresFreshApprovalOnRetry() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeHeaders: true)
        let requestID = try XCTUnwrap(stack.approvalStore.pendingRequests.first?.requestID)
        try stack.approvalStore.deny(requestID: requestID)
        let retry = try await callSessionSummary(stack: stack, includeHeaders: true)
        XCTAssertEqual(retry.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
    }

    func testApplyDisableRuleNeverReturnsApprovalRequiredOverHTTP() async throws {
        let stack = try await makeMutationWiredStack()
        let ruleID = try await createAndEnableBlockViaMutation(stack: stack, path: "/http-disable-approval")

        let propose = try await callNamedTool(
            stack: stack,
            name: "propose_disable_rule",
            arguments: ["overrideID": ruleID.uuidString]
        )
        XCTAssertNil(propose.errorData)
        let structured = try XCTUnwrap(
            (propose.result?["structuredContent"] as? [String: Any])
        )
        let proposalPayload = (structured["payload"] as? [String: Any]) ?? structured
        let token = try XCTUnwrap(proposalPayload["proposalToken"] as? String)

        let apply = try await callNamedTool(
            stack: stack,
            name: "apply_disable_rule",
            arguments: ["proposalToken": token]
        )
        XCTAssertNil(
            apply.errorData,
            "apply_disable_rule must not return approval_required; got \(apply.errorData?["mcpCode"] as? String ?? "nil")"
        )
        XCTAssertNotNil(apply.result)
        let store = try XCTUnwrap(stack.responseOverrideStore)
        let rules = await store.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
    }

    /// New capability: `approvals_list` lets an operator/agent discover every pending request's
    /// capability and reason at once, instead of only ever learning about one `requestID` per
    /// blocked call (see `MCPAndCLIUserExperienceValidation.md`, "No CLI command surfaces the list
    /// of currently-pending approval requests").
    func testApprovalsListReturnsAllPendingRequestsWithCapabilityAndReason() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeHeaders: true)
        _ = try await callSessionSummary(stack: stack, includeBody: true)
        XCTAssertEqual(stack.approvalStore.pendingCount, 2)

        let response = try await callNamedTool(stack: stack, name: "approvals_list", arguments: [:])
        XCTAssertNil(response.errorData)
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        XCTAssertEqual(payload["count"] as? Int, 2)
        let pending = try XCTUnwrap(payload["pending"] as? [[String: Any]])
        let capabilities = Set(pending.compactMap { $0["capability"] as? String })
        XCTAssertEqual(capabilities, [MCPCapabilityID.headerRead.rawValue, MCPCapabilityID.bodyRead.rawValue])
        XCTAssertTrue(pending.allSatisfy { !(($0["reason"] as? String) ?? "").isEmpty })
        XCTAssertTrue(pending.allSatisfy { $0["requestID"] != nil && $0["expiresAt"] != nil })
    }

    /// Approved-and-consumed or denied requests must never reappear in `approvals_list` — it only
    /// ever reflects genuinely outstanding requests, matching `pendingRequests`'/`pendingCount`'s
    /// existing pending-only semantics.
    func testApprovalsListOmitsConsumedAndDeniedRequests() async throws {
        let stack = try await makeStack()
        let toConsume = try await callSessionSummary(stack: stack, includeHeaders: true)
        let consumeRequestID = try XCTUnwrap(toConsume.requestID)
        let authorization = try stack.approvalStore.approve(requestID: consumeRequestID)
        let authObject = try authorizationJSONObject(authorization)
        _ = try await callSessionSummary(stack: stack, includeHeaders: true, approval: authObject)

        let toDeny = try await callSessionSummary(stack: stack, includeBody: true)
        let denyRequestID = try XCTUnwrap(toDeny.requestID)
        try stack.approvalStore.deny(requestID: denyRequestID)

        let response = try await callNamedTool(stack: stack, name: "approvals_list", arguments: [:])
        let structured = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        XCTAssertEqual(payload["count"] as? Int, 0)
        XCTAssertEqual((payload["pending"] as? [[String: Any]])?.isEmpty, true)
    }

    func testClientDisconnectPrunesPendingApprovals() async throws {
        let stack = try await makeStack()
        _ = try await callSessionSummary(stack: stack, includeHeaders: true)
        XCTAssertEqual(stack.approvalStore.pendingCount, 1)
        stack.approvalStore.prunePending(for: stack.enrollment.client.id)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    private struct TestStack {
        let protocolService: MCPProtocolService
        let approvalStore: MCPApprovalStore
        let policyStore: MCPPolicyStore
        let grantStore: MCPClientGrantStore
        let enrollment: MCPClientRegistry.EnrollmentResult
        let session: SessionRecord
        let transportSessionID: String
        let mutationService: MCPMutationService?
        let responseOverrideStore: ResponseOverrideStore?
    }

    private struct ToolResponse {
        let result: [String: Any]?
        let errorData: [String: Any]?
        let requestID: String?
    }

    private func makeStack() async throws -> TestStack {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-approval.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-approval.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-approval.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "grants-approval.json"))
        grantStore.load()
        let sessionStore = InMemorySessionStore()
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/resource?token=secret",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer secret"),
                    HTTPHeaderField(name: "Accept", value: "application/json")
                ],
                bodyData: Data("{\"ok\":true}".utf8),
                bodySize: 11
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                bodySize: 11
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        sessionStore.append(session)
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            grantStore: grantStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: approvalStore
        )
        let enrollment = try clientRegistry.enroll(
            displayName: "Approval",
            assignedProfileID: .shareable
        )
        let transportSessionID = try await initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        return TestStack(
            protocolService: protocolService,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            enrollment: enrollment,
            session: session,
            transportSessionID: transportSessionID,
            mutationService: nil,
            responseOverrideStore: nil
        )
    }

    private func makeMutationWiredStack() async throws -> TestStack {
        let stack = try await makeStack()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-approval-disable.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { stack.policyStore.policyRevision }
        )
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-approval-disable-mut.json"))
        auditStore.load()
        let mutationService = MCPMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: stack.approvalStore,
            policyStore: stack.policyStore,
            grantStore: stack.grantStore,
            auditStore: auditStore,
            enforcesLiveRewritePreview: false
        )
        stack.protocolService.setMutationService(mutationService)
        return TestStack(
            protocolService: stack.protocolService,
            approvalStore: stack.approvalStore,
            policyStore: stack.policyStore,
            grantStore: stack.grantStore,
            enrollment: stack.enrollment,
            session: stack.session,
            transportSessionID: stack.transportSessionID,
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore
        )
    }

    private func createAndEnableBlockViaMutation(stack: TestStack, path: String) async throws -> UUID {
        let mutationService = try XCTUnwrap(stack.mutationService)
        let store = try XCTUnwrap(stack.responseOverrideStore)
        let client = stack.enrollment.client
        let proposal = try await mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "statusCode": 403
            ],
            client: client
        )
        let createToken = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approveAndApply(
            stack: stack,
            mutationService: mutationService,
            tool: "apply_create_block",
            args: ["proposalToken": createToken]
        )
        let rules = await store.rules()
        let ruleID = try XCTUnwrap(rules.first?.id)
        let enableProposal = try await mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: client
        )
        let enableToken = try XCTUnwrap(enableProposal["proposalToken"] as? String)
        _ = try await approveAndApply(
            stack: stack,
            mutationService: mutationService,
            tool: "apply_enable_rule",
            args: ["proposalToken": enableToken]
        )
        return ruleID
    }

    private func approveAndApply(
        stack: TestStack,
        mutationService: MCPMutationService,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await mutationService.handleTool(name: tool, arguments: args, client: stack.enrollment.client)
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(authorization)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var retry = args
            retry["approval"] = object
            return try await mutationService.handleTool(name: tool, arguments: retry, client: stack.enrollment.client)
        }
    }

    private func callNamedTool(
        stack: TestStack,
        name: String,
        arguments: [String: Any]
    ) async throws -> ToolResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ])
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: stack.enrollment.plaintextCredential,
                sessionID: stack.transportSessionID
            ),
            body: body
        )
        let object = try response.jsonBodyObject()
        if let error = object["error"] as? [String: Any],
           let data = error["data"] as? [String: Any] {
            return ToolResponse(
                result: nil,
                errorData: data,
                requestID: data["requestID"] as? String
            )
        }
        return ToolResponse(result: object["result"] as? [String: Any], errorData: nil, requestID: nil)
    }

    private func callSessionSummary(
        stack: TestStack,
        includeHeaders: Bool = false,
        includeQuery: Bool = false,
        includeBody: Bool = false,
        approval: [String: Any]? = nil
    ) async throws -> ToolResponse {
        var arguments: [String: Any] = ["sessionID": stack.session.id.uuidString]
        if includeHeaders { arguments["includeHeaders"] = true }
        if includeQuery { arguments["includeQuery"] = true }
        if includeBody { arguments["includeBody"] = true }
        if let approval { arguments["approval"] = approval }
        let bodyObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 99,
            "method": "tools/call",
            "params": [
                "name": "session_summary",
                "arguments": arguments
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: stack.enrollment.plaintextCredential,
                sessionID: stack.transportSessionID
            ),
            body: body
        )
        let object = try response.jsonBodyObject()
        if let error = object["error"] as? [String: Any],
           let data = error["data"] as? [String: Any] {
            return ToolResponse(
                result: nil,
                errorData: data,
                requestID: data["requestID"] as? String
            )
        }
        return ToolResponse(result: object["result"] as? [String: Any], errorData: nil, requestID: nil)
    }

    private func callRuntimeControl(
        stack: TestStack,
        name: String,
        arguments: [String: Any] = [:], sessionID: String? = nil
    ) async throws -> ToolResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 100,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: stack.enrollment.plaintextCredential,
                sessionID: sessionID ?? stack.transportSessionID
            ),
            body: body
        )
        let object = try response.jsonBodyObject()
        if let error = object["error"] as? [String: Any],
           let data = error["data"] as? [String: Any] {
            return ToolResponse(result: nil, errorData: data, requestID: data["requestID"] as? String)
        }
        return ToolResponse(result: object["result"] as? [String: Any], errorData: nil, requestID: nil)
    }

    private func authorizationJSONObject(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initializeSession(protocolService: MCPProtocolService, bearer: String) async throws -> String {
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let sessionID = try XCTUnwrap(response.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private func temporaryURL(named: String) -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/TransportDiagnostics/RecoveryFaultTests")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + named)
        addTeardownBlock { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
        return url
    }

    private func authenticatedHeaders(bearer: String, sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer \(bearer)",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            "accept": "application/json, text/event-stream",
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
            MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID
        ]
    }
}
