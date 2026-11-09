import Foundation
import XCTest
@testable import JoesProxy

/// Focused coverage for AS — Local Directory Mapping static serve (`LocalDirectoryServer`).
final class LocalDirectoryServerTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDirectoryServerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data("index-body".utf8).write(to: rootDirectory.appendingPathComponent("index.html"))
        try Data("{\"ok\":true}".utf8).write(to: rootDirectory.appendingPathComponent("api.json"))
        try Data("missing-page".utf8).write(to: rootDirectory.appendingPathComponent("404.html"))
        let nested = rootDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("png-bytes".utf8).write(to: nested.appendingPathComponent("logo.png"))
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        rootDirectory = nil
        try super.tearDownWithError()
    }

    func testServesRegularFileWithInferredContentType() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/api.json", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "{\"ok\":true}")
    }

    func testEmptyPathServesIndexHTMLWhenPresent() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "index-body")
        XCTAssertTrue(response.headers["Content-Type"]?.contains("html") == true)
    }

    func testTrailingSlashUnderNestedFolderResolvesIndexWhenPresent() throws {
        let nested = rootDirectory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("docs-index".utf8).write(to: nested.appendingPathComponent("index.html"))
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/docs/", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "docs-index")
    }

    func testPathTraversalIsRejected() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/../\(rootDirectory.lastPathComponent)/api.json", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testDotDotSegmentIsRejected() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        XCTAssertFalse(server.isSafeRelativePath("../api.json"))
        XCTAssertFalse(server.isSafeRelativePath("assets/../../api.json"))
        let response = server.response(forPath: "/assets/../../api.json", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
    }

    func testNotFoundFallbackServesConfiguredFileAs404() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: "404.html")
        let response = server.response(forPath: "/missing.css", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "missing-page")
    }

    func testSingleByteRangeReturns206() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/api.json", method: "GET", rangeHeader: "bytes=1-4")
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "\"ok\"")
        XCTAssertEqual(response.headers["Content-Range"], "bytes 1-4/11")
    }

    func testHEADOmitsBodyButKeepsContentLength() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/api.json", method: "HEAD", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.headers["Content-Length"], "11")
    }

    func testUnsupportedMethodReturns405() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/api.json", method: "POST", rangeHeader: nil)
        XCTAssertEqual(response.status, 405)
    }

    func testOversizedFileIsNotServed() throws {
        let oversized = rootDirectory.appendingPathComponent("huge.bin")
        let payload = Data(repeating: 0x41, count: LocalDirectoryLimits.maxServedFileBytes + 1)
        try payload.write(to: oversized)
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/huge.bin", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
    }

    func testNestedAssetPathIsServed() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        let response = server.response(forPath: "/assets/logo.png", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "png-bytes")
        XCTAssertEqual(response.headers["Content-Type"], "image/png")
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): `hasLocalFile`
    /// is the pure "is this a miss" check `ConnectionHandler` calls before serving a response, so
    /// `.overlayFailOpen` can forward to the real upstream instead of ever building a 404.
    func testHasLocalFileMatchesResponseHitBranch() {
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: nil)
        XCTAssertTrue(server.hasLocalFile(forPath: "/api.json"))
        XCTAssertTrue(server.hasLocalFile(forPath: "/assets/logo.png"))
        XCTAssertTrue(server.hasLocalFile(forPath: "/"))
        XCTAssertFalse(server.hasLocalFile(forPath: "/missing.css"))
        XCTAssertFalse(server.hasLocalFile(forPath: "/../\(rootDirectory.lastPathComponent)/api.json"))
    }

    func testHasLocalFileIgnoresConfiguredNotFoundFallback() {
        // A miss is still a miss for `hasLocalFile` even when a `notFoundRelativePath` fallback file
        // exists — that fallback is `response(forPath:...)`'s own concern, not a real local hit.
        let server = LocalDirectoryServer(rootDirectory: rootDirectory, notFoundRelativePath: "404.html")
        XCTAssertFalse(server.hasLocalFile(forPath: "/missing.css"))
    }
}
