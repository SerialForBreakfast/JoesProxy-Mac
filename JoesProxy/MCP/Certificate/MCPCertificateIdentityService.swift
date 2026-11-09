import Foundation

/// Pending propose→apply plan for a fingerprint-targeted certificate cleanup.
struct CertificateCleanupPlan: Equatable, Sendable {
    var fingerprint: String
    var allowCurrentRoot: Bool
    var clientID: String
    var effectSummary: String
}

/// MCP surface for Phase C certificate identity reads and fingerprint-targeted trust cleanup.
///
/// Owns no persistence of its own: the CA-instance and distribution stores are the same instances
/// ``ProxyViewModel`` mutates, because both write by rewriting the whole JSON sidecar — a second
/// in-memory copy would silently revert the other's edits on its next persist.
///
/// Concurrency: `@MainActor` — reads Keychain trust state and main-actor metadata stores.
@MainActor
final class MCPCertificateIdentityService {
    private let configuration: AppConfiguration
    private let certificateStore: any CertificateStore
    private let trustInstaller: any TrustInstalling
    private let trustCleaner: any CertificateFingerprintTrustCleaning
    private let metadataStore: CAInstanceMetadataStore
    private let distributionStore: CertificateDistributionRecordStore
    private let proposalCoordinator: MCPProposalCoordinator
    private let approvalStore: MCPApprovalStore
    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private var plansByProposalToken: [String: CertificateCleanupPlan] = [:]

    /// Cap on artifact rows returned by `certificate_artifacts_list`.
    private static let artifactPageLimit = 50

    private var policyEvaluator: MCPPolicyEvaluator {
        MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
    }

