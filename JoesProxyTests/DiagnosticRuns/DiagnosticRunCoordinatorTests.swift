import XCTest
@testable import JoesProxy

/// AN-2: durable diagnostic-run coordinator lifecycle, ownership, quotas, and relaunch.
@MainActor
final class DiagnosticRunCoordinatorTests: XCTestCase {
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    func testDraftToWatchingToPassedCleanupProof() async throws {
        let installer = NoOpDiagnosticRunWatchInstaller()
        let resolver = NoOpDiagnosticRunEffectResolver()
        let coordinator = makeCoordinator(watchInstaller: installer, effectResolver: resolver)
        await coordinator.bootstrap()

        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope(path: "/v1/health")]
        )
        XCTAssertEqual(draft.status, .draft)

        let watching = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(watching.status, .watching)
        XCTAssertEqual(watching.installedWatchIDs.count, 1)
        XCTAssertEqual(installer.installed.count, 1)

        let closed = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .passed,
            conclusion: conclusion(outcome: .passed, reason: .expectedObserved)
        )
        XCTAssertEqual(closed.status, .passed)
        XCTAssertTrue(closed.cleanupProof?.verifiedClean == true)
        XCTAssertTrue(installer.installed.isEmpty)
    }

    func testWatchingBecomesActiveWhenOwnerScopedEffectIsLive() async throws {
        let resolver = NoOpDiagnosticRunEffectResolver()
        resolver.states["overrideRule:rule-1"] = .live(ownerID: DiagnosticRunOwner.localUserOwnerID)
        let coordinator = makeCoordinator(effectResolver: resolver)
        await coordinator.bootstrap()

        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let active = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: "rule-1",
                relationship: .ownerScopedCleanup,
                ownerIDSnapshot: DiagnosticRunOwner.localUserOwnerID,
                targetRevision: "rev-1",
                attachedAt: clock
            ),
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(active.status, .active)
        XCTAssertNotNil(active.activeAt)
    }

    func testAttachDoesNotActivateEffect() async throws {
        let resolver = NoOpDiagnosticRunEffectResolver()
        resolver.states["overrideRule:rule-1"] = .inactive(ownerID: DiagnosticRunOwner.localUserOwnerID)
        let coordinator = makeCoordinator(effectResolver: resolver)
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        _ = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: "rule-1",
                relationship: .ownerScopedCleanup,
                ownerIDSnapshot: DiagnosticRunOwner.localUserOwnerID,
                targetRevision: nil,
                attachedAt: clock
            ),
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let state = await resolver.liveState(kind: .overrideRule, opaqueID: "rule-1")
        XCTAssertEqual(state, .inactive(ownerID: DiagnosticRunOwner.localUserOwnerID))
    }

    func testAtomicWatchInstallRollsBackOnPartialFailure() async throws {
        let installer = FlakyWatchInstaller(failOnScopeIndex: 3)
        let coordinator = makeCoordinator(watchInstaller: installer)
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [
                httpScope(path: "/a"),
                httpScope(path: "/b"),
                httpScope(path: "/c"),
                httpScope(path: "/d")
            ]
        )
        do {
            _ = try await coordinator.startWatching(
                id: draft.id,
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
            )
            XCTFail("expected install failure")
        } catch {
            XCTAssertTrue(installer.installed.isEmpty)
            let stillDraft = try XCTUnwrap(coordinator.run(id: draft.id))
            XCTAssertEqual(stillDraft.status, .draft)
            XCTAssertTrue(stillDraft.installedWatchIDs.isEmpty)
        }
    }

    func testOwnershipIsolationRejectsForeignMCPClient() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .mcpClient(id: "client-a", displayNameSnapshot: "A"),
            hypothesis: hypothesis(source: .mcpClient),
            scopes: [httpScope()]
        )
        do {
            _ = try await coordinator.startWatching(id: draft.id, requestingOwnerID: "client-b")
            XCTFail("expected notOwner")
        } catch {
            XCTAssertEqual(error as? DiagnosticRunError, .notOwner)
        }
    }

    func testLocalRunCannotClaimCleanupOnForeignEffect() async throws {
        let resolver = NoOpDiagnosticRunEffectResolver()
        resolver.states["overrideRule:foreign"] = .live(ownerID: "other-client")
        let coordinator = makeCoordinator(effectResolver: resolver)
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        do {
            _ = try await coordinator.attachReference(
                id: draft.id,
                reference: DiagnosticRunReference(
                    kind: .overrideRule,
                    opaqueID: "foreign",
                    relationship: .ownerScopedCleanup,
                    ownerIDSnapshot: "other-client",
                    targetRevision: nil,
                    attachedAt: clock
                ),
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
            )
            XCTFail("expected attachRejected")
        } catch {
            guard case DiagnosticRunError.attachRejected = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        let observeOnly = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: "foreign",
                relationship: .observeOnly,
                ownerIDSnapshot: "other-client",
                targetRevision: nil,
                attachedAt: clock
            ),
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(observeOnly.references.count, 1)
        XCTAssertEqual(observeOnly.status, .watching)
    }

    func testCleanupConflictLeavesCleanupRequired() async throws {
        let resolver = StickyLiveEffectResolver()
        resolver.states["overrideRule:sticky"] = .live(ownerID: DiagnosticRunOwner.localUserOwnerID)
        let coordinator = makeCoordinator(effectResolver: resolver)
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        _ = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: "sticky",
                relationship: .ownerScopedCleanup,
                ownerIDSnapshot: DiagnosticRunOwner.localUserOwnerID,
                targetRevision: nil,
                attachedAt: clock
            ),
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        do {
            _ = try await coordinator.close(
                id: draft.id,
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
                requestedTerminal: .passed,
                conclusion: conclusion(outcome: .passed, reason: .expectedObserved)
            )
            XCTFail("expected cleanupNotVerified")
        } catch {
            XCTAssertEqual(error as? DiagnosticRunError, .cleanupNotVerified)
        }
        let required = try XCTUnwrap(coordinator.run(id: draft.id))
        XCTAssertEqual(required.status, .cleanupRequired)
        XCTAssertEqual(required.requestedTerminal, .passed)
        XCTAssertEqual(required.cleanupProof?.verifiedClean, false)
    }

    func testWatchingRelaunchBecomesInconclusive() async throws {
        let url = temporaryStoreURL()
        let store = DiagnosticRunStore(
            persistenceURL: url,
            clock: { [unowned self] in self.clock }
        )
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )

        let relaunchedStore = DiagnosticRunStore(
            persistenceURL: url,
            clock: { [unowned self] in self.clock }
        )
        let relaunched = DiagnosticRunCoordinator(
            store: relaunchedStore,
            clock: { [unowned self] in self.clock }
        )
        await relaunched.bootstrap()
        let run = try XCTUnwrap(relaunched.run(id: draft.id))
        XCTAssertEqual(run.status, .inconclusive)
        XCTAssertEqual(run.conclusion?.reasonCode, .operationInterrupted)
        XCTAssertTrue(run.installedWatchIDs.isEmpty)
        XCTAssertTrue(run.cleanupProof?.verifiedClean == true)
    }

    func testActiveRelaunchBecomesCleanupRequired() async throws {
        let url = temporaryStoreURL()
        let resolver = NoOpDiagnosticRunEffectResolver()
        resolver.states["overrideRule:rule-1"] = .live(ownerID: DiagnosticRunOwner.localUserOwnerID)
        let store = DiagnosticRunStore(
            persistenceURL: url,
            clock: { [unowned self] in self.clock }
        )
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            effectResolver: resolver,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        _ = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: "rule-1",
                relationship: .ownerScopedCleanup,
                ownerIDSnapshot: DiagnosticRunOwner.localUserOwnerID,
                targetRevision: nil,
                attachedAt: clock
            ),
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(coordinator.run(id: draft.id)?.status, .active)

        let relaunched = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: url,
                clock: { [unowned self] in self.clock }
            ),
            effectResolver: resolver,
            clock: { [unowned self] in self.clock }
        )
        await relaunched.bootstrap()
        let run = try XCTUnwrap(relaunched.run(id: draft.id))
        XCTAssertEqual(run.status, .cleanupRequired)
        XCTAssertTrue(run.installedWatchIDs.isEmpty)
    }

    func testExpiryUsesInjectedClock() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()],
            lifetime: 60
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        clock = clock.addingTimeInterval(61)
        await coordinator.synchronizeExpiry()
        let expired = try XCTUnwrap(coordinator.run(id: draft.id))
        XCTAssertEqual(expired.status, .expired)
        XCTAssertTrue(expired.cleanupProof?.verifiedClean == true)
    }

    func testQuotaRejectsExcessNonterminalRuns() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        for index in 0..<DiagnosticRunBudget.maxConcurrentNonterminalLocalUser {
            _ = try coordinator.createDraft(
                owner: .localUser,
                hypothesis: hypothesis(summary: "run \(index)"),
                scopes: []
            )
        }
        do {
            _ = try coordinator.createDraft(
                owner: .localUser,
                hypothesis: hypothesis(summary: "overflow"),
                scopes: []
            )
            XCTFail("expected quotaExceeded")
        } catch {
            guard case DiagnosticRunError.quotaExceeded = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testCorruptStoreFailsClosedWithoutOverwrite() async throws {
        let url = temporaryStoreURL()
        try Data("not-json".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        let store = DiagnosticRunStore(persistenceURL: url)
        store.load()
        XCTAssertFalse(store.isLoaded)
        XCTAssertNotNil(store.loadFailureReason)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)

        let coordinator = DiagnosticRunCoordinator(store: store)
        await coordinator.bootstrap()
        do {
            _ = try coordinator.createDraft(owner: .localUser, hypothesis: hypothesis())
            XCTFail("expected storeUnavailable")
        } catch {
            guard case DiagnosticRunError.storeUnavailable = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testCleanupRequiredSurvivesTerminalPrune() async throws {
        let url = temporaryStoreURL()
        let store = DiagnosticRunStore(
            persistenceURL: url,
            clock: { [unowned self] in self.clock }
        )
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        await coordinator.markCleanupRequired(ownedBy: DiagnosticRunOwner.localUserOwnerID)

        // Age far beyond terminal retention and reload; Cleanup Required must remain.
        clock = clock.addingTimeInterval(DiagnosticRunBudget.terminalRetention + 86_400)
        let relaunched = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: url,
                clock: { [unowned self] in self.clock }
            ),
            clock: { [unowned self] in self.clock }
        )
        await relaunched.bootstrap()
        let run = try XCTUnwrap(relaunched.run(id: draft.id))
        XCTAssertEqual(run.status, .cleanupRequired)
    }

    func testScopeValidationRejectsWildcardAndQueryPath() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        do {
            _ = try coordinator.createDraft(
                owner: .localUser,
                hypothesis: hypothesis(),
                scopes: [.http(DiagnosticHTTPScope(
                    method: "*",
                    scheme: .https,
                    host: "example.test",
                    port: 443,
                    path: "/v1",
                    pathMatch: .exact
                ))]
            )
            XCTFail("expected invalidScopes")
        } catch {
            guard case DiagnosticRunError.invalidScopes = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        do {
            _ = try coordinator.createDraft(
                owner: .localUser,
                hypothesis: hypothesis(),
                scopes: [.http(DiagnosticHTTPScope(
                    method: "GET",
                    scheme: .https,
                    host: "example.test",
                    port: 443,
                    path: "/v1?x=1",
                    pathMatch: .exact
                ))]
            )
            XCTFail("expected invalidScopes")
        } catch {
            guard case DiagnosticRunError.invalidScopes = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testDigestIsStableAcrossEncodes() throws {
        let proof = DiagnosticRunCleanupProof(
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            checkedReferenceIDs: ["a"],
            cleanedReferenceIDs: [],
            observeOnlyReferenceIDs: [],
            conflictReasonCodes: [],
            remainingLiveEffectCount: 0,
            policyRevision: .initial,
            verifiedClean: true,
            verificationDigest: nil
        )
        let first = try DiagnosticRunValidation.digest(proof)
        let second = try DiagnosticRunValidation.digest(proof)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testCloseIsIdempotentOnceTerminal() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let first = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .failed,
            conclusion: conclusion(outcome: .failed, reason: .contraryObserved)
        )
        let second = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .passed,
            conclusion: conclusion(outcome: .passed, reason: .expectedObserved)
        )
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(second.requestedTerminal, .failed)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        watchInstaller: (any DiagnosticRunWatchInstalling)? = nil,
        effectResolver: (any DiagnosticRunEffectResolving)? = nil
    ) -> DiagnosticRunCoordinator {
        DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            watchInstaller: watchInstaller,
            effectResolver: effectResolver,
            clock: { [unowned self] in self.clock }
        )
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-diagnostic-run-\(UUID().uuidString).json")
    }

    private func hypothesis(
        summary: String = "Client recovers after a scoped fault.",
        source: DiagnosticRunTextSource = .localUser
    ) -> DiagnosticRunHypothesis {
        DiagnosticRunHypothesis(
            summary: summary,
            expectedObservation: "Matching request returns the injected fault status.",
            source: source
        )
    }

    private func conclusion(
        outcome: DiagnosticConclusionOutcome,
        reason: DiagnosticConclusionReasonCode
    ) -> DiagnosticRunConclusion {
        DiagnosticRunConclusion(
            outcome: outcome,
            reasonCode: reason,
            summary: "Bounded conclusion for AN-2 tests.",
            confidence: .medium,
            concludedAt: clock,
            evidenceDigest: "abc"
        )
    }

    private func httpScope(path: String = "/v1/health") -> DiagnosticRunScope {
        .http(DiagnosticHTTPScope(
            method: "GET",
            scheme: .https,
            host: "example.test",
            port: 443,
            path: path,
            pathMatch: .exact
        ))
    }
}

