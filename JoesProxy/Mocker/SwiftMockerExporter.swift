import Foundation

/// Pure Swift generator that converts captured `SessionRecord` instances into ready-to-run Swift test code
/// supporting WeTransfer/Mocker and vanilla Foundation URLProtocol mocks.
struct SwiftMockerExporter: Sendable {

    /// Generates a single standalone Swift snippet for registering a mock from a session.
    static func generateSnippet(for session: SessionRecord, framework: SwiftMockFramework = .mocker) -> String {
        switch framework {
        case .mocker:
            return generateMockerSnippet(for: session, variablePrefix: "mock")
        case .vanillaURLProtocol:
            return generateURLProtocolSnippet(for: session, variablePrefix: "mock")
        }
    }

    /// Generates a complete `XCTestCase` test suite and companion fixture files for a series of captured sessions.
    static func generateSuite(
        for sessions: [SessionRecord],
        options: SwiftMockExportOptions = SwiftMockExportOptions()
    ) -> SwiftMockGeneratedSuite {
        var fixtureFiles: [SwiftMockFixtureFile] = []
        var testBodyLines: [String] = []

        for (index, session) in sessions.enumerated() {
            let varName = "mock\(index + 1)"
            let comment = "// Step \(index + 1): \(session.request.method) \(session.request.path)"
            testBodyLines.append("        \(comment)")

            if options.fixtureMode == .bundledJSONFile, let body = session.response?.bodyData, !body.isEmpty {
                let sanitizedPath = sanitizeFilename(session.request.path, index: index + 1)
                let fixtureFilename = "\(sanitizedPath).json"
                let fixtureFile = SwiftMockFixtureFile(
                    filename: fixtureFilename,
                    relativePath: "Fixtures/\(fixtureFilename)",
                    data: body,
                    mimeType: contentType(from: session.response) ?? "application/json"
                )
                fixtureFiles.append(fixtureFile)

                switch options.framework {
                case .mocker:
                    testBodyLines.append(generateMockerBundleSnippet(
                        for: session,
                        varName: varName,
                        fixtureFilename: fixtureFilename,
                        options: options
                    ))
                case .vanillaURLProtocol:
                    testBodyLines.append(generateURLProtocolBundleSnippet(
                        for: session,
                        varName: varName,
                        fixtureFilename: fixtureFilename,
                        options: options
                    ))
                }
            } else {
                switch options.framework {
                case .mocker:
                    testBodyLines.append(generateMockerInlineSnippet(
                        for: session,
                        varName: varName,
                        options: options
                    ))
                case .vanillaURLProtocol:
                    testBodyLines.append(generateURLProtocolInlineSnippet(
                        for: session,
                        varName: varName,
                        options: options
                    ))
                }
            }

            if index < sessions.count - 1 {
                testBodyLines.append("")
            }
        }

        let fullSource: String
        switch options.framework {
        case .mocker:
            fullSource = generateMockerClassSource(
                className: options.testClassName,
                methodName: options.testMethodName,
                bodyLines: testBodyLines
            )
        case .vanillaURLProtocol:
            fullSource = generateURLProtocolClassSource(
                className: options.testClassName,
                methodName: options.testMethodName,
                bodyLines: testBodyLines
            )
        }

        return SwiftMockGeneratedSuite(
            swiftSourceCode: fullSource,
            fixtureFiles: fixtureFiles,
            sessionCount: sessions.count,
            framework: options.framework
        )
    }

    // MARK: - Mocker Snippet Generators

    private static func generateMockerSnippet(for session: SessionRecord, variablePrefix: String) -> String {
        var lines: [String] = []
        let urlString = requestURLString(for: session.request)
        let statusCode = session.response?.statusCode ?? 200
        let httpMethod = session.request.method.lowercased()
        let dataTypeEnum = mockerDataType(for: contentType(from: session.response))

        lines.append("let \(variablePrefix)URL = URL(string: \"\(urlString)\")!")

        if let body = session.response?.bodyData, !body.isEmpty {
            if let jsonString = String(data: body, encoding: .utf8), isValidJSON(body) {
                let formattedJSON = prettyPrintJSON(jsonString)
                lines.append("let \(variablePrefix)Data = \"\"\"")
                lines.append(formattedJSON)
                lines.append("\"\"\".data(using: .utf8)!")
            } else {
                let base64 = body.base64EncodedString()
                lines.append("let \(variablePrefix)Data = Data(base64Encoded: \"\(base64)\")!")
            }
            lines.append("var \(variablePrefix) = Mock(url: \(variablePrefix)URL, dataType: \(dataTypeEnum), statusCode: \(statusCode), data: [.\(httpMethod): \(variablePrefix)Data])")
        } else {
            lines.append("var \(variablePrefix) = Mock(url: \(variablePrefix)URL, dataType: \(dataTypeEnum), statusCode: \(statusCode), data: [.\(httpMethod): Data()])")
        }

        if let headers = session.response?.headers, !headers.isEmpty {
            let headerDict = formatHeadersDictionary(headers)
            lines.append("\(variablePrefix).headers = \(headerDict)")
        }

        lines.append("\(variablePrefix).register()")
        return lines.joined(separator: "\n")
    }

