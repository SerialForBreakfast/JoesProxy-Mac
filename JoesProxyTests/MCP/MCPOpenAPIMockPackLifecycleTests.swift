import XCTest
@testable import JoesProxy

/// AW-4: one-approval activate, owner stop, redaction, leftover-approval prune.
@MainActor
final class MCPOpenAPIMockPackLifecycleTests: XCTestCase {
    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI", isDirectory: true)
    }

    func testToolsAppearInProductionManifest() {
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.isSuperset(of: [
            "openapi_pack_preview",
            "propose_openapi_pack_start",
            "apply_openapi_pack_start",
            "openapi_pack_status",
            "openapi_pack_stop"
        ]))
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "openapi_pack_preview"), .openAPIMockInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "propose_openapi_pack_start"), .openAPIMockLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "apply_openapi_pack_start"), .openAPIMockLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "openapi_pack_status"), .openAPIMockInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "openapi_pack_stop"), .openAPIMockLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "propose_create_map_local"), .createDisabledMapLocal)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "apply_create_map_local"), .createDisabledMapLocal)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "arm_test_scenario"), .scenarioLifecycle)
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.contains("propose_create_map_local"))
    }

    func testPreviewRedactsBodiesAndPaths() async throws {
        let (service, _, _, catalogURL) = try makeService()
        let client = makeClient()
        let bookmark = try OpenAPIMockDocumentReader.bookmark(forFileURL: catalogURL)
        let preview = try await service.handleTool(
            name: "openapi_pack_preview",
            arguments: [
                "openapiDocumentBookmarkRef": bookmark.ref,
                "scheme": "http",
                "host": "catalog.example.invalid"
            ],
            client: client
        )
        let payload = try XCTUnwrap(preview["payload"] as? [String: Any])
        let encoded = String(describing: payload)
        XCTAssertFalse(encoded.contains(catalogURL.path))
        XCTAssertEqual(payload["schemaValidOutputIsNotAuthorization"] as? Bool, true)
        XCTAssertNotNil(payload["operations"])
        XCTAssertNil(payload["body"])
        XCTAssertNil(payload["bodyText"])
    }

    func testProposeApplyUsesOneApprovalAndStopInvalidatesLeftover() async throws {
        let (service, _, approvalStore, catalogURL) = try makeService()
        let client = makeClient()
        let bookmark = try OpenAPIMockDocumentReader.bookmark(forFileURL: catalogURL)
        let propose = try await service.handleTool(
            name: "propose_openapi_pack_start",
            arguments: [
                "openapiDocumentBookmarkRef": bookmark.ref,
                "scheme": "http",
                "host": "catalog.example.invalid",
                "conflictStrategy": "refuse"
            ],
            client: client
        )
        let proposePayload = try XCTUnwrap(propose["payload"] as? [String: Any])
        let token = try XCTUnwrap(proposePayload["proposalToken"] as? String)
        let proposedPackID = try XCTUnwrap(proposePayload["proposedPackID"] as? String)
        XCTAssertFalse(String(describing: proposePayload).contains(catalogURL.path))

        do {
            _ = try await service.handleTool(
                name: "apply_openapi_pack_start",
                arguments: ["proposalToken": token],
                client: client
            )
            XCTFail("expected approval_required")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
        }
        XCTAssertEqual(approvalStore.pendingCount, 1)

        let requestID = try XCTUnwrap(approvalStore.pendingRequests.first?.requestID)
        _ = try approvalStore.approve(requestID: requestID)

        let apply = try await service.handleTool(
            name: "apply_openapi_pack_start",
            arguments: ["proposalToken": token],
            client: client
        )
        let applyPayload = try XCTUnwrap(apply["payload"] as? [String: Any])
        XCTAssertEqual(applyPayload["packID"] as? String, proposedPackID)
        XCTAssertEqual(applyPayload["state"] as? String, "serving")
        XCTAssertEqual(approvalStore.pendingCount, 0)
        XCTAssertEqual(service.unresolvedPackCount(forClientID: client.id), 1)

        let stop = try await service.handleTool(
            name: "openapi_pack_stop",
            arguments: ["packID": proposedPackID],
            client: client
        )
        let stopPayload = try XCTUnwrap(stop["payload"] as? [String: Any])
        XCTAssertEqual(stopPayload["state"] as? String, "stopped")
        XCTAssertEqual(service.unresolvedPackCount(forClientID: client.id), 0)

        let leftoverPropose = try await service.handleTool(
            name: "propose_openapi_pack_start",
            arguments: [
                "openapiDocumentBookmarkRef": bookmark.ref,
                "scheme": "http",
                "host": "catalog.example.invalid"
            ],
            client: client
        )
        let leftoverToken = try XCTUnwrap((leftoverPropose["payload"] as? [String: Any])?["proposalToken"] as? String)
        do {
            _ = try await service.handleTool(
                name: "apply_openapi_pack_start",
                arguments: ["proposalToken": leftoverToken],
                client: client
            )
            XCTFail("expected approval")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
        }
        XCTAssertEqual(approvalStore.pendingCount, 1)
        await service.stopAll(ownedBy: client.id)
        XCTAssertEqual(approvalStore.pendingCount, 0)
    }

    func testShareableGateRejectsMetadataOnly() async throws {
        let (service, _, _, catalogURL) = try makeService()
        let client = MCPClientRecord(
            id: "meta-client",
            displayName: "Metadata",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let bookmark = try OpenAPIMockDocumentReader.bookmark(forFileURL: catalogURL)
        do {
            _ = try await service.handleTool(
                name: "propose_openapi_pack_start",
                arguments: ["openapiDocumentBookmarkRef": bookmark.ref, "host": "catalog.example.invalid"],
                client: client
            )
            XCTFail("expected policyDenied")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testOwnerStopRefusesForeignClient() async throws {
        let (service, _, approvalStore, catalogURL) = try makeService(grantLifecycle: true)
        let owner = makeClient()
        let bookmark = try OpenAPIMockDocumentReader.bookmark(forFileURL: catalogURL)
        let propose = try await service.handleTool(
            name: "propose_openapi_pack_start",
            arguments: [
                "openapiDocumentBookmarkRef": bookmark.ref,
                "scheme": "http",
                "host": "catalog.example.invalid"
            ],
            client: owner
        )
        let token = try XCTUnwrap((propose["payload"] as? [String: Any])?["proposalToken"] as? String)
        let packID = try XCTUnwrap((propose["payload"] as? [String: Any])?["proposedPackID"] as? String)
        let apply = try await service.handleTool(
            name: "apply_openapi_pack_start",
            arguments: ["proposalToken": token],
            client: owner
        )
        XCTAssertEqual((apply["payload"] as? [String: Any])?["packID"] as? String, packID)
        XCTAssertEqual(approvalStore.pendingCount, 0)

        let foreign = MCPClientRecord(
            id: "other-client",
            displayName: "Other",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        do {
            _ = try await service.handleTool(
                name: "openapi_pack_stop",
                arguments: ["packID": packID],
                client: foreign
            )
            XCTFail("expected not owner")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    private func makeService(grantLifecycle: Bool = false) throws -> (
        MCPOpenAPIMockPackService,
        OpenAPIMockPackCoordinator,
        MCPApprovalStore,
        URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openapi-mcp-\(UUID().uuidString)", isDirectory: true)
        let coordinator = OpenAPIMockPackCoordinator(
            routeStore: OpenAPIMockRouteStore(),
            persistenceURL: base.appendingPathComponent("packs.json")
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let grantStore = MCPClientGrantStore()
        if grantLifecycle {
            _ = try grantStore.addGrant(
                clientID: "pack-client",
                capability: .openAPIMockLifecycle,
                mode: .durablePolicy
            )
            _ = try grantStore.addGrant(
                clientID: "pack-client",
                capability: .openAPIMockInspect,
                mode: .durablePolicy
            )
        }
        let service = MCPOpenAPIMockPackService(
            packCoordinator: coordinator,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: MCPPolicyStore(),
            grantStore: grantStore,
            auditStore: MCPAuditStore()
        )
        let catalogURL = fixturesURL.appendingPathComponent("catalog-v1.json")
        return (service, coordinator, approvalStore, catalogURL)
    }

    private func makeClient() -> MCPClientRecord {
        MCPClientRecord(
            id: "pack-client",
            displayName: "Pack Client",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
    }
}
