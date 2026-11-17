import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    func testExportCompactRowModelTrial() async throws {
        guard ProcessInfo.processInfo.environment["JOESPROXY_EXPORT_COMPACT_TRIAL"] == "1" else {
            throw XCTSkip("Run explicitly to export synthetic dispatcher responses for BigDog.")
        }
        let failed = [3, 7, 19, 49, 53]
        let pending = [9]
        func id(_ index: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
        }
        var cases: [[String: Any]] = []
        for count in [0, 1, 54] {
            let stack = try await makeStack()
            let records = (0..<count).map { i in
                SessionRecord(id: id(i), request: stack.session.request,
                    response: pending.contains(i) ? nil : .init(statusCode: failed.contains(i) ? 503 : 200,
                        headers: [], bodyData: Data([1]), bodySize: 1),
                    state: pending.contains(i) ? .pending : .completed, timing: stack.session.timing)
            }
            stack.sessionStore.load(sessions: records)
            if count == 54 { stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0) }
            var plain: [String: Any] = ["limit": 50]
            var compact = plain
            compact["compactRows"] = true
            var offset = 0
            repeat {
                let a = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: plain)
                let b = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: compact)
                let ordinary = try summaryPayload(from: a)
                let table = try summaryPayload(from: b)
                let end = min(offset + 50, count)
                let expected: [String: Any] = ["failureIDs": failed.filter { (offset..<end).contains($0) }.map { id($0).uuidString },
                    "unknownStatusCount": pending.filter { (offset..<end).contains($0) }.count,
                    "hasMore": end < count, "retentionWarning": count == 54]
                XCTAssertEqual(ordinary["captureWarning"] != nil, count == 54)
                XCTAssertEqual(ordinary["hasMore"] as? Bool, end < count)
                XCTAssertEqual(table["rows"] != nil, end - offset > 1)
                cases.append(["id": "page-\(count)-\(offset)", "ordinary": ordinary, "compact": table, "expected": expected])
                plain["cursor"] = ordinary["nextCursor"]
                compact["cursor"] = table["nextCursor"]
                offset = end
                if end < count { _ = try XCTUnwrap(compact["cursor"]); _ = try XCTUnwrap(plain["cursor"]) }
            } while offset < count
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/compact-row-pages.json")
        try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys]).write(to: output, options: .atomic)
    }

    func testCompactSearchMatchesEveryPage() async throws {
        let stack = try await makeStack()
        for count in [0, 1, 54] {
            let records = (0..<count).map { i in
                SessionRecord(request: stack.session.request, response: i == 2 ? nil : stack.session.response,
                    state: i == 2 ? .pending : .completed, timing: stack.session.timing)
            }
            stack.sessionStore.load(sessions: records)
            stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0)
            var ordinary: [String: Any] = ["limit": 50]
            var compact = ordinary
            compact["compactRows"] = true
            var ids: [String] = []
            repeat {
                let started = ContinuousClock.now
                let control = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: ordinary)
                let middle = ContinuousClock.now
                let candidate = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: compact)
                let finished = ContinuousClock.now
                var expected = try summaryPayload(from: control)
                var actual = try summaryPayload(from: candidate)
                if let columns = actual.removeValue(forKey: "columns") as? [String] {
                    let rows = try XCTUnwrap(actual.removeValue(forKey: "rows") as? [[Any]])
                    actual["items"] = rows.map { row in
                        Dictionary(uniqueKeysWithValues: zip(columns, row).filter { !($0.1 is NSNull) })
                    }
                    XCTAssertLessThan(candidate.wireBytes + candidate.requestBytes, control.wireBytes + control.requestBytes)
                } else { XCTAssertLessThanOrEqual(count, 1) }
                ordinary["cursor"] = expected.removeValue(forKey: "nextCursor")
                compact["cursor"] = actual.removeValue(forKey: "nextCursor")
                XCTAssertEqual(ordinary["cursor"] == nil, compact["cursor"] == nil)
                XCTAssertEqual(expected as NSDictionary, actual as NSDictionary)
                if count > 1 { XCTAssertNotNil(actual["captureWarning"]) }
                let rows = try XCTUnwrap(actual["items"] as? [[String: Any]])
                ids += rows.compactMap { $0["id"] as? String }
                print("EDGE_SEARCH rows=\(rows.count) old=\(control.requestBytes)/\(control.wireBytes) compact=\(candidate.requestBytes)/\(candidate.wireBytes) time=\(started.duration(to: middle))/\(middle.duration(to: finished))")
            } while ordinary["cursor"] != nil && compact["cursor"] != nil && ids.count <= count
            XCTAssertEqual(ids, records.map { $0.id.uuidString })
        }
    }

    func testHTTPErrorClustersMatchDisclosedBodyControl() async throws {
        let stack = try await makeStack()
        let inputs = [#"{"code":"busy","n":1}"#, #"{"n":1, "code":"busy"}"#, #"{"code":"gone","n":1}"#]
        let records = inputs.map { json in
            SessionRecord(request: stack.session.request, response: .init(statusCode: 503,
                headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: Data(json.utf8), bodySize: json.utf8.count), state: .completed, timing: stack.session.timing)
        }
        stack.sessionStore.load(sessions: records)
        let args = ["errorClusters": true]
        let denied = try await callSessionSummary(stack: stack, toolName: "audit_cache_efficiency", toolArguments: args)
        XCTAssertNotNil(denied.errorData)
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let start = ContinuousClock.now
        let page = try await callSessionSummary(stack: stack, toolName: "sessions_search", toolArguments: ["statusClass": "error"])
        let items = try XCTUnwrap(try summaryPayload(from: page)["items"] as? [[String: Any]])
        var control: [Data: [String]] = [:]
        var requests = page.requestBytes, responses = page.wireBytes
        for item in items {
            let id = try XCTUnwrap(item["id"] as? String)
            let read = try await callSessionSummary(stack: stack, includeBody: true, toolArguments: ["sessionID": id])
            let text = try XCTUnwrap(try summaryPayload(from: read)["bodyExcerpt"] as? String)
            let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
            control[try JSONSerialization.data(withJSONObject: obj, options: .sortedKeys), default: []].append(id)
            requests += read.requestBytes
            responses += read.wireBytes
        }
        let middle = ContinuousClock.now
        let answer = try await callSessionSummary(stack: stack, toolName: "audit_cache_efficiency", toolArguments: args)
        let finish = ContinuousClock.now
        let report = try XCTUnwrap(try summaryPayload(from: answer)["errorClusters"] as? [String: Any])
        let clusters = try XCTUnwrap(report["clusters"] as? [String: Any])
        let examples = try XCTUnwrap(clusters["examples"] as? [[String: Any]])
        XCTAssertEqual(report["matchedHTTPFailures"] as? Int, 3)
        XCTAssertEqual(clusters["distinct"] as? Int, 2)
        XCTAssertEqual(control.values.map(\.count).sorted(), [1, 2])
        XCTAssertEqual(examples.count, control.count)
        for members in control.values {
            let example = examples.first { ($0["representativeSessionID"] as? String) == members.first }
            XCTAssertEqual(example?["occurrences"] as? Int, members.count)
            XCTAssertEqual(example?["statusCode"] as? Int, 503)
        }
        print("EDGE_ERRORS oldCalls=\(1 + items.count) old=\(requests)/\(responses) newCalls=1 new=\(answer.requestBytes)/\(answer.wireBytes) time=\(start.duration(to: middle))/\(middle.duration(to: finish))")
    }

    func testErrorClusterLimitsPreserveRareEvidenceAndExplainFallbacks() async throws {
        let stack = try await makeStack()
        func row(_ text: String, status: Int = 503, mime: String = "application/json", truncated: Bool = false) -> SessionRecord {
            SessionRecord(request: stack.session.request, response: .init(statusCode: status,
                headers: [.init(name: "Content-Type", value: mime)], bodyData: Data(text.utf8),
                bodySize: text.utf8.count, bodyTruncated: truncated), state: .completed, timing: stack.session.timing)
        }
        var rows: [SessionRecord] = []
        for n in 0..<17 { rows += [row("[\(n),99]"), row("[\(n),99]")] }
        let rare = row("[99,0]")
        rows.append(rare)
        let bounded = try ResponseVariantAudit.ErrorReport(rows)
        XCTAssertEqual(bounded.clusters.distinct, 18)
        XCTAssertEqual(bounded.clusters.omitted, 2)
        XCTAssertTrue(bounded.clusters.examples.contains { $0.representativeSessionID == rare.id })
        let mixed = try ResponseVariantAudit.ErrorReport([row("bad"), row("bad"), row("bad", status: 400),
            row("busy", mime: "text/plain"), row("missing", truncated: true), row("ok", status: 200)])
        XCTAssertEqual(mixed.matchedHTTPFailures, 5)
        XCTAssertEqual(mixed.clusters.distinct, 3)
        XCTAssertEqual(mixed.skippedBodies, ["incomplete": 1])
        XCTAssertEqual(mixed.rawBodyFallbacks, ["malformed_source": 3, "not_json": 1])
    }

    func testPollingAgainstWaitAndCheckpoint() async throws {
        _ = try await pollingComparison()
    }

    /// Both observers see the same synthetic publication and share the same checkpoint boundaries.
    func pollingComparison() async throws -> [String: Any] {
        let stack = try await makeStack(responseBody: Data("healthy".utf8))
        let start = try await callSessionSummary(stack: stack, toolName: "capture_digest", toolArguments: ["interval": "start"])
        let token = try XCTUnwrap(try summaryPayload(from: start)["checkpoint"] as? String)
        let wait = Task { @MainActor in
            let reply = try await self.callSessionSummary(stack: stack, toolName: "capture_wait",
                toolArguments: ["statusClass": "5xx", "seconds": 3])
            return (reply, ContinuousClock.now)
        }
        defer { wait.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while stack.snapshotService.activeWaits == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(stack.snapshotService.activeWaits, 1)
        var polls: [ToolResponse] = []
        func poll() async throws -> [[String: Any]] {
            let read = try await callSessionSummary(stack: stack, toolName: "sessions_search",
                toolArguments: ["statusClass": "5xx", "limit": 1])
            polls.append(read)
            return try XCTUnwrap(try summaryPayload(from: read)["items"] as? [[String: Any]])
        }
        for _ in 0..<3 {
            let items = try await poll()
            XCTAssertTrue(items.isEmpty)
            try await Task.sleep(for: .milliseconds(20))
        }
        let rare = SessionRecord(request: stack.session.request, response: .init(statusCode: 503, headers: [],
            bodyData: Data([1]), bodySize: 1), state: .completed, timing: stack.session.timing)
        let published = ContinuousClock.now
        stack.sessionStore.append(rare)
        try await Task.sleep(for: .milliseconds(20))
        let detected = try await poll()
        let polled = ContinuousClock.now
        XCTAssertEqual(detected.first?["id"] as? String, rare.id.uuidString)
        let (wake, woke) = try await wait.value
        let notice = try summaryPayload(from: wake)
        XCTAssertEqual(notice["outcome"] as? String, "matched")
        XCTAssertEqual(notice["matched"] as? Int, 1)
        stack.sessionStore.retentionPolicy = .keepLastBodyBytes(0)
        stack.sessionStore.retentionPolicy = .keepLastSessions(1)
        let end = try await callSessionSummary(stack: stack, toolName: "capture_digest", toolArguments: ["interval": token])
        let report = try summaryPayload(from: end)
        XCTAssertEqual(report["failureTransitions"] as? Int, 1)
        XCTAssertEqual(report["removedBodies"] as? Int, 2)
        XCTAssertEqual(report["removedSessions"] as? Int, 1)
        let fixedRequest = start.requestBytes + end.requestBytes, fixedResponse = start.wireBytes + end.wireBytes
        let receipt: [String: Any] = ["pollCalls": polls.count + 2, "waitCalls": 3, "pollRetries": 0, "waitRetries": 0,
            "pollRequest": polls.reduce(fixedRequest) { $0 + $1.requestBytes },
            "pollResponse": polls.reduce(fixedResponse) { $0 + $1.wireBytes },
            "waitRequest": fixedRequest + wake.requestBytes, "waitResponse": fixedResponse + wake.wireBytes,
            "pollDetection": String(describing: published.duration(to: polled)),
            "waitDetection": String(describing: published.duration(to: woke))]
        print("EDGE_WAIT \(receipt)")
        return receipt
    }
}