    private static func generateMockerInlineSnippet(
        for session: SessionRecord,
        varName: String,
        options: SwiftMockExportOptions
    ) -> String {
        let snippet = generateMockerSnippet(for: session, variablePrefix: varName)
        let indented = snippet.split(separator: "\n").map { "        \($0)" }.joined(separator: "\n")
        return indented
    }

    private static func generateMockerBundleSnippet(
        for session: SessionRecord,
        varName: String,
        fixtureFilename: String,
        options: SwiftMockExportOptions
    ) -> String {
        var lines: [String] = []
        let urlString = requestURLString(for: session.request)
        let statusCode = session.response?.statusCode ?? 200
        let httpMethod = session.request.method.lowercased()
        let dataTypeEnum = mockerDataType(for: contentType(from: session.response))

        lines.append("        let \(varName)URL = URL(string: \"\(urlString)\")!")
        lines.append("        guard let \(varName)FixtureURL = Bundle.module.url(forResource: \"\(fixtureFilename)\", withExtension: nil) else {")
        lines.append("            XCTFail(\"Missing test fixture: \(fixtureFilename)\")")
        lines.append("            return")
        lines.append("        }")
        lines.append("        let \(varName)Data = try Data(contentsOf: \(varName)FixtureURL)")
        lines.append("        var \(varName) = Mock(url: \(varName)URL, dataType: \(dataTypeEnum), statusCode: \(statusCode), data: [.\(httpMethod): \(varName)Data])")

        if options.includeHeaders, let headers = session.response?.headers, !headers.isEmpty {
            let headerDict = formatHeadersDictionary(headers)
            lines.append("        \(varName).headers = \(headerDict)")
        }

        lines.append("        \(varName).register()")
        return lines.joined(separator: "\n")
    }

    private static func generateMockerClassSource(
        className: String,
        methodName: String,
        bodyLines: [String]
    ) -> String {
        return """
        import XCTest
        import Mocker

        final class \(className): XCTestCase {

            override func setUp() {
                super.setUp()
                Mocker.removeAll()
            }

            override func tearDown() {
                Mocker.removeAll()
                super.tearDown()
            }

            func \(methodName)() throws {
        \(bodyLines.joined(separator: "\n"))
            }
        }
        """
    }

    // MARK: - Vanilla URLProtocol Snippet Generators

    private static func generateURLProtocolSnippet(for session: SessionRecord, variablePrefix: String) -> String {
        var lines: [String] = []
        let urlString = requestURLString(for: session.request)
        let statusCode = session.response?.statusCode ?? 200

        lines.append("let \(variablePrefix)URL = URL(string: \"\(urlString)\")!")
        if let body = session.response?.bodyData, !body.isEmpty {
            if let jsonString = String(data: body, encoding: .utf8), isValidJSON(body) {
                let formattedJSON = prettyPrintJSON(jsonString)
                lines.append("let \(variablePrefix)Data = \"\"\"")
                lines.append(formattedJSON)
                lines.append("\"\"\".data(using: .utf8)!")
            } else {
                let base64 = body.base64EncodedString()
                lines.append("let \(variablePrefix)Data = Data(base64Encoded: \"\(base64)\")!")
            }
        } else {
            lines.append("let \(variablePrefix)Data = Data()")
        }

        lines.append("TestURLProtocolStub.registerMock(")
        lines.append("    url: \(variablePrefix)URL,")
        lines.append("    statusCode: \(statusCode),")
        lines.append("    data: \(variablePrefix)Data")
        lines.append(")")
        return lines.joined(separator: "\n")
    }

    private static func generateURLProtocolInlineSnippet(
        for session: SessionRecord,
        varName: String,
        options: SwiftMockExportOptions
    ) -> String {
        let snippet = generateURLProtocolSnippet(for: session, variablePrefix: varName)
        let indented = snippet.split(separator: "\n").map { "        \($0)" }.joined(separator: "\n")
        return indented
    }

