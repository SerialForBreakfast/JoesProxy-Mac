import XCTest
@testable import JoesProxy

/// Live-code proof (not a mocked assumption) that the `ownerScopedCleanup` reference mechanism
/// (AN-2/AN-5) reports false cleanup success against a real effect.
///
/// Confirmed 2026-08-12: `DiagnosticRunCoordinator.attachReference` has zero callers anywhere in
/// production code — no MCP tool, no CLI command, no UI action attaches a reference today,
/// only test files do. That makes the originally-planned live CLI repro impossible as written.
/// This test instead drives the real `DiagnosticRunCoordinator` against a real
/// `ResponseOverrideStore` (not a mock) the same way a real caller eventually would, so the
/// cleanup gap is demonstrated against actual production code rather than restated as a
/// hypothetical.
@MainActor
final class DiagnosticRunCleanupGapIntegrationTests: XCTestCase {
    func testCleanupProofReportsVerifiedCleanWithoutTouchingTheRealRule() async throws {
        let overrideStore = ResponseOverrideStore()
        let ownerID = DiagnosticRunOwner.localUserOwnerID

        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/items",
            sourceKind: .inlineText,
            sourceDescription: "Phase B cleanup-gap repro",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("{}".utf8))
        )
        try await overrideStore.addRule(rule)
        let liveBefore = await overrideStore.rule(id: rule.id)
        XCTAssertEqual(liveBefore?.isEnabled, true)

        // The resolver's `liveState` read side is stubbed to report what a real
        // ResponseOverrideStore-backed resolver would say (the rule is live and owned by us) —
        // the only way `attachReference` accepts an `ownerScopedCleanup` reference at all. Its
        // `requestRiskReducingCleanup` is left as NoOp's real, unmodified default: an
        // in-memory-only flag flip with no connection to `overrideStore` — exactly what ships
        // today, since `AppCoordinator` still constructs `DiagnosticRunCoordinator` with
        // `effectResolver: nil`.
        let effectResolver = NoOpDiagnosticRunEffectResolver()
        effectResolver.states["overrideRule:\(rule.id.uuidString)"] = .live(ownerID: ownerID)

        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("joesproxy-cleanup-gap-\(UUID().uuidString).json"),
                clock: { clock }
            ),
            watchInstaller: NoOpDiagnosticRunWatchInstaller(),
            effectResolver: effectResolver,
            clock: { clock }
        )
        await coordinator.bootstrap()

        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: DiagnosticRunHypothesis(
                summary: "Cleanup-gap repro",
                expectedObservation: "n/a",
                source: .localUser
            ),
            scopes: [.http(DiagnosticHTTPScope(
                method: "GET", scheme: .https, host: "api.example.com", port: 443,
                path: "/v1/items", pathMatch: .exact
            ))]
        )
        _ = try await coordinator.startWatching(id: draft.id, requestingOwnerID: ownerID)
        let active = try await coordinator.attachReference(
            id: draft.id,
            reference: DiagnosticRunReference(
                kind: .overrideRule,
                opaqueID: rule.id.uuidString,
                relationship: .ownerScopedCleanup,
                ownerIDSnapshot: ownerID,
                targetRevision: nil,
                attachedAt: clock
            ),
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(active.status, .active, "Attaching a live owner-scoped effect moves Watching -> Active.")

        let closed = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: ownerID,
            requestedTerminal: .passed,
            conclusion: DiagnosticRunConclusion(
                outcome: .passed,
                reasonCode: .expectedObserved,
                summary: "Cleanup-gap repro.",
                confidence: .high,
                concludedAt: clock,
                evidenceDigest: "placeholder"
            )
        )

        // The lie: cleanup reports success...
        XCTAssertEqual(closed.status, .passed)
        XCTAssertTrue(closed.cleanupProof?.verifiedClean == true, "cleanupProof claims the reference was cleaned.")
        XCTAssertEqual(closed.cleanupProof?.remainingLiveEffectCount, 0)

        // ...the NoOp resolver's own bookkeeping agrees the effect is now inactive...
        let resolverState = await effectResolver.liveState(kind: .overrideRule, opaqueID: rule.id.uuidString)
        XCTAssertEqual(resolverState, .inactive(ownerID: ownerID))

        // ...but the real rule in the real store was never touched.
        let liveAfter = await overrideStore.rule(id: rule.id)
        XCTAssertEqual(
            liveAfter?.isEnabled, true,
            "BUG (AN-2/AN-5 known gap): cleanupProof.verifiedClean is true and the resolver's own "
                + "bookkeeping says the effect is inactive, but the real Map Local rule in "
                + "ResponseOverrideStore is still enabled — nothing in NoOpDiagnosticRunEffectResolver "
                + "is wired to the real store. Fixing this requires a real MCPMutationService-backed "
                + "DiagnosticRunEffectResolving adapter (AppCoordinator.swift still passes "
                + "effectResolver: nil), out of scope for this repro."
        )
    }
}
