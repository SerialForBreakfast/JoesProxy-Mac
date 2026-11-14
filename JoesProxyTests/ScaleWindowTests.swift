import Foundation
import XCTest
@testable import JoesProxy

extension MCPResponseDisclosureIntegrationTests {
    func scaleHistogramRecords() -> [SessionRecord] {
        let request = CapturedRequest(method:"GET",scheme:.https,host:"media.example.test",port:443,path:"/vod/segment.ts",headers:[],bodyData:nil,bodySize:0)
        let statuses: [Int?] = [200,206,200,200,200,304,206,200,200,200,200,200,404,206,200,200,200,503,200,nil]
        let records = (0..<1200).map { i in
            let status = statuses[(i * 7 + 3) % statuses.count]
            return SessionRecord(id:UUID(uuidString:String(format:"91000000-0000-4000-8000-%012d",i))!,
                request:request,response:status.map { CapturedResponse(statusCode:$0,headers:[],bodyData:nil,bodySize:0) },
                state:status == nil ? .pending : .completed,timing:SessionTiming(startedAt:Date(timeIntervalSince1970:Double(i))))
        }
        return records
    }
    func testScaleWindowHistogram() async throws {
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        let stack = try await makeStack()
        _ = try stack.grantStore.addGrant(clientID: stack.enrollment.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        stack.sessionStore.load(sessions:scaleHistogramRecords())
        let catalog = try await callRPC(stack:stack,method:"tools/list",params:[:])
        let defs = try XCTUnwrap(catalog.result?["tools"] as? [[String:Any]])
        var windows:[[String:Any]]=[]
        for (offset,n) in [(0,1),(10,20),(100,100),(200,400),(0,1200),(671,400)] {
            let fmt=ISO8601DateFormatter()
            let filter=["method":"GET","path":"/vod/","startedAfter":fmt.string(from:Date(timeIntervalSince1970:Double(offset))),"startedBefore":fmt.string(from:Date(timeIntervalSince1970:Double(offset+n-1)))]
            var calls:[[String:Any]]=[]
            func invoke(_ name:String,_ args:[String:Any]) async throws -> [String:Any] {
                let response=try await callSessionSummary(stack:stack,toolName:name,toolArguments:args)
                let payload=try summaryPayload(from:response)
                calls.append(["tool":name,"arguments":args,"answer":payload])
                return payload
            }
            var observed:[String:Int]=[:]
            if version=="1.9.0" {
                var args:[String:Any]=filter
                args["limit"]=100;args["projection"]="minimal"
                repeat {
                    let page=try await invoke("sessions_search",args)
                    for row in try XCTUnwrap(page["items"] as? [[String:Any]]) {
                        observed[(row["statusCode"] as? Int).map(String.init) ?? "missing",default:0]+=1
                    }
                    args["cursor"]=page["nextCursor"] as? String
                } while args["cursor"] != nil && calls.count < 30
            } else {
                let payload=try await invoke("capture_calculate",["dataset":"sessionMetadata","selectionPointer":"","filter":filter,"operation":["kind":"groupCount","fieldPointer":"/statusCode"]])
                let groups=try XCTUnwrap((payload["result"] as? [String:Any])?["groups"] as? [[String:Any]])
                for group in groups { let k=try XCTUnwrap(group["key"] as? [String:String]); observed[k["value"] ?? "missing"]=try XCTUnwrap(group["count"] as? Int) }
            }
            let oracle = n==1 ? ["200":1] : ["200":13*n/20,"206":3*n/20,"304":n/20,"404":n/20,"503":n/20,"missing":n/20]
            XCTAssertEqual(observed,oracle)
            windows.append(["offset":offset,"rows":n,"calls":calls,"oracle":oracle])
        }
        let packet:[String:Any]=["version":version,"discovery":defs,"windows":windows]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys,.withoutEscapingSlashes]),uniformTypeIdentifier:"public.json")
        attachment.name="scale-histogram";attachment.lifetime = .keepAlways;add(attachment)
    }
}
