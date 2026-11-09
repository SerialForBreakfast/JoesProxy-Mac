import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPEvidenceReferenceStoreTests: XCTestCase {
    func testReferenceIsClientEpochAndPolicyScoped() throws {
        let store = MCPEvidenceReferenceStore()
        let summary = MCPSessionSummaryDTO(id: UUID().uuidString, captureSequence: 7, method: "GET")
        let reference = try store.retain(
            summary: summary,
            clientID: "owner",
            captureEpoch: .initial,
            policyRevision: .initial,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            try store.resolve(
                reference.evidenceRef,
                clientID: "owner",
                captureEpoch: .initial,
                policyRevision: .initial,
                now: Date(timeIntervalSince1970: 101)
            ).summary,
            summary
        )
        XCTAssertThrowsError(
            try store.resolve(
                reference.evidenceRef,
                clientID: "other",
                captureEpoch: .initial,
                policyRevision: .initial,
                now: Date(timeIntervalSince1970: 101)
            )
        ) { XCTAssertEqual($0 as? MCPEvidenceReferenceError, .notFound) }
        XCTAssertThrowsError(
            try store.resolve(
                reference.evidenceRef,
                clientID: "owner",
                captureEpoch: MCPCaptureEpoch(rawValue: "capture-epoch-2"),
                policyRevision: .initial,
                now: Date(timeIntervalSince1970: 101)
            )
        ) { XCTAssertEqual($0 as? MCPEvidenceReferenceError, .staleCapture) }
    }

    func testExpiredReferenceIsRemoved() throws {
        let store = MCPEvidenceReferenceStore()
        let reference = try store.retain(
            summary: MCPSessionSummaryDTO(id: UUID().uuidString, captureSequence: 1),
            clientID: "owner",
            captureEpoch: .initial,
            policyRevision: .initial,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertThrowsError(
            try store.resolve(
                reference.evidenceRef,
                clientID: "owner",
                captureEpoch: .initial,
                policyRevision: .initial,
                now: Date(timeIntervalSince1970: 100 + MCPEvidenceReferenceStore.timeToLive + 1)
            )
        ) { XCTAssertEqual($0 as? MCPEvidenceReferenceError, .notFound) }
    }
}
