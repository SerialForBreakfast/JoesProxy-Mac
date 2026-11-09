import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPDisclosurePreviewTests: XCTestCase {
    func testSyntheticMetadataOnlyPreviewRemovesShareableFields() throws {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "preview-policy.json"))
        policyStore.load()
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let client = MCPClientRecord(
            id: "client-preview",
            displayName: "Preview",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let engine = MCPDisclosurePreviewEngine(policyStore: policyStore, snapshotService: snapshotService)
        let envelope = try engine.preview(client: client, source: .syntheticFixture)
        XCTAssertTrue(envelope.removedFieldClasses.contains(MCPPolicyFieldClass.sanitizedPath.rawValue))
        XCTAssertTrue(envelope.removedFieldClasses.contains(MCPPolicyFieldClass.safeHeaders.rawValue))
        XCTAssertNil(envelope.summary.sanitizedPath)
        XCTAssertNil(envelope.summary.safeHeaders)
    }

    func testShareableSyntheticPreviewPartiallyRedactsAdversarialFixture() throws {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "preview-shareable.json"))
        policyStore.load()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore())
        let client = MCPClientRecord(
            id: "client-shareable",
            displayName: "Shareable",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let engine = MCPDisclosurePreviewEngine(policyStore: policyStore, snapshotService: snapshotService)
        let envelope = try engine.preview(client: client, source: .syntheticFixture)
        XCTAssertTrue(envelope.partiallyRedactedFieldClasses.contains(MCPPolicyFieldClass.sanitizedPath.rawValue))
        XCTAssertTrue(envelope.partiallyRedactedFieldClasses.contains(MCPPolicyFieldClass.safeHeaders.rawValue))
        XCTAssertEqual(envelope.summary.sanitizedPath, "/reset/confirm/<redacted>")
        XCTAssertTrue(envelope.bodyTruncated)
        XCTAssertGreaterThan(envelope.estimatedJSONBytes, 0)
    }

    func testSelectedSessionPreviewUsesSnapshotIndex() throws {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "preview-session-policy.json"))
        policyStore.load()
        let sessionStore = InMemorySessionStore()
        let record = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            timing: SessionTiming(startedAt: Date())
        )
        sessionStore.append(record)
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let client = MCPClientRecord(
            id: "client-session",
            displayName: "Session",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let engine = MCPDisclosurePreviewEngine(policyStore: policyStore, snapshotService: snapshotService)
        let envelope = try engine.preview(client: client, source: .capturedSession(record.id))
        XCTAssertEqual(envelope.summary.method, "POST")
        XCTAssertEqual(envelope.summary.hostCategory, MCPHostCategory.api.rawValue)
    }

    private func sessionStore() -> InMemorySessionStore {
        InMemorySessionStore()
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
