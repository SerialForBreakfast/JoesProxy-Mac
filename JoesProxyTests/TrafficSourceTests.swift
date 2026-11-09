import XCTest
@testable import JoesProxy

final class TrafficSourceTests: XCTestCase {
    func testLoopbackWithIOSUserAgentIsSimulator() {
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        XCTAssertEqual(TrafficSource.classify(clientAddress: "127.0.0.1", userAgent: ua), .simulator)
    }

    func testLoopbackWithIPadUserAgentIsSimulator() {
        let ua = "MyApp/1.0 (iPad; iOS 18.0)"
        XCTAssertEqual(TrafficSource.classify(clientAddress: "127.0.0.1", userAgent: ua), .simulator)
    }

    func testLoopbackWithMacUserAgentIsMac() {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        XCTAssertEqual(TrafficSource.classify(clientAddress: "127.0.0.1", userAgent: ua), .mac)
    }

    func testIPv6LoopbackWithMacUserAgentIsMac() {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        XCTAssertEqual(TrafficSource.classify(clientAddress: "::1", userAgent: ua), .mac)
    }

    func testLanAddressIsDeviceRegardlessOfUserAgent() {
        XCTAssertEqual(TrafficSource.classify(clientAddress: "192.168.1.42", userAgent: "iPhone"), .device)
        XCTAssertEqual(TrafficSource.classify(clientAddress: "10.0.0.5", userAgent: nil), .device)
    }

    func testLoopbackWithoutUserAgentIsUnknown() {
        // Tunneled HTTPS (CONNECT) has no visible User-Agent.
        XCTAssertEqual(TrafficSource.classify(clientAddress: "127.0.0.1", userAgent: nil), .unknown)
    }

    func testNilAddressIsUnknown() {
        XCTAssertEqual(TrafficSource.classify(clientAddress: nil, userAgent: "Macintosh"), .unknown)
    }

    func testLoopbackWithUnrecognizedUserAgentIsUnknown() {
        XCTAssertEqual(TrafficSource.classify(clientAddress: "127.0.0.1", userAgent: "curl/8.1.2"), .unknown)
    }
}
