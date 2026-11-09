import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    func reviewedHAR(_ stack: TestStack, scopes: [String], recordAttempt: (String, Int) -> Void = { _, _ in }) async throws -> [String: Any] {
        try await reviewedSource(stack, kind: .har, data: RepeatedArtifactSearchBenchmarkTests.encodedHAR(varied: true),
                                 scopes: scopes, recordAttempt: recordAttempt)
    }

    func reviewedSource(_ stack: TestStack, kind: ArtifactSourceKind, data: Data, scopes: [String],
                        recordAttempt: (String, Int) -> Void) async throws -> [String: Any] {
        let key = UUID().uuidString
        let registration: [String: Any] = ["requestKey": key, "kind": kind.rawValue, "scopes": scopes]
        var bytes = 0
        let pending = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: registration)
        XCTAssertNotNil(pending.errorData)
        recordAttempt("pending", pending.wireBytes)
        bytes += pending.wireBytes
        let poll = try await callSessionSummary(stack: stack, toolName: "artifact_source_status", toolArguments: ["requestKey": key])
        recordAttempt("poll", poll.wireBytes)
        bytes += poll.wireBytes
        let request = try XCTUnwrap(stack.artifactSources.requests.first { $0.key == key })
        stack.artifactSources.prepare(id: request.id, selection: .synthetic(data))
        await stack.artifactSources.waitForPreparation(id: request.id)
        try stack.artifactSources.share(id: request.id)
        let retry = try await callSessionSummary(stack: stack, toolName: "artifact_source_register", toolArguments: registration)
        let ready = try summaryPayload(from: retry)
        recordAttempt("retry", retry.wireBytes)
        print("SAVED_REVIEW setupCalls=3 setupBytes=\(bytes + retry.wireBytes) rawBytes=\(data.count)")
        return ["handle": try XCTUnwrap(ready["handle"]), "snapshotRevision": try XCTUnwrap(ready["snapshotRevision"])]
    }

    func testColdSavedBriefDiscoveryAndReviewThroughAnswer() async throws {
        let stack = try await makeStack()
        let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
        let tools = try XCTUnwrap(catalog.result?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "artifact_response_brief" })
        var setupBytes = 0
        var args = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"]) { _, bytes in setupBytes += bytes }
        args["recordIndex"] = 0
        let answer = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: args)
        let report = try summaryPayload(from: answer)
        XCTAssertEqual(report["status"] as? String, "complete")
        XCTAssertEqual(report["itemCount"] as? Int, 1)
        XCTAssertGreaterThan(setupBytes, 0)
        XCTAssertLessThanOrEqual(answer.wireBytes, 65_536)
        args["recordIndex"] = 63
        let omission = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: args)
        XCTAssertEqual(try summaryPayload(from: omission)["reason"] as? String, "incomplete_body")
        print("EC07_BRIEF coldCalls=5 catalogBytes=\(catalog.wireBytes) setupBytes=\(setupBytes) briefBytes=\(answer.wireBytes) coldBytes=\(catalog.wireBytes + setupBytes + answer.wireBytes) missingFollowupBytes=\(omission.wireBytes)")
    }

    func testSavedBriefDiscoveryCatalogsThroughReviewedAnswer() async throws {
        enum Route: String, CaseIterable { case full, guidedCapture, captureSelected, fullThenCapture }
        let requiredTools = ["artifact_source_register", "artifact_source_status", "artifact_response_brief"]
        var referenceAnswer: NSDictionary?
        var fullCatalogSize = 0
        for route in Route.allCases {
            let work = ArtifactWorkCounter()
            let stack = try await makeStack(worker: ArtifactAnalysisWorker(beforeWork: { work.increment() }))
            var bytes: [String: Int] = [:]
            func selectCapture() async throws -> Int {
                let selection = try await callSessionSummary(stack: stack, toolName: "agent_toolset_select", toolArguments: ["toolset": "capture"])
                let payload = try summaryPayload(from: selection)
                XCTAssertEqual(payload["selectedToolset"] as? String, "capture")
                XCTAssertEqual(payload["relistRequired"] as? Bool, true)
                return selection.wireBytes
            }
            // An established preference has a separate setup cost outside this investigation.
            let priorSelectionBytes = route == .captureSelected ? try await selectCapture() : 0
            if route == .fullThenCapture {
                let firstList = try await callRPC(stack: stack, method: "tools/list", params: [:])
                let firstTools = try XCTUnwrap(firstList.result?["tools"] as? [[String: Any]])
                XCTAssertTrue(firstTools.contains { $0["name"] as? String == "agent_toolset_select" })
                bytes["initialFullList"] = firstList.wireBytes
            }
            if route == .guidedCapture || route == .fullThenCapture {
                let status = try await callSessionSummary(stack: stack, toolName: "agent_toolset_status", toolArguments: [:])
                XCTAssertEqual(try summaryPayload(from: status)["selectedToolset"] as? String, "all")
                bytes["status"] = status.wireBytes
                bytes["select"] = try await selectCapture()
            }
            let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
            bytes["catalog"] = catalog.wireBytes
            let tools = try XCTUnwrap(catalog.result?["tools"] as? [[String: Any]])
            let names = Set(tools.compactMap { $0["name"] as? String })
            XCTAssertTrue(names.isSuperset(of: requiredTools))
            if route == .full { fullCatalogSize = catalog.wireBytes }
            else { XCTAssertLessThan(catalog.wireBytes, fullCatalogSize) }
            XCTAssertEqual(work.value, 0)
            var args = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"]) { stage, size in bytes[stage] = size }
            XCTAssertEqual(work.value, 1)
            args["recordIndex"] = 0
            let answer = try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: args)
            bytes["answer"] = answer.wireBytes
            var facts = try summaryPayload(from: answer)
            for key in ["handle", "snapshotRevision"] {
                XCTAssertEqual(try XCTUnwrap(facts.removeValue(forKey: key) as? String), try XCTUnwrap(args[key] as? String))
            }
            XCTAssertEqual(facts["recordIndex"] as? Int, 0)
            XCTAssertEqual(facts["status"] as? String, "complete")
            XCTAssertEqual(facts["itemCount"] as? Int, 1)
            XCTAssertEqual(work.value, 2)
            if let referenceAnswer { XCTAssertEqual(facts as NSDictionary, referenceAnswer) }
            else { referenceAnswer = facts as NSDictionary }
            let sample: [String: Any] = ["route": route.rawValue, "tools": names.count, "calls": bytes.count,
                "stageBytes": bytes, "totalBytes": bytes.values.reduce(0, +), "priorSelectionBytes": priorSelectionBytes,
                "preparations": 1, "briefAnalyses": work.value - 1]
            let encoded = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
            print("SAVED_BRIEF_DISCOVERY " + String(decoding: encoded, as: UTF8.self))
        }
    }

    func testBriefGrantCoverageAndRevocationBeforePublication() async throws {
        let counter = ArtifactWorkCounter()
        let gate = ArtifactTestGate()
        defer { gate.open() }
        let worker = ArtifactAnalysisWorker(beforeWork: {
            counter.increment()
            if counter.value == 6 { gate.wait() }
        })
        let stack = try await makeStack(worker: worker)
        var args = try await reviewedHAR(stack, scopes: ["metadata-v1", "search-v1", "calculations-v1"])
        args["recordIndex"] = 0
        func brief(_ args: [String: Any]) async throws -> [String: Any] {
            try summaryPayload(from: await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: args))
        }
        let denied = try await brief(args)
        XCTAssertEqual(denied["reason"] as? String, "source_unavailable")
        _ = try await callSessionSummary(stack: stack, toolName: "artifact_source_release", toolArguments: ["handle": try XCTUnwrap(args["handle"])])
        args = try await reviewedHAR(stack, scopes: ["metadata-v1", "brief-v1"])
        args["recordIndex"] = 0
        var stale = args
        stale["snapshotRevision"] = UUID().uuidString
        let refused = try await brief(stale)
        XCTAssertEqual(refused["reason"] as? String, "source_unavailable")
        let first = try await brief(args)
        XCTAssertEqual(first["status"] as? String, "complete")
        XCTAssertEqual(first["recordIndex"] as? Int, 0)
        XCTAssertEqual(first["itemCount"] as? Int, 1)
        XCTAssertFalse(String(describing: first).contains("tag-0000"))
        args["recordIndex"] = 63
        let missing = try await brief(args)
        XCTAssertEqual(missing["reason"] as? String, "incomplete_body")
        args["recordIndex"] = 0
        args["selectionPointer"] = "/missing"
        let noSelection = try await brief(args)
        XCTAssertEqual(noSelection["reason"] as? String, "selection_not_found")
        XCTAssertEqual(counter.value, 5)
        let running = Task { try await brief(args) }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        stack.artifactSources.currentBriefPermission = { _ in false }
        gate.open()
        let retired = try await running.value
        XCTAssertEqual(retired["reason"] as? String, "source_unavailable")
        XCTAssertNil(retired["fields"])
    }

    func testNativeProbeThroughMCPAndCLI() async throws {
        for trial in 0..<5 {
            let stack = try await makeStack()
            let identity = try await reviewedHAR(stack, scopes: ["metadata-v1", "search-v1", "brief-v1"])
            let transport = MCPNIOHTTPTransport(protocolService: stack.protocolService)
            try await transport.start(port: 0)
            do {
                let port = try XCTUnwrap(transport.boundPort)
                stack.protocolService.rebindLoopbackPort(port)
                let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
                try await measureLoopback(stack, identity: identity, endpoint: endpoint, trial: trial)
            } catch {
                await transport.shutdown()
                throw error
            }
            await transport.shutdown()
        }
    }

    private func measureLoopback(_ stack: TestStack, identity: [String: Any], endpoint: URL, trial: Int) async throws {
        let store = TestCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: stack.transportSessionID,
            protocolVersion: "2025-11-25", updatedAt: Date()))
        let credentials = TestCLICredentialStore()
        try credentials.save(stack.enrollment.plaintextCredential, endpoint: endpoint)
        var output = Data()
        let cli = CLIApplication(credentialStore: credentials, sessionStore: store, writeResult: { output = $0 })
        let rpc = MCPCLIClient(endpoint: endpoint, credential: stack.enrollment.plaintextCredential, sessionStore: store, timeout: 10)
        let base = ["--handle", try XCTUnwrap(identity["handle"] as? String), "--snapshot-revision",
            try XCTUnwrap(identity["snapshotRevision"] as? String), "--endpoint", endpoint.absoluteString, "--json"]
        let briefCode = await cli.run(arguments: ["artifact", "brief", "--record-index", "0", "--include-structure"] + base)
        XCTAssertEqual(briefCode, .success)
        let brief = try XCTUnwrap((JSONSerialization.jsonObject(with: output) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(brief["status"] as? String, "complete")
        XCTAssertEqual(brief["structureCoverage"] as? String, "complete")
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("tag-0000"))
        if trial == 0 { print("SAVED_BRIEF cliOutputBytes=\(output.count)") }
        let sampler = CurrentProcessMetricsSampler()
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        let sessions = stack.artifactSources.searchSessions
        defer { sessions.observePage = nil }
        for route in trial.isMultiple(of: 2) ? ["mcp", "cli"] : ["cli", "mcp"] {
            for probe in trial.isMultiple(of: 2) ? [false, true] : [true, false] {
                sessions.nativeProbe = probe
                for (workload, terms) in [("selective", ["tag-0034", "absent-A", "tag-0049", "absent-B"]), ("dense", ["common"])] {
                    var elapsed = 0.0, worker = 0.0
                    var calls = 0, envelopeBytes = 0, outputBytes = 0, chargedBytes = 0
                    sessions.observePage = { duration, size in worker += ms(duration); envelopeBytes += size }
                    for term in terms {
                        var cursor: String?
                        var hits: [Int] = []
                        repeat {
                            let began = ContinuousClock.now
                            let page: [String: Any]
                            if route == "cli" {
                                let continuation = cursor.map { ["--cursor", $0] } ?? []
                                let exit = await cli.run(arguments: ["artifact", "search", "--dataset", "responseJSON", "--literal", term] + base + continuation)
                                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
                                page = try XCTUnwrap(envelope["result"] as? [String: Any])
                                XCTAssertEqual(exit, page["hasMore"] as? Bool == true ? .success : .partialResult)
                                outputBytes += output.count
                            } else {
                                var args = identity
                                args["dataset"] = "responseJSON"
                                args["literal"] = term
                                args["cursor"] = cursor
                                page = try await rpc.callTool(name: "artifact_search", arguments: args, retryOnStaleSession: false)
                            }
                            elapsed += ms(began.duration(to: .now))
                            calls += 1
                            let rows = try XCTUnwrap(page["items"] as? [[String: Any]])
                            for row in rows {
                                hits.append(try XCTUnwrap(row["recordIndex"] as? Int))
                                XCTAssertEqual(row["byteOffset"] as? Int, term == "common" ? 2 : 2035)
                                XCTAssertEqual(row["byteLength"] as? Int, term.utf8.count)
                                XCTAssertNotNil(row["matchRef"] as? String)
                            }
                            let coverage = try XCTUnwrap(page["coverage"] as? [String: Any])
                            chargedBytes += try XCTUnwrap(coverage["pageScannedBytes"] as? Int)
                            cursor = page["nextCursor"] as? String
                            XCTAssertTrue(page["exactTotal"] is NSNull)
                            if cursor == nil {
                                XCTAssertEqual(page["status"] as? String, "incomplete")
                                XCTAssertEqual(coverage["omissions"] as? [String: Int], ["representation_unavailable": 1])
                                XCTAssertEqual(coverage["searchedUnits"] as? Int, 63)
                            }
                            guard calls <= 16 else { return XCTFail("Unexpected pagination") }
                        } while cursor != nil
                        let expected = term == "common" ? Array(0..<63) : Int(term.suffix(4)).map { [$0] } ?? []
                        XCTAssertEqual(hits, expected)
                    }
                    let memory = sampler.sample()
                    let sample: [String: Any] = ["route": route, "probe": probe, "workload": workload, "trial": trial,
                        "ms": elapsed, "workerMs": worker, "calls": calls, "envelopeBytes": envelopeBytes,
                        "cliOutputBytes": outputBytes, "chargedBytes": chargedBytes, "processPeakResidentBytes": memory.peakResidentMemoryBytes]
                    print("EC10_LOOPBACK " + String(decoding: try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]), as: UTF8.self))
                }
            }
        }
    }
}