/// Installs watches until `failOnScopeIndex`, then throws so AN-2 can prove rollback.
@MainActor
private final class FlakyWatchInstaller: DiagnosticRunWatchInstalling {
    let failOnScopeIndex: Int
    private(set) var installed: [UUID: DiagnosticRunID] = [:]
    private var attempt = 0

    init(failOnScopeIndex: Int) {
        self.failOnScopeIndex = failOnScopeIndex
    }

    func installWatches(
        runID: DiagnosticRunID,
        ownerID: String,
        scopes: [DiagnosticRunScope]
    ) async throws -> [UUID] {
        _ = ownerID
        if attempt == failOnScopeIndex {
            throw DiagnosticRunError.invalidScopes("Forced install failure.")
        }
        attempt += 1
        let ids = scopes.map { _ in UUID() }
        for id in ids {
            installed[id] = runID
        }
        return ids
    }

    func removeWatches(_ watchIDs: [UUID]) async {
        for id in watchIDs {
            installed.removeValue(forKey: id)
        }
    }
}

/// Cleanup that never clears a live effect (forces Cleanup Required).
@MainActor
private final class StickyLiveEffectResolver: DiagnosticRunEffectResolving {
    var states: [String: DiagnosticEffectLiveState] = [:]

    private func key(_ kind: DiagnosticReferenceKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    func liveState(kind: DiagnosticReferenceKind, opaqueID: String) async -> DiagnosticEffectLiveState {
        states[key(kind, opaqueID)] ?? .notFound
    }

    func requestRiskReducingCleanup(
        kind: DiagnosticReferenceKind,
        opaqueID: String,
        requestingOwnerID: String
    ) async -> DiagnosticCleanupActionResult {
        _ = requestingOwnerID
        return DiagnosticCleanupActionResult(cleaned: false, conflictReasonCode: "sticky_live")
    }
}