    init(
        configuration: AppConfiguration,
        certificateStore: any CertificateStore,
        trustInstaller: any TrustInstalling,
        trustCleaner: any CertificateFingerprintTrustCleaning,
        metadataStore: CAInstanceMetadataStore,
        distributionStore: CertificateDistributionRecordStore,
        proposalCoordinator: MCPProposalCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore
    ) {
        self.configuration = configuration
        self.certificateStore = certificateStore
        self.trustInstaller = trustInstaller
        self.trustCleaner = trustCleaner
        self.metadataStore = metadataStore
        self.distributionStore = distributionStore
        self.proposalCoordinator = proposalCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        self.grantStore = grantStore
        self.auditStore = auditStore
    }

    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "certificate_status":
            return try status(client: client)
        case "certificate_identity":
            return try identity(client: client)
        case "certificate_artifacts_list":
            return try artifactsList(arguments: arguments, client: client)
        case "certificate_export":
            return try exportCertificate(client: client)
        case "certificate_compare":
            return try compare(arguments: arguments, client: client)
        case "propose_certificate_cleanup":
            return try proposeCleanup(arguments: arguments, client: client)
        case "apply_certificate_cleanup":
            return try await applyCleanup(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown certificate tool: \(name).")
        }
    }

    // MARK: - Read tools

    private func status(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateStatus)
        let root = liveRoot()
        return CertificateIdentityProjection.statusPayload(
            root: root,
            metadata: metadata(forRoot: root),
            trustStatus: trustInstaller.installationStatus(for: configuration.certificateLabel)
        )
    }

    /// Exports the plain public root CA certificate (DER, base64-encoded) — never the private key.
    /// Intended for trust stores outside the Apple-platform profile flows (e.g. a Docker container).
    private func exportCertificate(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateExport)
        guard let root = liveRoot() else {
            throw MCPStructuredError(
                code: .internalFailure,
                message: "No root certificate available. Complete HTTPS setup first."
            )
        }
        return [
            "certificateDataBase64": root.certificateData.base64EncodedString(),
            "certificateSHA256Fingerprint": liveFingerprint(root) as Any,
            "filename": "JoesProxy-Root-CA.cer"
        ]
    }

    private func identity(client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateIdentity)
        let root = liveRoot()
        let metadata = metadata(forRoot: root)
        return [
            "caInstanceID": metadata?.id.uuidString as Any,
            "shortCode": metadata?.shortCode as Any,
            "certificateSHA256Fingerprint": liveFingerprint(root) as Any,
            "serialNumber": metadata?.certificateSerialNumber as Any,
            "nickname": metadata?.nickname as Any,
            "storageState": metadata?.storageState.rawValue as Any,
            "renewalState": metadata?.renewalState?.rawValue as Any,
            "status": CertificateIdentityExtraction.evaluateIdentityStatus(
                rootCertificateData: root?.certificateData,
                metadata: metadata
            ).title
        ]
    }

    /// Lists distribution artifacts, honoring an explicit `fingerprint` filter and defaulting to
    /// the live root only when the caller did not supply one.
    private func artifactsList(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateArtifactsList)
        let requested = (arguments["fingerprint"] as? String).map(Self.normalizedFingerprint)
        let filter = requested ?? liveFingerprint(liveRoot())
        let records = filter.map { distributionStore.records(forFingerprint: $0) } ?? distributionStore.records
        let projected = records.prefix(Self.artifactPageLimit).map { record -> [String: Any] in
            [
                "artifactID": record.artifactID.uuidString,
                "caInstanceID": record.caInstanceID.uuidString,
                "shortCode": record.shortCode,
                "certificateSHA256Fingerprint": record.certificateSHA256Fingerprint,
                "profileKind": record.profileKind.rawValue,
                "payloadIdentifier": record.payloadIdentifier,
                "generatedAt": MCPApprovalPolicy.iso8601String(from: record.generatedAt),
                "status": record.status.rawValue,
                "resolvedHost": record.resolvedHost as Any,
                "proxyPort": record.proxyPort as Any
            ]
        }
        return [
            "artifacts": Array(projected),
            "fingerprintFilter": filter as Any,
            "count": projected.count,
            "truncated": records.count > Self.artifactPageLimit
        ]
    }

    private func compare(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateCompare)
        guard let left = arguments["fingerprint"] as? String,
              let right = arguments["otherFingerprint"] as? String else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "certificate_compare requires fingerprint and otherFingerprint."
            )
        }
        return CertificateIdentityProjection.compare(fingerprintA: left, fingerprintB: right)
    }

    // MARK: - Cleanup propose/apply

    private func proposeCleanup(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateCleanup)
        guard let target = arguments["fingerprint"] as? String, !target.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "propose_certificate_cleanup requires fingerprint.")
        }
        let normalized = Self.normalizedFingerprint(target)
        let allowCurrent = arguments["allowCurrentRoot"] as? Bool == true
        try requireNotActiveRoot(normalized, allowCurrent: allowCurrent)

        let effectSummary = allowCurrent
            ? "Retire CA \(normalized) and remove its installed trust material and active Keychain root."
            : "Retire CA \(normalized) and remove its installed trust material."
        let plan = CertificateCleanupPlan(
            fingerprint: normalized,
            allowCurrentRoot: allowCurrent,
            clientID: client.id,
            effectSummary: effectSummary
        )
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: .certificateCleanup,
            argumentDigest: digest,
            targetRevision: nil,
            targetLockKey: "certificate-cleanup:\(normalized)"
        )
        plansByProposalToken[proposal.token] = plan
        return [
            "proposal": "certificate_cleanup",
            "proposalToken": proposal.token,
            "expiresAt": MCPApprovalPolicy.iso8601String(from: proposal.expiresAt),
            "targetLockKey": proposal.targetLockKey,
            "fingerprint": normalized,
            "allowCurrentRoot": allowCurrent,
            "riskTier": MCPCapabilityID.certificateCleanup.riskTier.rawValue,
            "effect": "Marks matching CA metadata and distribution records retired; removes matching installed trust material by fingerprint. Does not wipe the active Keychain root unless allowCurrentRoot is set.",
            "effectSummary": effectSummary,
            "next": "apply_certificate_cleanup"
        ]
    }

    private func applyCleanup(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireAccess(client: client, capability: .certificateCleanup)
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "proposalToken is required.")
        }
        guard let proposal = proposalCoordinator.proposal(forToken: proposalToken),
              proposal.clientID == client.id,
              proposal.capability == .certificateCleanup,
              let plan = plansByProposalToken[proposalToken],
              plan.clientID == client.id else {
            approvalStore.invalidate(proposalToken: proposalToken)
            plansByProposalToken.removeValue(forKey: proposalToken)
            throw MCPStructuredError(code: .staleProposal, message: "Certificate cleanup proposal is stale or unknown.")
        }
        // Re-checked at apply time: the active root can change between propose and apply.
        try requireNotActiveRoot(plan.fingerprint, allowCurrent: plan.allowCurrentRoot)
        try resolveLifecycleApproval(
            toolName: "apply_certificate_cleanup",
            arguments: arguments,
            client: client,
            capability: .certificateCleanup,
            proposalToken: proposalToken,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String
        )

        var outcome = CleanupOutcome()
        let result: MCPProposalApplyResult
        do {
            result = try await proposalCoordinator.applyProposal(
                token: proposalToken,
                clientID: client.id,
                capability: .certificateCleanup,
                argumentDigest: proposal.argumentDigest,
                currentTargetRevision: nil,
                mutationIntent: MCPMutationIntent(
                    clientID: client.id,
                    targetKind: .certificateTrustCleanup,
                    targetID: plan.fingerprint,
                    baselineRevision: nil,
                    intendedChangeDigest: proposal.argumentDigest,
                    rollbackSnapshot: nil,
                    expiresAt: MCPApprovalPolicy.expiration()
                ),
                performMutation: {
                    outcome = try self.performCleanup(plan: plan)
                    return nil
                },
                idempotencyKey: idempotencyKey(from: arguments, proposalToken: proposalToken)
            )
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        } catch let error as MCPRecoveryCoordinatorError {
            switch error {
            case .journalUnavailable:
                throw proposalCoordinator.structuredError(for: .journalUnavailable)
            default:
                throw MCPStructuredError(code: .conflict, message: "Certificate cleanup conflicted with recovery state.")
            }
        }
        plansByProposalToken.removeValue(forKey: proposalToken)
        recordApplied(client: client, targetID: plan.fingerprint, detail: plan.effectSummary)
        return [
            "cleanedFingerprint": plan.fingerprint,
            "metadataRetired": outcome.metadataRetired,
            "distributionRecordsRetired": outcome.distributionRecordsRetired,
            "installedCertificatesRemoved": outcome.installedCertificatesRemoved,
            "activeRootRemoved": outcome.activeRootRemoved,
            "transactionID": result.transactionID,
            "appliedAt": MCPApprovalPolicy.iso8601String(from: result.appliedAt)
        ]
    }

    /// What the cleanup actually changed — reported verbatim so callers never see a fabricated
    /// success for a fingerprint that matched nothing.
    private struct CleanupOutcome {
        var metadataRetired = false
        var distributionRecordsRetired = 0
        var installedCertificatesRemoved = 0
        var activeRootRemoved = false
    }

    private func performCleanup(plan: CertificateCleanupPlan) throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        if metadataStore.metadata(forFingerprint: plan.fingerprint) != nil {
            _ = try metadataStore.markRetired(fingerprint: plan.fingerprint)
            outcome.metadataRetired = true
        }
        outcome.distributionRecordsRetired = try distributionStore.markRetired(fingerprint: plan.fingerprint)
        outcome.installedCertificatesRemoved = try trustCleaner.removeInstalledCertificate(
            matchingFingerprint: plan.fingerprint,
            label: configuration.certificateLabel
        )
        if plan.allowCurrentRoot, liveFingerprint(liveRoot()) == plan.fingerprint {
            try certificateStore.removeRootCertificate(label: configuration.certificateLabel)
            outcome.activeRootRemoved = true
        }
        return outcome
    }

    // MARK: - Helpers

    private func liveRoot() -> RootCertificateIdentity? {
        certificateStore.loadRootCertificate(label: configuration.certificateLabel)
    }

    private func liveFingerprint(_ root: RootCertificateIdentity?) -> String? {
        root.map { CertificateIdentityExtraction.sha256Fingerprint(from: $0.certificateData) }
    }

    private func metadata(forRoot root: RootCertificateIdentity?) -> CAInstanceMetadata? {
        liveFingerprint(root).flatMap { metadataStore.metadata(forFingerprint: $0) }
    }

    private static func normalizedFingerprint(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }

    private func requireNotActiveRoot(_ fingerprint: String, allowCurrent: Bool) throws {
        guard !allowCurrent else { return }
        guard liveFingerprint(liveRoot()) == fingerprint else { return }
        throw MCPStructuredError(
            code: .conflict,
            message: "Refusing to cleanup the active .current root without allowCurrentRoot=true."
        )
    }

    private func requireAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Certificate tools denied by profile or policy."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Profile or policy denies \(capability.rawValue).")
        }
    }

    private func resolveLifecycleApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        proposalToken: String,
        mcpSessionID: String?
    ) throws {
        let boundArguments = MCPArgumentDigest.dispatchArguments(arguments)
        let digest = MCPArgumentDigest.normalized(boundArguments)
        if let presentedAuthorization = MCPArgumentDigest.authorization(from: arguments) {
            if approvalStore.nonceAlreadyUsed(presentedAuthorization.nonce) {
                throw approvalValidationError(.reused)
            }
            if approvalStore.nonceExpired(presentedAuthorization.nonce) {
                throw approvalValidationError(.expired)
            }
            if let granted = approvalStore.grantedAuthorization(nonce: presentedAuthorization.nonce) {
                if let failure = MCPApprovalValidation.validateRetry(
                    request: granted.request,
                    authorization: granted.authorization,
                    currentClientID: client.id,
                    currentCapability: capability,
                    normalizedArgumentDigest: digest,
                    currentPolicyRevision: policyStore.policyRevision,
                    currentTargetRevision: nil,
                    nonceAlreadyUsed: false
                ) {
                    throw approvalValidationError(failure)
                }
                approvalStore.consumeNonce(granted.authorization.nonce)
                return
            }
        }
        if approvalStore.consumeApprovedRequest(
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            proposalToken: proposalToken
        ) {
            return
        }
        // Deliberately no `skipsApprovalNonce` bypass: certificate cleanup deletes trust material,
        // so a standing grant must not stand in for an explicit in-app confirmation.
        let reason = "\(toolName) requires in-app approval to remove CA trust material."
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            targetRevision: nil,
            mcpSessionID: mcpSessionID,
            proposalToken: proposalToken,
            reason: reason
        )
        throw MCPStructuredError.approvalRequired(request)
    }

    private func approvalValidationError(_ failure: MCPApprovalValidation.Failure) -> MCPStructuredError {
        switch failure {
        case .expired:
            return MCPStructuredError(code: .approvalExpired, message: "Approval authorization expired.")
        case .reused:
            return MCPStructuredError(code: .approvalReused, message: "Approval authorization was already used.")
        case .argumentMismatch:
            return MCPStructuredError(code: .malformedRequest, message: "Approval authorization does not match request arguments.")
        case .policyTightened:
            return MCPStructuredError(code: .policyDenied, message: "Policy changed; approval is no longer valid.")
        case .targetRevisionChanged:
            return MCPStructuredError(code: .staleTargetRevision, message: "Target revision changed; approval is no longer valid.")
        }
    }

    private func idempotencyKey(from arguments: [String: Any], proposalToken: String) -> MCPIdempotencyKey? {
        if let raw = arguments["idempotencyKey"] as? String, !raw.isEmpty {
            return MCPIdempotencyKey(rawValue: raw)
        }
        return MCPIdempotencyKey(rawValue: "proposal:\(proposalToken)")
    }

    private func recordApplied(client: MCPClientRecord, targetID: String, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalApplied,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "\(MCPCapabilityID.certificateCleanup.rawValue):\(targetID)",
                detail: detail
            )
        )
    }
}
