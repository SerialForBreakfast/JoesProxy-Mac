import XCTest
@testable import JoesProxy

final class CapturedMockReviewAdvisoryTests: XCTestCase {
    private func image(_ url: String, id: String = "image-0", retained: Bool = true) -> CapturedMockImagePreview {
        .init(assetID: id, url: url, sha256: "synthetic-hash", contentType: "image/png",
            width: 1, height: 1, byteCount: 1, retainsOriginalURL: retained)
    }

    func testLocalImageDestinationsWarnWithoutChangingTheURL() {
        for host in ["localhost", "LOCALHOST.", "poster.localhost", "127.0.0.1", "127.0.0.2",
                     "127.1", "0.0.0.0", "[::1]", "[0:0:0:0:0:0:0:1]", "[::]", "[::ffff:127.0.0.1]"] {
            let asset = image("http://\(host)/poster.png")
            let advisories = CapturedMockReviewAdvisory.evaluate(images: [asset])
            XCTAssertEqual(advisories.first?.code, .nonPortableImageDestination, host)
            XCTAssertEqual(advisories.first?.assetIDs, ["image-0"])
            XCTAssertEqual(asset.url, "http://\(host)/poster.png")
        }
    }

    func testPortableAddressesNeverImplyRoutingOrRenderingSuccess() {
        for host in [SyntheticAssetOriginServer.defaultHost, "192.0.2.10", "cdn.example.test", "[2001:db8::1]"] {
            let advisories = CapturedMockReviewAdvisory.evaluate(images: [image("https://\(host)/poster.png", retained: false)])
            XCTAssertFalse(advisories.contains { $0.code == .nonPortableImageDestination })
            XCTAssertFalse(advisories.contains { $0.code == .retainedImageCacheRisk })
            XCTAssertTrue(advisories.contains { $0.code == .routingNotVerified })
            XCTAssertTrue(advisories.contains { $0.code == .visibleOutcomeNotVerified })
        }
    }

    func testWarningsCoalesceByReasonAndRetainAffectedAssets() {
        let advisories = CapturedMockReviewAdvisory.evaluate(images: [
            image("http://127.0.0.1/a.png", id: "a"), image("http://localhost/b.png", id: "b"),
            image("https://cdn.example.test/c.png", id: "c")
        ])
        XCTAssertEqual(Set(advisories.map(\.id)).count, advisories.count)
        XCTAssertEqual(advisories.first { $0.code == .nonPortableImageDestination }?.assetIDs, ["a", "b"])
        XCTAssertEqual(advisories.first { $0.code == .retainedImageCacheRisk }?.assetIDs, ["a", "b", "c"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(advisories.map(\.payload)))
    }

    func testJSONOnlyMockStillRequiresVisibleAndBaselineEvidence() {
        let advisories = CapturedMockReviewAdvisory.evaluate(images: [])
        XCTAssertEqual(advisories.map(\.code), [.visibleOutcomeNotVerified, .syntheticResponseNotUpstreamEvidence])
        XCTAssertTrue(advisories.allSatisfy { $0.assetIDs.isEmpty })
    }

    func testCatalogImageDefaultUsesVirtualOriginNotLoopback() throws {
        let asset = try XCTUnwrap(SyntheticAssetCatalog.availableAssets().first { $0.kind == .testPatternImage })
        XCTAssertEqual(URL(string: asset.localURL)?.host, SyntheticAssetOriginServer.defaultHost)
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: try XCTUnwrap(URL(string: asset.localURL)?.path), headers: [], bodyData: nil, bodySize: nil)
        let response = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(try XCTUnwrap(response.bodyData).isEmpty)
        // In-process availability is deliberately not a physical-device delivery assertion.
    }
}
