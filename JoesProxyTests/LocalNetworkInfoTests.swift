import XCTest
@testable import JoesProxy

final class LocalNetworkInfoTests: XCTestCase {
    func testPreferredIPv4AddressPrefersPrivateWiFiAddressOverLinkLocal() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(from: [
            LocalNetworkIPv4Candidate(interfaceName: "en0", address: "169.254.12.3", isRunning: true),
            LocalNetworkIPv4Candidate(interfaceName: "en0", address: "192.168.1.44", isRunning: true)
        ])

        XCTAssertEqual(preferred, "192.168.1.44")
    }

    func testPreferredIPv4AddressPrefersRunningWiFiOverBridgeAddress() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(from: [
            LocalNetworkIPv4Candidate(interfaceName: "bridge100", address: "169.254.9.20", isRunning: true),
            LocalNetworkIPv4Candidate(interfaceName: "en0", address: "192.168.4.20", isRunning: true)
        ])

        XCTAssertEqual(preferred, "192.168.4.20")
    }

    func testPreferredIPv4AddressSupportsPrivateLANRanges() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(from: [
            LocalNetworkIPv4Candidate(interfaceName: "en0", address: "203.0.113.10", isRunning: true),
            LocalNetworkIPv4Candidate(interfaceName: "en1", address: "10.0.0.12", isRunning: true),
            LocalNetworkIPv4Candidate(interfaceName: "en2", address: "172.16.2.12", isRunning: true)
        ])

        XCTAssertEqual(preferred, "10.0.0.12")
    }

    func testPreferredIPv4AddressPrefersPrimaryPrivateInterfaceWhenWifiAndEthernetAreConnected() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(
            from: [
                LocalNetworkIPv4Candidate(interfaceName: "en0", address: "192.168.1.44", isRunning: true),
                LocalNetworkIPv4Candidate(interfaceName: "en5", address: "10.0.0.22", isRunning: true)
            ],
            primaryInterfaceName: "en5"
        )

        XCTAssertEqual(preferred, "10.0.0.22")
    }

    func testPreferredIPv4AddressDoesNotPreferPrimaryInterfaceWhenItIsLinkLocal() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(
            from: [
                LocalNetworkIPv4Candidate(interfaceName: "en0", address: "192.168.1.44", isRunning: true),
                LocalNetworkIPv4Candidate(interfaceName: "en5", address: "169.254.0.22", isRunning: true)
            ],
            primaryInterfaceName: "en5"
        )

        XCTAssertEqual(preferred, "192.168.1.44")
    }

    func testPreferredIPv4AddressFallsBackToLinkLocalWhenNoUsableLanAddressExists() {
        let preferred = LocalNetworkInfo.preferredIPv4Address(from: [
            LocalNetworkIPv4Candidate(interfaceName: "bridge100", address: "169.254.9.20", isRunning: true)
        ])

        XCTAssertEqual(preferred, "169.254.9.20")
    }
}
