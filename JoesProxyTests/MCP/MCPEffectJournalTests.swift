import XCTest
@testable import JoesProxy

@MainActor
final class MCPEffectJournalTests: XCTestCase {
    func testIntentWithoutCommitReconcilesAtLaunch() throws {
        let url = temporaryURL(named: "effect-journal.json")
        let journal = MCPEffectJournalStore(persistenceURL: url)
        journal.load()
        let coordinator = MCPRecoveryCoordinator(journalStore: journal)

        let intent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .responseOverride,
            targetID: UUID().uuidString,
            baselineRevision: MCPTargetRevision(rawValue: "target-a"),
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(120)
        )
        _ = try coordinator.beginMutation(intent)
        XCTAssertEqual(journal.unresolvedEntries().count, 1)

        let relaunchedJournal = MCPEffectJournalStore(persistenceURL: url)
        let relaunchedCoordinator = MCPRecoveryCoordinator(journalStore: relaunchedJournal)
        relaunchedCoordinator.bootstrap()
        if case .clean = relaunchedCoordinator.effectState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected clean state after rolling back intent-only transaction.")
        }
        XCTAssertEqual(relaunchedJournal.entries.first?.phase, .rolledBack)
    }

    /// Regression test for a confirmed HIGH bug: `unresolvedEntries` used to exclude an
    /// `.intent`-phase entry whose `expiresAt` had already passed before the app restarted, so
    /// `reconcileAtLaunch` never saw it and it stayed in `.intent` phase — permanently ambiguous,
    /// never resolved — forever. Expiry bounds how long a proposal token is valid for a client to
    /// act on; it is not a reason to stop reconciling an incomplete journal entry.
    func testExpiredIntentEntryIsStillReconciledAtLaunch() throws {
        let url = temporaryURL(named: "effect-journal-expired-intent.json")
        let journal = MCPEffectJournalStore(persistenceURL: url)
        journal.load()
        let coordinator = MCPRecoveryCoordinator(journalStore: journal)

        let alreadyExpiredIntent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .responseOverride,
            targetID: UUID().uuidString,
            baselineRevision: MCPTargetRevision(rawValue: "target-a"),
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(-120)
        )
        _ = try coordinator.beginMutation(alreadyExpiredIntent)
        XCTAssertEqual(
            journal.unresolvedEntries().count, 1,
            "an expired intent is still unresolved — expiry is not the same as resolution"
        )

        let relaunchedJournal = MCPEffectJournalStore(persistenceURL: url)
        let relaunchedCoordinator = MCPRecoveryCoordinator(journalStore: relaunchedJournal)
        relaunchedCoordinator.bootstrap()

        XCTAssertEqual(
            relaunchedJournal.entries.first?.phase, .rolledBack,
            "an expired intent must be reconciled to a terminal state at launch, not left ambiguous forever"
        )
        if case .clean = relaunchedCoordinator.effectState {
        } else {
            XCTFail("Expected clean state after reconciling the expired intent.")
        }
    }

    func testCommitRemovesUnresolvedEntry() throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "effect-journal-commit.json"))
        journal.load()
        let coordinator = MCPRecoveryCoordinator(journalStore: journal)
        let intent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .block,
            targetID: "rule-1",
            baselineRevision: nil,
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(120)
        )
        let transactionID = try coordinator.beginMutation(intent)
        try coordinator.commitMutation(transactionID: transactionID)
        XCTAssertTrue(journal.unresolvedEntries().isEmpty)
        if case .clean = coordinator.effectState {
        } else {
            XCTFail("Expected clean effect state after commit.")
        }
    }

    func testConflictStateSurfacesFromJournal() throws {
        let journal = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "effect-journal-conflict.json"))
        journal.load()
        let coordinator = MCPRecoveryCoordinator(journalStore: journal)
        let intent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .throttle,
            targetID: "throttle",
            baselineRevision: MCPTargetRevision(rawValue: "target-throttle"),
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(120)
        )
        let transactionID = try coordinator.beginMutation(intent)
        try coordinator.markConflict(transactionID: transactionID, message: "User edited throttle after MCP intent.")
        if case .conflict(let items) = coordinator.effectState {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.kind, .throttle)
        } else {
            XCTFail("Expected conflict effect state.")
        }
    }

    func testClearAllForFreshLaunchRemovesEveryPhaseAndPersists() throws {
        let url = temporaryURL(named: "effect-journal-fresh-launch.json")
        let journal = MCPEffectJournalStore(persistenceURL: url)
        journal.load()
        let coordinator = MCPRecoveryCoordinator(journalStore: journal)

        let intent = MCPMutationIntent(
            clientID: "client-1",
            targetKind: .throttle,
            targetID: "throttle",
            baselineRevision: MCPTargetRevision(rawValue: "target-throttle"),
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(120)
        )
        let transactionID = try coordinator.beginMutation(intent)
        try coordinator.markConflict(transactionID: transactionID, message: "Orphaned from a prior crash.")
        XCTAssertEqual(journal.entries.count, 1)
        XCTAssertEqual(journal.entries.first?.phase, .conflict)

        journal.clearAllForFreshLaunch()
        XCTAssertTrue(journal.entries.isEmpty)

        let reloaded = MCPEffectJournalStore(persistenceURL: url)
        reloaded.load()
        XCTAssertTrue(reloaded.entries.isEmpty, "clearAllForFreshLaunch must persist the empty journal to disk")
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
