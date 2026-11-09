import XCTest
@testable import JoesProxy

@MainActor
final class MCPSubscriptionTests: XCTestCase {
    func testQueueCoalescesCaptureUpdatesForSameURI() {
        var queue = MCPNotificationQueue(capacity: 8)
        queue.enqueue(.resourceUpdated(uri: "joesproxy://capture/summary", droppedEventCount: 0))
        queue.enqueue(.resourceUpdated(uri: "joesproxy://capture/summary", droppedEventCount: 2))
        XCTAssertEqual(queue.events.count, 1)
        if case .resourceUpdated(_, let dropped) = queue.events[0] {
            XCTAssertEqual(dropped, 2)
        } else {
            XCTFail("Expected coalesced capture update")
        }
    }

    /// Regression test for a confirmed bug: `accumulatedDroppedCount` used to be read directly at
    /// several hub call sites without resetting it, so the same historical drop got re-reported on
    /// every later notification instead of exactly once. `takeDroppedCount()` must read-and-clear
    /// atomically.
    func testQueueTakeDroppedCountReadsAndClearsAtomically() {
        var queue = MCPNotificationQueue(capacity: 1)
        // Force a real drop: capacity 1, two non-coalescible events (different categories).
        queue.enqueue(.resourceInvalidated(uri: nil, reason: "a", captureEpoch: .initial, policyRevision: .initial, droppedEventCount: 0))
        queue.enqueue(.operationUpdated(operationID: "op-1", descriptor: sampleDescriptor(operationID: "op-1", progress: 0.1, status: .running), isTerminal: false))
        XCTAssertEqual(queue.accumulatedDroppedCount, 1, "sanity check: a real drop must have occurred")

        XCTAssertEqual(queue.takeDroppedCount(), 1, "first read must report the real accumulated drop")
        XCTAssertEqual(queue.takeDroppedCount(), 0, "second read must not re-report the same drop")
        XCTAssertEqual(queue.accumulatedDroppedCount, 0)
    }

    func testQueueTerminalReplacesPendingProgressForSameOperation() {
        var queue = MCPNotificationQueue(capacity: 8)
        let progress = sampleDescriptor(operationID: "op-1", progress: 0.4, status: .running)
        let terminal = sampleDescriptor(operationID: "op-1", progress: 1, status: .completed)
        queue.enqueue(.operationUpdated(operationID: "op-1", descriptor: progress, isTerminal: false))
        queue.enqueue(.operationUpdated(operationID: "op-1", descriptor: terminal, isTerminal: true))
        XCTAssertEqual(queue.events.count, 1)
        if case .operationUpdated(_, _, let isTerminal) = queue.events[0] {
            XCTAssertTrue(isTerminal)
        } else {
            XCTFail("Expected terminal operation event")
        }
    }

    func testQueueDropsLowestPriorityWhenFull() {
        var queue = MCPNotificationQueue(capacity: 2)
        queue.enqueue(.resourceUpdated(uri: "joesproxy://capture/summary", droppedEventCount: 0))
        queue.enqueue(.resourceUpdated(uri: "joesproxy://capture/health", droppedEventCount: 0))
        queue.enqueue(
            .resourceInvalidated(
                uri: nil,
                reason: "policy_changed",
                captureEpoch: .initial,
                policyRevision: .initial,
                droppedEventCount: 0
            )
        )
        XCTAssertEqual(queue.events.count, 2)
        XCTAssertEqual(queue.accumulatedDroppedCount, 1)
        XCTAssertTrue(queue.events.contains {
            if case .resourceInvalidated = $0 { return true }
            return false
        })
    }

