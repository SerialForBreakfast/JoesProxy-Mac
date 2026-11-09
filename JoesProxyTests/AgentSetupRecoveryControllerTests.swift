import XCTest
@testable import JoesProxy

@MainActor
final class AgentSetupRecoveryControllerTests: XCTestCase {
    private let state = MCPSetupReadinessState(localTrustState: .notSetUp, profileHealth: .unknown,
                                              verificationState: .proxyStopped, profileDownloadObserved: false)

    func testReadinessNeverPerformsRecoveryAndDoesNotClaimDeviceTrust() async {
        var installations = 0
        let controller = AgentSetupRecoveryController(read: { self.state }, install: { installations += 1 })
        await controller.refresh()
        XCTAssertEqual(installations, 0)
        XCTAssertEqual(controller.readiness, state)
        XCTAssertNil(controller.receipt)
        XCTAssertFalse(controller.isWorking)
    }

    func testFailurePersistsAcrossRefreshAndExplicitRetryReplacesIt() async {
        struct Failure: LocalizedError { var errorDescription: String? { "Synthetic install failure" } }
        var fails = true
        var installations = 0
        let controller = AgentSetupRecoveryController(read: { self.state }, install: {
            installations += 1
            if fails { throw Failure() }
        })
        await controller.installCertificate()
        XCTAssertEqual(controller.failure, "Synthetic install failure")
        XCTAssertNil(controller.receipt)
        await controller.refresh()
        XCTAssertEqual(controller.failure, "Synthetic install failure")
        fails = false
        await controller.installCertificate()
        XCTAssertEqual(installations, 2)
        XCTAssertNil(controller.failure)
        XCTAssertNotNil(controller.receipt)
        XCTAssertEqual(controller.readiness?.localTrustState, .notSetUp)
    }

    func testConcurrentRefreshCannotDuplicateInstallation() async {
        var release: CheckedContinuation<MCPSetupReadinessState, Never>?
        var installations = 0
        let controller = AgentSetupRecoveryController(read: {
            await withCheckedContinuation { release = $0 }
        }, install: { installations += 1 })
        let first = Task { await controller.installCertificate() }
        while release == nil { await Task.yield() }
        XCTAssertTrue(controller.isWorking)
        await controller.installCertificate()
        await controller.refresh()
        XCTAssertEqual(installations, 1)
        release?.resume(returning: state)
        await first.value
        XCTAssertFalse(controller.isWorking)
    }
}
