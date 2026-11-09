import XCTest
@testable import JoesProxy

final class CDNHeaderReaderTests: XCTestCase {
    func testCloudflareStatusAndRegion() {
        let signals = CDNHeaderReader().read(headers: [
            HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"),
            HTTPHeaderField(name: "CF-Ray", value: "89a3f2c4b1d8e9a7-IAD")
        ])

        XCTAssertEqual(signals.cacheStatus, .hit)
        XCTAssertEqual(signals.cdnRegion, "IAD")
    }

    func testCloudFrontPriorityOverGenericXCache() {
        let signals = CDNHeaderReader().read(headers: [
            HTTPHeaderField(name: "X-Cache", value: "RefreshHit from cloudfront"),
            HTTPHeaderField(name: "X-Amz-Cf-Pop", value: "IAD89-C2")
        ])

        XCTAssertEqual(signals.cacheStatus, .expired)
        XCTAssertEqual(signals.cdnRegion, "IAD89-C2")
    }

    func testFastlyStatusAndRegion() {
        let signals = CDNHeaderReader().read(headers: [
            HTTPHeaderField(name: "X-Cache", value: "MISS"),
            HTTPHeaderField(name: "X-Served-By", value: "cache-lax-klax3026-LAX")
        ])

        XCTAssertEqual(signals.cacheStatus, .miss)
        XCTAssertEqual(signals.cdnRegion, "LAX")
    }

    func testAkamaiStatusVariants() {
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "TCP_HIT from a1")]).cacheStatus,
            .hit
        )
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "TCP_MISS from a1")]).cacheStatus,
            .miss
        )
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "TCP_REFRESH_HIT from a1")]).cacheStatus,
            .stale
        )
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "TCP_EXPIRED_MISS from a1")]).cacheStatus,
            .expired
        )
    }

    func testGenericXCacheFallback() {
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "HIT")]).cacheStatus,
            .hit
        )
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "X-Cache", value: "MISS")]).cacheStatus,
            .miss
        )
    }

    func testUnknownAndAbsentHeaders() {
        XCTAssertEqual(
            CDNHeaderReader().read(headers: [HTTPHeaderField(name: "CF-Cache-Status", value: "REVALIDATED")]).cacheStatus,
            .unknown
        )
        XCTAssertNil(CDNHeaderReader().read(headers: [HTTPHeaderField(name: "Age", value: "32")]).cacheStatus)
    }

    func testHeaderLookupIsCaseInsensitive() {
        let signals = CDNHeaderReader().read(headers: [
            HTTPHeaderField(name: "cf-cache-status", value: "miss"),
            HTTPHeaderField(name: "cf-ray", value: "abc-SFO")
        ])

        XCTAssertEqual(signals.cacheStatus, .miss)
        XCTAssertEqual(signals.cdnRegion, "SFO")
    }
}
