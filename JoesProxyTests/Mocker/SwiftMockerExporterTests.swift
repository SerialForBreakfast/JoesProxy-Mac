import XCTest
@testable import JoesProxy

final class SwiftMockerExporterTests: XCTestCase {

    private func makeSampleSession(
        path: String = "/api/v1/user/123",
        method: String = "GET",
        statusCode: Int = 200,
        jsonBody: String = "{\"id\": 123, \"name\": \"Alice\"}"
    ) -> SessionRecord {
        let request = CapturedRequest(
            method: method,
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )
        let bodyData = jsonBody.data(using: .utf8)
        let response = CapturedResponse(
            statusCode: statusCode,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: bodyData,
            bodySize: bodyData?.count
        )
        return SessionRecord(
            request: request,
            response: response,
            timing: SessionTiming(startedAt: Date())
        )
    }

    func testGenerateMockerSnippetForJSON() {
        let session = makeSampleSession()
        let snippet = SwiftMockerExporter.generateSnippet(for: session, framework: .mocker)

        XCTAssertTrue(snippet.contains("let mockURL = URL(string: \"https://api.example.com/api/v1/user/123\")!"))
        XCTAssertTrue(snippet.contains("var mock = Mock(url: mockURL, dataType: .json, statusCode: 200, data: [.get: mockData])"))
        XCTAssertTrue(snippet.contains("mock.register()"))
        XCTAssertTrue(snippet.contains("\"Content-Type\": \"application/json\""))
    }

    func testGenerateURLProtocolSnippet() {
        let session = makeSampleSession(method: "POST", statusCode: 201)
        let snippet = SwiftMockerExporter.generateSnippet(for: session, framework: .vanillaURLProtocol)

        XCTAssertTrue(snippet.contains("TestURLProtocolStub.registerMock("))
        XCTAssertTrue(snippet.contains("statusCode: 201"))
        XCTAssertTrue(snippet.contains("url: mockURL"))
    }

    func testGenerateMultiStepMockerSuiteInline() {
        let session1 = makeSampleSession(path: "/api/v1/auth/token", method: "POST", jsonBody: "{\"token\": \"abc\"}")
        let session2 = makeSampleSession(path: "/api/v1/profile", method: "GET", jsonBody: "{\"username\": \"alice\"}")

        let options = SwiftMockExportOptions(
            framework: .mocker,
            fixtureMode: .inlineString,
            testClassName: "UserAuthFlowTests",
            testMethodName: "testLoginAndFetchProfile"
        )

        let suite = SwiftMockerExporter.generateSuite(for: [session1, session2], options: options)

        XCTAssertEqual(suite.sessionCount, 2)
        XCTAssertEqual(suite.framework, .mocker)
        XCTAssertTrue(suite.swiftSourceCode.contains("final class UserAuthFlowTests: XCTestCase"))
        XCTAssertTrue(suite.swiftSourceCode.contains("func testLoginAndFetchProfile() throws"))
        XCTAssertTrue(suite.swiftSourceCode.contains("mock1.register()"))
        XCTAssertTrue(suite.swiftSourceCode.contains("mock2.register()"))
        XCTAssertTrue(suite.fixtureFiles.isEmpty)
    }

    func testGenerateMockerSuiteWithBundledFixtures() {
        let session1 = makeSampleSession(path: "/api/v1/catalog", method: "GET", jsonBody: "{\"items\": [1, 2, 3]}")
        let options = SwiftMockExportOptions(
            framework: .mocker,
            fixtureMode: .bundledJSONFile,
            testClassName: "CatalogTests",
            testMethodName: "testCatalogLoad"
        )

        let suite = SwiftMockerExporter.generateSuite(for: [session1], options: options)

        XCTAssertEqual(suite.fixtureFiles.count, 1)
        XCTAssertEqual(suite.fixtureFiles[0].mimeType, "application/json")
        XCTAssertTrue(suite.swiftSourceCode.contains("Bundle.module.url(forResource:"))
        XCTAssertTrue(suite.swiftSourceCode.contains("mock1.register()"))
    }
}
