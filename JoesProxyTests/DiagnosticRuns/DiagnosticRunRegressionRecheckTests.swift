import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class DiagnosticRunRegressionRecheckTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Deterministic match → Still Holds

    func testDeterministicMatchStillHolds() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-1", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(reference)] = .recreated(newOpaqueID: "rule-1-new", targetRevision: "rev-1")

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 3])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        XCTAssertTrue(preparation.isCompatible)

        harness.captureHistory.events = [hitEvent(statusCode: 200, at: clock.addingTimeInterval(1))]
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .stillHolds)
        XCTAssertEqual(result.recreatedReferences.count, 1)
        XCTAssertTrue(result.cleanupProof.verifiedClean)
        XCTAssertEqual(result.cleanupProof.checkedReferenceIDs, ["overrideRule:rule-1-new"])
    }

    // MARK: - Changed result → Regression Detected

    func testChangedResultDetectsRegression() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-2", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(reference)] = .recreated(newOpaqueID: "rule-2-new", targetRevision: "rev-1")

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 3])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        harness.captureHistory.events = [
            hitEvent(statusCode: 500, at: clock.addingTimeInterval(1)),
            hitEvent(statusCode: 503, at: clock.addingTimeInterval(2))
        ]
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .regressionDetected)
        XCTAssertTrue(result.cleanupProof.verifiedClean)
    }

    // MARK: - Stale target (changed fingerprint)

    func testChangedFingerprintIsIncompatibleAndInconclusive() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-3", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-2", revisionChanged: true)

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        XCTAssertFalse(preparation.isCompatible)
        XCTAssertEqual(preparation.incompatibilityReason, .targetChanged)

        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .inconclusive(.targetChanged))
        XCTAssertTrue(result.recreatedReferences.isEmpty, "An incompatible preparation must never recreate anything.")
        XCTAssertTrue(result.cleanupProof.verifiedClean)
    }

    // MARK: - Missing target

    func testMissingTargetIsInconclusive() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-4", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .targetMissing

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        XCTAssertFalse(preparation.isCompatible)
        XCTAssertEqual(preparation.incompatibilityReason, .targetMissing)

        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .inconclusive(.targetMissing))
        XCTAssertTrue(result.cleanupProof.verifiedClean)
    }

    // MARK: - No traffic

    func testNoTrafficIsInconclusive() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-5", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(reference)] = .recreated(newOpaqueID: "rule-5-new", targetRevision: "rev-1")

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .inconclusive(.noRequest))
        XCTAssertEqual(result.recreatedReferences.count, 1, "Effects are still recreated even if no traffic later arrives.")
        XCTAssertTrue(result.cleanupProof.verifiedClean)
    }

    // MARK: - Approval denial

    func testApprovalDenialIsInconclusiveAndCleansUpPriorRecreations() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let first = makeReference(opaqueID: "rule-6a", targetRevision: "rev-1")
        let second = makeReference(opaqueID: "rule-6b", targetRevision: "rev-1")
        recreator.previews[key(first)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.previews[key(second)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(first)] = .recreated(newOpaqueID: "rule-6a-new", targetRevision: "rev-1")
        recreator.results[key(second)] = .approvalDenied

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [first, second],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .inconclusive(.approvalDenied))
        XCTAssertEqual(
            result.recreatedReferences.count,
            1,
            "The first successfully-recreated reference must still be tracked for cleanup."
        )
        XCTAssertTrue(result.cleanupProof.verifiedClean)
        XCTAssertEqual(result.cleanupProof.checkedReferenceIDs, ["overrideRule:rule-6a-new"])
    }

    // MARK: - Interruption

    func testInterruptionIsInconclusiveAndCleansUp() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-7", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(reference)] = .interrupted

        let harness = makeService(recreator: recreator)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .inconclusive(.operationInterrupted))
        XCTAssertTrue(result.recreatedReferences.isEmpty)
        XCTAssertTrue(result.cleanupProof.verifiedClean)
    }

    // MARK: - Cleanup conflict surfaces as unverified, not silently swallowed

    func testCleanupConflictLeavesProofUnverified() async throws {
        let recreator = NoOpDiagnosticRunEffectRecreator()
        let reference = makeReference(opaqueID: "rule-8", targetRevision: "rev-1")
        recreator.previews[key(reference)] = .supported(currentTargetRevision: "rev-1", revisionChanged: false)
        recreator.results[key(reference)] = .recreated(newOpaqueID: "rule-8-new", targetRevision: "rev-1")

        let resolver = NoOpDiagnosticRunEffectResolver()
        resolver.states["overrideRule:rule-8-new"] = .live(ownerID: "someone-else")

        let harness = makeService(recreator: recreator, resolver: resolver)
        try seedEvidence(
            into: harness.testStore,
            references: [reference],
            observationSummary: summary(statusFamilies: ["2xx": 1])
        )

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        harness.captureHistory.events = [hitEvent(statusCode: 200, at: clock.addingTimeInterval(1))]
        let result = try await harness.service.executeRecheck(
            preparation: preparation,
            requestingOwnerID: ownerID
        )
        XCTAssertEqual(result.outcome, .stillHolds, "Comparison outcome is independent of cleanup success.")
        XCTAssertFalse(result.cleanupProof.verifiedClean)
        XCTAssertFalse(result.cleanupProof.conflictReasonCodes.isEmpty)
    }

    // MARK: - Ownership / preconditions

    func testForeignOwnerCannotPrepare() async throws {
        let harness = makeService(recreator: NoOpDiagnosticRunEffectRecreator())
        try seedEvidence(into: harness.testStore, references: [], observationSummary: summary(statusFamilies: [:]))

        do {
            _ = try await harness.service.prepareRecheck(
                sourceEvidenceID: seededEvidenceID,
                requestingOwnerID: "someone-else"
            )
            XCTFail("Expected notOwner")
        } catch DiagnosticRunRecheckError.notOwner {
            // expected
        }
    }

    func testExpiredPreparationCannotBeExecuted() async throws {
        let harness = makeService(recreator: NoOpDiagnosticRunEffectRecreator())
        try seedEvidence(into: harness.testStore, references: [], observationSummary: summary(statusFamilies: [:]))

        let preparation = try await harness.service.prepareRecheck(
            sourceEvidenceID: seededEvidenceID,
            requestingOwnerID: ownerID
        )
        clock = preparation.expiresAt.addingTimeInterval(1)

        do {
            _ = try await harness.service.executeRecheck(
                preparation: preparation,
                requestingOwnerID: ownerID
            )
            XCTFail("Expected preparationExpired")
        } catch DiagnosticRunRecheckError.preparationExpired {
            // expected
        }
    }

    // MARK: - Helpers

    private let ownerID = DiagnosticRunOwner.localUserOwnerID
    private var seededEvidenceID = UUID()
    private let defaultScope = DiagnosticRunScope.http(
        DiagnosticHTTPScope(method: "GET", scheme: .https, host: "example.com", port: 443, path: "/", pathMatch: .exact)
    )

    /// Bundles the service under test with its backing store and a fake capture-history source,
    /// since `executeRecheck` now gathers its own fresh observation by re-scanning captured
    /// events against the run's saved scopes rather than accepting one directly from the caller.
    private struct TestHarness {
        let service: DiagnosticRunRegressionRecheckService
        let testStore: DiagnosticRunStore
        let captureHistory: NoOpDiagnosticRunCaptureHistory
    }

    private func makeService(
        recreator: DiagnosticRunEffectRecreating,
        resolver: DiagnosticRunEffectResolving? = nil
    ) -> TestHarness {
        let store = DiagnosticRunStore(persistenceURL: temporaryStoreURL(), clock: { [unowned self] in self.clock })
        store.load()
        let captureHistory = NoOpDiagnosticRunCaptureHistory()
        let service = DiagnosticRunRegressionRecheckService(
            store: store,
            effectResolver: resolver,
            effectRecreator: recreator,
            captureHistory: captureHistory,
            clock: { [unowned self] in self.clock }
        )
        return TestHarness(service: service, testStore: store, captureHistory: captureHistory)
    }

    /// A matching HTTP hit for `defaultScope`, for tests that need `executeRecheck` to gather a
    /// real fresh observation instead of short-circuiting before it ever looks.
    private func hitEvent(statusCode: Int, at date: Date) -> DiagnosticRunCaptureEvent {
        DiagnosticRunCaptureEvent(
            sessionID: UUID(),
            captureSequence: 1,
            captureEpoch: .initial,
            method: "GET",
            scheme: .https,
            host: "example.com",
            port: 443,
            path: "/",
            statusCode: statusCode,
            latencyMilliseconds: 50,
            observedAt: date,
            isMarker: false,
            attributionIDs: []
        )
    }

    private func makeReference(opaqueID: String, targetRevision: String) -> DiagnosticRunReference {
        DiagnosticRunReference(
            kind: .overrideRule,
            opaqueID: opaqueID,
            relationship: .ownerScopedCleanup,
            ownerIDSnapshot: ownerID,
            targetRevision: targetRevision,
            attachedAt: clock
        )
    }

    private func key(_ reference: DiagnosticRunReference) -> String {
        "\(reference.kind.rawValue):\(reference.opaqueID)"
    }

    private func summary(statusFamilies: [String: Int]) -> DiagnosticRunObservationSummary {
        var value = DiagnosticRunObservationSummary.empty
        value.statusFamilies = statusFamilies
        value.matchedRequestCount = statusFamilies.values.reduce(0, +)
        return value
    }

    private func seedEvidence(
        into store: DiagnosticRunStore,
        references: [DiagnosticRunReference],
        observationSummary: DiagnosticRunObservationSummary,
        scopes: [DiagnosticRunScope]? = nil
    ) throws {
        let scopes = scopes ?? [defaultScope]
        let runID = DiagnosticRunID()
        seededEvidenceID = UUID()
        let conclusion = DiagnosticRunConclusion(
            outcome: .passed,
            reasonCode: .expectedObserved,
            summary: "Original conclusion summary.",
            confidence: .high,
            concludedAt: clock,
            evidenceDigest: "placeholder"
        )
        let cleanupProof = DiagnosticRunCleanupProof(
            startedAt: clock,
            completedAt: clock,
            checkedReferenceIDs: [],
            cleanedReferenceIDs: [],
            observeOnlyReferenceIDs: [],
            conflictReasonCodes: [],
            remainingLiveEffectCount: 0,
            policyRevision: .initial,
            verifiedClean: true,
            verificationDigest: nil
        )
        let payload = DiagnosticEvidenceImmutablePayload(
            schemaVersion: DiagnosticEvidenceSchemaVersion.current,
            runID: runID,
            ownerID: ownerID,
            hypothesis: DiagnosticRunHypothesis(
                summary: "Test hypothesis",
                expectedObservation: "2xx",
                source: .localUser
            ),
            scopes: scopes,
            references: references,
            observationSummary: observationSummary,
            observations: [],
            conclusion: conclusion,
            cleanupProof: cleanupProof,
            terminalStatus: .passed,
            terminalAt: clock,
            captureEpochs: [],
            markerIDs: [],
            referencedSessionIDs: [],
            materializedAt: clock,
            isEvidenceComplete: true,
            incompleteReasonCode: nil
        )
        let record = DiagnosticEvidenceRecord(
            id: seededEvidenceID,
            runID: runID,
            ownerID: ownerID,
            createdAt: clock,
            immutable: payload,
            provenanceDigest: "placeholder",
            evidenceDigest: "placeholder",
            editableNotes: nil,
            notesUpdatedAt: nil
        )
        try store.appendEvidence(record)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-diagnostic-run-recheck-\(UUID().uuidString).json")
    }
}
