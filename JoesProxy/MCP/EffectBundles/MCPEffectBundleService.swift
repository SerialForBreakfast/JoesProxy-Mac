import Foundation

@MainActor
final class MCPEffectBundleService {
    private let repository: EffectBundleRepository
    private let activationCoordinator: EffectBundleActivationCoordinator
    private let proposalCoordinator: MCPProposalCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private let authoringService: CollectionMockAuthoringService?
    private let sessionStore: (any SessionStore)?
    private let inspectionService: EffectBundleInspectionService

    private var activationPlansByProposalToken: [String: EffectBundleActivationPlan] = [:]
    private var discardPlansByProposalToken: [String: EffectBundleDiscardPlan] = [:]

    struct EffectBundleActivationPlan: Equatable, Sendable {
        var bundleID: UUID
        var clientID: String
        var ttlSeconds: TimeInterval?
        var replaceConflicts: Bool
        var summary: String
        var reviewedRecord: EffectBundleRecord
    }

    struct EffectBundleDiscardPlan: Equatable, Sendable {
        var bundleID: UUID
        var clientID: String
        var summary: String
        var reviewedRecord: EffectBundleRecord
    }

    init(
        repository: EffectBundleRepository,
        activationCoordinator: EffectBundleActivationCoordinator,
        proposalCoordinator: MCPProposalCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore,
        authoringService: CollectionMockAuthoringService? = nil,
        sessionStore: (any SessionStore)? = nil,
        admissionSnapshot: @escaping () -> CaptureAdmissionBudget.Snapshot? = { nil }
    ) {
        self.repository = repository
        self.activationCoordinator = activationCoordinator
        self.proposalCoordinator = proposalCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        self.grantStore = grantStore
        self.auditStore = auditStore
        self.authoringService = authoringService
        self.sessionStore = sessionStore
        self.inspectionService = EffectBundleInspectionService(repository: repository, coordinator: activationCoordinator,
            admissionSnapshot: admissionSnapshot)
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "effect_bundle_compare":
            guard Set(arguments.keys).isSubset(of: ["baselineWindowID", "modifiedWindowID"]) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Allowed arguments: baselineWindowID, modifiedWindowID. Authority comes from the authenticated client.")
            }
            guard let baseline = (arguments["baselineWindowID"] as? String).flatMap(UUID.init(uuidString:)),
                  let modified = (arguments["modifiedWindowID"] as? String).flatMap(UUID.init(uuidString:)),
                  let diagnostics = activationCoordinator.diagnosticRuns else {
                throw MCPStructuredError(code: .malformedRequest, message: "Supply baselineWindowID and modifiedWindowID from explicit closed diagnostic windows; runtime window service must be available.")
            }
            let report = try diagnostics.compareExperimentWindows(baselineID: baseline, modifiedID: modified, requestingOwnerID: client.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(report)
            guard bytes.count <= EffectBundleJoinedInspection.maximumBytes else { throw EffectBundleJoinedInspection.InspectionError.responseBudgetExceeded }
            return ["schemaVersion": 1, "payload": try JSONSerialization.jsonObject(with: bytes)]
        case "effect_bundle_prepare":
            do {
                return try await prepareBundle(arguments: arguments, client: client)
            } catch let failure as CapturedMockPreparationFailure {
                throw MCPStructuredError(code: .malformedRequest, message: failure.message, details: failure.details)
            }
        case "effect_bundle_list":
            return try listBundles(arguments: arguments, client: client)
        case "effect_bundle_inspect":
            let result = try await inspectBundle(arguments: arguments, client: client)
            // Leave room for the protocol wrapper and its compact text summary.
            guard try JSONSerialization.data(withJSONObject: result).count <= MCPResourceBudget.maxResponseBytes - 4_096 else {
                throw MCPStructuredError(code: .conflict, message: "inspectionBudgetExceeded: inspect a narrower prepared resource set; no evidence marker was advanced.")
            }
            return result
        case "effect_bundle_import":
            do { return try await importBundle(arguments: arguments, client: client) }
            catch let error as CollectionMockAuthoringError { throw Self.lifecycleError(error) }
        case "effect_bundle_retire_preparation":
            guard Set(arguments.keys) == ["revisionID"],
                  let text = arguments["revisionID"] as? String, let id = UUID(uuidString: text),
                  let authoringService else {
                throw MCPStructuredError(code: .malformedRequest, message: "Supply only revisionID for an owned prepared handle.")
            }
            do {
                let changed = try await authoringService.retire(id: id, ownerID: client.id)
                return ["schemaVersion": 1, "payload": ["revisionID": id.uuidString,
                    "preparationState": "retired", "alreadyRetired": !changed,
                    "importedBundlesUnchanged": true]]
            } catch let error as CollectionMockAuthoringError { throw Self.lifecycleError(error) }
        case "propose_activate_effect_bundle":
            return try proposeActivate(arguments: arguments, client: client)
        case "apply_activate_effect_bundle":
            return try await applyActivate(arguments: arguments, client: client)
        case "effect_bundle_stop":
            return try await stopBundle(arguments: arguments, client: client)
        case "effect_bundle_advance":
            guard let id = (arguments["bundleID"] as? String).flatMap(UUID.init(uuidString:)),
                  let activation = (arguments["activationID"] as? String).flatMap(UUID.init(uuidString:)),
                  let phase = (arguments["expectedPhaseID"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw MCPStructuredError(code: .malformedRequest,
                    message: "Supply bundleID, activationID and expectedPhaseID from effect_bundle_inspect; all must be UUIDs.")
            }
            _ = try await activationCoordinator.advance(id: id, requestingOwnerID: client.id,
                activationID: activation, expectedPhaseID: phase)
            return ["schemaVersion": 1, "payload": ["bundleID": id.uuidString,
                "phase": try phasePayload(id: id), "isServing": repository.record(id: id)?.isServing ?? false]]
        case "propose_discard_effect_bundle":
            return try proposeDiscard(arguments: arguments, client: client)
        case "apply_discard_effect_bundle":
            return try await applyDiscard(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown effect bundle tool: \(name)")
        }
    }

    private static func lifecycleError(_ error: CollectionMockAuthoringError) -> MCPStructuredError {
        let recovery: String
        switch error {
        case .revisionRetired:
            recovery = "The handle was retired. Use a new key to prepare again; inspect bundleID to resolve any earlier import outcome."
        case .revisionNotFound:
            recovery = "No owned handle exists in this app process. Inspect a previously imported bundleID before preparing again."
        case .requestHistoryFull:
            recovery = "The bounded preparation history is full for this process. No automatic retry or app restart is performed."
        default:
            recovery = "Review the preparation inputs and retained capacity before retrying."
        }
        return MCPStructuredError(code: .conflict, message: "\(error.rawValue): \(recovery)",
            details: ["phase": "preparation", "reason": error.rawValue, "recommendedAction": recovery])
    }

    private func prepareBundle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard let authoringService, let sessionStore else {
            throw MCPStructuredError(code: .internalFailure, message: "Captured fixture preparation is unavailable.")
        }
        let input = try CapturedMockPreparationArguments(arguments)
        let sessionID = input.sessionID
        let name = input.name
        let key = input.idempotencyKey
        let address = input.clientAddress
        let draft = input.draftJSON
        let retained = sessionStore.record(for: sessionID)
        let response = try CapturedMockPreparationArguments.response(from: retained)
        guard let record = retained else { throw CollectionMockAuthoringError.invalidRequest }
        let scope = CapturedMockScope(host: record.request.host, scheme: record.request.scheme,
            port: record.request.port ?? (record.request.scheme == .https ? 443 : 80),
            path: record.request.path, clients: .address(address))
        let imageFiles = try CapturedMockImageArguments.decode(arguments["images"])
        var relatedInputs: [CapturedRelatedResponseInput] = []
        if let supplied = arguments["relatedResponsesJSON"] {
            guard let text = supplied as? String, text.utf8.count <= 65_536,
                  let entries = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
                  entries.count <= 8 else {
                throw CapturedMockPreparationFailure(reason: "invalidRelatedResponses", field: "relatedResponsesJSON",
                    recovery: "Supply a JSON array of at most eight captured responses (64 KiB maximum).")
            }
            var ids = Set<UUID>()
            for (index, suppliedEntry) in entries.enumerated() {
                var entry = suppliedEntry
                let field = "relatedResponses[\(index)]"
                guard let text = entry.removeValue(forKey: "sessionID") as? String,
                      let id = UUID(uuidString: text), id != sessionID, ids.insert(id).inserted,
                      let related = sessionStore.record(for: id), let body = related.response,
                      related.request.method == "GET" else {
                    throw CapturedMockPreparationFailure(reason: "sourceUnavailable", field: "\(field).sessionID",
                        recovery: "Select a distinct captured GET response, different from the primary source. No upstream refetch is performed.")
                }
                guard !body.bodyDeferred, !body.bodyTruncated, body.recordingBodyOmissionReason == nil,
                      body.bodyData != nil else {
                    throw CapturedMockPreparationFailure(reason: "bodyUnavailable", field: "\(field).sessionID",
                        recovery: "Wait for loading or select a complete related capture. No upstream refetch is performed.")
                }
                if let path = entry.removeValue(forKey: "targetPath") {
                    let targetScope = try CapturedMockExplicitTarget.scope(path: path, source: related.request,
                        clientAddress: address, field: "\(field).targetPath",
                        hasObservedTarget: entry["targetSessionID"] != nil,
                        hasIgnoredQueryNames: entry["ignoredQueryNames"] != nil)
                    relatedInputs.append(.init(sessionID: id, response: body, scope: targetScope,
                        editsJSON: try JSONSerialization.data(withJSONObject: entry), targetSessionID: nil))
                    continue
                }
                let targetID: UUID
                if let target = entry.removeValue(forKey: "targetSessionID") {
                    guard let text = target as? String, let parsed = UUID(uuidString: text) else {
                        throw CapturedMockPreparationFailure(reason: "invalidTarget", field: "\(field).targetSessionID",
                            recovery: "Supply the UUID of an observed GET request, not an invented endpoint.")
                    }
                    targetID = parsed
                } else { targetID = id }
                guard let target = sessionStore.record(for: targetID), target.request.method == "GET" else {
                    throw CapturedMockPreparationFailure(reason: "targetUnavailable", field: "\(field).targetSessionID",
                        recovery: "Select a captured GET request for the related response destination.")
                }
                let request = target.request
                relatedInputs.append(.init(sessionID: id, response: body,
                    scope: .init(host: request.host, scheme: request.scheme,
                        port: request.port ?? (request.scheme == .https ? 443 : 80), path: request.path,
                        clients: .address(address)), editsJSON: try JSONSerialization.data(withJSONObject: entry),
                    targetSessionID: targetID))
            }
        }
        do {
            let package = try await authoringService.prepareCapturedResponse(ownerID: client.id,
                idempotencyKey: key, name: name, response: response, draftJSON: Data(draft.utf8),
                scope: scope, appVersion: Bundle.main.marketingVersionOrDev, imageFiles: imageFiles,
                relatedInputs: relatedInputs)
            guard let metadata = package.manifest.authoring else {
                throw MCPStructuredError(code: .internalFailure, message: "Prepared revision metadata is missing.")
            }
            let preflight = try await authoringService.preflight(id: package.manifest.id, ownerID: client.id,
                snapshot: CapturedMockPreflightSnapshot.capture(from: sessionStore))
            return ["payload": ["revisionID": package.manifest.id.uuidString, "state": "prepared",
                "preflight": preflight.payload,
                "isServing": false, "sourceDigest": metadata.sourceDigest,
                "workflow": ExperimentWorkflowGuidance.prepared.payload,
                "beforeCount": metadata.beforeCount, "afterCount": metadata.afterCount,
                "nextAction": "effect_bundle_import", "clientAddress": address,
                "images": Self.revisionInspection(package, retainedRecord: nil)["images"] ?? [],
                "relatedResponses": Self.revisionInspection(package, retainedRecord: nil)["relatedResponses"] ?? [],
                "warnings": package.reviewAdvisories.map(\.message),
                "advisories": package.reviewAdvisories.map(\.payload),
                "limitations": ["Captured GET fixture only. Device routing and visible target outcomes require separate verification."]]]
        } catch let error as CollectionMockAuthoringError {
            if error == .invalidRequest {
                throw MCPStructuredError(code: .malformedRequest,
                    message: "invalidRequest: related entries allow sessionID, optional targetSessionID or targetPath, edits [{pointer,value}], images [{pointer,assetID}], identityLinks [{pointer,primaryPointer}], and optional ignoredQueryNames for observed targets only. Select complete captured GET sources; declare at least one identity link per response. Unknown fields and missing typed values are rejected.")
            }
            throw Self.lifecycleError(error)
        } catch {
            guard let failure = CapturedMockPreparationFailure.describe(error) else { throw error }
            throw MCPStructuredError(code: .malformedRequest, message: failure.message, details: failure.details)
        }
    }

