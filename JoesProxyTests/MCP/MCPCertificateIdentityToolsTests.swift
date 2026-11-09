import XCTest
@testable import JoesProxy

/// Phase C certificate tool gating: disclosure-profile policy, the propose→approve→apply gate on
/// the only `.destructiveTool` capability, and artifact filtering.
@MainActor
final class MCPCertificateIdentityToolsTests: XCTestCase {
    private let retiredFingerprint = String(repeating: "a", count: 64)
    private let otherFingerprint = String(repeating: "b", count: 64)

    // MARK: - Profile gating

    func testMetadataOnlyProfileDeniesCertificateCapabilities() {
        let policyStore = MCPPolicyStore()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: MCPClientGrantStore())

        // Cleanup is destructive: Shareable only, matching every other lifecycle capability.
        XCTAssertFalse(evaluator.profileAllows(capability: .certificateCleanup, profileID: .metadataOnly))
        XCTAssertTrue(evaluator.profileAllows(capability: .certificateCleanup, profileID: .shareable))

        // Reads follow the inspect-tool gate rather than defaulting to "allowed everywhere".
        for capability in [
            MCPCapabilityID.certificateStatus,
            .certificateIdentity,
            .certificateArtifactsList,
            .certificateCompare,
            .certificateExport
        ] {
            XCTAssertEqual(
                evaluator.profileAllows(capability: capability, profileID: .metadataOnly),
                policyStore.allowsInspectTools(for: .metadataOnly),
                "\(capability.rawValue) must follow the inspect-tool gate"
            )
        }
    }

    func testDeniedProfileCannotInvokeCleanupTools() async throws {
        let harness = makeHarness(profileID: .metadataOnly)
        await assertStructuredError(code: .policyDenied) {
            try await harness.service.handleTool(
                name: "propose_certificate_cleanup",
                arguments: ["fingerprint": self.retiredFingerprint],
                client: harness.client
            )
        }
    }

    // MARK: - Cleanup approval gate

    func testApplyRejectsFabricatedTokenIncludingRawFingerprint() async throws {
        let harness = makeHarness()
        // The pre-fix contract let a bare fingerprint stand in for a proposal token.
        await assertStructuredError(code: .staleProposal) {
            try await harness.service.handleTool(
                name: "apply_certificate_cleanup",
                arguments: ["proposalToken": self.retiredFingerprint],
                client: harness.client
            )
        }
        XCTAssertEqual(harness.trustCleaner.removedFingerprints, [])
        XCTAssertEqual(
            harness.metadataStore.metadata(forFingerprint: retiredFingerprint)?.storageState,
            .current
        )
    }

    func testApplyRequiresApprovalEvenWithStandingGrant() async throws {
        let harness = makeHarness()
        _ = try harness.grantStore.addGrant(
            clientID: harness.client.id,
            capability: .certificateCleanup,
            mode: .durablePolicy
        )
        let token = try await proposeCleanup(harness)

        await assertStructuredError(code: .approvalRequired) {
            try await harness.service.handleTool(
                name: "apply_certificate_cleanup",
                arguments: ["proposalToken": token],
                client: harness.client
            )
        }
        // Nothing may be deleted while the approval is still pending.
        XCTAssertEqual(harness.trustCleaner.removedFingerprints, [])
        XCTAssertEqual(
            harness.metadataStore.metadata(forFingerprint: retiredFingerprint)?.storageState,
            .current
        )
    }

    func testApplySucceedsAfterApprovalAndReportsRealCounts() async throws {
        let harness = makeHarness()
        let token = try await proposeCleanup(harness)
        _ = try await expectApprovalRequirement {
            try await harness.service.handleTool(
                name: "apply_certificate_cleanup",
                arguments: ["proposalToken": token],
                client: harness.client
            )
        }
        let pending = try XCTUnwrap(harness.approvalStore.pendingRequests.first)
        _ = try harness.approvalStore.approve(requestID: pending.requestID)

        let payload = try await harness.service.handleTool(
            name: "apply_certificate_cleanup",
            arguments: ["proposalToken": token],
            client: harness.client
        )
        XCTAssertEqual(payload["cleanedFingerprint"] as? String, retiredFingerprint)
        XCTAssertEqual(payload["metadataRetired"] as? Bool, true)
        XCTAssertEqual(payload["distributionRecordsRetired"] as? Int, 1)
        XCTAssertEqual(payload["installedCertificatesRemoved"] as? Int, 1)
        XCTAssertEqual(payload["activeRootRemoved"] as? Bool, false)
        XCTAssertEqual(harness.trustCleaner.removedFingerprints, [retiredFingerprint])
        XCTAssertEqual(
            harness.metadataStore.metadata(forFingerprint: retiredFingerprint)?.storageState,
            .retired
        )
    }

    func testCleanupReportsZeroCountsWhenNothingMatched() async throws {
        let harness = makeHarness()
        let unknown = String(repeating: "c", count: 64)
        let token = try await proposeCleanup(harness, fingerprint: unknown)
        _ = try await expectApprovalRequirement {
            try await harness.service.handleTool(
                name: "apply_certificate_cleanup",
                arguments: ["proposalToken": token],
                client: harness.client
            )
        }
        let pending = try XCTUnwrap(harness.approvalStore.pendingRequests.first)
        _ = try harness.approvalStore.approve(requestID: pending.requestID)

        let payload = try await harness.service.handleTool(
            name: "apply_certificate_cleanup",
            arguments: ["proposalToken": token],
            client: harness.client
        )
        XCTAssertEqual(payload["metadataRetired"] as? Bool, false)
        XCTAssertEqual(payload["distributionRecordsRetired"] as? Int, 0)
        XCTAssertEqual(payload["installedCertificatesRemoved"] as? Int, 0)
    }

    // MARK: - Artifact filtering

    func testArtifactsListHonorsExplicitFingerprintFilter() async throws {
        let harness = makeHarness()
        let payload = try await harness.service.handleTool(
            name: "certificate_artifacts_list",
            arguments: ["fingerprint": otherFingerprint],
            client: harness.client
        )
        let artifacts = try XCTUnwrap(payload["artifacts"] as? [[String: Any]])
        XCTAssertEqual(payload["fingerprintFilter"] as? String, otherFingerprint)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(
            artifacts.first?["certificateSHA256Fingerprint"] as? String,
            otherFingerprint
        )
    }

    func testArtifactsListNormalizesColonSeparatedFingerprint() async throws {
        let harness = makeHarness()
        let colonized = stride(from: 0, to: otherFingerprint.count, by: 2)
            .map { offset -> String in
                let start = otherFingerprint.index(otherFingerprint.startIndex, offsetBy: offset)
                let end = otherFingerprint.index(start, offsetBy: 2)
                return String(otherFingerprint[start..<end]).uppercased()
            }
            .joined(separator: ":")

        let payload = try await harness.service.handleTool(
            name: "certificate_artifacts_list",
            arguments: ["fingerprint": colonized],
            client: harness.client
        )
        let artifacts = try XCTUnwrap(payload["artifacts"] as? [[String: Any]])
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?["certificateSHA256Fingerprint"] as? String, otherFingerprint)
    }

    // MARK: - Export

    func testExportReturnsBase64CertificateMatchingLiveFingerprint() async throws {
        let root = RootCertificateIdentity(
            label: "test-root",
            subjectSummary: "CN=JoesProxy Root CA",
            certificateData: Data("fake-der-cert-bytes".utf8),
            privateKeyData: nil
        )
        let harness = makeHarness(certificateStore: StubCertificateStoreWithRoot(root: root))

        let payload = try await harness.service.handleTool(
            name: "certificate_export",
            arguments: [:],
            client: harness.client
        )

        let base64 = try XCTUnwrap(payload["certificateDataBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), root.certificateData)
        XCTAssertEqual(payload["filename"] as? String, "JoesProxy-Root-CA.cer")
        XCTAssertEqual(
            payload["certificateSHA256Fingerprint"] as? String,
            CertificateIdentityExtraction.sha256Fingerprint(from: root.certificateData)
        )

        // Same root, so certificate_identity's reported fingerprint must match exactly.
        let identityPayload = try await harness.service.handleTool(
            name: "certificate_identity",
            arguments: [:],
            client: harness.client
        )
        XCTAssertEqual(
            payload["certificateSHA256Fingerprint"] as? String,
            identityPayload["certificateSHA256Fingerprint"] as? String
        )
    }

    func testExportFailsCleanlyWithNoRootCertificate() async throws {
        let harness = makeHarness()
        await assertStructuredError(code: .internalFailure) {
            try await harness.service.handleTool(
                name: "certificate_export",
                arguments: [:],
                client: harness.client
            )
        }
    }

    // MARK: - Schema / argument contracts

    func testCertificateCompareRequiresFingerprintAndOtherFingerprint() async throws {
        let harness = makeHarness()
        await assertStructuredError(code: .malformedRequest) {
            try await harness.service.handleTool(
                name: "certificate_compare",
                arguments: [
                    "fingerprintA": self.retiredFingerprint,
                    "fingerprintB": self.otherFingerprint
                ],
                client: harness.client
            )
        }

        let payload = try await harness.service.handleTool(
            name: "certificate_compare",
            arguments: [
                "fingerprint": retiredFingerprint,
                "otherFingerprint": otherFingerprint
            ],
            client: harness.client
        )
        XCTAssertEqual(payload["matches"] as? Bool, false)
        XCTAssertEqual(payload["fingerprintA"] as? String, retiredFingerprint)
        XCTAssertEqual(payload["fingerprintB"] as? String, otherFingerprint)
    }

    func testApplyCertificateCleanupSchemaRejectsBareFingerprint() async throws {
        let harness = makeHarness()
        // Apply must not accept a raw fingerprint in place of proposalToken (pre-rewrite contract).
        await assertStructuredError(code: .malformedRequest) {
            try await harness.service.handleTool(
                name: "apply_certificate_cleanup",
                arguments: ["fingerprint": self.retiredFingerprint],
                client: harness.client
            )
        }
        XCTAssertEqual(harness.trustCleaner.removedFingerprints, [])
    }

    // MARK: - Harness

    private struct Harness {
        let service: MCPCertificateIdentityService
        let client: MCPClientRecord
        let metadataStore: CAInstanceMetadataStore
        let distributionStore: CertificateDistributionRecordStore
        let trustCleaner: RecordingTrustCleaner
        let approvalStore: MCPApprovalStore
        let grantStore: MCPClientGrantStore
    }

    private func makeHarness(
        profileID: MCPDisclosureProfileID = .shareable,
        certificateStore: (any CertificateStore)? = nil
    ) -> Harness {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-meta-\(UUID().uuidString).json")
        let distributionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-dist-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: metadataURL)
            try? FileManager.default.removeItem(at: distributionURL)
        }

        let metadataStore = CAInstanceMetadataStore(persistenceURL: metadataURL)
        metadataStore.load()
        try? metadataStore.upsert(
            CAInstanceMetadata(
                id: UUID(),
                shortCode: "ABCD-EF12",
                certificateSHA256Fingerprint: retiredFingerprint,
                certificateSerialNumber: "01",
                subjectSummary: "CN=JoesProxy Root CA",
                notBefore: Date().addingTimeInterval(-3600),
                notAfter: Date().addingTimeInterval(3600),
                createdAt: Date(),
                appVersionCreated: "test",
                storageState: .current,
                nickname: nil,
                renewalState: CARenewalState.none
            )
        )

        let distributionStore = CertificateDistributionRecordStore(persistenceURL: distributionURL)
        distributionStore.load()
        try? distributionStore.append(makeRecord(fingerprint: retiredFingerprint))
        try? distributionStore.append(makeRecord(fingerprint: otherFingerprint))

        let journalStore = MCPEffectJournalStore(
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cert-journal-\(UUID().uuidString).json")
        )
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let policyStore = MCPPolicyStore()
        let grantStore = MCPClientGrantStore()
        let trustCleaner = RecordingTrustCleaner(matchCount: 1)
        let certificateStore = certificateStore ?? StubCertificateStore()

        let service = MCPCertificateIdentityService(
            configuration: UserDefaultsAppConfiguration(
                userDefaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            certificateStore: certificateStore,
            trustInstaller: StubTrustInstaller(),
            trustCleaner: trustCleaner,
            metadataStore: metadataStore,
            distributionStore: distributionStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: MCPAuditStore()
        )

        return Harness(
            service: service,
            client: MCPClientRecord(
                id: "certificate-client",
                displayName: "Certificate Client",
                assignedProfileID: profileID,
                credentialState: .active,
                credentialGeneration: 1,
                createdAt: Date(),
                lastSeenAt: nil
            ),
            metadataStore: metadataStore,
            distributionStore: distributionStore,
            trustCleaner: trustCleaner,
            approvalStore: approvalStore,
            grantStore: grantStore
        )
    }

    private func makeRecord(fingerprint: String) -> CertificateDistributionRecord {
        CertificateDistributionRecord(
            artifactID: UUID(),
            caInstanceID: UUID(),
            shortCode: "ABCD-EF12",
            certificateSHA256Fingerprint: fingerprint,
            certificateSerialNumber: "01",
            certificateNotAfter: Date().addingTimeInterval(3600),
            profileKind: .iosTrustProfile,
            payloadIdentifier: "com.showblender.joesproxy.ca.abcdef12.profile.\(UUID().uuidString.lowercased())",
            resolvedHost: nil,
            proxyPort: nil,
            userNickname: nil,
            generatedAt: Date(),
            appVersion: "test",
            status: .generated
        )
    }

    private func proposeCleanup(
        _ harness: Harness,
        fingerprint: String? = nil
    ) async throws -> String {
        let payload = try await harness.service.handleTool(
            name: "propose_certificate_cleanup",
            arguments: ["fingerprint": fingerprint ?? retiredFingerprint],
            client: harness.client
        )
        let token = try XCTUnwrap(payload["proposalToken"] as? String)
        // The token must be an opaque coordinator handle, never the fingerprint itself.
        XCTAssertNotEqual(token, fingerprint ?? retiredFingerprint)
        return token
    }

    private func assertStructuredError(
        code: MCPErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> [String: Any]
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(code.rawValue) error", file: file, line: line)
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Expected MCPStructuredError, got \(error)", file: file, line: line)
        }
    }

    /// Runs the first apply, which is expected to raise the approval requirement.
    @discardableResult
    private func expectApprovalRequirement(
        _ body: () async throws -> [String: Any]
    ) async throws -> Error? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }
}

