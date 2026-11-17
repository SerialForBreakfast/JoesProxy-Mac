import XCTest
import SwiftUI
#if !STANDALONE_SETUP_PROBE
@testable import JoesProxy
#endif

final class SetupTrafficProbeTests: XCTestCase {
    @MainActor
    func testNativeFooterFitsSmallSheetOnAllFivePages() {
        for (page, title) in ["Proxy", "Verify Capture", "Finish setup", "MCP/CLI", "Finish setup"].enumerated() {
            let footer = SetupNavigationFooter(nextTitle: title, finishes: title == "Finish setup",
                                              back: page == 0 ? nil : {}, close: {}, next: {})
            let size = NSHostingView(rootView: footer.fixedSize()).fittingSize
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.width, 360 - 32, title)
            XCTAssertLessThan(size.height, 60, title)
        }
    }
    func testOnlyTheFreshInspectedGETWithMatchingResponsePasses() {
        let probe = SetupTrafficProbe(kind: .https, nonce: UUID())
        func accepts(_ path: String, host: String = "example.org", inspection: String = "interceptedTLS",
                     status: Int? = 200, method: String = "GET") -> Bool {
            probe.matches(method: method, host: host, scheme: "https", path: path, inspection: inspection,
                          status: status, clientStatus: 200)
        }
        XCTAssertTrue(accepts(probe.path))
        XCTAssertTrue(accepts(probe.url))
        XCTAssertFalse(accepts(SetupTrafficProbe(kind: .https, nonce: UUID()).path))
        XCTAssertFalse(accepts(probe.path, host: "unrelated.example"))
        XCTAssertFalse(accepts(probe.path, inspection: "tunneledTLS"))
        XCTAssertFalse(accepts(probe.path, inspection: "plain"))
        XCTAssertFalse(accepts(probe.path, status: nil))
        XCTAssertFalse(accepts(probe.path, status: 502))
        XCTAssertFalse(accepts(probe.path, method: "CONNECT"))
    }

    func testHTTPAndHTTPSCannotCreditOneAnother() {
        let http = SetupTrafficProbe(kind: .http, nonce: UUID())
        let https = SetupTrafficProbe(kind: .https, nonce: http.nonce)
        XCTAssertTrue(http.matches(method: "GET", host: "example.org", scheme: "http", path: http.path,
                                   inspection: "plain", status: 200, clientStatus: 200))
        XCTAssertFalse(http.matches(method: "GET", host: "example.org", scheme: "https", path: https.path,
                                    inspection: "interceptedTLS", status: 200, clientStatus: 200))
        XCTAssertFalse(http.matches(method: "GET", host: "example.org", scheme: "http", path: http.path,
                                    inspection: "plain", status: 404, clientStatus: 404))
    }
}

#if STANDALONE_SETUP_PROBE
@main enum ProbeTestRunner {
    static func main() async throws {
        let suite = XCTestSuite(forTestCaseClass: SetupTrafficProbeTests.self)
        suite.run()
        guard let run = suite.testRun, run.executionCount == 3, run.hasSucceeded else { exit(1) }
        if let argument = CommandLine.arguments.dropFirst().first, let port = UInt16(argument) {
            let nonce = UUID()
            for kind in SetupTrafficProbe.Kind.allCases {
                let probe = SetupTrafficProbe(kind: kind, nonce: nonce)
                let status = try await probe.send(port: port)
                print("\(probe.url): \(status)")
                guard (200..<300).contains(status) else { exit(1) }
            }
        }
    }
}
#endif
