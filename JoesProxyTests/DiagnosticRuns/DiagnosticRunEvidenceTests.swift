import XCTest
@testable import JoesProxy

/// AN-4: durable evidence records, digests, migration, retention, and disclosure.
@MainActor
final class DiagnosticRunEvidenceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    func testVerifiedTerminalCloseMaterializesEvidence() async throws {
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
        let closed = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .passed,
            conclusion: conclusion(outcome: .passed, reason: .expectedObserved)
        )
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(record.runID, closed.id)
        XCTAssertEqual(record.immutable.hypothesis.summary, hypothesis().summary)
        XCTAssertEqual(record.immutable.terminalStatus, .passed)
        XCTAssertTrue(record.immutable.cleanupProof.verifiedClean)
        XCTAssertEqual(closed.conclusion?.evidenceDigest, record.evidenceDigest)
        XCTAssertTrue(try coordinator.verifyEvidenceIntegrity(
            id: record.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        ))
    }

    func testCleanupRequiredDoesNotMaterializeEvidence() async throws {
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
        XCTAssertThrowsError(
            try coordinator.evidenceRecord(
                forRunID: draft.id,
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
            )
        ) { error in
            XCTAssertEqual(error as? DiagnosticRunError, .evidenceNotFound)
        }
    }

    func testEditableNotesDoNotChangeDigests() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let beforeDigest = record.evidenceDigest
        let beforeProvenance = record.provenanceDigest
        let updated = try coordinator.updateEvidenceNotes(
            id: record.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            notes: "Human follow-up for the investigation."
        )
        XCTAssertEqual(updated.editableNotes, "Human follow-up for the investigation.")
        XCTAssertNotNil(updated.notesUpdatedAt)
        XCTAssertEqual(updated.evidenceDigest, beforeDigest)
        XCTAssertEqual(updated.provenanceDigest, beforeProvenance)
        XCTAssertTrue(try coordinator.verifyEvidenceIntegrity(
            id: record.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        ))
    }

    func testDisclosedRecordOmitsExactHostAndPath() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let disclosed = try coordinator.disclosedEvidenceRecord(
            id: record.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(disclosed.hypothesisSummary, hypothesis().summary)
        XCTAssertEqual(disclosed.conclusionOutcome, .passed)
        let encoded = try JSONEncoder().encode(disclosed)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("example.test"))
        XCTAssertFalse(json.contains("/v1/health"))
    }

    func testTamperedImmutablePayloadFailsIntegrityCheck() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        var record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        record.immutable.hypothesis.summary = "Tampered summary."
        XCTAssertFalse(try DiagnosticRunEvidenceMaterializer.verifyIntegrity(record))
    }

    func testStoreMigratesSchemaV1ToV2() async throws {
        let url = temporaryStoreURL()
        let store = DiagnosticRunStore(persistenceURL: url, clock: { [unowned self] in self.clock })
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedV2 = try decoder.decode(PersistedEnvelope.self, from: Data(contentsOf: url))
        let legacyV1 = LegacyPersistedStateV1(
            schemaVersion: 1,
            runs: persistedV2.runs,
            evidenceRecords: [
                LegacyEvidencePlaceholder(
                    id: UUID(),
                    runID: closed.id,
                    createdAt: clock
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyV1).write(to: url, options: .atomic)

        let migrated = DiagnosticRunStore(persistenceURL: url, clock: { [unowned self] in self.clock })
        migrated.load()
        XCTAssertTrue(migrated.isLoaded)
        XCTAssertEqual(migrated.runs.count, 1)
        XCTAssertTrue(migrated.evidenceRecords.isEmpty)
        let header = try decoder.decode(MigrationHeader.self, from: Data(contentsOf: url))
        XCTAssertEqual(header.schemaVersion, DiagnosticRunSchemaVersion.current)
    }

    func testEvidencePrunedWithExpiredTerminalRuns() async throws {
        let url = temporaryStoreURL()
        let store = DiagnosticRunStore(persistenceURL: url, clock: { [unowned self] in self.clock })
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        clock = clock.addingTimeInterval(DiagnosticRunBudget.terminalRetention + 86_400)
        let reloaded = DiagnosticRunStore(persistenceURL: url, clock: { [unowned self] in self.clock })
        reloaded.load()
        XCTAssertTrue(reloaded.runs.isEmpty)
        XCTAssertTrue(reloaded.evidenceRecords.isEmpty)
        _ = record
    }

    func testOwnershipIsolationForEvidenceReads() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .mcpClient(id: "client-a", displayNameSnapshot: "A"),
            hypothesis: hypothesis(source: .mcpClient),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: "client-a"
        )
        let closed = try await coordinator.close(
            id: draft.id,
            requestingOwnerID: "client-a",
            requestedTerminal: .failed,
            conclusion: conclusion(outcome: .failed, reason: .contraryObserved)
        )
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: "client-a"
        )
        do {
            _ = try coordinator.evidenceRecord(id: record.id, requestingOwnerID: "client-b")
            XCTFail("expected notOwner")
        } catch {
            XCTAssertEqual(error as? DiagnosticRunError, .notOwner)
        }
    }

    func testIncompleteEvidenceWhenObservationsWereTruncated() async throws {
        let index = DiagnosticRunObservationIndex()
        let installer = DiagnosticRunObservationWatchInstaller(index: index)
        let coordinator = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            watchInstaller: installer,
            observationIndex: index,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        let watching = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        for _ in 0..<(DiagnosticRunBudget.maxLiveObservationsPerRun + 2) {
            await ingest(event(sessionID: UUID()), index: index, coordinator: coordinator)
        }
        let closed = try await coordinator.close(
            id: watching.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .inconclusive,
            conclusion: conclusion(outcome: .inconclusive, reason: .insufficientEvidence)
        )
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertFalse(record.immutable.isEvidenceComplete)
        XCTAssertEqual(record.immutable.incompleteReasonCode, "observation_truncated")
    }

    func testExportEnvelopeRoundTrips() async throws {
        let coordinator = makeCoordinator()
        await coordinator.bootstrap()
        let closed = try await closeSampleRun(coordinator)
        let record = try coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let export = try coordinator.exportEvidence(
            id: record.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(DiagnosticRunEvidenceExportEnvelope.self, from: data)
        XCTAssertEqual(decoded.record.evidenceDigest, record.evidenceDigest)
        XCTAssertTrue(try DiagnosticRunEvidenceMaterializer.verifyIntegrity(decoded.record))
    }

    // MARK: - Helpers

    private struct MigrationHeader: Decodable {
        var schemaVersion: Int
    }

    private struct PersistedEnvelope: Codable {
        var schemaVersion: Int
        var runs: [DiagnosticRun]
        var evidenceRecords: [DiagnosticEvidenceRecord]
    }

    private struct LegacyPersistedStateV1: Codable {
        var schemaVersion: Int
        var runs: [DiagnosticRun]
        var evidenceRecords: [LegacyEvidencePlaceholder]
    }

    private struct LegacyEvidencePlaceholder: Codable {
        var id: UUID
        var runID: DiagnosticRunID
        var createdAt: Date
    }

    private func makeCoordinator(
        effectResolver: (any DiagnosticRunEffectResolving)? = nil
    ) -> DiagnosticRunCoordinator {
        DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            effectResolver: effectResolver,
            clock: { [unowned self] in self.clock }
        )
    }

    private func closeSampleRun(_ coordinator: DiagnosticRunCoordinator) async throws -> DiagnosticRun {
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: hypothesis(),
            scopes: [httpScope()]
        )
        _ = try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        return try await coordinator.close(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .passed,
            conclusion: conclusion(outcome: .passed, reason: .expectedObserved)
        )
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
            summary: "Bounded conclusion for AN-4 tests.",
            confidence: .medium,
            concludedAt: clock,
            evidenceDigest: "placeholder"
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

    private func event(sessionID: UUID) -> DiagnosticRunCaptureEvent {
        DiagnosticRunCaptureEvent(
            sessionID: sessionID,
            captureSequence: 1,
            captureEpoch: .initial,
            method: "GET",
            scheme: .https,
            host: "example.test",
            port: 443,
            path: "/v1/health",
            statusCode: 200,
            latencyMilliseconds: 12,
            observedAt: clock,
            isMarker: false,
            attributionIDs: []
        )
    }

    private func ingest(
        _ event: DiagnosticRunCaptureEvent,
        index: DiagnosticRunObservationIndex,
        coordinator: DiagnosticRunCoordinator
    ) async {
        let result = await index.ingest(event)
        coordinator.applyObservationSummaries(result.updatedSummaries)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-diagnostic-evidence-\(UUID().uuidString).json")
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
