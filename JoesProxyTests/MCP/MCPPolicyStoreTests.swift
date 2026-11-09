import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPPolicyStoreTests: XCTestCase {
    func testDeveloperInspectionIsSelectableInPhase1() throws {
        let store = MCPPolicyStore(
            persistenceURL: temporaryURL(named: "policy-dev-inspection.json")
        )
        store.load()
        let profile = try store.resolvedProfile(for: .developerInspection)
        XCTAssertEqual(profile.id, .developerInspection)
        XCTAssertTrue(profile.isSelectableInPhase1)
    }

    func testFullLocalInspectionStillNotSelectable() {
        let store = MCPPolicyStore(
            persistenceURL: temporaryURL(named: "policy-full-local.json")
        )
        store.load()
        XCTAssertThrowsError(try store.resolvedProfile(for: .fullLocalInspection)) { error in
            XCTAssertEqual(error as? MCPPolicyStoreError, .profileNotSelectable(.fullLocalInspection))
        }
    }

    func testTighteningBumpsRevision() {
        let url = temporaryURL(named: "policy-tighten.json")
        let store = MCPPolicyStore(persistenceURL: url)
        store.load()
        let before = store.policyRevision
        let after = store.bumpRevisionForTightening()
        XCTAssertNotEqual(before, after)
    }

    func testCorruptStoreFailsClosed() throws {
        let url = temporaryURL(named: "policy-corrupt.json")
        try Data("{".utf8).write(to: url)
        let store = MCPPolicyStore(persistenceURL: url)
        store.load()
        XCTAssertFalse(store.isLoaded)
        XCTAssertNotNil(store.loadFailureReason)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
