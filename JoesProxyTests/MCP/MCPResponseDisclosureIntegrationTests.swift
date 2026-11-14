import Foundation
import XCTest
@testable import JoesProxy

/// End-to-end MCP disclosure coverage for GET response bodies and response headers (AM-1).
@MainActor
final class MCPResponseDisclosureIntegrationTests: XCTestCase {
    func testArtifactSearchConsentPaginationReplayAndRelease() async throws {
        let stack = try await makeStack()
        let raw = Data((String(repeating: "public marker ", count: 32) + "private-sentinel").utf8)
        for search in [false, true] {
            var calls = 0, bytes = 0
            func call(_ name: String, _ args: [String: Any]) async throws -> ToolResponse {
                let response = try await callSessionSummary(stack: stack, toolName: name, toolArguments: args)
                calls += 1
                bytes += response.wireBytes
                return response
            }
            let list = try await callRPC(stack: stack, method: "tools/list", params: [:])
            bytes += list.wireBytes
            calls += 1
            let key = UUID().uuidString
            let register: [String: Any] = ["requestKey": key, "kind": "text", "scopes": search ? ["metadata-v1", "search-v1"] : ["metadata-v1"]]
            let pending = try await call("artifact_source_register", register)
            XCTAssertNotNil(pending.errorData)
            _ = try await call("artifact_source_status", ["requestKey": key])
            let request = try XCTUnwrap(stack.artifactSources.requests.first { $0.key == key })
            stack.artifactSources.prepare(id: request.id, selection: .synthetic(raw))
            await stack.artifactSources.waitForPreparation(id: request.id)
            try stack.artifactSources.share(id: request.id)
            let ready = try summaryPayload(from: await call("artifact_source_register", register))
            let handle = try XCTUnwrap(ready["handle"] as? String)
            let identity: [String: Any] = ["handle": handle, "snapshotRevision": try XCTUnwrap(ready["snapshotRevision"])]
            var args = identity
            args["dataset"] = "sourceUTF8"
            args["literal"] = "marker"
            args["limit"] = 7
            let inventory = try summaryPayload(from: await call("artifact_inventory", identity))
            let first = try summaryPayload(from: await call("artifact_search", args))
            guard search else {
                XCTAssertEqual(first["status"] as? String, "unavailable")
                XCTAssertEqual(inventory["status"] as? String, "unavailable")
                continue
            }
            XCTAssertEqual(inventory["exactTotal"] as? Int, 1)
            XCTAssertTrue(first["exactTotal"] is NSNull)
            let cursor = try XCTUnwrap(first["nextCursor"] as? String)
            args["cursor"] = cursor
            let second = try summaryPayload(from: await call("artifact_search", args))
            let replay = try summaryPayload(from: await call("artifact_search", args))
            XCTAssertEqual(second as NSDictionary, replay as NSDictionary)
            var wrong = args
            wrong["literal"] = "public"
            let rejected = try summaryPayload(from: await call("artifact_search", wrong))
            XCTAssertEqual(rejected["reason"] as? String, "cursor_expired")
            var pages = [first, second]
            while let next = pages.last?["nextCursor"] as? String, pages.count < 10 {
                args["cursor"] = next
                pages.append(try summaryPayload(from: await call("artifact_search", args)))
            }
            XCTAssertEqual(pages.last?["exactTotal"] as? Int, 32)
            let items = pages.flatMap { $0["items"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(items.compactMap { $0["byteOffset"] as? Int }, (0..<32).map { 7 + 14 * $0 })
            XCTAssertEqual(Set(items.compactMap { $0["matchRef"] as? String }).count, 32)
            for p in pages {
                let encoded = try JSONSerialization.data(withJSONObject: p)
                XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-sentinel"))
            }
            _ = try await call("artifact_source_release", ["handle": handle])
            let retired = try summaryPayload(from: await call("artifact_search", args))
            XCTAssertEqual(retired["reason"] as? String, "source_unavailable")
            XCTAssertEqual(stack.sessionStore.sessions.count, 1)
            print("EC06_WORKFLOW rawBytes=\(raw.count) responseBytes=\(bytes) calls=\(calls) pages=\(pages.count) matches=\(items.count) discoveryBytes=\(list.wireBytes)")
        }
    }

    func testSparseSavedSearchWorkflowMatchesLiveOffsetsAndRawOracle() async throws {
        let marker = "synthetic-marker"
        let raw = Data(("\"" + String(repeating: "x", count: 131_072) + marker + "\"").utf8)
        let stack = try await makeStack(responseBody: raw)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .responseTextSearch, mode: .untilSessionEnd)
        let live = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "response_text_search",
            toolArguments: ["sessionID": stack.session.id.uuidString, "find": marker]))
        let liveRows = try XCTUnwrap(live["matches"] as? [[String: Any]])
        let oracle = try XCTUnwrap(raw.range(of: Data(marker.utf8)))
        XCTAssertEqual(liveRows.compactMap { $0["byteOffset"] as? Int }, [oracle.lowerBound])
        let start = ContinuousClock.now
        let list = try await callRPC(stack: stack, method: "tools/list", params: [:])
        var calls = 1
        var received = list.wireBytes
        func call(_ name: String, _ args: [String: Any]) async throws -> ToolResponse {
            let response = try await callSessionSummary(stack: stack, toolName: name, toolArguments: args)
            calls += 1
            received += response.wireBytes
            return response
        }
        let key = UUID().uuidString
        let registration: [String: Any] = ["requestKey": key, "kind": "text", "scopes": ["metadata-v1", "search-v1"]]
        let pending = try await call("artifact_source_register", registration)
        XCTAssertNotNil(pending.errorData)
        _ = try await call("artifact_source_status", ["requestKey": key])
        let request = try XCTUnwrap(stack.artifactSources.requests.first { $0.key == key })
        stack.artifactSources.prepare(id: request.id, selection: .synthetic(raw))
        await stack.artifactSources.waitForPreparation(id: request.id)
        try stack.artifactSources.share(id: request.id)
        let ready = try summaryPayload(from: await call("artifact_source_register", registration))
        let identity: [String: Any] = ["handle": try XCTUnwrap(ready["handle"]), "snapshotRevision": try XCTUnwrap(ready["snapshotRevision"])]
        _ = try await call("artifact_inventory", identity)
        var args = identity
        args["literal"] = marker
        args["dataset"] = "sourceUTF8"
        for phase in ["cold", "warm"] {
            let began = phase == "cold" ? start : ContinuousClock.now
            if phase == "warm" {
                calls = 0
                received = 0
            }
            var query = args
            var offsets: [Int] = []
            var page: [String: Any]
            repeat {
                page = try summaryPayload(from: await call("artifact_search", query))
                let rows = try XCTUnwrap(page["items"] as? [[String: Any]])
                XCTAssertTrue(rows.allSatisfy { $0["byteLength"] as? Int == oracle.count })
                offsets += rows.compactMap { $0["byteOffset"] as? Int }
                query["cursor"] = page["nextCursor"] as? String
            } while query["cursor"] != nil && calls < 30
            XCTAssertEqual(offsets, [oracle.lowerBound])
            XCTAssertEqual(page["exactTotal"] as? Int, 1)
            XCTAssertLessThan(received, raw.count)
            let elapsed = began.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("EC06_SPARSE phase=\(phase) rawBytes=\(raw.count) responseBytes=\(received) calls=\(calls) seconds=\(seconds)")
        }
        _ = try await call("artifact_source_release", ["handle": try XCTUnwrap(ready["handle"])])
    }

    func testLiveDiscoveryWorkflowComparesFullAndCompactCatalogs() async throws {
        let raw = Data(("[" + (0..<1000).map {
            "{\"price\":0.1,\"description\":\"synthetic mock item \($0)\"}"
        }.joined(separator: ",") + "]").utf8)
        let work = ArtifactWorkCounter()
        let stack = try await makeStack(responseBody: raw, worker: ArtifactAnalysisWorker(beforeWork: { work.increment() }))
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)

        // Same initialized client, capture revision and grant throughout. Selecting core persists for the third journey.
        var fullCatalogBytes = 0
        var fullTotalBytes = 0
        var fullAnswer: NSDictionary?
        for mode in ["full", "switchToCore", "coreAlreadySelected"] {
            let start = ContinuousClock.now
            var calls = 0
            var statusBytes = 0
            var selectBytes = 0
            if mode == "switchToCore" {
                let status = try await callSessionSummary(stack: stack, toolName: "agent_toolset_status", toolArguments: [:])
                XCTAssertEqual(try summaryPayload(from: status)["selectedToolset"] as? String, "all")
                statusBytes = status.wireBytes
                let select = try await callSessionSummary(stack: stack, toolName: "agent_toolset_select", toolArguments: ["toolset": "core"])
                let selected = try summaryPayload(from: select)
                XCTAssertEqual(selected["selectedToolset"] as? String, "core")
                XCTAssertEqual(selected["relistRequired"] as? Bool, true)
                selectBytes = select.wireBytes
                calls += 2
            }
            let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
            let tools = try XCTUnwrap(catalog.result?["tools"] as? [[String: Any]])
            let names = Set(tools.compactMap { $0["name"] as? String })
            XCTAssertTrue(names.isSuperset(of: ["sessions_list", "capture_calculate", "agent_toolset_select"]))
            let page = try await callSessionSummary(stack: stack, toolName: "sessions_list", toolArguments: ["projection": "minimal", "limit": 1])
            let items = try XCTUnwrap(try summaryPayload(from: page)["items"] as? [[String: Any]])
            let id = try XCTUnwrap(items.first?["id"] as? String)
            XCTAssertEqual(id, stack.session.id.uuidString)
            let before = work.value
            let answer = try await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: [
                "sessionIDs": [id], "dataset": "responseJSON", "selectionPointer": "",
                "operation": ["kind": "numericSummary", "fieldPointer": "/price"]
            ])
            calls += 3
            let elapsed = start.duration(to: .now)
            let payload = try summaryPayload(from: answer)
            XCTAssertEqual(work.value - before, 1)
            XCTAssertEqual(payload["status"] as? String, "complete")
            XCTAssertEqual(payload["sourceKind"] as? String, "live_capture")
            XCTAssertEqual((payload["result"] as? [String: Any])?["sum"] as? String, "100")
            let total = statusBytes + selectBytes + catalog.wireBytes + page.wireBytes + answer.wireBytes
            if mode == "full" {
                fullAnswer = payload as NSDictionary
                fullCatalogBytes = catalog.wireBytes
                fullTotalBytes = total
            } else {
                XCTAssertEqual(payload as NSDictionary, fullAnswer)
                XCTAssertLessThan(catalog.wireBytes * 4, fullCatalogBytes * 3)
                XCTAssertLessThan(total, fullTotalBytes)
            }
            let metric: [String: Any] = [
                "fixture": "live-discovery-v1", "mode": mode, "tools": names.count, "calls": calls,
                "statusBytes": statusBytes, "selectBytes": selectBytes, "catalogBytes": catalog.wireBytes,
                "sessionListBytes": page.wireBytes, "answerBytes": answer.wireBytes, "totalBytes": total,
                "analyses": work.value - before, "elapsedSeconds": Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            ]
            print("LIVE_DISCOVERY_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metric, options: [.sortedKeys]), as: UTF8.self))
        }
        XCTAssertEqual(work.value, 3)
    }

    func testArtifactWorkflowMeasuresEveryAttemptAndWarmCalculationEnvelope() async throws {
        let raw = Data(("[" + (0..<1000).map {
            "{\"price\":0.1,\"description\":\"synthetic mock item \($0)\"}"
        }.joined(separator: ",") + "]").utf8)
        let work = ArtifactWorkCounter()
        let stack = try await makeStack(responseBody: raw, worker: ArtifactAnalysisWorker(beforeWork: { work.increment() }))
        var attempts: [ToolResponse] = []
        let args: [String: Any] = ["requestKey": UUID().uuidString, "kind": "json", "scopes": ["metadata-v1", "calculations-v1"]]
        let discoveryStart = ContinuousClock.now
        let discovery = try await callRPC(stack: stack, method: "tools/list", params: [:])
        let tools = try XCTUnwrap(discovery.result?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "artifact_calculate" })
        XCTAssertEqual(work.value, 0)
        let start = ContinuousClock.now
        attempts.append(try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args))
        attempts.append(try await callSessionSummary(stack: stack, toolName: "artifact_source_status", toolArguments: ["requestKey": try XCTUnwrap(args["requestKey"])]))
        let request = try XCTUnwrap(stack.artifactSources.requests.first)
        stack.artifactSources.prepare(id: request.id, selection: .synthetic(raw))
        await stack.artifactSources.waitForPreparation(id: request.id)
        XCTAssertEqual(work.value, 1, "One preparation, including validation, before any calculation")
        attempts.append(try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args))
        try stack.artifactSources.share(id: request.id)
        let readyResponse = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args)
        attempts.append(readyResponse)
        let ready = try summaryPayload(from: readyResponse)
        let calculation: [String: Any] = ["handle": try XCTUnwrap(ready["handle"]),
            "snapshotRevision": try XCTUnwrap(ready["snapshotRevision"]), "dataset": ["kind": "json"],
            "selectionPointer": "", "operation": ["kind": "numericSummary", "fieldPointer": "/price"]]
        let answer = try await callSessionSummary(stack: stack, toolName: "artifact_calculate", toolArguments: calculation)
        attempts.append(answer)
        XCTAssertEqual((try summaryPayload(from: answer)["result"] as? [String: Any])?["sum"] as? String, "100")
        XCTAssertEqual(attempts.filter { $0.errorData != nil }.count, 2)
        XCTAssertEqual(attempts.count, 5)
        XCTAssertEqual(work.value, 2, "Pending polls/retries must not trigger extra preparation or analysis")
        let coldBytes = attempts.reduce(0) { $0 + $1.wireBytes }
        XCTAssertLessThan(coldBytes, raw.count)
        let warmStart = ContinuousClock.now
        let warm = try await callSessionSummary(stack: stack, toolName: "artifact_calculate", toolArguments: calculation)
        let warmDuration = warmStart.duration(to: .now)
        XCTAssertEqual((try summaryPayload(from: warm)["result"] as? [String: Any])?["sum"] as? String, "100")
        XCTAssertLessThan(warm.wireBytes, 4096)
        XCTAssertEqual(work.value, 3)
        print("EFFICIENCY_METRIC artifact-discovery-workflow-v1 boundary=initialized-client discoveryBytes=\(discovery.wireBytes) totalResponseBytes=\(discovery.wireBytes + coldBytes) totalCalls=\(1 + attempts.count) totalElapsed=\(discoveryStart.duration(to: warmStart))")
        print("EFFICIENCY_METRIC artifact-workflow-v1 boundary=initialized-client-known-tool rawBytes=\(raw.count) coldResponseBytes=\(coldBytes) coldCalls=5 approvalRequiredAttempts=2 coldPreparations=1 coldAnalyses=1 coldElapsed=\(start.duration(to: warmStart)) warmResponseBytes=\(warm.wireBytes) warmCalls=1 warmAnalyses=1 warmElapsed=\(warmDuration)")
    }

    func testLiveCalculationRejectsSelectedSourceDriftButNotUnrelatedArrival() async throws {
        for mutateSelected in [false, true] {
            let gate = ArtifactTestGate()
            let worker = ArtifactAnalysisWorker(beforeWork: { gate.wait() })
            let stack = try await makeStack(responseBody: Data("[1,2]".utf8), worker: worker)
            _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
            let call = Task { try await self.callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: [
                "sessionIDs": [stack.session.id.uuidString], "dataset": "responseJSON", "selectionPointer": "",
                "operation": ["kind": "numericSummary", "fieldPointer": ""]]) }
            for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(gate.entered)
            if mutateSelected { stack.sessionStore.update(stack.session) }
            else { stack.sessionStore.append(SessionRecord(request: stack.session.request, response: stack.session.response,
                state: .completed, timing: stack.session.timing)) }
            gate.open()
            let answer = try summaryPayload(from: await call.value)
            XCTAssertEqual(answer["status"] as? String, mutateSelected ? "unavailable" : "complete")
            if mutateSelected { XCTAssertEqual(answer["reason"] as? String, "source_changed") }
        }
    }

    func testSavedSourceRequiresLocalReviewAndRoundTripsThroughRealDispatch() async throws {
        let stack = try await makeStack()
        let descriptors = stack.protocolService.toolDescriptors(for: stack.enrollment.client)
        for name in ["capture_calculate", "artifact_calculate"] {
            let descriptor = try XCTUnwrap(descriptors.first { $0["name"] as? String == name })
            XCTAssertNotNil((descriptor["_meta"] as? [String: Any])?["joesproxy.analysis"])
        }
        let key = UUID().uuidString
        let args: [String: Any] = ["requestKey": key, "kind": "json", "scopes": ["metadata-v1", "calculations-v1"], "ttlSeconds": 60]
        let initialCount = stack.sessionStore.sessions.count
        let pending = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args)
        XCTAssertNotNil(pending.errorData)
        let request = try XCTUnwrap(stack.artifactSources.requests.first)
        let status = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_source_status", toolArguments: ["requestKey": key]))
        XCTAssertNil(status["bytes"])
        XCTAssertNil(status["sourceSHA256"])
        stack.artifactSources.prepare(id: request.id, selection: .synthetic(Data("[0.1,0.2]".utf8)))
        await stack.artifactSources.waitForPreparation(id: request.id)
        let stillPending = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args)
        XCTAssertNotNil(stillPending.errorData)
        try stack.artifactSources.share(id: request.id)
        let ready = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args))
        let handle = try XCTUnwrap(ready["handle"] as? String)
        let revision = try XCTUnwrap(ready["snapshotRevision"] as? String)
        let repeatRead = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args))
        XCTAssertEqual(repeatRead["handle"] as? String, handle)
        let calculation: [String: Any] = ["handle": handle, "snapshotRevision": revision, "dataset": ["kind": "json"],
            "selectionPointer": "", "operation": ["kind": "numericSummary", "fieldPointer": ""]]
        let answer = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_calculate", toolArguments: calculation))
        XCTAssertEqual((answer["result"] as? [String: Any])?["sum"] as? String, "0.3")
        XCTAssertEqual(stack.sessionStore.sessions.count, initialCount)
        _ = try await callSessionSummary(stack: stack, toolName: "artifact_source_release", toolArguments: ["handle": handle])
        let unavailable = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_calculate", toolArguments: calculation))
        XCTAssertEqual(unavailable["reason"] as? String, "source_unavailable")
    }

    func testMetadataSourceDoesNotDiscloseDigestOrAllowCalculations() async throws {
        let stack = try await makeStack()
        let args: [String: Any] = ["requestKey": UUID().uuidString, "kind": "json", "scopes": ["metadata-v1"]]
        _ = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args)
        let request = try XCTUnwrap(stack.artifactSources.requests.first)
        stack.artifactSources.prepare(id: request.id, selection: .synthetic(Data("[1]".utf8)))
        await stack.artifactSources.waitForPreparation(id: request.id)
        try stack.artifactSources.share(id: request.id)
        let ready = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: args))
        XCTAssertNil(ready["sourceSHA256"])
        let answer = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_calculate", toolArguments: [
            "handle": try XCTUnwrap(ready["handle"]), "snapshotRevision": try XCTUnwrap(ready["snapshotRevision"]),
            "dataset": ["kind": "json"], "selectionPointer": "", "operation": ["kind": "rowCount"]]))
        XCTAssertEqual(answer["status"] as? String, "unavailable")
        XCTAssertTrue(answer["result"] is NSNull)
    }

    func testLiveCalculationUsesExactNumbersAndCannotBypassBodyAuthority() async throws {
        let stack = try await makeStack(responseBody: Data(#"{"items":[{"price":0.1},{"price":0.2}]}"#.utf8))
        let arguments: [String: Any] = ["sessionIDs": [stack.session.id.uuidString], "dataset": "responseJSON",
            "selectionPointer": "/items", "operation": ["kind": "numericSummary", "fieldPointer": "/price"]]
        let pending = try await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: arguments)
        XCTAssertNotNil(pending.errorData)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let response = try await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: arguments)
        let result = try summaryPayload(from: response)
        XCTAssertEqual(result["status"] as? String, "complete")
        XCTAssertEqual((result["result"] as? [String: Any])?["sum"] as? String, "0.3")
        XCTAssertEqual(result["sourceKind"] as? String, "live_capture")
        XCTAssertNotNil(result["sourceSHA256"])
        XCTAssertNotNil(result["sourceRevisions"])
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!.contains("\"items\""))
        stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0)
        let missing = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: arguments))
        XCTAssertEqual(missing["status"] as? String, "unavailable")
        XCTAssertTrue(missing["result"] is NSNull)
    }

    func testFilteredCalculationChecksAuthorityAndQualifiesEmptyWindows() async throws {
        let stack = try await makeStack(profile: .metadataOnly)
        let scope = ["startedAfter": "1970-01-01T00:00:00Z", "startedBefore": "1970-01-01T00:00:00Z"]
        var args: [String: Any] = ["filter": scope, "dataset": "sessionMetadata", "selectionPointer": "",
                                   "operation": ["kind": "rowCount"]]
        args["filter"] = scope.merging(["path": "/secret"]) { _, new in new }
        let denied = try await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: args)
        XCTAssertNotNil(denied.errorData)
        let permitted = try await makeStack()
        _ = try permitted.grantStore.addGrant(clientID: permitted.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        args["filter"] = scope
        let empty = try summaryPayload(from: await callSessionSummary(stack: permitted, toolName: "capture_calculate", toolArguments: args))
        XCTAssertEqual(empty["rows"] as? Int, 0)
        XCTAssertEqual(empty["admissionCoverage"] as? String, "unknown")
        args["sessionIDs"] = [permitted.session.id.uuidString]
        let mixed = try summaryPayload(from: await callSessionSummary(stack: permitted, toolName: "capture_calculate", toolArguments: args))
        XCTAssertEqual(mixed["status"] as? String, "unavailable")
    }

    func testFilteredWindowDetectsLateCompletion() async throws {
        let gate = ArtifactTestGate()
        let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: { gate.wait() }))
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        var row = stack.session
        row.response = nil
        row.state = .pending
        stack.sessionStore.update(row)
        let args: [String: Any] = ["filter": ["startedAfter": "1970-01-01T00:00:00Z", "startedBefore": "2099-01-01T00:00:00Z"],
                                   "dataset": "sessionMetadata", "selectionPointer": "", "operation": ["kind": "rowCount"]]
        let call = Task { try await self.callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: args) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        stack.sessionStore.update(stack.session)
        gate.open()
        let result = try summaryPayload(from: await call.value)
        XCTAssertEqual(result["reason"] as? String, "source_changed")
        XCTAssertTrue(result["result"] is NSNull)
    }

    func testFilteredGroupsReconcileTiesHistoryLossAndWorkLimit() async throws {
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let timing = SessionTiming(startedAt: Date(timeIntervalSince1970: 0))
        let rows = [503, 200, 503, 200].map { status in
            SessionRecord(request: stack.session.request, response: CapturedResponse(statusCode: status, headers: [],
                bodyData: nil, bodySize: 0), state: .completed, timing: timing)
        }
        stack.sessionStore.load(sessions: rows)
        let scope = ["startedAfter": "1970-01-01T00:00:00Z", "startedBefore": "1970-01-01T00:00:00Z"]
        let args: [String: Any] = ["filter": scope, "dataset": "sessionMetadata", "selectionPointer": "",
                                   "operation": ["kind": "groupCount", "fieldPointer": "/statusCode", "limit": 1]]
        let budget = CaptureAdmissionBudget(byteLimit: 1, countLimit: 1)
        XCTAssertNil(budget.reserve(bytes: 2))
        stack.protocolService.setCaptureStatusProvider {
            MCPCaptureStatusDTO(proxyState: "running", admission: budget.snapshot, perResponseByteLimit: 1, retainedBodyByteLimit: nil)
        }
        let tied = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: args))
        XCTAssertNil(tied["possibleCaptureGap"], "A later rejection cannot affect this earlier window")
        XCTAssertEqual(tied["rowsInOmittedGroups"] as? Int, 2)
        let groups = try XCTUnwrap((tied["result"] as? [String: Any])?["groups"] as? [[String: Any]])
        XCTAssertEqual((groups.first?["key"] as? [String: String])?["value"], "200")
        stack.sessionStore.clear()
        var wide = args
        wide["filter"] = ["startedAfter": scope["startedAfter"]!, "startedBefore": "2099-01-01T00:00:00Z"]
        let cleared = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: wide))
        XCTAssertEqual(cleared["historyChangedSinceWindowStart"] as? Bool, true)
        XCTAssertEqual(cleared["possibleCaptureGap"] as? Bool, true)
        stack.sessionStore.load(sessions: (0...10_000).map { _ in
            SessionRecord(request: stack.session.request, state: .pending, timing: timing)
        })
        let over = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: args))
        XCTAssertEqual(over["reason"] as? String, "input_limit")
        XCTAssertTrue(over["result"] is NSNull)
    }

    func testFilteredCalculationAgainstPagedSearchAndExplicitBatches() async throws {
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let start = Date(timeIntervalSince1970: 0)
        let records = (0...300).map { i in
            SessionRecord(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!,
                request: stack.session.request, response: i == 299 ? nil : stack.session.response,
                state: i == 299 ? .pending : .completed,
                timing: SessionTiming(startedAt: start.addingTimeInterval(Double(i))))
        }
        stack.sessionStore.load(sessions: records)
        let scope = ["method": "get", "path": "/APP/", "startedAfter": "1970-01-01T00:00:00Z",
                     "startedBefore": "1970-01-01T00:04:59Z"]
        let base: [String: Any] = ["dataset": "sessionMetadata", "selectionPointer": "",
                                   "operation": ["kind": "groupCount", "fieldPointer": "/statusCode"]]
        let candidateStart = ContinuousClock.now
        let single = try await callSessionSummary(stack: stack, toolName: "capture_calculate",
            toolArguments: base.merging(["filter": scope]) { _, new in new })
        let candidateElapsed = candidateStart.duration(to: .now)
        let result = try summaryPayload(from: single)
        XCTAssertEqual(result["rows"] as? Int, 300)
        XCTAssertNil(result["sessionIDs"])
        func counts(_ result: [String: Any]) throws -> [String: Int] {
            let groups = try XCTUnwrap((result["result"] as? [String: Any])?["groups"] as? [[String: Any]])
            var values: [String: Int] = [:]
            for group in groups {
                let key = try XCTUnwrap(group["key"] as? [String: String])
                values[key["value"] ?? "missing"] = try XCTUnwrap(group["count"] as? Int)
            }
            return values
        }
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FilteredCapture/busy-window.json")
        struct Oracle: Decodable {
            let firstID: String
            let lastID: String
            let rows: Int
            let counts: [String: Int]
        }
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: manifestURL))
        let expected = oracle.counts
        XCTAssertEqual(result["rows"] as? Int, oracle.rows)
        XCTAssertEqual(try counts(result), expected)
        var search: [String: Any] = scope
        search["limit"] = 50
        var ids: [String] = []
        var baselineMessages: [[String: String]] = []
        var baselineCalls = 0
        var baselineBytes = 0
        let baselineStart = ContinuousClock.now
        repeat {
            let response = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: search)
            baselineCalls += 1
            baselineBytes += response.requestBytes + response.wireBytes
            baselineMessages.append(response.measurementMessages)
            let page = try summaryPayload(from: response)
            let items = try XCTUnwrap(page["items"] as? [[String: Any]])
            ids += try items.map { try XCTUnwrap($0["id"] as? String) }
            search["cursor"] = page["nextCursor"] as? String
        } while search["cursor"] != nil && baselineCalls < 301
        let membership = Set(ids.map { $0.lowercased() })
        XCTAssertEqual(ids.count, oracle.rows)
        XCTAssertEqual(membership.count, oracle.rows)
        XCTAssertEqual(membership.min(), oracle.firstID)
        XCTAssertEqual(membership.max(), oracle.lastID)
        XCTAssertEqual(membership, Set(records.prefix(oracle.rows).map { $0.id.uuidString.lowercased() }))
        var pooled: [String: Int] = [:]
        // Leave room for UUID strings and operation fields in the 8 KiB RPC argument budget.
        for offset in stride(from: 0, to: ids.count, by: 192) {
            let batch = Array(ids.dropFirst(offset).prefix(192))
            let response = try await callSessionSummary(stack: stack, toolName: "capture_calculate",
                toolArguments: base.merging(["sessionIDs": batch]) { _, new in new })
            baselineCalls += 1
            baselineBytes += response.requestBytes + response.wireBytes
            baselineMessages.append(response.measurementMessages)
            for (key, value) in try counts(summaryPayload(from: response)) { pooled[key, default: 0] += value }
        }
        let baselineElapsed = baselineStart.duration(to: .now)
        XCTAssertEqual(pooled, expected)
        let candidateBytes = single.requestBytes + single.wireBytes
        XCTAssertGreaterThan(baselineCalls, 1)
        XCTAssertLessThan(candidateBytes, baselineBytes)
        // Both consumers ask for one concrete example after seeing the counts.
        var sampleQuery: [String: Any] = scope
        sampleQuery["limit"] = 1
        func followUp() async throws -> [[String: String]] {
            let page = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: sampleQuery)
            let items = try XCTUnwrap(try summaryPayload(from: page)["items"] as? [[String: Any]])
            let id = try XCTUnwrap(items.first?["id"] as? String)
            XCTAssertEqual(id.lowercased(), records[0].id.uuidString.lowercased())
            let detail = try await callSessionSummary(stack: stack, toolArguments: ["sessionID": id])
            XCTAssertEqual(try summaryPayload(from: detail)["statusCode"] as? Int, 502)
            return [page.measurementMessages, detail.measurementMessages]
        }
        let baselineExample = try await callSessionSummary(stack: stack, toolArguments: ["sessionID": try XCTUnwrap(ids.first)])
        XCTAssertEqual(try summaryPayload(from: baselineExample)["statusCode"] as? Int, 502)
        let baselineDetail = [baselineExample.measurementMessages]
        let candidateDetail = try await followUp()
        let transcript = ["baseline": baselineMessages + baselineDetail,
                          "candidate": [single.measurementMessages] + candidateDetail]
        print("aggregate latency baseline=\(baselineElapsed) candidate=\(candidateElapsed); follow-up baselineCalls=1 candidateCalls=2")
        for (arm, messages) in transcript.sorted(by: { $0.key < $1.key }) {
            let aggregate = arm == "baseline" ? baselineCalls : 1
            for count in [aggregate, messages.count] {
                let requests = messages.prefix(count).reduce(0) { $0 + ($1["request"]?.utf8.count ?? 0) }
                let responses = messages.prefix(count).reduce(0) { $0 + ($1["response"]?.utf8.count ?? 0) }
                print("filtered-capture-300 arm=\(arm) calls=\(count) requestBytes=\(requests) responseBytes=\(responses)")
            }
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(transcript), uniformTypeIdentifier: "public.json")
        attachment.name = "filtered-capture-300-rpc-bodies"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("filtered-capture-300 baselineCalls=\(baselineCalls) candidateCalls=1 baselineRPCBytes=\(baselineBytes) candidateRPCBytes=\(candidateBytes) providerTokens=unmeasured")
    }

    func testLiveMetadataGroupingIsExplicitAndBounded() async throws {
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let result = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: [
            "sessionIDs": [stack.session.id.uuidString], "dataset": "sessionMetadata", "selectionPointer": "",
            "operation": ["kind": "groupCount", "fieldPointer": "/statusCode"]]))
        let groups = try XCTUnwrap((result["result"] as? [String: Any])?["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["count"] as? Int, 1)
        XCTAssertEqual((groups.first?["key"] as? [String: String])?["value"], "502")
        let denied = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "capture_calculate", toolArguments: [
            "sessionIDs": [stack.session.id.uuidString], "dataset": "sessionMetadata", "selectionPointer": "",
            "operation": ["kind": "groupCount", "fieldPointer": "/headers"]]))
        XCTAssertEqual(denied["status"] as? String, "unavailable")
    }

    func testMixedOverlappingSelectionsAndMissingSourceArrival() async throws {
        let stack = try await makeStack(responseBody: Data(#"{"items":[{"id":"synthetic"}],"other":[]}"#.utf8))
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let second = SessionRecord(request: stack.session.request, response: stack.session.response, state: .completed, timing: stack.session.timing)
        let arriving = SessionRecord(request: stack.session.request, response: stack.session.response, state: .completed, timing: stack.session.timing)
        stack.sessionStore.append(second)
        var calls = 0, bytes = 0, hits = 0, conditional = 0
        var receipts: [String: String] = [:]
        func read(_ key: String, _ baseline: UUID, _ candidate: UUID, pointer: String = "/items", hit: Bool) async throws -> [String: Any] {
            var args: [String: Any] = ["baselineSessionIDs": [baseline.uuidString], "candidateSessionIDs": [candidate.uuidString], "selectionPointer": pointer]
            if let digest = receipts[key] { args["ifBriefDigest"] = digest; conditional += 1 }
            let before = stack.protocolService.briefAnalysisExecutionCount
            let response = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args)
            let payload = try summaryPayload(from: response)
            XCTAssertEqual(payload["unchanged"] as? Bool, hit)
            let presentSources = Set([baseline, candidate]).filter { stack.sessionStore.record(for: $0) != nil }.count
            XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount - before, hit ? 0 : presentSources)
            calls += 1
            bytes += try JSONSerialization.data(withJSONObject: XCTUnwrap(response.result)).count
            if hit { hits += 1 }
            receipts[key] = try XCTUnwrap(payload["briefDigest"] as? String)
            return payload
        }
        _ = try await read("ab", stack.session.id, second.id, hit: false)
        let missing = try await read("bc", second.id, arriving.id, hit: false)
        XCTAssertEqual(missing["status"] as? String, "incomplete")
        _ = try await read("ab", stack.session.id, second.id, hit: true)
        _ = try await read("bc", second.id, arriving.id, hit: true)
        stack.sessionStore.update(stack.session)
        _ = try await read("ab", stack.session.id, second.id, hit: false)
        _ = try await read("bc", second.id, arriving.id, hit: true)
        stack.sessionStore.append(arriving)
        let arrived = try await read("bc", second.id, arriving.id, hit: false)
        XCTAssertEqual(arrived["status"] as? String, "complete")
        _ = try await read("ab", stack.session.id, second.id, hit: true)
        _ = try await read("ab", stack.session.id, second.id, pointer: "/other", hit: false)
        _ = try await read("ab", stack.session.id, second.id, pointer: "/other", hit: true)
        stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0)
        let strippedAB = try await read("ab", stack.session.id, second.id, hit: false)
        let strippedBC = try await read("bc", second.id, arriving.id, hit: false)
        XCTAssertEqual(strippedAB["status"] as? String, "incomplete")
        XCTAssertEqual(strippedBC["status"] as? String, "incomplete")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let gates = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("memlog/Research/Agent-Efficiency-Edge-Baseline-v1.json"))) as? [String: Any])
        XCTAssertEqual(calls, gates["calls"] as? Int)
        XCTAssertEqual(hits, gates["conditionalHits"] as? Int)
        XCTAssertEqual(conditional, gates["conditionalAttempts"] as? Int)
        XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount, gates["sourceAnalysisExecutions"] as? Int)
        XCTAssertLessThanOrEqual(bytes, try XCTUnwrap(gates["maximumWorkflowBytes"] as? Int))
        let metrics: [String: Any] = ["fixture": "mixed-selection-v1", "calls": calls, "responseBytes": bytes,
            "analysisExecutions": stack.protocolService.briefAnalysisExecutionCount, "conditionalAttempts": conditional, "conditionalHits": hits]
        print("EDGE_MIXED_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }

    func testBusyCaptureRetainsSelectedBriefAndMeasuresWholeWorkflow() async throws {
        let rows = (0..<200).map { ["id": "synthetic-\($0)", "title": String(repeating: "Synthetic title ", count: 8)] }
        let data = try JSONSerialization.data(withJSONObject: ["items": rows, "excluded": "sentinel"], options: [.sortedKeys])
        let stack = try await makeStack(responseBody: data)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let first = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", selectionPointer: "/items")
        let digest = try XCTUnwrap(try summaryPayload(from: first)["briefDigest"] as? String)
        let fullBytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(first.result)).count
        var baselineBytes = fullBytes, candidateBytes = fullBytes
        let initialExecutions = stack.protocolService.briefAnalysisExecutionCount
        for _ in 0..<8 {
            let noise = SessionRecord(request: stack.session.request, response: stack.session.response, state: .completed, timing: stack.session.timing)
            stack.sessionStore.append(noise)
            stack.sessionStore.update(noise)
            stack.sessionStore.remove(ids: [noise.id])
            let before = stack.protocolService.briefAnalysisExecutionCount
            let repeated = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
                "sessionID": stack.session.id.uuidString, "selectionPointer": "/items", "ifBriefDigest": digest])
            XCTAssertEqual(try summaryPayload(from: repeated)["unchanged"] as? Bool, true)
            XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount, before)
            candidateBytes += try JSONSerialization.data(withJSONObject: XCTUnwrap(repeated.result)).count
            let full = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", selectionPointer: "/items")
            baselineBytes += try JSONSerialization.data(withJSONObject: XCTUnwrap(full.result)).count
        }
        XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount - initialExecutions, 8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let gates = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("memlog/Research/Agent-Efficiency-Busy-Baseline-v1.json"))) as? [String: Any])
        XCTAssertLessThan(candidateBytes, baselineBytes * (try XCTUnwrap(gates["candidateBytesMaximumPercentOfFullReads"] as? Int)) / 100)
        let offline = try CLIWorkflowCostReport.report(Data(contentsOf: root.appendingPathComponent("memlog/Research/Agent-Efficiency-Workflow-v1.json")))
        XCTAssertEqual((offline["baseline"] as? [String: Any])?["responseBytes"] as? Int, baselineBytes)
        XCTAssertEqual((offline["candidate"] as? [String: Any])?["responseBytes"] as? Int, candidateBytes)
        let metrics: [String: Any] = ["baselineVersion": 1, "fixture": "busy-collection-200-v1",
            "measurementLayer": "authenticatedMCPResult", "baselineWorkflowBytes": baselineBytes,
            "candidateWorkflowBytes": candidateBytes, "callsPerWorkflow": 9,
            "baselineAnalysisExecutions": 9, "candidateAnalysisExecutions": 1,
            "conditionalHits": 8, "conditionalAttempts": 8, "providerTokens": NSNull()]
        print("EFFICIENCY_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        stack.sessionStore.remove(ids: [stack.session.id])
        let missing = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
            "sessionID": stack.session.id.uuidString, "ifBriefDigest": digest, "selectionPointer": "/items"])
        XCTAssertNotNil(missing.errorData)
        stack.sessionStore.append(stack.session)
        let reinserted = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
            "sessionID": stack.session.id.uuidString, "ifBriefDigest": digest, "selectionPointer": "/items"]))
        XCTAssertEqual(reinserted["unchanged"] as? Bool, false)
        let reinsertedDigest = try XCTUnwrap(reinserted["briefDigest"] as? String)
        stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0)
        let stripped = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
            "sessionID": stack.session.id.uuidString, "ifBriefDigest": reinsertedDigest, "selectionPointer": "/items"]))
        XCTAssertEqual(stripped["unchanged"] as? Bool, false)
        XCTAssertNotEqual(stripped["status"] as? String, "complete")
    }
    func testLargeResponseNestedBriefDoesNotWidenOrdinaryExcerpt() async throws {
        let body = Data((#"{"items":[{"meta":{"title":""# + String(repeating: "synthetic", count: 10_000) + #""}}]}"#).utf8)
        let stack = try await makeStack(responseBody: body)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let summary = try summaryPayload(from: await callSessionSummary(stack: stack, includeBody: true))
        XCTAssertEqual(summary["bodyExcerptTruncated"] as? Bool, true)
        let brief = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "response_evidence_brief",
            selectionPointer: "/items", toolArguments: ["sessionID": stack.session.id.uuidString, "includeStructure": true]))
        XCTAssertEqual(brief["status"] as? String, "complete")
        XCTAssertEqual(brief["structureCoverage"] as? String, "complete")
        XCTAssertEqual(brief["analyzedUTF8Bytes"] as? Int, body.count)
        XCTAssertNil(brief["bodyExcerpt"])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: brief).count, 10_000)
        print("NESTED_BRIEF_BENCHMARK decodedInputBytes=\(body.count) briefPayloadBytes=\(try JSONSerialization.data(withJSONObject: brief).count) providerTokens=unavailable")
    }

    func testComparisonApprovalSelectionMissingSourcesAndNoRawValues() async throws {
        let stack = try await makeStack(responseBody: Data(#"{"items":[{"name":"private-before"}]}"#.utf8))
        let candidateBody = Data(#"{"items":[{"name":null},{"name":"private-after"}]}"#.utf8)
        let candidate = SessionRecord(request: stack.session.request,
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: candidateBody, bodySize: candidateBody.count),
            state: .completed, timing: stack.session.timing)
        stack.sessionStore.append(candidate)
        var args: [String: Any] = ["baselineSessionIDs": [stack.session.id.uuidString],
            "candidateSessionIDs": [candidate.id.uuidString], "selectionPointer": "/items"]
        let denied = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args)
        XCTAssertNotNil(denied.errorData)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let result = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args)
        let payload = try summaryPayload(from: result)
        XCTAssertEqual(payload["status"] as? String, "complete")
        XCTAssertEqual(payload["targetOutcome"] as? String, "not_observed")
        XCTAssertTrue((payload["changes"] as? [[String: Any]])?.contains { $0["kind"] as? String == "selected_item_count_changed" } == true)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        XCTAssertFalse(text.contains("private-before"))
        XCTAssertFalse(text.contains("private-after"))
        XCTAssertFalse(text.contains("api.example.com"))
        args["ifBriefDigest"] = try XCTUnwrap(payload["briefDigest"] as? String)
        let analysisCount = stack.protocolService.briefAnalysisExecutionCount
        let noise = SessionRecord(request: stack.session.request, response: stack.session.response,
            state: .completed, timing: stack.session.timing)
        stack.sessionStore.append(noise)
        stack.sessionStore.update(noise)
        stack.sessionStore.remove(ids: [noise.id])
        let repeated = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args))
        XCTAssertEqual(repeated["unchanged"] as? Bool, true)
        XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount, analysisCount)
        stack.sessionStore.update(candidate)
        let revised = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args))
        XCTAssertEqual(revised["unchanged"] as? Bool, false)
        args["baselineSessionIDs"] = [UUID().uuidString]
        let missing = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args))
        XCTAssertEqual(missing["status"] as? String, "incomplete")
        XCTAssertEqual((missing["baseline"] as? [[String: Any]])?.first?["analysisStatus"] as? String, "session_missing")
        XCTAssertEqual(missing["unchanged"] as? Bool, false)
        args["ifBriefDigest"] = try XCTUnwrap(missing["briefDigest"] as? String)
        let repeatedMissing = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args))
        XCTAssertEqual(repeatedMissing["unchanged"] as? Bool, true)
        XCTAssertEqual(repeatedMissing["status"] as? String, "incomplete")
        _ = stack.grantStore.addDenial(clientID: stack.enrollment.client.id, capability: .bodyRead)
        let revoked = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: args)
        XCTAssertNotNil(revoked.errorData, "A receipt must never bypass current authority")
    }

    func testComparisonRejectsDuplicateAndOversizedSelectionsBeforeApproval() async throws {
        let stack = try await makeStack()
        for ids in [[stack.session.id.uuidString, stack.session.id.uuidString], (0..<17).map { _ in UUID().uuidString }] {
            let response = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief",
                toolArguments: ["baselineSessionIDs": ids, "candidateSessionIDs": [stack.session.id.uuidString]])
            XCTAssertEqual(response.errorData?["code"] as? Int, -32602)
            XCTAssertNil(response.result)
        }
        let malformed = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief",
            toolArguments: ["sessionID": stack.session.id.uuidString, "includeStructure": 1])
        XCTAssertEqual(malformed.errorData?["code"] as? Int, -32602)
    }

    func testComparisonAggregateBudgetReportsUnanalyzedSources() async throws {
        let body = Data((#"{"title":""# + String(repeating: "x", count: 220_000) + #""}"#).utf8)
        let stack = try await makeStack(responseBody: body)
        var ids = [stack.session.id.uuidString]
        for _ in 0..<5 {
            let record = SessionRecord(request: stack.session.request, response: stack.session.response,
                state: .completed, timing: stack.session.timing)
            stack.sessionStore.append(record)
            ids.append(record.id.uuidString)
        }
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let payload = try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "investigation_compare_brief",
            toolArguments: ["baselineSessionIDs": ids, "candidateSessionIDs": [stack.session.id.uuidString]]))
        XCTAssertEqual(payload["status"] as? String, "incomplete")
        let sources = try XCTUnwrap(payload["baseline"] as? [[String: Any]])
        XCTAssertEqual(sources.filter { $0["analysisStatus"] as? String == "aggregate_input_limit" }.count, 2)
    }

    func testComparisonCannotUseGrantToBypassMetadataProfile() async throws {
        let stack = try await makeStack(profile: .metadataOnly)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let response = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief",
            toolArguments: ["baselineSessionIDs": [stack.session.id.uuidString], "candidateSessionIDs": [stack.session.id.uuidString]])
        XCTAssertNotNil(response.errorData)
        XCTAssertNil(response.result)
    }

    func testAnalysisInputRequiresApprovalAndPreservesTruncation() throws {
        let record = Self.fixtureGET502()
        XCTAssertThrowsError(try MCPDisclosureSerializer().responseAnalysisInput(from: record, approvedCapabilities: []))
        var truncated = record
        truncated.response = CapturedResponse(statusCode: 200, headers: [], bodyData: Data("{}".utf8), bodySize: 2, bodyTruncated: true)
        let input = try MCPDisclosureSerializer().responseAnalysisInput(from: truncated, approvedCapabilities: [.bodyRead])
        XCTAssertTrue(input.truncated)
        XCTAssertEqual(ResponseEvidenceBrief.analyze(text: input.text, truncated: input.truncated,
            unavailableReason: input.unavailableReason, pointer: "").status, "incomplete_body")
        for state in [SessionLifecycleState.pending, .failed, .cancelled] {
            var unfinished = record
            unfinished.state = state
            let result = try MCPDisclosureSerializer().responseAnalysisInput(from: unfinished, approvedCapabilities: [.bodyRead])
            XCTAssertNil(result.text)
            XCTAssertEqual(result.unavailableReason, "response_\(state.rawValue)")
        }
    }

    func testEvidenceBriefTransportBenchmarkAndExplicitSelection() async throws {
        let rows = (0..<200).map { ["id": "synthetic-\($0)", "title": String(repeating: "Synthetic title ", count: 8)] }
        let data = try JSONSerialization.data(withJSONObject: ["items": rows, "excluded": "sentinel"], options: [.sortedKeys])
        let stack = try await makeStack(responseBody: data)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let baseline = try await callSessionSummary(stack: stack, includeBody: true)
        let brief = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", selectionPointer: "/items")
        let payload = try summaryPayload(from: brief)
        XCTAssertEqual(payload["itemCount"] as? Int, 200)
        XCTAssertEqual(payload["selectionPointer"] as? String, "/items")
        let fields = try XCTUnwrap(payload["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.compactMap { $0["name"] as? String }, ["id", "title"])
        let baselineBytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(baseline.result)).count
        let briefBytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(brief.result)).count
        XCTAssertLessThan(briefBytes * 5, baselineBytes)
        let digest = try XCTUnwrap(payload["briefDigest"] as? String)
        let executions = stack.protocolService.briefAnalysisExecutionCount
        var repeatBytes = 0
        var latencies: [Double] = []
        for _ in 0..<8 {
            let start = Date()
            let repeated = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
                "sessionID": stack.session.id.uuidString, "selectionPointer": "/items", "ifBriefDigest": digest
            ])
            latencies.append(Date().timeIntervalSince(start) * 1000)
            let repeatedPayload = try summaryPayload(from: repeated)
            XCTAssertEqual(repeatedPayload["unchanged"] as? Bool, true)
            XCTAssertEqual(repeatedPayload["analysisReused"] as? Bool, true)
            repeatBytes += try JSONSerialization.data(withJSONObject: XCTUnwrap(repeated.result)).count
        }
        XCTAssertEqual(stack.protocolService.briefAnalysisExecutionCount, executions)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let baselineData = try Data(contentsOf: repository.appendingPathComponent("memlog/Research/Agent-Efficiency-Baseline-v1.json"))
        let baselineContract = try XCTUnwrap(JSONSerialization.jsonObject(with: baselineData) as? [String: Any])
        let gates = try XCTUnwrap(baselineContract["regressionGates"] as? [String: Int])
        XCTAssertLessThan(briefBytes, try XCTUnwrap(gates["fullBriefResultBytesMaximumExclusive"]))
        XCTAssertLessThan(repeatBytes, 8 * (try XCTUnwrap(gates["repeatResultBytesMaximumExclusive"])))
        var changed = stack.session
        let changedBody = Data("{\"items\":[{\"different\":true}]}".utf8)
        changed.response = CapturedResponse(statusCode: 200, headers: [], bodyData: changedBody, bodySize: changedBody.count)
        stack.sessionStore.update(changed)
        let refreshed = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", toolArguments: [
            "sessionID": stack.session.id.uuidString, "selectionPointer": "/items", "ifBriefDigest": digest
        ])
        let refreshedPayload = try summaryPayload(from: refreshed)
        XCTAssertEqual(refreshedPayload["unchanged"] as? Bool, false)
        XCTAssertEqual(refreshedPayload["itemCount"] as? Int, 1)
        XCTAssertNotEqual(refreshedPayload["briefDigest"] as? String, digest)
        let metrics: [String: Any] = ["baselineVersion": 1, "fixture": "collection-200-v1", "rawResultBytes": baselineBytes,
            "fullBriefResultBytes": briefBytes, "repeatResultBytesTotal": repeatBytes, "repeatCalls": 8,
            "repeatAnalysisExecutions": stack.protocolService.briefAnalysisExecutionCount - executions - 1,
            "repeatLatencyMilliseconds": latencies, "providerTokens": NSNull()]
        print("EFFICIENCY_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        print("EVIDENCE_BRIEF_TRANSPORT baselineResultBytes=\(baselineBytes) briefResultBytes=\(briefBytes) baselineToolCalls=1 briefToolCalls=1 approval=existing_synthetic_grant providerTokens=unavailable")
    }

    func testEvidenceBriefRejectsInvalidSelectionBeforeApproval() async throws {
        let stack = try await makeStack()
        let response = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief", selectionPointer: "/~2")
        XCTAssertEqual(response.errorData?["code"] as? Int, -32602)
        XCTAssertNil(response.result)
    }

    func testEvidenceBriefRequiresApprovalAndDoesNotReturnBody() async throws {
        let stack = try await makeStack()
        let denied = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief")
        XCTAssertNotNil(denied.errorData)
        XCTAssertNil(denied.result)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let response = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief")
        let payload = try summaryPayload(from: response)
        XCTAssertEqual(payload["status"] as? String, "complete")
        XCTAssertEqual(payload["itemCount"] as? Int, 1)
        XCTAssertNotNil(payload["sourceSHA256"])
        XCTAssertNil(payload["bodyExcerpt"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self).contains("bad_gateway"))
        XCTAssertTrue(MCPToolset.core.includes(toolName: "response_evidence_brief"))
    }

    func testEvidenceBriefMissingBodyIsNotSuccessfulAnalysis() async throws {
        let stack = try await makeStack(includeResponseBody: false)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let response = try await callSessionSummary(stack: stack, toolName: "response_evidence_brief")
        let payload = try summaryPayload(from: response)
        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertEqual(payload["bodyUnavailableReason"] as? String, "body_missing")
        XCTAssertNil(payload["itemCount"])
    }
    func testMissingBodyReasonIsReadableWithoutSensitiveReadGrant() async throws {
        let stack = try await makeStack(includeResponseBody: false)
        let response = try await callSessionSummary(stack: stack, includeBody: false)
        XCTAssertNil(response.errorData)
        let payload = try XCTUnwrap(summaryPayload(from: response))
        XCTAssertEqual(payload["bodyUnavailableReason"] as? String, "body_missing")
        XCTAssertTrue((payload["bodyRecoveryAction"] as? String)?.contains("capture_status") == true)
        XCTAssertTrue((payload["bodyRecoveryAction"] as? String)?.contains("do_not_reinstall_device_profile") == true)
        XCTAssertNil(payload["bodyExcerpt"])
        XCTAssertNil(stack.grantStore.activeGrant(capability: .bodyRead, clientID: stack.enrollment.client.id))
    }
    func testGETResponseBodyAndHeadersWithStandingBodyReadGrant() async throws {
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .bodyRead,
            mode: .durablePolicy
        )
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .headerRead,
            mode: .durablePolicy
        )

        let response = try await callSessionSummary(
            stack: stack,
            includeHeaders: true,
            includeBody: true,
            headerSource: "both"
        )
        XCTAssertNil(response.errorData, "Standing grants should skip approval for body/header reads")
        let payload = try XCTUnwrap(summaryPayload(from: response))

        XCTAssertEqual(payload["bodyExcerptSource"] as? String, "response")
        XCTAssertEqual(payload["bodyExcerptAvailable"] as? Bool, true)
        XCTAssertEqual(payload["bodyAvailable"] as? Bool, true)
        XCTAssertEqual(payload["responseBodyAvailable"] as? Bool, true)
        XCTAssertEqual(payload["requestBodyAvailable"] as? Bool, false)
        let excerpt = try XCTUnwrap(payload["bodyExcerpt"] as? String)
        XCTAssertFalse(excerpt.isEmpty)
        XCTAssertTrue(excerpt.contains("\"error\":\"bad_gateway\""))

        let approvedResponseHeaders = try XCTUnwrap(payload["approvedResponseHeaders"] as? [[String: Any]])
        let responseNames = Set(approvedResponseHeaders.compactMap { $0["name"] as? String })
        XCTAssertTrue(responseNames.contains("Server"))
        XCTAssertTrue(responseNames.contains("Via"))
        XCTAssertTrue(responseNames.contains("Content-Type"))

        let approvedRequestHeaders = try XCTUnwrap(payload["approvedHeaders"] as? [[String: Any]])
        let requestNames = Set(approvedRequestHeaders.compactMap { $0["name"] as? String })
        XCTAssertTrue(requestNames.contains("Accept"))
        XCTAssertFalse(requestNames.contains("Server"))
    }

    func testBodyAvailableIsFalseWhenResponseBodyMissing() async throws {
        let stack = try await makeStack(includeResponseBody: false)
        _ = try stack.grantStore.addGrant(
            clientID: stack.enrollment.client.id,
            capability: .bodyRead,
            mode: .untilSessionEnd
        )
        let response = try await callSessionSummary(stack: stack, includeBody: true)
        let payload = try XCTUnwrap(summaryPayload(from: response))
        XCTAssertEqual(payload["bodyExcerptAvailable"] as? Bool, false)
        XCTAssertEqual(payload["bodyAvailable"] as? Bool, false)
        XCTAssertEqual(payload["responseBodyAvailable"] as? Bool, false)
        XCTAssertEqual(payload["bodyUnavailableReason"] as? String, "body_missing")
    }

    func testSerializerExposesResponseHeadersForHeaderSourceBoth() throws {
        let serializer = MCPDisclosureSerializer()
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: Set(MCPPolicyFieldClass.allCases),
            isSelectableInPhase1: true
        )
        let record = Self.fixtureGET502()
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile,
            approvedCapabilities: [.bodyRead, .headerRead],
            bodySource: .response,
            headerSource: .both
        )
        XCTAssertEqual(summary.bodyExcerptAvailable, true)
        XCTAssertFalse(summary.bodyExcerpt?.isEmpty ?? true)
        XCTAssertEqual(summary.bodyExcerptSource, "response")
        XCTAssertEqual(summary.safeResponseHeaders?.map(\.name).sorted(), ["Content-Type", "Server", "Via"])
        XCTAssertTrue(summary.approvedResponseHeaders?.contains(where: { $0.name == "Server" }) == true)
        XCTAssertEqual(summary.hostCategory, MCPHostCategory.api.rawValue)
    }

    struct TestStack {
        let protocolService: MCPProtocolService
        let grantStore: MCPClientGrantStore
        let enrollment: MCPClientRegistry.EnrollmentResult
        let session: SessionRecord
        let transportSessionID: String
        let sessionStore: InMemorySessionStore
        let artifactSources: ArtifactSourceRegistry
    }

    struct ToolResponse {
        let result: [String: Any]?
        let errorData: [String: Any]?
        var wireBytes = 0
        var requestBytes = 0
        var measurementMessages: [String: String] = [:]
    }

    func makeStack(includeResponseBody: Bool = true, responseBody: Data? = nil,
                           profile: MCPDisclosureProfileID = .shareable, worker injectedWorker: ArtifactAnalysisWorker? = nil) async throws -> TestStack {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-response-disclosure.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-response-disclosure.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-response-disclosure.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "grants-response-disclosure.json"))
        grantStore.load()
        let sessionStore = InMemorySessionStore()
        var session = includeResponseBody ? Self.fixtureGET502() : Self.fixtureGETWithoutResponseBody()
        if let responseBody {
            session.response = CapturedResponse(statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: responseBody, bodySize: responseBody.count)
        }
        sessionStore.append(session)
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let worker = injectedWorker ?? ArtifactAnalysisWorker()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            grantStore: grantStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: approvalStore,
            artifactWorker: worker
        )
        let enrollment = try clientRegistry.enroll(
            displayName: "ResponseDisclosure",
            assignedProfileID: profile
        )
        let artifactSources = ArtifactSourceRegistry(worker: worker, approvals: approvalStore)
        artifactSources.currentOwner = { id in
            guard let client = clientRegistry.client(id: id), client.credentialState == .active else { return nil }
            return .init(clientID: id, generation: client.credentialGeneration, policyRevision: policyStore.policyRevision, profile: client.assignedProfileID)
        }
        artifactSources.currentCalculationPermission = { id in clientRegistry.client(id: id)?.assignedProfileID == .shareable }
        artifactSources.currentBriefPermission = { id in clientRegistry.client(id: id)?.assignedProfileID == .shareable }
        artifactSources.currentComparePermission = { id in clientRegistry.client(id: id)?.assignedProfileID == .shareable }
        artifactSources.currentSearchPermission = { id in clientRegistry.client(id: id)?.assignedProfileID == .shareable }
        protocolService.configureArtifactSources(artifactSources)
        let transportSessionID = try await initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        return TestStack(
            protocolService: protocolService,
            grantStore: grantStore,
            enrollment: enrollment,
            session: session,
            transportSessionID: transportSessionID,
            sessionStore: sessionStore,
            artifactSources: artifactSources
        )
    }

    func callSessionSummary(
        stack: TestStack,
        includeHeaders: Bool = false,
        includeBody: Bool = false,
        headerSource: String? = nil,
        toolName: String = "session_summary",
        selectionPointer: String? = nil,
        toolArguments: [String: Any]? = nil
    ) async throws -> ToolResponse {
        var arguments: [String: Any] = toolArguments ?? ["sessionID": stack.session.id.uuidString]
        if includeHeaders { arguments["includeHeaders"] = true }
        if includeBody { arguments["includeBody"] = true }
        if let headerSource { arguments["headerSource"] = headerSource }
        if let selectionPointer { arguments["selectionPointer"] = selectionPointer }
        return try await callRPC(stack: stack, method: "tools/call", params: ["name": toolName, "arguments": arguments])
    }

    func callRPC(stack: TestStack, method: String, params: [String: Any], session: String? = nil) async throws -> ToolResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ])
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(stack.enrollment.plaintextCredential)",
                "accept": "application/json, text/event-stream",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                MCPNetworkConstants.sessionIDHeader.lowercased(): session ?? stack.transportSessionID,
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
            ],
            body: body
        )
        let object = try response.jsonBodyObject()
        if let error = object["error"] as? [String: Any] {
            return ToolResponse(result: nil, errorData: error["data"] as? [String: Any] ?? error, wireBytes: response.body.count)
        }
        var result = ToolResponse(result: object["result"] as? [String: Any], errorData: nil,
                                  wireBytes: response.body.count, requestBytes: body.count)
        if let name = params["name"] as? String, ["sessions_search", "session_summary", "capture_calculate"].contains(name) {
            result.measurementMessages = ["request": String(decoding: body, as: UTF8.self),
                                          "response": String(decoding: response.body, as: UTF8.self)]
        }
        return result
    }

    func summaryPayload(from response: ToolResponse) throws -> [String: Any] {
        // `session_summary` returns the summary DTO directly as structuredContent (not an envelope).
        if let structured = response.result?["structuredContent"] as? [String: Any] {
            if let nested = structured["payload"] as? [String: Any] {
                return nested
            }
            return structured
        }
        XCTFail("Missing structuredContent in \(String(describing: response.result)) error=\(String(describing: response.errorData))")
        throw NSError(domain: "MCPResponseDisclosureIntegrationTests", code: 1)
    }

    func initializeSession(
        protocolService: MCPProtocolService,
        bearer: String
    ) async throws -> String {
        let initBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "response-disclosure-test", "version": "1"]
            ]
        ])
        let initResponse = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "accept": "application/json, text/event-stream",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)"
            ],
            body: initBody
        )
        let sessionID = try XCTUnwrap(initResponse.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        let initializedBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "accept": "application/json, text/event-stream",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID,
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
            ],
            body: initializedBody
        )
        return sessionID
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + name)
    }

    private static func fixtureGET502() -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/app/status.json",
                headers: [
                    HTTPHeaderField(name: "Host", value: "api.example.com"),
                    HTTPHeaderField(name: "Accept", value: "application/json"),
                    HTTPHeaderField(name: "User-Agent", value: "JoesProxyTests/1")
                ],
                bodyData: nil,
                bodySize: 0
            ),
            response: CapturedResponse(
                statusCode: 502,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json"),
                    HTTPHeaderField(name: "Server", value: "envoy"),
                    HTTPHeaderField(name: "Via", value: "1.1 google")
                ],
                bodyData: Data("{\"error\":\"bad_gateway\",\"code\":502}".utf8),
                bodySize: 36
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private static func fixtureGETWithoutResponseBody() -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/app/status.json",
                headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
                bodyData: nil,
                bodySize: 0
            ),
            response: CapturedResponse(
                statusCode: 204,
                headers: [HTTPHeaderField(name: "Server", value: "envoy")],
                bodyData: nil,
                bodySize: 0
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }
}
