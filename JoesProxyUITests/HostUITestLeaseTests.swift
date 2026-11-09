import Foundation
import XCTest

final class HostUITestLeaseTests: XCTestCase {
    func testSecondLeaseFailsImmediatelyWithInfrastructureContention() {
        let leaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-lease-\(UUID().uuidString).lock", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: leaseURL) }

        let firstLease = HostUITestLease(leaseURL: leaseURL)
        XCTAssertNil(firstLease.failureMessage)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let secondLease = HostUITestLease(leaseURL: leaseURL)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(
            secondLease.failureMessage,
            "Host UI test infrastructure contention: another UI runner owns this Mac login session."
        )
        XCTAssertLessThan(elapsed, .seconds(1))
        withExtendedLifetime(firstLease) {}
    }
}
