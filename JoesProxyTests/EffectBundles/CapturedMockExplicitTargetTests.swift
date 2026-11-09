import XCTest
@testable import JoesProxy

final class CapturedMockExplicitTargetTests: XCTestCase {
    private let source = CapturedRequest(method: "GET", scheme: .https, host: "api.example.test",
        port: 8443, path: "/items/old", headers: [], bodyData: nil, bodySize: nil)

    private func scope(_ path: Any, observed: Bool = false, ignored: Bool = false) throws -> CapturedMockScope {
        try CapturedMockExplicitTarget.scope(path: path, source: source, clientAddress: "192.0.2.1",
            field: "relatedResponses[0].targetPath", hasObservedTarget: observed, hasIgnoredQueryNames: ignored)
    }

    func testExplicitPathRetainsOriginClientAndExactQuery() throws {
        let result = try scope("/items/test-456?language=de")
        XCTAssertEqual(result.host, source.host)
        XCTAssertEqual(result.port, 8443)
        XCTAssertEqual(result.scheme, .https)
        XCTAssertEqual(result.path, "/items/test-456?language=de")
        XCTAssertEqual(result.clients, .address("192.0.2.1"))
    }

    func testMalformedPathsHaveIndexedRedactedRecovery() {
        for invalid: Any in [17, NSNull(), "", "//secret.example.test/x", "https://secret.example.test/x",
                             "/secret path", "/x#secret", "/x\nsecret", "/x\\secret", "/" + String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try scope(invalid)) { error in
                let failure = error as? CapturedMockPreparationFailure
                XCTAssertEqual(failure?.reason, "invalidTargetPath")
                XCTAssertEqual(failure?.field, "relatedResponses[0].targetPath")
                XCTAssertFalse(failure?.message.contains("secret") ?? true)
            }
        }
    }

    func testAmbiguousOrBroadenedTargetsAreRejected() {
        XCTAssertThrowsError(try scope("/new", observed: true))
        XCTAssertThrowsError(try scope("/new", ignored: true))
    }
}
