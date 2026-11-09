import CryptoKit
import Foundation

extension MCPMutationService {
    // MARK: - Response drafts (G4)

    func responseDraftsList(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .responseDraftInspect)
        let store = try requireDraftStore()
        let items = store.drafts(ownedBy: client.id).map { draftSummaryDictionary($0) }
        return [
            "schemaVersion": 1,
            "payload": [
                "items": items,
                "count": items.count
            ]
        ]
    }

    func responseDraftGet(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .responseDraftInspect)
        let store = try requireDraftStore()
        let draft = try ownedDraft(from: arguments, client: client, store: store)
        let liveOverrideIDs = await liveBoundOverrideIDs(for: draft)
        var payload = draftDetailDictionary(draft)
        payload["referencedByOverrideIDs"] = liveOverrideIDs.map(\.uuidString)
        payload["isReferencedByMapLocalRule"] = !liveOverrideIDs.isEmpty
        return [
            "schemaVersion": 1,
            "payload": payload
        ]
    }

    func proposeCreateResponseDraft(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        _ = try requireDraftStore()
        guard let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID is required.")
        }
        let prepared = try prepareDraftBody(sessionID: sessionID, arguments: arguments)
        let proposedID = UUID()
        let plan = MCPMutationPlan(
            capability: .createResponseDraft,
            matcher: prepared.matcher,
            proposedTargetID: proposedID,
            effectKind: .responseDraft,
            effectSummary: "Create response draft from session \(sessionID.uuidString).",
            inlineBodyData: prepared.bodyData,
            inlineContentType: prepared.contentType,
            inlineStatusCode: prepared.statusCode,
            draftSourceSessionID: sessionID,
            draftLabel: arguments["label"] as? String
        )
        // Stash capture sequence in rewriteLabel-adjacent plan field via targetRevision? Store on plan via draftPreviewDigest misuse is bad.
        // Encode capture sequence into effectSummary is enough for apply — re-read session at apply time.
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    func applyCreateResponseDraft(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        let store = try requireDraftStore()
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createResponseDraft, client: client)
        try resolveMutationApproval(
            toolName: "apply_create_response_draft",
            arguments: arguments,
            client: client,
            capability: .createResponseDraft
        )
        guard let sessionID = plan.draftSourceSessionID,
              let matcher = plan.matcher,
              let bodyData = plan.inlineBodyData,
              let statusCode = plan.inlineStatusCode,
              let contentType = plan.inlineContentType,
              let snapshotService,
              let indexed = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete or the source session is gone.")
        }
        let bodySHA256 = sha256HexPublic(bodyData)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createResponseDraft,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .responseDraft,
                targetID: plan.proposedTargetID.uuidString,
                baselineRevision: nil,
                intendedChangeDigest: proposal.argumentDigest,
                rollbackSnapshot: nil,
                expiresAt: MCPApprovalPolicy.expiration()
            ),
            performMutation: {
                _ = try store.createDraft(
                    id: plan.proposedTargetID,
                    clientID: client.id,
                    label: plan.draftLabel,
                    sourceSessionID: sessionID,
                    sourceCaptureSequence: indexed.captureSequence,
                    matcher: matcher,
                    bodyData: bodyData,
                    bodySHA256: bodySHA256,
                    statusCode: statusCode,
                    contentType: contentType
                )
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(
            client: client,
            capability: .createResponseDraft,
            targetID: plan.proposedTargetID.uuidString,
            detail: plan.effectSummary
        )
        var payload = try payloadDictionary(
            applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false)
        )
        if let draft = store.draft(id: plan.proposedTargetID) {
            payload["draft"] = draftSummaryDictionary(draft)
            payload["currentRevisionID"] = draft.currentRevisionID.uuidString
        }
        return payload
    }

    func proposeCommitResponseEdit(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        let store = try requireDraftStore()
        guard let draftIDString = arguments["draftID"] as? String,
              let draftID = UUID(uuidString: draftIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "draftID is required.")
        }
        guard let draft = store.draft(id: draftID), draft.clientID == client.id else {
            throw MCPStructuredError(code: .malformedRequest, message: "draftID was not found for this client.")
        }
        let digest = (arguments["responseEditPreviewDigest"] as? String)
            ?? (arguments["previewDigest"] as? String)
        guard let digest else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "responseEditPreviewDigest is required."
            )
        }
        let previewArgs: [String: Any] = [
            "responseEditPreviewDigest": digest,
            "__mcpInternalSessionID": arguments["__mcpInternalSessionID"] as Any
        ]
        guard let preview = try resolvedResponseEditPreviewIfRequested(arguments: previewArgs, client: client) else {
            throw MCPStructuredError(code: .staleProposal, message: "The response-edit preview is missing, consumed, or expired.")
        }
        guard preview.sessionID == draft.sourceSessionID else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "The preview belongs to a different source session than this draft."
            )
        }
        let plan = MCPMutationPlan(
            capability: .createResponseDraft,
            matcher: draft.matcher,
            proposedTargetID: draftID,
            effectKind: .responseDraft,
            effectSummary: "Commit response-edit preview into draft \(draftID.uuidString).",
            inlineBodyData: preview.patchedBody,
            inlineContentType: preview.contentType,
            inlineStatusCode: preview.statusCode,
            draftID: draftID,
            draftPreviewDigest: digest
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    func applyCommitResponseEdit(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        let store = try requireDraftStore()
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createResponseDraft, client: client)
        try resolveMutationApproval(
            toolName: "apply_commit_response_edit",
            arguments: arguments,
            client: client,
            capability: .createResponseDraft
        )
        guard let draftID = plan.draftID,
              let bodyData = plan.inlineBodyData,
              let statusCode = plan.inlineStatusCode,
              let contentType = plan.inlineContentType,
              let previewDigest = plan.draftPreviewDigest else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let bodySHA256 = sha256HexPublic(bodyData)
        var committedRevisionID: UUID?
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createResponseDraft,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .responseDraft,
                targetID: draftID.uuidString,
                baselineRevision: nil,
                intendedChangeDigest: proposal.argumentDigest,
                rollbackSnapshot: nil,
                expiresAt: MCPApprovalPolicy.expiration()
            ),
            performMutation: {
                let draft = try store.commitRevision(
                    draftID: draftID,
                    clientID: client.id,
                    bodyData: bodyData,
                    bodySHA256: bodySHA256,
                    statusCode: statusCode,
                    contentType: contentType,
                    previewDigest: previewDigest
                )
                committedRevisionID = draft.currentRevisionID
                self.consumeResponseEditPreview(digest: previewDigest)
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createResponseDraft, targetID: draftID.uuidString, detail: plan.effectSummary)
        var payload = try payloadDictionary(
            applyResultDTO(result: result, targetID: draftID.uuidString, isEnabled: false)
        )
        payload["currentRevisionID"] = committedRevisionID?.uuidString as Any
        if let draft = store.draft(id: draftID) {
            payload["draft"] = draftSummaryDictionary(draft)
        }
        return payload
    }

    func proposeDeleteResponseDraft(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        let store = try requireDraftStore()
        let draft = try ownedDraft(from: arguments, client: client, store: store)
        let liveRefs = await liveBoundOverrideIDs(for: draft)
        if !liveRefs.isEmpty {
            throw MCPStructuredError(
                code: .policyDenied,
                message: "Draft is referenced by Map Local rule(s): \(liveRefs.map(\.uuidString).joined(separator: ", ")). Disable/delete those rules first."
            )
        }
        let plan = MCPMutationPlan(
            capability: .createResponseDraft,
            matcher: draft.matcher,
            proposedTargetID: draft.id,
            effectKind: .responseDraft,
            effectSummary: "Delete response draft \(draft.id.uuidString).",
            draftID: draft.id
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    func applyDeleteResponseDraft(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createResponseDraft)
        let store = try requireDraftStore()
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createResponseDraft, client: client)
        try resolveMutationApproval(
            toolName: "apply_delete_response_draft",
            arguments: arguments,
            client: client,
            capability: .createResponseDraft
        )
        guard let draftID = plan.draftID else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        if let draft = store.draft(id: draftID) {
            let liveRefs = await liveBoundOverrideIDs(for: draft)
            if !liveRefs.isEmpty {
                throw MCPStructuredError(
                    code: .policyDenied,
                    message: "Draft is still referenced by Map Local rule(s)."
                )
            }
        }
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createResponseDraft,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .responseDraft,
                targetID: draftID.uuidString,
                baselineRevision: nil,
                intendedChangeDigest: proposal.argumentDigest,
                rollbackSnapshot: nil,
                expiresAt: MCPApprovalPolicy.expiration()
            ),
            performMutation: {
                try store.deleteDraft(id: draftID, clientID: client.id)
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createResponseDraft, targetID: draftID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: draftID.uuidString, isEnabled: false))
    }

    // MARK: - Draft helpers

    private func requireDraftStore() throws -> ResponseDraftStore {
        guard let store = responseDraftStore else {
            throw MCPStructuredError(code: .internalFailure, message: "Response draft store is unavailable.")
        }
        if !store.isLoaded {
            store.load()
        }
        guard store.isLoaded else {
            throw MCPStructuredError(
                code: .internalFailure,
                message: store.loadFailureReason ?? "Response draft store failed to load."
            )
        }
        return store
    }

    private func ownedDraft(
        from arguments: [String: Any],
        client: MCPClientRecord,
        store: ResponseDraftStore
    ) throws -> ResponseDraft {
        guard let draftIDString = arguments["draftID"] as? String,
              let draftID = UUID(uuidString: draftIDString),
              let draft = store.draft(id: draftID),
              draft.clientID == client.id else {
            throw MCPStructuredError(code: .malformedRequest, message: "draftID was not found for this client.")
        }
        return draft
    }

    private func prepareDraftBody(
        sessionID: UUID,
        arguments: [String: Any]
    ) throws -> (matcher: MCPMutationMatcher, bodyData: Data, statusCode: Int, contentType: String) {
        guard let snapshotService,
              let indexed = snapshotService.indexedSession(id: sessionID),
              let response = indexed.record.response,
              let rawBody = response.bodyData else {
            throw MCPStructuredError(code: .malformedRequest, message: "A captured response body is required.")
        }
        guard let decoded = CapturedBodyDecoder.decode(
            bodyData: rawBody,
            headers: response.headers,
            maxDecodedBytes: ResponseDraftStore.maxBodyBytesPerRevision
        ), decoded.canUseAnalysisDataForInspection,
        let bodyData = decoded.analysisUTF8Text().map({ Data($0.utf8) }),
        bodyData.count <= ResponseDraftStore.maxBodyBytesPerRevision else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "The captured response body is unavailable, encoded with an unsupported coding, or too large."
            )
        }
        let matcher = try MCPMutationMatcher(
            method: indexed.record.request.method,
            scheme: indexed.record.request.scheme,
            host: indexed.record.request.host,
            port: indexed.record.request.port,
            path: indexed.record.request.path,
            matchMode: ResponseOverrideMatchMode(
                rawValue: (arguments["matchMode"] as? String) ?? ResponseOverrideMatchMode.ignoreQuery.rawValue
            ) ?? .ignoreQuery
        )
        let contentType = response.headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value ?? "application/octet-stream"
        return (matcher, bodyData, response.statusCode, contentType)
    }

    private func liveBoundOverrideIDs(for draft: ResponseDraft) async -> [UUID] {
        let bound = Set(draft.boundOverrideIDsByRevisionID.values.flatMap { $0 })
        guard !bound.isEmpty else { return [] }
        let rules = await responseOverrideStore.rules()
        let live = Set(rules.map(\.id))
        return bound.filter { live.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    private func draftSummaryDictionary(_ draft: ResponseDraft) -> [String: Any] {
        [
            "draftID": draft.id.uuidString,
            "label": draft.label as Any,
            "sourceSessionID": draft.sourceSessionID.uuidString,
            "sourceCaptureSequence": draft.sourceCaptureSequence,
            "originalRevisionID": draft.originalRevisionID.uuidString,
            "currentRevisionID": draft.currentRevisionID.uuidString,
            "revisionCount": draft.revisions.count,
            "bodySHA256": draft.currentRevision?.bodySHA256 as Any,
            "statusCode": draft.currentRevision?.statusCode as Any,
            "contentType": draft.currentRevision?.contentType as Any,
            "createdAt": ISO8601DateFormatter().string(from: draft.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: draft.updatedAt)
        ]
    }

    private func draftDetailDictionary(_ draft: ResponseDraft) -> [String: Any] {
        var payload = draftSummaryDictionary(draft)
        payload["revisions"] = draft.revisions.map { revision in
            [
                "revisionID": revision.id.uuidString,
                "revisionIndex": revision.revisionIndex,
                "bodySHA256": revision.bodySHA256,
                "bodyByteCount": revision.bodyData.count,
                "statusCode": revision.statusCode,
                "contentType": revision.contentType,
                "parentRevisionID": revision.parentRevisionID?.uuidString as Any,
                "previewDigest": revision.previewDigest as Any,
                "createdAt": ISO8601DateFormatter().string(from: revision.createdAt)
            ] as [String: Any]
        }
        payload["matcher"] = [
            "method": draft.matcher.method,
            "scheme": draft.matcher.scheme.rawValue,
            "host": draft.matcher.host,
            "port": draft.matcher.port as Any,
            "path": draft.matcher.path,
            "matchMode": draft.matcher.matchMode.rawValue
        ]
        return payload
    }

    private func sha256HexPublic(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
