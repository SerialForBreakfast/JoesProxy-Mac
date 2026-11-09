import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    private func compare(_ args: [String: Any], _ stack: TestStack) async throws -> ToolResponse {
        try await callSessionSummary(stack: stack, toolName: "artifact_compare_responses", toolArguments: args)
    }

    func testRevokingEitherShareWhileComparingSuppressesAllEvidence() async throws {
        for retireBaseline in [true, false] {
            let gate = ArtifactTestGate()
            let counter = ArtifactWorkCounter()
            defer { gate.open() }
            let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: {
                counter.increment()
                if counter.value == 3 { gate.wait() }
            }))
            var a = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
            var b = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
            a["recordIndex"] = 1
            b["recordIndex"] = 2
            let args = ["baseline": a, "candidate": b]
            let pending = try await compare(args, stack)
            XCTAssertNotNil(pending.errorData)
            let registry = stack.artifactSources
            let id = try XCTUnwrap(registry.pairReviews.keys.first)
            let duplicate = try await compare(args, stack)
            XCTAssertNotNil(duplicate.errorData)
            XCTAssertEqual(Array(registry.pairReviews.keys), [id])
            try registry.approvePair(id: id)
            let running = Task { try await self.compare(args, stack) }
            for _ in 0..<400 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(gate.entered)
            let competing = try summaryPayload(from: await compare(args, stack))
            XCTAssertEqual(competing["reason"] as? String, "busy")
            let retired = retireBaseline ? a : b
            let survivor = retireBaseline ? b : a
            let retiredHandle = try XCTUnwrap(retired["handle"] as? String)
            let request = try XCTUnwrap(registry.requests.first { $0.handle == retiredHandle })
            registry.retire(id: request.id, reason: "revoked")
            gate.open()
            let result = try summaryPayload(from: await running.value)
            XCTAssertEqual(result["reason"] as? String, "source_unavailable")
            XCTAssertEqual(Set(result.keys), ["status", "reason", "result", "analysisReused"])
            XCTAssertTrue(result["result"] is NSNull)
            let subsequent = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: survivor)
            XCTAssertEqual(try summaryPayload(from: subsequent)["status"] as? String, "complete")
        }
    }

    func testSavedPairApprovalBindingAndWorkflowCost() async throws {
        let counter = ArtifactWorkCounter()
        let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: { counter.increment() }))
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
        let discoveryStart = ContinuousClock.now
        let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
        let discoveryMs = milliseconds(since: discoveryStart)
        var setupBytes = 0
        let setupStart = ContinuousClock.now
        var left = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"]) { _, size in setupBytes += size }
        var right = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"]) { _, size in setupBytes += size }
        left["recordIndex"] = 0
        right["recordIndex"] = 1
        let setupMs = milliseconds(since: setupStart)
        let args: [String: Any] = ["baseline": left, "candidate": right]
        let reviewStart = ContinuousClock.now
        let pending = try await compare(args, stack)
        let registry = stack.artifactSources
        let review = try XCTUnwrap(registry.pairReviews.values.first)
        XCTAssertNotNil(pending.errorData)
        XCTAssertEqual(counter.value, 2)
        try registry.approvePair(id: review.approval.requestID)
        let poll = try await callSessionSummary(stack: stack, toolName: "approval_status", toolArguments: ["requestID": review.approval.requestID])
        let reviewMs = milliseconds(since: reviewStart)
        let reversed = try await compare(["baseline": right, "candidate": left], stack)
        XCTAssertNotNil(reversed.errorData)
        let compareStart = ContinuousClock.now
        let answer = try await compare(args, stack)
        let answerMs = milliseconds(since: compareStart)
        let report = try summaryPayload(from: answer)
        XCTAssertEqual(report["status"] as? String, "complete")
        XCTAssertEqual(report["wholeResponseBytesEqual"] as? Bool, false)
        XCTAssertEqual((report["changes"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(counter.value, 3)
        let again = try await compare(args, stack)
        XCTAssertNotNil(again.errorData)
        let singlesStart = ContinuousClock.now
        let first = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: left.merging(["includeStructure": true]) { _, new in new })
        let second = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: right.merging(["includeStructure": true]) { _, new in new })
        let before = try summaryPayload(from: first), after = try summaryPayload(from: second)
        XCTAssertEqual(before["structure"] as? NSArray, after["structure"] as? NSArray)
        XCTAssertNotEqual(before["sourceSHA256"] as? String, after["sourceSHA256"] as? String)
        let singlesMs = milliseconds(since: singlesStart)
        print("PAIR_COST catalog=\(catalog.wireBytes) setup=\(setupBytes) pending=\(pending.wireBytes) poll=\(poll.wireBytes) answer=\(answer.wireBytes) singles=\(first.wireBytes + second.wireBytes)")
        print("PAIR_TIME_MS discovery=\(discoveryMs) sourceSetup=\(setupMs) pairReview=\(reviewMs) pairAnswer=\(answerMs) singlesWithLocalComparison=\(singlesMs)")
        registry.revokeAll()
        XCTAssertTrue(registry.pairReviews.isEmpty)
        let denied = try summaryPayload(from: await compare(args, stack))
        XCTAssertEqual(denied["reason"] as? String, "source_unavailable")
    }

    func testPairReviewsRetireBeforeRetryAndNeverAuthorizeOtherSelections() async throws {
        for approved in [false, true] {
            for retireLeft in [false, true] {
                let stack = try await makeStack()
                var a = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
                var b = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
                a["recordIndex"] = 0
                b["recordIndex"] = 1
                let args = ["baseline": a, "candidate": b]
                let proposed = try await compare(args, stack)
                XCTAssertNotNil(proposed.errorData)
                let registry = stack.artifactSources
                let id = try XCTUnwrap(registry.pairReviews.keys.first)
                if approved { try registry.approvePair(id: id) }
                let handle = try XCTUnwrap((retireLeft ? a : b)["handle"] as? String)
                try registry.release(handle: handle, clientID: stack.enrollment.client.id)
                XCTAssertTrue(registry.pairReviews.isEmpty)
                XCTAssertThrowsError(try registry.approvePair(id: id))
                let poll = try await callSessionSummary(stack: stack, toolName: "approval_status", toolArguments: ["requestID": id])
                XCTAssertEqual(try summaryPayload(from: poll)["status"] as? String, "invalidated")
                let denied = try summaryPayload(from: await compare(args, stack))
                XCTAssertEqual(denied["reason"] as? String, "source_unavailable")
                XCTAssertFalse(denied.keys.contains("candidate"))
            }
        }
    }

    func testPairSuppressesInFlightReportOnExpiryPolicyRotationAndCancellation() async throws {
        for event in ["expiry", "policy", "rotation", "cancel", "revokeAll"] {
            let gate = ArtifactTestGate()
            defer { gate.open() }
            let counter = ArtifactWorkCounter()
            let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: {
                counter.increment()
                if counter.value == 2 { gate.wait() }
            }))
            var side = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
            side["recordIndex"] = 0
            let args = ["baseline": side, "candidate": side]
            _ = try await compare(args, stack)
            let registry = stack.artifactSources
            let review = try XCTUnwrap(registry.pairReviews.values.first)
            try registry.approvePair(id: review.approval.requestID)
            let running = Task { try await self.compare(args, stack) }
            for _ in 0..<400 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(gate.entered)
            switch event {
            case "expiry": registry.prune(now: Date().addingTimeInterval(3601))
            case "policy": registry.currentComparePermission = { _ in false }
            case "rotation": registry.currentOwner = { id in .init(clientID: id, generation: review.owner.generation + 1,
                policyRevision: review.owner.policyRevision, profile: .shareable) }
            case "cancel": running.cancel()
            default: registry.revokeAll()
            }
            gate.open()
            let result = try summaryPayload(from: await running.value)
            XCTAssertEqual(result["status"] as? String, "unavailable", event)
            XCTAssertTrue(result["result"] is NSNull, event)
            XCTAssertNil(result["changes"], event)
            XCTAssertNil(result["baseline"], event)
            XCTAssertNil(result["candidate"], event)
            XCTAssertFalse(registry.worker.busy)
        }
    }

    func testPairRequiresBothBriefScopesAndSameSessionEvenWithStandingGrant() async throws {
        let counter = ArtifactWorkCounter()
        let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: { counter.increment() }))
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .artifactCompare, mode: .untilSessionEnd)
        var side = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
        var metadata = try await reviewedHAR(stack, scopes: ["metadata-v1"])
        side["recordIndex"] = 0
        metadata["recordIndex"] = 0
        let registry = stack.artifactSources
        for pair in [["baseline": side, "candidate": metadata], ["baseline": metadata, "candidate": side]] {
            let response = try summaryPayload(from: await compare(pair, stack))
            XCTAssertEqual(response["reason"] as? String, "source_unavailable")
            XCTAssertTrue(registry.pairReviews.isEmpty)
        }
        let args: [String: Any] = ["baseline": side, "candidate": side, "selectionPointer": "/id"]
        let pending = try await compare(args, stack)
        XCTAssertNotNil(pending.errorData)
        let firstID = try XCTUnwrap(registry.pairReviews.keys.first)
        try registry.approvePair(id: firstID)
        let other = try await initializeSession(protocolService: stack.protocolService, bearer: stack.enrollment.plaintextCredential)
        let second = try await callRPC(stack: stack, method: "tools/call", params: ["name": "artifact_compare_responses", "arguments": args], session: other)
        XCTAssertNotNil(second.errorData)
        XCTAssertEqual(registry.pairReviews.count, 2)
        let changed = try await compare(args.merging(["selectionPointer": "/common"]) { _, new in new }, stack)
        XCTAssertEqual(try summaryPayload(from: changed)["reason"] as? String, "busy")
        XCTAssertEqual(counter.value, 2)
        let valid = try summaryPayload(from: await compare(args, stack))
        XCTAssertEqual(valid["wholeResponseBytesEqual"] as? Bool, true)
        XCTAssertEqual(counter.value, 3)
    }

    func testPairCLIWaitsForLocalApprovalOverLoopback() async throws {
        let stack = try await makeStack()
        let source = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
        let transport = MCPNIOHTTPTransport(protocolService: stack.protocolService)
        try await transport.start(port: 0)
        do {
            let port = try XCTUnwrap(transport.boundPort)
            stack.protocolService.rebindLoopbackPort(port)
            let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
            let store = TestCLISessionStore()
            try store.save(.init(endpoint: endpoint.absoluteString, sessionID: stack.transportSessionID, protocolVersion: "2025-11-25", updatedAt: Date()))
            let credentials = TestCLICredentialStore()
            try credentials.save(stack.enrollment.plaintextCredential, endpoint: endpoint)
            var output = Data()
            let cli = CLIApplication(credentialStore: credentials, sessionStore: store, writeResult: { output = $0 })
            let handle = try XCTUnwrap(source["handle"] as? String), revision = try XCTUnwrap(source["snapshotRevision"] as? String)
            let command = ["artifact", "compare", "--baseline-handle", handle, "--candidate-handle", handle,
                "--baseline-revision", revision, "--candidate-revision", revision, "--baseline-record", "1",
                "--candidate-record", "63", "--endpoint", endpoint.absoluteString, "--json", "--wait-for-approval", "--approval-timeout", "10"]
            let task = Task { await cli.run(arguments: command) }
            for _ in 0..<400 where stack.artifactSources.pairReviews.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            try stack.artifactSources.approvePair(id: XCTUnwrap(stack.artifactSources.pairReviews.keys.first))
            let exit = await task.value
            XCTAssertEqual(exit, .partialResult)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertEqual(result["status"] as? String, "incomplete")
            XCTAssertEqual((result["candidate"] as? [String: Any])?["reason"] as? String, "incomplete_body")
            XCTAssertEqual((result["changes"] as? [[String: Any]])?.count, 0)
        } catch {
            await transport.shutdown()
            throw error
        }
        await transport.shutdown()
    }
}
