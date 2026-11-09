import XCTest
@testable import JoesProxy

/// HAR 1.2 shape and interop guarantees for ``HARSessionExportService``.
final class HARExportServiceTests: XCTestCase {
    func testHARRootIsVersion12WithJoesProxyCreator() throws {
        let envelope = makeEnvelope(sessions: [makeGETSession()])
        let root = try decodeHARRoot(from: HARSessionExportService().harData(envelope))
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        let creator = try XCTUnwrap(log["creator"] as? [String: Any])
        XCTAssertEqual(creator["name"] as? String, "JoesProxy")
        XCTAssertEqual(creator["version"] as? String, envelope.appVersion)
    }

    func testGETAndPOSTEntriesIncludeHeadersBodiesAndStatus() throws {
        let get = makeGETSession(
            path: "/status?x=1",
            requestHeaders: [HTTPHeaderField(name: "Host", value: "example.com")],
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "text/plain")],
            responseBody: Data("OK".utf8)
        )
        let postBody = Data(#"{"q":true}"#.utf8)
        let post = makePOSTSession(
            path: "/submit",
            requestHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            requestBody: postBody,
            responseStatus: 201,
            responseBody: Data("created".utf8)
        )
        let root = try decodeHARRoot(from: HARSessionExportService().harData(makeEnvelope(sessions: [get, post])))
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)

        let getEntry = try XCTUnwrap(entries.first)
        let getRequest = try XCTUnwrap(getEntry["request"] as? [String: Any])
        XCTAssertEqual(getRequest["method"] as? String, "GET")
        XCTAssertEqual(getRequest["url"] as? String, "https://example.com/status?x=1")
        let getHeaders = try XCTUnwrap(getRequest["headers"] as? [[String: Any]])
        XCTAssertTrue(getHeaders.contains { ($0["name"] as? String) == "Host" })
        let getResponse = try XCTUnwrap(getEntry["response"] as? [String: Any])
        XCTAssertEqual(getResponse["status"] as? Int, 200)
        let getContent = try XCTUnwrap(getResponse["content"] as? [String: Any])
        XCTAssertEqual(getContent["text"] as? String, "OK")

        let postEntry = try XCTUnwrap(entries.last)
        let postRequest = try XCTUnwrap(postEntry["request"] as? [String: Any])
        XCTAssertEqual(postRequest["method"] as? String, "POST")
        let postData = try XCTUnwrap(postRequest["postData"] as? [String: Any])
        XCTAssertEqual(postData["text"] as? String, #"{"q":true}"#)
        let postResponse = try XCTUnwrap(postEntry["response"] as? [String: Any])
        XCTAssertEqual(postResponse["status"] as? Int, 201)
    }

    func testBinaryResponseBodyUsesBase64Encoding() throws {
        let binary = Data([0x00, 0xFF, 0x10, 0x80])
        let session = makeGETSession(
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/octet-stream")],
            responseBody: binary
        )
        let root = try decodeHARRoot(from: HARSessionExportService().harData(makeEnvelope(sessions: [session])))
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        let content = try XCTUnwrap(
            (entries.first?["response"] as? [String: Any])?["content"] as? [String: Any]
        )
        XCTAssertEqual(content["encoding"] as? String, "base64")
        let text = try XCTUnwrap(content["text"] as? String)
        XCTAssertEqual(Data(base64Encoded: text), binary)
    }

    func testMarkerSessionsAreExcludedFromEntries() throws {
        let normal = makeGETSession(path: "/ok")
        let marker = SessionRecord(
            request: CapturedRequest(
                method: CaptureMarkerConstants.method,
                scheme: .https,
                host: CaptureMarkerConstants.host,
                port: 443,
                path: CaptureMarkerConstants.markerPath(name: "checkpoint"),
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.1))
        )
        let root = try decodeHARRoot(from: HARSessionExportService().harData(makeEnvelope(sessions: [marker, normal])))
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let url = try XCTUnwrap((entries.first?["request"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.contains("/ok"))
    }

    func testEntriesAreSortedByStartedDateTimeAscending() throws {
        let later = makeGETSession(path: "/later", startedAt: Date(timeIntervalSince1970: 2_000))
        let earlier = makeGETSession(path: "/earlier", startedAt: Date(timeIntervalSince1970: 1_000))
        let root = try decodeHARRoot(from: HARSessionExportService().harData(makeEnvelope(sessions: [later, earlier])))
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        let paths = entries.compactMap { entry -> String? in
            (entry["request"] as? [String: Any])?["url"] as? String
        }
        XCTAssertEqual(paths.first, "https://example.com/earlier")
        XCTAssertEqual(paths.last, "https://example.com/later")
    }

    func testExportToFileRoundTripsValidJSON() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("har-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: destination) }
        try HARSessionExportService().export(makeEnvelope(sessions: [makeGETSession()]), to: destination)
        let data = try Data(contentsOf: destination)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertNotNil(log["entries"] as? [[String: Any]])
    }

    // MARK: - Helpers

    private func makeEnvelope(sessions: [SessionRecord]) -> SessionExportEnvelope {
        SessionExportEnvelope(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "test",
            proxyPort: 9890,
            sessionCount: sessions.count,
            sessions: sessions
        )
    }

    private func makeGETSession(
        path: String = "/status",
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        requestHeaders: [HTTPHeaderField] = [],
        responseHeaders: [HTTPHeaderField] = [],
        responseBody: Data? = Data("OK".utf8)
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "example.com",
                port: 443,
                path: path,
                headers: requestHeaders,
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: responseHeaders,
                bodyData: responseBody,
                bodySize: responseBody?.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.05))
        )
    }

    private func makePOSTSession(
        path: String,
        requestHeaders: [HTTPHeaderField],
        requestBody: Data,
        responseStatus: Int,
        responseBody: Data
    ) -> SessionRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_200)
        return SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "example.com",
                port: 443,
                path: path,
                headers: requestHeaders,
                bodyData: requestBody,
                bodySize: requestBody.count
            ),
            response: CapturedResponse(
                statusCode: responseStatus,
                headers: [HTTPHeaderField(name: "Content-Type", value: "text/plain")],
                bodyData: responseBody,
                bodySize: responseBody.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.1))
        )
    }

    private func decodeHARRoot(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
