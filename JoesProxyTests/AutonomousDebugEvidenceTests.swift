import CoreFoundation
import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    func testWireScalarContract() async throws {
        guard Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String == "1.9.1" else { throw XCTSkip("Typed contract introduced in build 25") }
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        let before = #"{"flag":false,"literal":"false","mixed":"false","zero":0,"authToken":false}"#
        let after = #"{"flag":true,"literal":"true","mixed":true,"zero":1,"authToken":true}"#
        let rows = autonomousRows(stack, bodies: [before, after])
        stack.sessionStore.load(sessions: rows)
        let wire = try await callSessionSummary(stack: stack, toolName: "investigation_compare_brief", toolArguments: [
            "baselineSessionIDs":[rows[0].id.uuidString],"candidateSessionIDs":[rows[1].id.uuidString],"includeValueDiff":true])
        let report = try summaryPayload(from: wire)
        XCTAssertEqual(report["status"] as? String,"complete")
        let changes = try XCTUnwrap(report["valueChanges"] as? [[String:Any]])
        XCTAssertEqual(changes.count,5)
        func row(_ key:String) throws -> [String:Any] { try XCTUnwrap(changes.first { $0["pointer"] as? String == "/"+key }) }
        for (field,left,right) in [("flag","boolean","boolean"),("literal","string","string"),("mixed","string","boolean"),("zero","number","number"),("authToken","boolean","boolean")] {
            let r = try row(field)
            for (side,type) in [("before",left),("after",right)] {
                let isAfter = side=="after"
                XCTAssertEqual(r[side+"Type"] as? String,type)
                if field=="authToken" {
                    XCTAssertEqual(r[side+"Preview"] as? String,"<redacted>"); XCTAssertNil(r[side+"Value"])
                } else if type=="boolean" {
                    let n = try XCTUnwrap(r[side+"Value"] as? NSNumber)
                    XCTAssertEqual(CFGetTypeID(n),CFBooleanGetTypeID()); XCTAssertEqual(n.boolValue,isAfter)
                    XCTAssertNil(r[side+"Preview"])
                } else {
                    XCTAssertNil(r[side+"Value"])
                    XCTAssertEqual(r[side+"Preview"] as? String,type=="string" ? (isAfter ? "true":"false") : (isAfter ? "1":"0"))
                }
            }
        }
    }

    private func autonomousRows(_ stack: TestStack,bodies:[String?]) -> [SessionRecord] {
        bodies.enumerated().map { i,text in
            let data = text.map { Data($0.utf8) }
            return SessionRecord(id:UUID(uuidString:String(format:"10000000-0000-4000-8000-%012d",i+1))!,request:stack.session.request,
                response:CapturedResponse(statusCode:200,headers:[HTTPHeaderField(name:"Content-Type",value:"application/json")],bodyData:data,bodySize:data?.count ?? 256),
                state:.completed,timing:SessionTiming(startedAt:Date(timeIntervalSince1970:Double(i+1))))
        }
    }

    // An opt-in synthetic test broker submits the agent's actual arguments to the production
    // authenticated RPC dispatcher. Credentials for the in-memory enrolled client stay in-process.
    func testAutonomousToolHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port=env["JP_BENCH_PORT"], let key=env["JP_BENCH_KEY"], let url=URL(string:"http://127.0.0.1:"+port+"/host") else { throw XCTSkip("Opt-in benchmark host") }
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        var stack = try await makeStack()
        var reply:[String:Any]=["ready":true,"version":version,"build":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""]
        let histogram=env["JP_BENCH_SCENARIO"]=="histogram"
        let allowed=Set(histogram ? ["sessions_list","sessions_search","session_summary","capture_calculate"] : ["sessions_list","sessions_search","session_summary","response_evidence_brief","investigation_compare_brief"])
        let end=Date().addingTimeInterval(3600)
        while Date()<end {
            var req=URLRequest(url:url); req.httpMethod="POST"; req.timeoutInterval=90
            req.setValue(key,forHTTPHeaderField:"X-Trial-Key"); req.httpBody=try JSONSerialization.data(withJSONObject:reply)
            let (data,res)=try await URLSession.shared.data(for:req)
            XCTAssertEqual((res as? HTTPURLResponse)?.statusCode,200)
            let cmd=try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any])
            switch cmd["action"] as? String {
            case "stop": return
            case "reset":
                stack=try await makeStack()
                _ = try stack.grantStore.addGrant(clientID:stack.enrollment.client.id,capability:.bodyRead,mode:.untilSessionEnd)
                let bodies=try XCTUnwrap(cmd["bodies"] as? [Any])
                stack.sessionStore.load(sessions:histogram ? scaleHistogramRecords() : autonomousRows(stack,bodies:bodies.map { $0 as? String }))
                reply=["ready":true,"version":version]
            case "list":
                let rpc=try await callRPC(stack:stack,method:"tools/list",params:[:])
                let defs=try XCTUnwrap(rpc.result?["tools"] as? [[String:Any]])
                reply=["tools":defs.filter { allowed.contains($0["name"] as? String ?? "") }]
            case "call":
                let name=try XCTUnwrap(cmd["name"] as? String)
                guard allowed.contains(name) else { XCTFail("Unexpected tool");return }
                let rpc=try await callSessionSummary(stack:stack,toolName:name,toolArguments:cmd["arguments"] as? [String:Any] ?? [:])
                if let error=rpc.errorData { reply=["error":error] }
                else { reply=["answer":try summaryPayload(from:rpc)] }
            default: reply=["idle":true]
            }
        }
        XCTFail("Benchmark host deadline exceeded")
    }
}
