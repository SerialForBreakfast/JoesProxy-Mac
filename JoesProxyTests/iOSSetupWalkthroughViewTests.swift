import XCTest
@testable import JoesProxy

/// Covers the `x-safari-` URL scheme transform used to force the profile-install QR code to open
/// specifically in Safari, regardless of the device's default browser — `.mobileconfig` profile
/// installation only triggers from Safari, so a scan landing in Chrome/Firefox/Edge previously just
/// downloaded an inert file instead of prompting install.
final class iOSSetupWalkthroughViewTests: XCTestCase {
    func testSafariForcedURLStringPrefixesHTTPURL() {
        let url = URL(string: "http://192.168.1.5:8765/profile")!
        XCTAssertEqual(
            iOSSetupWalkthroughView.safariForcedURLString(for: url),
            "x-safari-http://192.168.1.5:8765/profile"
        )
    }

    func testSafariForcedURLStringPrefixesHTTPSURL() {
        let url = URL(string: "https://joesproxy.local/profile.mobileconfig")!
        XCTAssertEqual(
            iOSSetupWalkthroughView.safariForcedURLString(for: url),
            "x-safari-https://joesproxy.local/profile.mobileconfig"
        )
    }

    func testSafariForcedURLStringPreservesQueryAndPath() {
        let url = URL(string: "http://192.168.1.5:8765/profile?token=abc123")!
        XCTAssertEqual(
            iOSSetupWalkthroughView.safariForcedURLString(for: url),
            "x-safari-http://192.168.1.5:8765/profile?token=abc123"
        )
    }
}
