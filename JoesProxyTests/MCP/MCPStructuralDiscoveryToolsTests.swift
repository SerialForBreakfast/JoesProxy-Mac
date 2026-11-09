import XCTest
@testable import JoesProxy

/// Coverage for `discover_response_structure` and `preview_live_rewrite` — the two read-only,
/// `.shareable`-gated tools added on `MCPMutationService` per `we-must-do-aj-2-jazzy-galaxy.md`'s
/// Phase 6/7 (structural discovery + capture-only preview never touch live traffic or persist
/// anything).
@MainActor
final class MCPStructuralDiscoveryToolsTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let approvalStore: MCPApprovalStore
        let client: MCPClientRecord
    }

    private func epgBody(title: String = "News Hour") -> Data {
        let json = """
        {"channels":[{"id":"c1","programs":[{"id":"p1","title":"\(title)"}]}]}
        """
        return Data(json.utf8)
    }

    private func makeSession(
        bodyData: Data?,
        path: String = "/epg",
        contentType: String = "application/json"
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: bodyData,
                bodySize: bodyData?.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func makeStack(profile: MCPDisclosureProfileID, snapshotService: MCPSessionSnapshotService?) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "discovery-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "discovery-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "discovery-audit.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let mutationService = MCPMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService
        )
        let client = MCPClientRecord(
            id: "client-discovery-test",
            displayName: "discovery-test",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore,
            approvalStore: approvalStore,
            client: client
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="main"
        https://cdn.example.com/video/one.m3u8?sid=secret
        """.utf8)
    }

    // MARK: - discover_response_structure

    func testDiscoverResponseStructureReportsShapeAndFingerprint() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        let payload = try await stack.mutationService.handleTool(
            name: "discover_response_structure",
            arguments: ["sessionIDs": [session.id.uuidString]],
            client: stack.client
        )
        XCTAssertEqual(payload["status"] as? String, "complete")
        XCTAssertEqual(payload["sampleCount"] as? Int, 1)
        let shapeDescription = try XCTUnwrap(payload["shapeDescription"] as? String)
        XCTAssertTrue(shapeDescription.contains("channels"))
        XCTAssertTrue(shapeDescription.contains("title"))
        XCTAssertNotNil(payload["schemaFingerprint"] as? String)
    }

    func testDiscoverResponseStructureRejectsBelowShareableProfile() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .metadataOnly, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "discover_response_structure",
                arguments: ["sessionIDs": [session.id.uuidString]],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testDiscoverResponseStructureFailsClosedWithoutSnapshotService() async throws {
        let stack = try makeStack(profile: .shareable, snapshotService: nil)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "discover_response_structure",
                arguments: ["sessionIDs": [UUID().uuidString]],
                client: stack.client
            )
            XCTFail("expected internal failure")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .internalFailure)
        }
    }

    func testDiscoverResponseStructureRejectsEmptySessionIDs() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "discover_response_structure",
                arguments: ["sessionIDs": []],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testDiscoverResponseStructureRedactsSensitiveKeyNames() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let body = Data("""
        {"user":{"authToken":"abc123","name":"A"}}
        """.utf8)
        let session = makeSession(bodyData: body)
        sessionStore.append(session)

        let payload = try await stack.mutationService.handleTool(
            name: "discover_response_structure",
            arguments: ["sessionIDs": [session.id.uuidString]],
            client: stack.client
        )
        let shapeDescription = try XCTUnwrap(payload["shapeDescription"] as? String)
        XCTAssertFalse(shapeDescription.contains("authToken"))
        XCTAssertTrue(shapeDescription.contains("redacted"))
    }

    // MARK: - preview_live_rewrite

    func testPreviewHLSCODECSEditBindsOpaqueVariantAndMapLocalUsesServerBody() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(
            bodyData: hlsMasterBody(),
            path: "/master.m3u8?sid=secret",
            contentType: "application/vnd.apple.mpegurl"
        )
        sessionStore.append(session)
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let structure = try inspection.manifestStructure(sessionID: session.id, policyRevision: .initial)
        let variantRef = try XCTUnwrap(structure.hlsVariants.first?.variantRef)
        let internalSessionID = "hls-test-session"

        var previewArguments: [String: Any] = [
            "sessionID": session.id.uuidString,
            "edits": [["variantRef": variantRef, "codecs": "avc1.640028,mp4a.40.2"]],
            "matchMode": "ignoreQuery",
            "__mcpInternalSessionID": internalSessionID
        ]
        let preview = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: previewArguments,
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["previewDigest"] as? String)
        XCTAssertEqual(preview["codecValueProvenance"] as? String, "user_supplied")
        XCTAssertEqual(preview["mediaVerified"] as? Bool, false)
        XCTAssertFalse(String(describing: preview).contains("secret"))

        previewArguments["hlsPreviewDigest"] = digest
        previewArguments["__mcpInternalSessionID"] = internalSessionID
        previewArguments["bodyText"] = "caller body must be rejected"
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: previewArguments,
                client: stack.client
            )
            XCTFail("expected caller-supplied body to be rejected")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }

        previewArguments.removeValue(forKey: "bodyText")
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: previewArguments,
            client: stack.client
        )
        let proposalToken = try XCTUnwrap(proposal["proposalToken"] as? String)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: ["proposalToken": proposalToken],
                client: stack.client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(authorization)
            let approval = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: [
                    "proposalToken": proposalToken,
                    "approval": approval
                ],
                client: stack.client
            )
        }
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        guard case .inline(let storedBody) = rule.bodySource else {
            return XCTFail("expected inline body source")
        }
        let expectedPatched = try HLSCODECSEditTransformer.apply(
            originalBytes: hlsMasterBody(),
            edits: [
                HLSCODECSVariantEdit(
                    locator: try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: hlsMasterBody()).first),
                    codecs: "avc1.640028,mp4a.40.2"
                )
            ]
        ).data
        XCTAssertEqual(storedBody, expectedPatched)
    }

    func testPreviewHLSCODECSEditRejectsForgedVariantReference() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody(), contentType: "application/vnd.apple.mpegurl")
        sessionStore.append(session)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_hls_codecs_edit",
                arguments: [
                    "sessionID": session.id.uuidString,
                    "edits": [["variantRef": "hls-variant-forged", "codecs": "avc1.640028"]]
                ],
                client: stack.client
            )
            XCTFail("expected forged variant reference to fail")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testPreviewHLSCODECSEditDisclosesHistoricalMatcherScopeAndFreshness() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(
            bodyData: hlsMasterBody(),
            path: "/master.m3u8?sid=secret",
            contentType: "application/vnd.apple.mpegurl"
        )
        sessionStore.append(session)
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let ref = try XCTUnwrap(
            inspection.manifestStructure(sessionID: session.id, policyRevision: .initial).hlsVariants.first?.variantRef
        )
        let payload = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [["variantRef": ref, "codecs": "avc1.640028,mp4a.40.2"]]
            ],
            client: stack.client
        )

        let scope = try XCTUnwrap(payload["matcherScope"] as? [String: Any])
        XCTAssertEqual(Set(scope.keys), Set([
            "method", "scheme", "host", "port", "path", "matchMode",
            "observedCaptureCardinality", "cardinalityIsHistorical", "warning",
            "observedAt", "conflictingEnabledRuleIDs", "activeScenarioIDs"
        ]))
        XCTAssertEqual(scope["observedCaptureCardinality"] as? Int, 1)
        XCTAssertEqual(scope["cardinalityIsHistorical"] as? Bool, true)
        XCTAssertTrue(scope["warning"] is NSNull)
        XCTAssertNotNil(scope["observedAt"] as? String)
        XCTAssertEqual(scope["conflictingEnabledRuleIDs"] as? [String], [])
        XCTAssertEqual(scope["activeScenarioIDs"] as? [String], [])

        let freshness = try XCTUnwrap(payload["captureFreshness"] as? [String: Any])
        XCTAssertNotNil(freshness["capturedAt"])
        XCTAssertNotNil(freshness["ageSeconds"])
        XCTAssertEqual(freshness["appearsCacheable"] as? Bool, true)
        XCTAssertEqual(freshness["absoluteChildURICount"] as? Int, 1)
        XCTAssertEqual(freshness["queryBearingChildURICount"] as? Int, 1)
        XCTAssertTrue((freshness["sessionLikeQueryKeyIndicators"] as? [String])?.contains("sid") == true)
        XCTAssertEqual(freshness["disclosureOnly"] as? Bool, true)
        // P1-06: lexical indicators only — never raw child URIs, query strings, or secret values.
        let freshnessText = String(describing: freshness)
        XCTAssertFalse(freshnessText.contains("secret"))
        XCTAssertFalse(freshnessText.contains("cdn.example.com/video"))
        XCTAssertFalse(freshnessText.contains("?sid="))
    }

    func testPreviewHLSCODECSEditRejectsInvalidPathSuffix() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody(), path: "/master.m3u8?sid=secret", contentType: "application/vnd.apple.mpegurl")
        sessionStore.append(session)
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let ref = try XCTUnwrap(
            inspection.manifestStructure(sessionID: session.id, policyRevision: .initial).hlsVariants.first?.variantRef
        )

        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_hls_codecs_edit",
                arguments: [
                    "sessionID": session.id.uuidString,
                    "matchMode": "pathSuffix",
                    "path": "/different.m3u8",
                    "edits": [["variantRef": ref, "codecs": "avc1.640028"]]
                ],
                client: stack.client
            )
            XCTFail("expected invalid suffix")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testPreviewHLSCODECSEditRejectsDuplicateVariantEdits() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody(), contentType: "application/vnd.apple.mpegurl")
        sessionStore.append(session)
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let ref = try XCTUnwrap(
            inspection.manifestStructure(sessionID: session.id, policyRevision: .initial).hlsVariants.first?.variantRef
        )

        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_hls_codecs_edit",
                arguments: [
                    "sessionID": session.id.uuidString,
                    "edits": [
                        ["variantRef": ref, "codecs": "avc1.640028"],
                        ["variantRef": ref, "codecs": "avc1.640029"]
                    ]
                ],
                client: stack.client
            )
            XCTFail("expected duplicate edit rejection")
        } catch let error as HLSCODECSEditError {
            XCTAssertEqual(error, .conflictingEdits(ordinal: 0))
        }
    }

    private func previewArguments(sessionIDs: [String], operation: String = "appendString") -> [String: Any] {
        [
            "method": "GET",
            "host": "api.example.com",
            "path": "/epg",
            "matchMode": "exactPath",
            "jsonPath": "$.channels[*].programs[*].title",
            "operation": operation,
            "overrideValue": ["type": "string", "value": "!"],
            "sessionIDs": sessionIDs
        ]
    }

    func testPreviewLiveRewriteReportsWildcardTransformCountsWithoutPersistingOrMutatingStore() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        let payload = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        XCTAssertEqual(payload["eligibleCount"] as? Int, 1)
        XCTAssertEqual(payload["transformedCount"] as? Int, 1)
        XCTAssertEqual(payload["zeroMatches"] as? Bool, false)
        XCTAssertNotNil(payload["previewDigest"] as? String)
        XCTAssertNotNil(payload["sanitizedExample"] as? String)
        let selectorResults = try XCTUnwrap(payload["selectorResults"] as? [[String: Any]])
        XCTAssertEqual(selectorResults.first?["selector"] as? String, "$.channels[*].programs[*].title")
        XCTAssertEqual(selectorResults.first?["changedCount"] as? Int, 1)
        // Preview reads captured bodies only — the session store's own copy is untouched.
        XCTAssertEqual(sessionStore.record(for: session.id)?.response?.bodyData, epgBody())
    }

    func testPreviewLiveRewriteReportsZeroMatchesDistinctlyWhenNothingTransforms() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: Data("{\"unrelated\":true}".utf8))
        sessionStore.append(session)

        let payload = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        XCTAssertEqual(payload["transformedCount"] as? Int, 0)
        XCTAssertEqual(payload["zeroMatches"] as? Bool, true)
        XCTAssertNil(payload["sanitizedExample"])
    }

    func testPreviewLiveRewriteDigestChangesWhenLocatorChanges() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        let first = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        var differentLocatorArgs = previewArguments(sessionIDs: [session.id.uuidString])
        differentLocatorArgs["jsonPath"] = "$.channels[*].id"
        let second = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: differentLocatorArgs,
            client: stack.client
        )
        XCTAssertNotEqual(first["previewDigest"] as? String, second["previewDigest"] as? String)
    }

    func testPreviewLiveRewriteRejectsWildcardWithInsert() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        var args = previewArguments(sessionIDs: [session.id.uuidString], operation: "insertArrayElement")
        args["jsonPath"] = "$.channels[*]"
        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_live_rewrite",
                arguments: args,
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testLiveRewriteProposalRequiresCurrentPreviewAndRejectsCaptureReplacement() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)
        var proposalArguments = previewArguments(sessionIDs: [session.id.uuidString])
        proposalArguments.removeValue(forKey: "sessionIDs")

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: proposalArguments,
                client: stack.client
            )
            XCTFail("expected missing preview to fail closed")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }

        let preview = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        proposalArguments["previewDigest"] = try XCTUnwrap(preview["previewDigest"] as? String)
        sessionStore.load(sessions: [session])

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: proposalArguments,
                client: stack.client
            )
            XCTFail("expected capture replacement to invalidate the preview")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testLiveRewriteProposalAcceptsCurrentPreviewDigest() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)
        let preview = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        var proposalArguments = previewArguments(sessionIDs: [session.id.uuidString])
        proposalArguments.removeValue(forKey: "sessionIDs")
        proposalArguments["previewDigest"] = try XCTUnwrap(preview["previewDigest"] as? String)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: proposalArguments,
            client: stack.client
        )

        XCTAssertNotNil(proposal["proposalToken"] as? String)
        XCTAssertEqual(proposal["defaultEnabled"] as? Bool, false)
    }

    func testLiveRewriteProposalAcceptsMatchingGraphQLOperationNameDigest() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        var previewArgs = previewArguments(sessionIDs: [session.id.uuidString])
        previewArgs["graphqlOperationName"] = "GetChannels"
        let preview = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArgs,
            client: stack.client
        )

        var proposalArguments = previewArgs
        proposalArguments.removeValue(forKey: "sessionIDs")
        proposalArguments["previewDigest"] = try XCTUnwrap(preview["previewDigest"] as? String)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: proposalArguments,
            client: stack.client
        )
        XCTAssertNotNil(proposal["proposalToken"] as? String)
    }

    /// Regression test: `MCPTransformationPreviewDigest.Payload` must include
    /// `graphQLOperationName`, or an operator could preview unscoped and sneak a different
    /// operation scope in at create time without the stale-proposal check catching it.
    func testLiveRewriteProposalRejectsMismatchedGraphQLOperationNameAsStaleDigest() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(profile: .shareable, snapshotService: snapshotService)
        let session = makeSession(bodyData: epgBody())
        sessionStore.append(session)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_live_rewrite",
            arguments: previewArguments(sessionIDs: [session.id.uuidString]),
            client: stack.client
        )
        var proposalArguments = previewArguments(sessionIDs: [session.id.uuidString])
        proposalArguments.removeValue(forKey: "sessionIDs")
        proposalArguments["previewDigest"] = try XCTUnwrap(preview["previewDigest"] as? String)
        // Previewed unscoped, but sneaking a scope in at create time — must be caught as stale.
        proposalArguments["graphqlOperationName"] = "GetChannels"

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: proposalArguments,
                client: stack.client
            )
            XCTFail("expected mismatched graphqlOperationName to invalidate the preview digest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }
}
