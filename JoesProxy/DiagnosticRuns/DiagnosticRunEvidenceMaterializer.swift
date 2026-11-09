import Foundation

/// Builds immutable diagnostic evidence envelopes at verified terminal close (AN-4).
enum DiagnosticRunEvidenceMaterializer {
    /// Snapshot payload from a terminal run and its frozen observation list.
    static func materialize(
        run: DiagnosticRun,
        observations: [DiagnosticRunObservationRecord],
        now: Date = Date()
    ) throws -> DiagnosticEvidenceRecord {
        guard run.status.isPrunableTerminal else {
            throw DiagnosticRunError.illegalTransition(from: run.status, to: .passed)
        }
        guard run.cleanupProof?.verifiedClean == true else {
            throw DiagnosticRunError.cleanupNotVerified
        }
        let terminalAt = run.terminalAt ?? now
        let markerIDs = observations.compactMap(\.markerID)
        let sessionIDs = observations.compactMap(\.sessionID)
        let dropped = run.observationSummary.droppedObservationCount
        let unavailable = run.observationSummary.evidenceUnavailableReason
        let isComplete = dropped == 0 && unavailable == nil
        var incompleteReason: String?
        if dropped > 0 {
            incompleteReason = "observation_truncated"
        } else if let unavailable {
            incompleteReason = unavailable.rawValue
        }

        let immutable = DiagnosticEvidenceImmutablePayload(
            schemaVersion: DiagnosticEvidenceSchemaVersion.current,
            runID: run.id,
            ownerID: run.owner.ownerID,
            hypothesis: run.hypothesis,
            scopes: run.scopes,
            references: run.references,
            observationSummary: run.observationSummary,
            observations: observations,
            conclusion: run.conclusion,
            cleanupProof: run.cleanupProof ?? DiagnosticRunCleanupProof(
                startedAt: terminalAt,
                completedAt: terminalAt,
                checkedReferenceIDs: [],
                cleanedReferenceIDs: [],
                observeOnlyReferenceIDs: [],
                conflictReasonCodes: [],
                remainingLiveEffectCount: 0,
                policyRevision: .initial,
                verifiedClean: true,
                verificationDigest: nil
            ),
            terminalStatus: run.status,
            terminalAt: terminalAt,
            captureEpochs: run.observationSummary.captureEpochs,
            markerIDs: Array(Set(markerIDs)),
            referencedSessionIDs: Array(Set(sessionIDs)),
            materializedAt: now,
            isEvidenceComplete: isComplete,
            incompleteReasonCode: incompleteReason
        )

        let provenanceDigest = try DiagnosticRunValidation.digest(immutable)
        struct DigestEnvelope: Encodable {
            var id: UUID
            var runID: DiagnosticRunID
            var provenanceDigest: String
        }
        let recordID = UUID()
        let evidenceDigest = try DiagnosticRunValidation.digest(
            DigestEnvelope(id: recordID, runID: run.id, provenanceDigest: provenanceDigest)
        )

        return DiagnosticEvidenceRecord(
            id: recordID,
            runID: run.id,
            ownerID: run.owner.ownerID,
            createdAt: now,
            immutable: immutable,
            provenanceDigest: provenanceDigest,
            evidenceDigest: evidenceDigest,
            editableNotes: nil,
            notesUpdatedAt: nil
        )
    }

    /// Verifies a stored record's digests still match its immutable payload.
    static func verifyIntegrity(_ record: DiagnosticEvidenceRecord) throws -> Bool {
        let provenance = try DiagnosticRunValidation.digest(record.immutable)
        guard provenance == record.provenanceDigest else { return false }
        struct DigestEnvelope: Encodable {
            var id: UUID
            var runID: DiagnosticRunID
            var provenanceDigest: String
        }
        let evidence = try DiagnosticRunValidation.digest(
            DigestEnvelope(
                id: record.id,
                runID: record.runID,
                provenanceDigest: record.provenanceDigest
            )
        )
        return evidence == record.evidenceDigest
    }

    /// Redacts exact host/path for metadata-only disclosure.
    static func disclosed(_ record: DiagnosticEvidenceRecord) -> DiagnosticEvidenceDisclosedRecord {
        DiagnosticEvidenceDisclosedRecord(
            id: record.id,
            runID: record.runID,
            ownerID: record.ownerID,
            createdAt: record.createdAt,
            terminalStatus: record.immutable.terminalStatus,
            terminalAt: record.immutable.terminalAt,
            hypothesisSummary: record.immutable.hypothesis.summary,
            conclusionOutcome: record.immutable.conclusion?.outcome,
            conclusionReasonCode: record.immutable.conclusion?.reasonCode,
            confidence: record.immutable.conclusion?.confidence,
            matchedRequestCount: record.immutable.observationSummary.matchedRequestCount,
            matcherMissCount: record.immutable.observationSummary.matcherMissCount,
            droppedObservationCount: record.immutable.observationSummary.droppedObservationCount,
            isEvidenceComplete: record.immutable.isEvidenceComplete,
            cleanupVerified: record.immutable.cleanupProof.verifiedClean,
            evidenceDigest: record.evidenceDigest,
            observationCount: record.immutable.observations.count
        )
    }

    /// Encoded byte size of one record for per-run quota enforcement.
    static func encodedByteCount(_ record: DiagnosticEvidenceRecord) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record).count
    }
}