    func testSubscribeRejectsUnknownURI() async throws {
        let stack = try await makeHubStack()
        let key = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: stack.sessionID)
        XCTAssertThrowsError(try stack.hub.subscribe(key: key, uri: "joesproxy://unknown/resource")) { error in
            let structured = error as? MCPStructuredError
            XCTAssertEqual(structured?.code, .malformedRequest)
        }
    }

    func testCaptureUpdateBroadcastsToAllSubscribers() async throws {
        let stack = try await makeHubStack()
        let firstKey = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "session-a")
        let secondKey = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "session-b")
        try stack.hub.subscribe(key: firstKey, uri: "joesproxy://capture/summary")
        try stack.hub.subscribe(key: secondKey, uri: "joesproxy://capture/summary")

        let firstWriter = MCPMockSSEWriter()
        let secondWriter = MCPMockSSEWriter()
        stack.hub.registerWriter(key: firstKey, writer: firstWriter)
        stack.hub.registerWriter(key: secondKey, writer: secondWriter)

        stack.hub.publishCaptureUpdates()

        XCTAssertEqual(firstWriter.frames.count, 1)
        XCTAssertEqual(secondWriter.frames.count, 1)
        XCTAssertEqual(firstWriter.frames[0]["method"] as? String, "notifications/resources/updated")
        let params = try XCTUnwrap(firstWriter.frames[0]["params"] as? [String: Any])
        XCTAssertEqual((params["captureHighWaterSequence"] as? NSNumber)?.uint64Value, 0)
    }

    func testToolsetChangeNotifiesOnlyMatchingClientWriters() async throws {
        let stack = try await makeHubStack()
        let matchingKey = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "matching")
        let otherKey = MCPLogicalSessionKey(clientID: "other-client", mcpSessionID: "other")
        let matchingWriter = MCPMockSSEWriter()
        let otherWriter = MCPMockSSEWriter()
        stack.hub.registerWriter(key: matchingKey, writer: matchingWriter)
        stack.hub.registerWriter(key: otherKey, writer: otherWriter)

        stack.hub.publishToolsListChanged(clientID: stack.client.id)

        XCTAssertEqual(matchingWriter.frames.count, 1)
        XCTAssertEqual(matchingWriter.frames.first?["method"] as? String, "notifications/tools/list_changed")
        XCTAssertTrue(otherWriter.frames.isEmpty)
    }

    /// Regression test for a confirmed bug: `accumulatedDroppedCount` used to be read without
    /// resetting at several hub call sites (stale re-reports of the same historical drop on every
    /// later notification) and `publishCaptureUpdates` hard-coded `droppedEventCount: 0` regardless
    /// of the session's real accumulated drops (silently hiding real drops). A genuine drop must be
    /// reported on exactly one delivered notification — not zero (hidden), not more than one (stale
    /// re-report) — and a subsequent `publishCaptureUpdates` with nothing newly dropped must
    /// correctly reflect that nothing is pending, proving it reads live state rather than some
    /// other stale or hardcoded value.
    func testDroppedEventIsReportedExactlyOnce() async throws {
        let stack = try await makeHubStack()
        let key = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "drop-session")
        try stack.hub.subscribe(key: key, uri: "joesproxy://capture/summary")

        // No writer registered yet, so nothing auto-flushes — force the queue past its 256
        // capacity with distinct, non-coalescible operation-progress events so a real drop occurs.
        for index in 0..<300 {
            let descriptor = sampleDescriptor(operationID: "op-\(index)", progress: 0.5, status: .running)
            stack.hub.publishOperationUpdate(key: key, descriptor: descriptor, isTerminal: false)
        }

        let writer = MCPMockSSEWriter()
        stack.hub.registerWriter(key: key, writer: writer)

        // `.operationUpdated` frames always carry a `droppedEventCount` field (even when 0);
        // `.resourceUpdated` only includes it when nonzero. Count only the nonzero reports — that's
        // what "the drop was actually communicated" means, not "the field happened to be present."
        let dropReports = writer.frames.compactMap(Self.droppedEventCount).filter { $0 > 0 }
        XCTAssertEqual(
            dropReports.count, 1,
            "a real drop occurred and must be reported on exactly one notification — not hidden, not repeated"
        )
        XCTAssertGreaterThan(dropReports.first ?? 0, 0)

        stack.hub.publishCaptureUpdates()
        let captureFrame = try XCTUnwrap(writer.frames.last { $0["method"] as? String == "notifications/resources/updated" })
        XCTAssertNil(
            Self.droppedEventCount(captureFrame),
            "the drop was already reported above; nothing new was dropped, so this must not re-report it"
        )
    }

    /// `.resourceUpdated` frames carry `droppedEventCount` flat in `params`; `.operationUpdated`/
    /// `.resourceInvalidated` frames go through `MCPDTOEnvelope` and nest it under `params.payload`.
    private static func droppedEventCount(_ frame: [String: Any]) -> Int? {
        guard let params = frame["params"] as? [String: Any] else { return nil }
        if let direct = params["droppedEventCount"] as? Int { return direct }
        if let payload = params["payload"] as? [String: Any] {
            return payload["droppedEventCount"] as? Int
        }
        return nil
    }

    func testOperationUpdateIsOwnerScopedOnly() async throws {
        let stack = try await makeHubStack()
        let ownerKey = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "owner-session")
        let otherKey = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: "other-session")
        try stack.hub.subscribe(key: otherKey, uri: "joesproxy://capture/summary")

        let ownerWriter = MCPMockSSEWriter()
        let otherWriter = MCPMockSSEWriter()
        stack.hub.registerWriter(key: ownerKey, writer: ownerWriter)
        stack.hub.registerWriter(key: otherKey, writer: otherWriter)

        let descriptor = sampleDescriptor(operationID: "op-owner", progress: 0.5, status: .running)
        stack.hub.publishOperationUpdate(key: ownerKey, descriptor: descriptor, isTerminal: false)

        XCTAssertEqual(ownerWriter.frames.count, 1)
        XCTAssertEqual(otherWriter.frames.count, 0)
        XCTAssertEqual(ownerWriter.frames[0]["method"] as? String, "notifications/joesproxy/operation_updated")
    }

    /// Regression test for a confirmed gap: `unsubscribe` never recorded an audit event, unlike
    /// `subscribe` and every other sensitive/state-changing MCP action — the same class of gap this
    /// codebase already hit once with `resources/read`, reintroduced on the unsubscribe side.
    func testUnsubscribeRecordsAuditEvent() async throws {
        let stack = try await makeHubStack()
        let key = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: stack.sessionID)
        try stack.hub.subscribe(key: key, uri: "joesproxy://capture/summary")

        stack.hub.unsubscribe(key: key, uri: "joesproxy://capture/summary")

        let unsubscribeEvent = stack.auditStore.recentEvents.first { $0.reasonCode == "unsubscribe:joesproxy://capture/summary" }
        XCTAssertNotNil(unsubscribeEvent, "unsubscribing must leave an audit trail, matching subscribe's discipline")
    }

    func testSlowWriterBackpressureUnregistersSubscriptions() async throws {
        let stack = try await makeHubStack()
        let key = MCPLogicalSessionKey(clientID: stack.client.id, mcpSessionID: stack.sessionID)
        try stack.hub.subscribe(key: key, uri: "joesproxy://capture/summary")

        let failingWriter = FailingSSEWriter()
        stack.hub.registerWriter(key: key, writer: failingWriter)
        stack.hub.publishCaptureUpdates()

        XCTAssertTrue(failingWriter.didClose)
        XCTAssertEqual(stack.hub.subscribedSessionCount, 0)
    }

    // MARK: - Helpers

    private struct HubStack {
        let hub: MCPNotificationHub
        let client: MCPClientRecord
        let sessionID: String
        let auditStore: MCPAuditStore
    }

    private func makeHubStack() async throws -> HubStack {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-subscriptions.json"))
        policyStore.load()
        let credentialStore = MCPInMemoryCredentialStore()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-subscriptions.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-subscriptions.json"))
        auditStore.load()
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let hub = MCPNotificationHub(
            sessionStore: sessionStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService
        )
        let enrollment = try clientRegistry.enroll(displayName: "Subscriptions")
        let client = try XCTUnwrap(clientRegistry.clients.first)
        return HubStack(hub: hub, client: client, sessionID: UUID().uuidString, auditStore: auditStore)
    }

    private func sampleDescriptor(
        operationID: String,
        progress: Double,
        status: MCPOperationStatus
    ) -> MCPOperationDescriptorDTO {
        MCPOperationDescriptorDTO(
            operationID: operationID,
            status: status,
            progress: progress,
            currentStage: status == .running ? "parsing" : nil,
            operationKind: .mediaInspection,
            requestedAnalyses: [.transportStructure],
            stages: [],
            warnings: [],
            failureCode: nil,
            result: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}

private final class FailingSSEWriter: MCPSSEWriting {
    private(set) var didClose = false

    func writeSSE(jsonObject: [String: Any]) -> Bool {
        false
    }

    func writeComment(_ comment: String) -> Bool {
        false
    }

    func close() {
        didClose = true
    }

    func closeAndWait() async {
        close()
    }
}