    private static func generateURLProtocolBundleSnippet(
        for session: SessionRecord,
        varName: String,
        fixtureFilename: String,
        options: SwiftMockExportOptions
    ) -> String {
        var lines: [String] = []
        let urlString = requestURLString(for: session.request)
        let statusCode = session.response?.statusCode ?? 200

        lines.append("        let \(varName)URL = URL(string: \"\(urlString)\")!")
        lines.append("        guard let \(varName)FixtureURL = Bundle.module.url(forResource: \"\(fixtureFilename)\", withExtension: nil) else {")
        lines.append("            XCTFail(\"Missing test fixture: \(fixtureFilename)\")")
        lines.append("            return")
        lines.append("        }")
        lines.append("        let \(varName)Data = try Data(contentsOf: \(varName)FixtureURL)")
        lines.append("        TestURLProtocolStub.registerMock(url: \(varName)URL, statusCode: \(statusCode), data: \(varName)Data)")
        return lines.joined(separator: "\n")
    }

    private static func generateURLProtocolClassSource(
        className: String,
        methodName: String,
        bodyLines: [String]
    ) -> String {
        return """
        import XCTest

        final class \(className): XCTestCase {

            private var session: URLSession!

            override func setUp() {
                super.setUp()
                TestURLProtocolStub.reset()
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [TestURLProtocolStub.self]
                session = URLSession(configuration: config)
            }

            override func tearDown() {
                TestURLProtocolStub.reset()
                session = nil
                super.tearDown()
            }

            func \(methodName)() throws {
        \(bodyLines.joined(separator: "\n"))
            }
        }

        /// Lightweight URLProtocol stub handler for testing without external packages.
        final class TestURLProtocolStub: URLProtocol, @unchecked Sendable {
            private static let lock = NSLock()
            private static var stubs: [URL: (statusCode: Int, data: Data, headers: [String: String]?)] = [:]

            static func registerMock(url: URL, statusCode: Int = 200, data: Data, headers: [String: String]? = nil) {
                lock.lock()
                defer { lock.unlock() }
                stubs[url] = (statusCode, data, headers)
            }

            static func reset() {
                lock.lock()
                defer { lock.unlock() }
                stubs.removeAll()
            }

            override class func canInit(with request: URLRequest) -> Bool {
                guard let url = request.url else { return false }
                lock.lock()
                defer { lock.unlock() }
                return stubs[url] != nil
            }

            override class func canonicalRequest(for request: URLRequest) -> URLRequest {
                request
            }

            override func startLoading() {
                guard let url = request.url else { return }
                Self.lock.lock()
                guard let stub = Self.stubs[url] else {
                    Self.lock.unlock()
                    client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                    return
                }
                Self.lock.unlock()

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers ?? ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stub.data)
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }
        """
    }

    // MARK: - Helpers

    private static func requestURLString(for request: CapturedRequest) -> String {
        let portPart: String
        if let port = request.port, port != (request.scheme == .https ? 443 : 80) {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        let normalizedPath = request.path.hasPrefix("/") ? request.path : "/\(request.path)"
        return "\(request.scheme.rawValue)://\(request.host)\(portPart)\(normalizedPath)"
    }

    private static func contentType(from response: CapturedResponse?) -> String? {
        response?.headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value
    }

    private static func mockerDataType(for mimeType: String?) -> String {
        guard let mimeType = mimeType?.lowercased() else { return ".json" }
        if mimeType.contains("json") {
            return ".json"
        } else if mimeType.contains("html") {
            return ".html"
        } else if mimeType.contains("png") {
            return ".imagePNG"
        } else if mimeType.contains("jpeg") || mimeType.contains("jpg") {
            return ".imageJPEG"
        } else if mimeType.contains("pdf") {
            return ".pdf"
        } else if mimeType.contains("text") {
            return ".custom(type: \"text/plain\")"
        } else {
            return ".custom(type: \"\(mimeType)\")"
        }
    }

    private static func formatHeadersDictionary(_ headers: [HTTPHeaderField]) -> String {
        let pairs = headers.map { "            \"\($0.name)\": \"\($0.value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        if pairs.isEmpty { return "[:]" }
        return "[\n" + pairs.joined(separator: ",\n") + "\n        ]"
    }

    private static func isValidJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func prettyPrintJSON(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return jsonString
        }
        return prettyString
    }

    private static func sanitizeFilename(_ path: String, index: Int) -> String {
        let cleaned = path
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        if cleaned.isEmpty {
            return "fixture_\(index)"
        }
        return String(cleaned.prefix(40))
    }
}
