import XCTest
#if !STANDALONE_RETIREMENT_TESTS
@testable import JoesProxy
#endif

final class CertificateRetirementTests: XCTestCase {
    enum Denied: Error { case access }

    func testRemoveAfterInstalledRootAlreadyAbsent() throws {
        var saved: String? = "target"
        let retired = try CertificateRetirement.run(readFingerprint: { saved }, removeInstalled: {
            XCTAssertEqual($0, "target")
        }, removeStored: { saved = nil })
        XCTAssertEqual(retired, "target")
        XCTAssertNil(saved)
    }

    func testLockedIdentityDoesNotAttemptEitherDeletion() {
        XCTAssertThrowsError(try CertificateRetirement.run(readFingerprint: { throw Denied.access },
            removeInstalled: { _ in XCTFail("Removed without an identity") },
            removeStored: { XCTFail("Deleted locked identity") }))
    }

    func testRemovalFailureRetainsSigningMaterial() {
        XCTAssertThrowsError(try CertificateRetirement.run(readFingerprint: { "target" },
            removeInstalled: { _ in throw Denied.access }, removeStored: { XCTFail("Lost retry identity") }))
    }

    func testRemainingIdentityFailsVerification() {
        XCTAssertThrowsError(try CertificateRetirement.run(readFingerprint: { "target" },
            removeInstalled: { _ in }, removeStored: {}))
    }
}

#if STANDALONE_RETIREMENT_TESTS
@main enum RetirementTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: CertificateRetirementTests.self)
        suite.run()
        guard let run = suite.testRun, run.executionCount == 4, run.hasSucceeded else { exit(1) }
        print("PASS: \(run.executionCount) certificate retirement tests")
    }
}
#endif