/// Records fingerprint-scoped removals without touching the Keychain.
private final class RecordingTrustCleaner: CertificateFingerprintTrustCleaning {
    private let matchCount: Int
    private(set) var removedFingerprints: [String] = []

    init(matchCount: Int) {
        self.matchCount = matchCount
    }

    @discardableResult
    func removeInstalledCertificate(matchingFingerprint fingerprint: String, label: String) throws -> Int {
        // Mirrors the real installer: only fingerprints that actually match report a removal.
        guard fingerprint == String(repeating: "a", count: 64) else { return 0 }
        removedFingerprints.append(fingerprint)
        return matchCount
    }
}

private final class StubTrustInstaller: TrustInstalling {
    func installationStatus(for label: String) -> TrustInstallationStatus { .notInstalled }
    func install(_ identity: RootCertificateIdentity) throws {}
    func removeCertificate(label: String) throws {}
}

/// No live root, so cleanup never collides with the active-root guard.
private final class StubCertificateStore: CertificateStore {
    private(set) var removedLabels: [String] = []
    func loadRootCertificate(label: String) -> RootCertificateIdentity? { nil }
    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {}
    func removeRootCertificate(label: String) throws { removedLabels.append(label) }
}

/// Reports a fixed root identity — used to exercise `certificate_export`'s happy path.
private final class StubCertificateStoreWithRoot: CertificateStore {
    let root: RootCertificateIdentity
    init(root: RootCertificateIdentity) { self.root = root }
    func loadRootCertificate(label: String) -> RootCertificateIdentity? { root }
    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {}
    func removeRootCertificate(label: String) throws {}
}
