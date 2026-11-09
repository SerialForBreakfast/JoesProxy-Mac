import XCTest
@testable import JoesProxy

final class ProxyChannelErrorClassifierTests: XCTestCase {
    func testExpectedDisconnectErrorsAreClassifiedAsExpected() {
        let descriptions = [
            "NIOSSL.NIOSSLError error 0",
            "NIOSSL.NIOSSLError error 12",
            "NIOCore.IOError error 1",
            "Connection reset by peer",
            "Broken pipe",
            "Operation canceled"
        ]

        for description in descriptions {
            XCTAssertEqual(
                ProxyChannelErrorClassifier.classify(description: description),
                .expectedDisconnect,
                "Expected \(description) to be downgraded for long-capture logs"
            )
        }
    }

    func testUnexpectedErrorsRemainFailures() {
        XCTAssertEqual(
            ProxyChannelErrorClassifier.classify(description: "TLS handshake failed because certificate identity is unavailable"),
            .unexpectedFailure
        )
    }
}
