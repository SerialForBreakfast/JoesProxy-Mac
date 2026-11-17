import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    func testReleasePairedEvidence() async throws {
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertTrue(["1.9.0", "1.9.1"].contains(version))
        let newer = version == "1.9.1"
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        var calls: [[String: Any]] = []
        func invoke(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let result = try await callSessionSummary(stack: stack, toolName: name, toolArguments: arguments)
            let answer = try summaryPayload(from: result)
            calls.append(["tool": name, "arguments": arguments, "answer": answer])
            return answer
        }
        let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
        let definitions = try XCTUnwrap(catalog.result?["tools"] as? [[String: Any]])
        let records = (0...300).map { i in
            SessionRecord(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!,
                request: stack.session.request, response: i == 299 ? nil : stack.session.response,
                state: i == 299 ? .pending : .completed,
                timing: SessionTiming(startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        stack.sessionStore.load(sessions: records)
        let filter = ["method":"GET", "path":"/app/", "startedAfter":"1970-01-01T00:00:00Z", "startedBefore":"1970-01-01T00:04:59Z"]
        if newer {
            let result = try await invoke("capture_calculate", ["dataset":"sessionMetadata", "selectionPointer":"", "filter":filter, "operation":["kind":"groupCount","fieldPointer":"/statusCode"]])
            XCTAssertEqual(result["rows"] as? Int, 300)
        } else {
            var args: [String: Any] = filter
            args["limit"] = 100
            args["projection"] = "minimal"
            var items: [[String:Any]] = []
            repeat {
                let page = try await invoke("sessions_search", args)
                items += try XCTUnwrap(page["items"] as? [[String:Any]])
                args["cursor"] = page["nextCursor"] as? String
            } while args["cursor"] != nil && calls.count < 10
            XCTAssertEqual(items.count, 300)
            XCTAssertEqual(items.filter { $0["statusCode"] as? Int == 502 }.count, 299)
        }
        let count = calls
        let exampleID: String
        if newer {
            var query: [String: Any] = filter
            query["limit"] = 1
            query["statusCode"] = 502
            let page = try await invoke("sessions_search", query)
            exampleID = try XCTUnwrap((page["items"] as? [[String:Any]])?.first?["id"] as? String)
        } else {
            let page = try XCTUnwrap(count.first?["answer"] as? [String:Any])
            exampleID = try XCTUnwrap((page["items"] as? [[String:Any]])?.first(where: { $0["statusCode"] as? Int == 502 })?["id"] as? String)
        }
        let example = try await invoke("session_summary", ["sessionID":exampleID])
        XCTAssertEqual(example["statusCode"] as? Int, 502)
        let detail = calls
        calls = []
        let pair = try (0...1).map { i -> SessionRecord in
            let content: [String: Any] = ["settings":["featureEnabled":i == 1,"updatedAt":i == 0 ? "2026-01-01T00:00:00Z":"2026-01-02T00:00:00Z"] as [String: Any]]
            let body = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
            return SessionRecord(id: records[i].id, request: stack.session.request,
                response: CapturedResponse(statusCode:200, headers:[HTTPHeaderField(name:"Content-Type",value:"application/json")], bodyData:body,bodySize:body.count),
                state:.completed,timing:records[i].timing)
        }
        stack.sessionStore.load(sessions:pair)
        if newer {
            _ = try await invoke("investigation_compare_brief", ["baselineSessionIDs":[pair[0].id.uuidString],"candidateSessionIDs":[pair[1].id.uuidString],"selectionPointer":"/settings","includeValueDiff":true])
        } else {
            for record in pair {
                _ = try await invoke("session_summary", ["sessionID":record.id.uuidString,"includeBody":true])
            }
        }
        let packet: [String:Any] = ["version":version,"discovery":definitions,"count":count,"example":detail,"comparison":calls]
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys,.withoutEscapingSlashes]),uniformTypeIdentifier:"public.json")
        attachment.name = "edge-release-evidence-" + version
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
