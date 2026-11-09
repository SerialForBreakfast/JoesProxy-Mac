import XCTest
@testable import JoesProxy

@MainActor
final class MCPProposalCoordinatorTests: XCTestCase {
    func testApplyProposalCommitsThroughRecoveryJournal() async throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "proposal-journal.json"))
        journal.load()
        let recovery = MCPRecoveryCoordinator(journalStore: journal)
        recovery.bootstrap()
        let coordinator = MCPProposalCoordinator(
            recoveryCoordinator: recovery,
            policyRevisionProvider: { .initial }
        )

        let proposal = try coordinator.createProposal(
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-a",
            targetRevision: MCPTargetRevision(rawValue: "target-1"),
            targetLockKey: "override:rule-1"
        )
        let result = try await coordinator.applyProposal(
            token: proposal.token,
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-a",
            currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
            mutationIntent: MCPMutationIntent(
                clientID: "client-1",
                targetKind: .responseOverride,
                targetID: "rule-1",
                baselineRevision: MCPTargetRevision(rawValue: "target-1"),
                intendedChangeDigest: "digest-a",
                rollbackSnapshot: nil,
                expiresAt: proposal.expiresAt
            )
        )
        XCTAssertFalse(result.transactionID.isEmpty)
        XCTAssertEqual(journal.entries.last?.phase, .committed)
    }

    func testDuplicateApplyWithIdempotencyKeyReturnsCachedResult() async throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "proposal-idempotency.json"))
        journal.load()
        let recovery = MCPRecoveryCoordinator(journalStore: journal)
        recovery.bootstrap()
        let coordinator = MCPProposalCoordinator(
            recoveryCoordinator: recovery,
            policyRevisionProvider: { .initial }
        )
        let idempotencyKey = MCPIdempotencyKey(rawValue: "idem-1")
        let proposal = try coordinator.createProposal(
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-b",
            targetRevision: nil,
            targetLockKey: "override:rule-2",
            idempotencyKey: idempotencyKey
        )
        let intent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .responseOverride,
            targetID: "rule-2",
            baselineRevision: nil,
            intendedChangeDigest: "digest-b",
            rollbackSnapshot: nil,
            expiresAt: proposal.expiresAt
        )
        let first = try await coordinator.applyProposal(
            token: proposal.token,
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-b",
            currentTargetRevision: nil,
            mutationIntent: intent,
            idempotencyKey: idempotencyKey
        )

        let cached = try await coordinator.applyProposal(
            token: proposal.token,
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-b",
            currentTargetRevision: nil,
            mutationIntent: intent,
            idempotencyKey: idempotencyKey
        )
        XCTAssertEqual(cached.transactionID, first.transactionID)
    }

    /// Regression test for a confirmed HIGH bug: the idempotency-key cache lookup used to return
    /// the cached result immediately, before validating the token, clientID, capability, or
    /// argument digest against anything. A second caller presenting the same idempotency key —
    /// whether a different client, or the same client attempting a genuinely different mutation —
    /// would get back the FIRST caller's result with zero re-validation. The fix binds the cache
    /// entry to the exact request that produced it and rejects a mismatched "hit" instead of
    /// honoring it.
    func testIdempotencyKeyReuseWithDifferentClientIsRejectedNotCached() async throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "proposal-idempotency-mismatch.json"))
        journal.load()
        let recovery = MCPRecoveryCoordinator(journalStore: journal)
        recovery.bootstrap()
        let coordinator = MCPProposalCoordinator(
            recoveryCoordinator: recovery,
            policyRevisionProvider: { .initial }
        )
        let sharedIdempotencyKey = MCPIdempotencyKey(rawValue: "shared-key")

        let firstProposal = try coordinator.createProposal(
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-victim",
            targetRevision: nil,
            targetLockKey: "override:rule-victim",
            idempotencyKey: sharedIdempotencyKey
        )
        let firstResult = try await coordinator.applyProposal(
            token: firstProposal.token,
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-victim",
            currentTargetRevision: nil,
            mutationIntent: MCPMutationIntent(
                clientID: "client-1",
                targetKind: .responseOverride,
                targetID: "rule-victim",
                baselineRevision: nil,
                intendedChangeDigest: "digest-victim",
                rollbackSnapshot: nil,
                expiresAt: firstProposal.expiresAt
            ),
            idempotencyKey: sharedIdempotencyKey
        )
        XCTAssertFalse(firstResult.transactionID.isEmpty)

        // A different client reuses the SAME idempotency key with its own, unrelated proposal.
        let attackerProposal = try coordinator.createProposal(
            clientID: "client-2",
            capability: .createDisabledBlock,
            argumentDigest: "digest-attacker",
            targetRevision: nil,
            targetLockKey: "override:rule-attacker",
            idempotencyKey: sharedIdempotencyKey
        )
        do {
            try await coordinator.applyProposal(
                token: attackerProposal.token,
                clientID: "client-2",
                capability: .createDisabledBlock,
                argumentDigest: "digest-attacker",
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: "client-2",
                    targetKind: .responseOverride,
                    targetID: "rule-attacker",
                    baselineRevision: nil,
                    intendedChangeDigest: "digest-attacker",
                    rollbackSnapshot: nil,
                    expiresAt: attackerProposal.expiresAt
                ),
                idempotencyKey: sharedIdempotencyKey
            )
            XCTFail("a different client's request must never receive another client's cached idempotency result")
        } catch let error as MCPProposalCoordinatorError {
            XCTAssertEqual(error, .staleProposal)
        }
    }

    func testStaleTargetRevisionRejected() async throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "proposal-stale.json"))
        journal.load()
        let recovery = MCPRecoveryCoordinator(journalStore: journal)
        recovery.bootstrap()
        let coordinator = MCPProposalCoordinator(
            recoveryCoordinator: recovery,
            policyRevisionProvider: { .initial }
        )
        let proposal = try coordinator.createProposal(
            clientID: "client-1",
            capability: .createDisabledBlock,
            argumentDigest: "digest-c",
            targetRevision: MCPTargetRevision(rawValue: "target-old"),
            targetLockKey: "override:rule-3"
        )
        do {
            try await coordinator.applyProposal(
                token: proposal.token,
                clientID: "client-1",
                capability: .createDisabledBlock,
                argumentDigest: "digest-c",
                currentTargetRevision: MCPTargetRevision(rawValue: "target-new"),
                mutationIntent: MCPMutationIntent(
                    clientID: "client-1",
                    targetKind: .responseOverride,
                    targetID: "rule-3",
                    baselineRevision: MCPTargetRevision(rawValue: "target-old"),
                    intendedChangeDigest: "digest-c",
                    rollbackSnapshot: nil,
                    expiresAt: proposal.expiresAt
                )
            )
            XCTFail("expected stale target revision rejection")
        } catch let error as MCPProposalCoordinatorError {
            XCTAssertEqual(error, .staleProposal)
        }
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