    private func listBundles(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        let records = repository.records(ownedBy: client.id)
        let summaries = records.map { record -> [String: Any] in
            [
                "id": record.id.uuidString,
                "name": record.manifest.name,
                "notes": record.manifest.notes,
                "state": record.state.rawValue,
                "isServing": record.isServing,
                "responseEffectCount": record.manifest.responseEffects.count,
                "hlsSubstitutionCount": record.manifest.hlsSubstitutions.count,
                "assetCount": record.manifest.assets.count,
                "importedAt": ISO8601DateFormatter().string(from: record.importedAt),
                "activatedAt": record.activatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "expiresAt": record.expiresAt.map { ISO8601DateFormatter().string(from: $0) } as Any
            ]
        }
        return [
            "schemaVersion": 1,
            "payload": [
                "bundles": summaries,
                "count": summaries.count
            ] as [String: Any]
        ]
    }

    private func inspectBundle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard arguments["afterMarker"] == nil || arguments["bundleID"] != nil else {
            throw MCPStructuredError(code: .malformedRequest, message: "afterMarker requires a retained bundleID.")
        }
        guard ["revisionID", "bundleID", "packagePath"].filter({ arguments[$0] != nil }).count == 1 else {
            throw MCPStructuredError(code: .malformedRequest, message: "Supply exactly one of revisionID, bundleID, or packagePath.")
        }
        if let value = arguments["revisionID"] {
            guard let text = value as? String, let id = UUID(uuidString: text), let authoringService else {
                throw MCPStructuredError(code: .malformedRequest, message: "A valid revisionID and configured authoring service are required.")
            }
            let package: PreparedCapturedMockPackage
            do { package = try await authoringService.inspectCapturedPackage(id: id, ownerID: client.id) }
            catch let error as CollectionMockAuthoringError { throw Self.lifecycleError(error) }
            let retained = repository.record(id: id) != nil
            let record = retained ? try repository.metadataRecord(id: id, requestingOwnerID: client.id) : nil
            let joined = try await joinedInspection(manifest: package.manifest, ownerID: client.id, retained: retained)
            var payload = Self.revisionInspection(package, retainedRecord: record)
            payload["preflight"] = joined.preflight?.payload
            payload["joinedEvidence"] = try joined.payload()
            if let evidence = joined.deliveryEvidence, let record {
                let current = try repository.metadataRecord(id: id, requestingOwnerID: client.id)
                payload["state"] = current.state.rawValue
                payload["isServing"] = current.isServing
                payload["workflow"] = ExperimentWorkflowGuidance.retained(state: current.state, evidence: evidence,
                    lifecycleChanged: joined.lifecycleChangedDuringRead || current.state != record.state).payload
            } else {
                payload["workflow"] = ExperimentWorkflowGuidance.prepared.payload
            }
            return ["schemaVersion": 1, "payload": payload]
        }
        if let idString = arguments["bundleID"] as? String, let bundleID = UUID(uuidString: idString) {
            let record = try repository.metadataRecord(id: bundleID, requestingOwnerID: client.id)
            let manifest = record.manifest
            let after: UInt64
            if let value = arguments["afterMarker"] {
                guard let text = value as? String, let marker = UInt64(text) else {
                    throw MCPStructuredError(code: .malformedRequest, message: "afterMarker must be an unsigned decimal string, for example \"0\".")
                }
                after = marker
            } else { after = 0 }
            let joined = try await joinedInspection(manifest: manifest, ownerID: client.id, retained: true, after: after)
            guard let evidence = joined.deliveryEvidence else {
                throw MCPStructuredError(code: .internalFailure, message: "Retained evidence is unavailable.")
            }
            let evidenceJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
            let current = try repository.metadataRecord(id: bundleID, requestingOwnerID: client.id)
            return [
                "schemaVersion": 1,
                "payload": [
                    "id": manifest.id.uuidString,
                    "joinedEvidence": try joined.payload(),
                    "preflight": joined.preflight?.payload ?? ["state": "unavailable"],
                    "deliveryEvidence": evidenceJSON,
                    "phase": try phasePayload(id: manifest.id),
                    "supervision": try supervisionPayload(id: manifest.id, ownerID: client.id),
                    "timestampBindings": Self.timestampBindingSummary(manifest),
                    "mediaPlan": Self.mediaPlanSummary(manifest),
                    "terminationReason": repository.record(id: manifest.id)?.terminationReason?.rawValue as Any? ?? NSNull(),
                    "state": current.state.rawValue,
                    "isServing": current.isServing,
                    "revisionID": manifest.id.uuidString,
                    "workflow": ExperimentWorkflowGuidance.retained(state: current.state, evidence: evidence,
                        lifecycleChanged: joined.lifecycleChangedDuringRead || current.state != record.state).payload,
                    "name": manifest.name,
                    "notes": manifest.notes,
                    "responseEffectCount": manifest.responseEffects.count,
                    "hlsSubstitutionCount": manifest.hlsSubstitutions.count,
                    "assetCount": manifest.assets.count,
                    "assetByteCount": manifest.assets.reduce(0) { $0 + $1.byteCount },
                    "defaultTTLSeconds": manifest.defaultTTLSeconds,
                    "privacyWarning": manifest.privacy.warning
                ] as [String: Any]
            ]
        } else if let path = arguments["packagePath"] as? String {
            let engine = EffectBundlePackageEngine()
            let (_, inspection) = try engine.inspectPackage(at: URL(fileURLWithPath: path))
            return [
                "schemaVersion": 1,
                "payload": [
                    "id": inspection.id.uuidString,
                    "name": inspection.name,
                    "notes": inspection.notes,
                    "responseEffectCount": inspection.responseEffectCount,
                    "hlsSubstitutionCount": inspection.hlsSubstitutionCount,
                    "assetCount": inspection.assetCount,
                    "assetByteCount": inspection.assetByteCount,
                    "defaultTTLSeconds": inspection.defaultTTLSeconds,
                    "privacyWarning": inspection.privacyWarning
                ] as [String: Any]
            ]
        } else {
            throw MCPStructuredError(code: .malformedRequest, message: "bundleID or packagePath is required.")
        }
    }

    private func joinedInspection(manifest: EffectBundleManifest, ownerID: String, retained: Bool,
                                  after: UInt64 = 0) async throws -> EffectBundleJoinedInspection {
        do {
            return try await inspectionService.inspect(manifest: manifest, ownerID: ownerID, retained: retained,
                after: after, snapshot: { self.sessionStore.map { CapturedMockPreflightSnapshot.capture(from: $0) } })
        } catch EffectBundleJoinedInspection.InspectionError.responseBudgetExceeded {
            throw MCPStructuredError(code: .conflict, message: "inspectionBudgetExceeded: narrow the prepared resource set; no evidence marker was advanced.")
        } catch EffectBundleJoinedInspection.InspectionError.revisionMismatch {
            throw MCPStructuredError(code: .conflict, message: "revisionMismatch: inspect the current owned bundle before retrying.")
        }
    }

    private static func timestampBindingSummary(_ manifest: EffectBundleManifest) -> [String: Any] {
        let bindings = (manifest.phases ?? []).flatMap(\.timestampBindings)
        return ["format": "ISO-8601 UTC milliseconds", "anchor": "activation start",
                "count": bindings.count, "previewTruncated": bindings.count > 8,
                "preview": bindings.prefix(8).map {
                    ["responseEffectID": $0.responseEffectID.uuidString,
                     "jsonPointer": $0.jsonPointer, "offsetSeconds": $0.offsetSeconds] as [String: Any]
                }]
    }

    static func mediaPlanSummary(_ manifest: EffectBundleManifest) -> [String: Any] {
        ["scope": "Each HLS definition carries its own reviewed policy; absent policy retains legacy all-client scope.",
         "definitions": manifest.hlsSubstitutions.map { effect in
             ["id": effect.id.uuidString, "replacesSubstitutionID": effect.replacesSubstitutionID?.uuidString as Any? ?? NSNull(),
              "requestPolicy": effect.requestPolicy?.summary ?? HLSRequestPolicy.legacySummary,
              "scopePolicy": HLSRequestPolicy.disclosure(effect.requestPolicy)] as [String: Any]
         },
         "phases": (manifest.phases ?? []).map { phase in
             ["phaseID": phase.id.uuidString, "startOrSwitchIDs": phase.hlsSubstitutionIDs.map(\.uuidString),
              "completeIDs": (phase.completeHLSSubstitutionIDs ?? []).map(\.uuidString)] as [String: Any]
         },
         "evidence": "Publication state and ENDLIST do not prove downstream delivery or target playback."]
    }

    private func supervisionPayload(id: UUID, ownerID: String) throws -> Any {
        let value = try activationCoordinator.supervision(id: id, requestingOwnerID: ownerID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    /// Metadata projection only: never include body bytes, local file paths, or draft item values.
    static func revisionInspection(_ package: PreparedCapturedMockPackage,
                                   retainedRecord: EffectBundleRecord?) -> [String: Any] {
        let manifest = package.manifest
        var result: [String: Any] = [
            "revisionID": manifest.id.uuidString, "name": manifest.name,
            "state": retainedRecord?.state.rawValue ?? "prepared",
            "isServing": retainedRecord?.isServing ?? false,
            "defaultTTLSeconds": manifest.defaultTTLSeconds,
            "privacyWarning": manifest.privacy.warning,
            "targetOutcome": "unknown",
            "assets": manifest.assets.map { asset -> [String: Any] in
                var metadata: [String: Any] = ["id": asset.id, "sha256": asset.sha256,
                    "byteCount": asset.byteCount, "role": asset.role.rawValue]
                if let contentType = asset.contentType { metadata["contentType"] = contentType }
                return metadata
            },
            "responseEffects": manifest.responseEffects.map { effect -> [String: Any] in
                var metadata: [String: Any] = ["method": effect.requestMethod,
                    "scheme": effect.requestScheme.rawValue, "host": effect.host, "path": effect.path,
                    "matchMode": effect.matchMode.rawValue, "statusCode": effect.statusCode,
                    "assetIDs": effect.bodySource.assetIDs]
                if let port = effect.port { metadata["port"] = port }
                metadata["clientScope"] = effect.sourceClientAddress ?? "allClients"
                metadata["ignoredQueryNames"] = effect.ignoredQueryNames ?? []
                metadata["queryPolicy"] = effect.ignoredQueryNames == nil ? "existingMatchMode" : "allOtherQueryItemsMustMatch"
                return metadata
            },
            "images": package.images.map { image -> [String: Any] in
                ["assetID": image.assetID, "url": image.url, "sha256": image.sha256,
                 "contentType": image.contentType, "width": image.width, "height": image.height,
                 "byteCount": image.byteCount, "retainsOriginalURL": image.retainsOriginalURL,
                 "imageReference": image.imageReference ?? image.url]
            }
        ]
        if let authoring = manifest.authoring {
            result["mode"] = authoring.mode.rawValue
            result["sourceDigest"] = authoring.sourceDigest
            result["beforeCount"] = authoring.beforeCount
            result["afterCount"] = authoring.afterCount
            let changes = authoring.reviewedChanges ?? []
            result["reviewedChanges"] = changes.prefix(32).map { String($0.prefix(256)) }
            result["reviewedChangesTruncated"] = authoring.reviewedChangesTruncated == true
                || changes.count > 32 || changes.contains { $0.count > 256 }
            result["relatedResponses"] = (authoring.relatedResponses ?? []).map { related -> [String: Any] in
                var info: [String: Any] = ["assetID": related.assetID, "sourceDigest": related.sourceDigest,
                    "changedPointers": related.changedPointers,
                    "images": related.images.map { ["pointer": $0.pointer, "assetID": $0.assetID] },
                    "identityLinks": related.identityLinks.map { ["pointer": $0.pointer, "primaryPointer": $0.primaryPointer] }]
                if let id = related.sourceSessionID { info["sourceSessionID"] = id.uuidString }
                if let id = related.targetSessionID { info["targetSessionID"] = id.uuidString }
                info["targetEvidence"] = related.targetSessionID == nil ? "unobserved" : "captured"
                if related.targetSessionID == nil {
                    info["limitation"] = "Authored destination; no captured target request is linked. Preparation does not prove the client will request or accept this response."
                }
                return info
            }
        }
        result["advisories"] = package.reviewAdvisories.map(\.payload)
        return result
    }

    private func importBundle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard (arguments["packagePath"] == nil) != (arguments["revisionID"] == nil) else {
            throw MCPStructuredError(code: .malformedRequest,
                message: "Supply exactly one of packagePath or revisionID.")
        }
        let owner = EffectBundleOwner.mcpClient(id: client.id, displayName: client.displayName)
        let record: EffectBundleRecord
        if let value = arguments["revisionID"] {
            guard let text = value as? String, let id = UUID(uuidString: text) else {
                throw MCPStructuredError(code: .malformedRequest, message: "revisionID must be a UUID.")
            }
            guard let authoringService else {
                throw MCPStructuredError(code: .malformedRequest, message: "Prepared revision import is unavailable in this configuration.")
            }
            record = try await repository.importPreparedRevision(id: id, owner: owner, authoringService: authoringService)
        } else {
            guard let path = arguments["packagePath"] as? String, !path.isEmpty else {
                throw MCPStructuredError(code: .malformedRequest, message: "packagePath must be a nonempty string.")
            }
            record = try repository.importPackage(at: URL(fileURLWithPath: path), owner: owner)
        }
        return [
            "schemaVersion": 1,
            "payload": [
                "id": record.id.uuidString,
                "name": record.manifest.name,
                "state": record.state.rawValue,
                "isServing": record.isServing,
                "workflow": ExperimentWorkflowGuidance.retained(state: record.state,
                    evidence: .init(receipts: [], nextMarker: 0, retentionGap: false, hasMore: false,
                        observationState: "notObserved")).payload,
                "importedAt": ISO8601DateFormatter().string(from: record.importedAt)
            ] as [String: Any]
        ]
    }

    private func phasePayload(id: UUID) throws -> Any {
        guard let phase = activationCoordinator.phaseSnapshots[id] else { return NSNull() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(phase))
    }

    private func proposeActivate(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireMutationAccess(client: client, capability: .enableRule)
        guard let idString = arguments["bundleID"] as? String, let bundleID = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "bundleID is required.")
        }
        guard let record = repository.record(id: bundleID), record.owner.ownerID == client.id else {
            throw MCPStructuredError(code: .conflict, message: "Effect bundle not found or not owned by client.")
        }
        let ttl = arguments["ttlSeconds"] as? TimeInterval
        let replaceConflicts = (arguments["replaceConflicts"] as? Bool) ?? false
        let unobservedCount = (record.manifest.authoring?.relatedResponses ?? []).filter { $0.targetSessionID == nil }.count
        let phaseSummary = (record.manifest.phases ?? []).map { "\($0.label): \($0.durationSeconds)s, start/switch \($0.hlsSubstitutionIDs.count), complete \($0.completeHLSSubstitutionIDs?.count ?? 0)" }.joined(separator: "; ")
        let mediaScope = record.manifest.hlsSubstitutions.map {
            " HLS \($0.id): \($0.requestPolicy?.summary ?? HLSRequestPolicy.legacySummary)"
        }.joined()
        let summary = "Activate effect bundle '\(record.manifest.name)' (\(record.manifest.responseEffects.count) response effects, \(record.manifest.hlsSubstitutions.count) HLS definitions). Reviewed phases: \(phaseSummary.isEmpty ? "none" : phaseSummary). Advance never extends expiry; sleep ends timed runs.\(mediaScope) \(unobservedCount) related destinations have no linked target capture; client requests and API compatibility are unverified."
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))

        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .enableRule,
            argumentDigest: digest,
            targetRevision: .init(rawValue: record.id.uuidString),
            targetLockKey: "effect-bundle:\(bundleID.uuidString)"
        )

        activationPlansByProposalToken[proposal.token] = EffectBundleActivationPlan(
            bundleID: bundleID,
            clientID: client.id,
            ttlSeconds: ttl,
            replaceConflicts: replaceConflicts,
            summary: summary,
            reviewedRecord: record
        )

        return [
            "schemaVersion": 1,
            "payload": [
                "proposalToken": proposal.token,
                "summary": summary
            ] as [String: Any]
        ]
    }

    private func applyActivate(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard let token = arguments["proposalToken"] as? String else {
            throw MCPStructuredError(code: .malformedRequest, message: "proposalToken is required.")
        }
        guard let plan = activationPlansByProposalToken[token], plan.clientID == client.id else {
            throw MCPStructuredError(code: .staleProposal, message: "Invalid or expired proposal token.")
        }

        var activated: EffectBundleActivationReceipt?
        do {
            _ = try await applyReviewedProposal(tool: "apply_activate_effect_bundle", arguments: arguments,
                client: client, capability: .enableRule, reviewed: plan.reviewedRecord, summary: plan.summary) {
                activated = try await self.activationCoordinator.activate(id: plan.bundleID,
                    requestingOwnerID: client.id, ttl: plan.ttlSeconds, reviewedRecord: plan.reviewedRecord)
            }
        } catch {
            // A journal-commit failure after activation must not leave an unreported live bundle.
            if activated != nil { try? await activationCoordinator.stop(id: plan.bundleID, requestingOwnerID: client.id) }
            throw error
        }
        guard let receipt = activated else {
            throw MCPStructuredError(code: .internalFailure, message: "Activation receipt unavailable; inspect the retained bundle.")
        }
        activationPlansByProposalToken.removeValue(forKey: token)

        return [
            "schemaVersion": 1,
            "payload": [
                "bundleID": receipt.bundleID.uuidString,
                "responseRuleIDs": receipt.responseRuleIDs.map(\.uuidString),
                "hlsExperimentIDs": receipt.hlsExperimentIDs.map(\.uuidString),
                "activatedAt": ISO8601DateFormatter().string(from: receipt.activatedAt),
                "workflow": ExperimentWorkflowGuidance.activated.payload,
                "expiresAt": ISO8601DateFormatter().string(from: receipt.expiresAt)
            ] as [String: Any]
        ]
    }

    private func stopBundle(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard let idString = arguments["bundleID"] as? String, let bundleID = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "bundleID is required.")
        }
        try await activationCoordinator.stop(id: bundleID, requestingOwnerID: client.id)
        return [
            "schemaVersion": 1,
            "payload": [
                "bundleID": bundleID.uuidString,
                "stopped": true,
                "workflow": ExperimentWorkflowGuidance.stopped.payload
            ] as [String: Any]
        ]
    }

    private func requireMutationAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        guard MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
            .effectiveAllows(capability: capability, client: client) else {
            throw MCPStructuredError(code: .policyDenied, message: "Current policy does not allow this bundle operation.")
        }
    }

    /// Uses the existing approval nonce, proposal lock and recovery journal. The retained record
    /// is checked before consuming approval and again by activation after its actor hop.
    private func applyReviewedProposal(tool: String, arguments: [String: Any], client: MCPClientRecord,
                                       capability: MCPCapabilityID, reviewed: EffectBundleRecord, summary: String,
                                       mutation: () async throws -> Void) async throws -> MCPProposalApplyResult {
        try requireMutationAccess(client: client, capability: capability)
        guard let token = arguments["proposalToken"] as? String,
              let proposal = proposalCoordinator.proposal(forToken: token),
              proposal.clientID == client.id, proposal.capability == capability, !proposal.consumed,
              proposal.policyRevision == policyStore.policyRevision else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal expired, was used, or its policy changed; inspect and propose again.")
        }
        let current = try repository.metadataRecord(id: reviewed.id, requestingOwnerID: client.id)
        guard current == reviewed else {
            approvalStore.invalidate(proposalToken: token)
            throw MCPStructuredError(code: .staleTargetRevision, message: "Bundle changed since review; inspect and propose again.")
        }
        let revision = MCPTargetRevision(rawValue: reviewed.id.uuidString)
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
        var approved = false
        if let authorization = MCPArgumentDigest.authorization(from: arguments) {
            guard !approvalStore.nonceAlreadyUsed(authorization.nonce) else {
                throw MCPStructuredError(code: .approvalReused, message: "Approval was already used.")
            }
            guard !approvalStore.nonceExpired(authorization.nonce) else {
                throw MCPStructuredError(code: .approvalExpired, message: "Approval expired.")
            }
            guard let granted = approvalStore.grantedAuthorization(nonce: authorization.nonce),
                  MCPApprovalValidation.validateRetry(request: granted.request, authorization: granted.authorization,
                    currentClientID: client.id, currentCapability: capability, normalizedArgumentDigest: digest,
                    currentPolicyRevision: policyStore.policyRevision, currentTargetRevision: revision,
                    nonceAlreadyUsed: false) == nil else {
                throw MCPStructuredError(code: .malformedRequest, message: "Approval does not match this reviewed operation.")
            }
            approvalStore.consumeNonce(authorization.nonce)
            approved = true
        }
        if !approved {
            approved = approvalStore.consumeApprovedRequest(clientID: client.id,
                mcpSessionID: arguments["__mcpInternalSessionID"] as? String, capability: capability,
                argumentDigest: digest, policyRevision: policyStore.policyRevision,
                targetRevision: revision, proposalToken: token)
        }
        if !approved && !evaluator.skipsApprovalNonce(capability: capability, client: client) {
            proposalCoordinator.extendProposal(token: token, through: Date().addingTimeInterval(MCPApprovalPolicy.defaultLifetime))
            let request = approvalStore.createPendingRequest(clientID: client.id, capability: capability,
                argumentDigest: digest, policyRevision: policyStore.policyRevision, targetRevision: revision,
                mcpSessionID: arguments["__mcpInternalSessionID"] as? String, proposalToken: token,
                reason: "\(tool) requires in-app approval. \(summary)")
            throw MCPStructuredError.approvalRequired(request)
        }
        do {
            let result = try await proposalCoordinator.applyProposal(token: token, clientID: client.id,
                capability: capability, argumentDigest: proposal.argumentDigest, currentTargetRevision: revision,
                mutationIntent: .init(clientID: client.id, targetKind: .effectBundle, targetID: reviewed.id.uuidString,
                    baselineRevision: revision, intendedChangeDigest: proposal.argumentDigest,
                    rollbackSnapshot: nil, expiresAt: MCPApprovalPolicy.expiration()), performMutation: {
                    try await mutation()
                    return nil
                })
            auditStore.record(MCPAuditEvent(id: UUID(), kind: .proposalApplied, timestamp: Date(), clientID: client.id,
                credentialFingerprint: nil, sourceProcess: nil, reasonCode: "\(capability.rawValue):\(reviewed.id)",
                detail: "Applied reviewed bundle operation \(tool)."))
            return result
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        }
    }

    private func proposeDiscard(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireMutationAccess(client: client, capability: .deleteRule)
        guard let idString = arguments["bundleID"] as? String, let bundleID = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "bundleID is required.")
        }
        guard let record = repository.record(id: bundleID), record.owner.ownerID == client.id else {
            throw MCPStructuredError(code: .conflict, message: "Effect bundle not found or not owned by client.")
        }
        let summary = "Discard effect bundle '\(record.manifest.name)'"
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))

        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .deleteRule,
            argumentDigest: digest,
            targetRevision: .init(rawValue: record.id.uuidString),
            targetLockKey: "effect-bundle:\(bundleID.uuidString)"
        )

        discardPlansByProposalToken[proposal.token] = EffectBundleDiscardPlan(
            bundleID: bundleID,
            clientID: client.id,
            summary: summary,
            reviewedRecord: record
        )

        return [
            "schemaVersion": 1,
            "payload": [
                "proposalToken": proposal.token,
                "summary": summary
            ] as [String: Any]
        ]
    }

    private func applyDiscard(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        guard let token = arguments["proposalToken"] as? String else {
            throw MCPStructuredError(code: .malformedRequest, message: "proposalToken is required.")
        }
        guard let plan = discardPlansByProposalToken[token], plan.clientID == client.id else {
            throw MCPStructuredError(code: .staleProposal, message: "Invalid or expired proposal token.")
        }

        _ = try await applyReviewedProposal(tool: "apply_discard_effect_bundle", arguments: arguments,
            client: client, capability: .deleteRule, reviewed: plan.reviewedRecord, summary: plan.summary) {
            try self.repository.discard(id: plan.bundleID, requestingOwnerID: client.id)
        }
        discardPlansByProposalToken.removeValue(forKey: token)

        return [
            "schemaVersion": 1,
            "payload": [
                "bundleID": plan.bundleID.uuidString,
                "discarded": true
            ] as [String: Any]
        ]
    }
}
