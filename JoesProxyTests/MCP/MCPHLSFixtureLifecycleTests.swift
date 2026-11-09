import XCTest
@testable import JoesProxy

/// MCP lifecycle smoke for P2-04 HLS fixture start/stop and cleanup counting.
@MainActor
final class MCPHLSFixtureLifecycleTests: XCTestCase {
    private func baselineProfileDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
    }

    private func profilesRoot() -> URL {
        baselineProfileDirectory().deletingLastPathComponent()
    }

    func testProposeApplyStartRegistersOriginAndStopClearsUnresolvedCount() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: baselineProfileDirectory().path),
            "Fixtures/HLS/baseline-aligned-codecs not present."
        )

        let registry = HLSFixtureOriginRegistry()
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-fixture-mcp-\(UUID().uuidString).json")
        let runStore = HLSFixtureRunStore(
            persistenceURL: persistenceURL,
            profileRootURL: profilesRoot(),
            originRegistry: registry
        )
        runStore.load()

        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-fixture-journal-\(UUID().uuidString).json")
        let journalStore = MCPEffectJournalStore(persistenceURL: journalURL)
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let policyStore = MCPPolicyStore()
        let grantStore = MCPClientGrantStore()
        let auditStore = MCPAuditStore()
        let service = MCPHLSFixtureService(
            runStore: runStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore
        )

        let client = MCPClientRecord(
            id: "fixture-client",
            displayName: "Fixture Client",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        _ = try grantStore.addGrant(
            clientID: client.id,
            capability: .hlsFixtureLifecycle,
            mode: .durablePolicy
        )

        let capabilities = try await service.handleTool(
            name: "hls_fixture_capabilities",
            arguments: [:],
            client: client
        )
        let capsPayload = try XCTUnwrap(capabilities["payload"] as? [String: Any])
        XCTAssertEqual(capsPayload["routingMode"] as? String, "reservedVirtualOrigin")
        let directConfigurationCapabilities = try XCTUnwrap(
            capsPayload["playbackConfiguration"] as? [String: Any]
        )
        XCTAssertEqual(
            directConfigurationCapabilities["presentationModes"] as? [String],
            ["vodStatic", "liveLoop"]
        )
        XCTAssertEqual(
            directConfigurationCapabilities["timeShiftModes"] as? [String],
            ["off", "warmDVR", "coldDVR"]
        )
        XCTAssertEqual(
            directConfigurationCapabilities["boundedTimeShiftSmokeWindowSegmentCount"] as? Int,
            15
        )

        let profiles = try await service.handleTool(
            name: "hls_fixture_profiles_list",
            arguments: [:],
            client: client
        )
        let profilesPayload = try XCTUnwrap(profiles["payload"] as? [String: Any])
        let items = try XCTUnwrap(profilesPayload["items"] as? [[String: Any]])
        XCTAssertTrue(items.contains(where: { $0["profileID"] as? String == "baseline-aligned-codecs" }))
        let captions = try XCTUnwrap(items.first { $0["profileID"] as? String == "multilingual-text-vod-v1" })
        XCTAssertEqual(captions["supportedPresentationModes"] as? [String], ["vodStatic", "liveLoop"])
        let tracks = try XCTUnwrap(captions["textRenditions"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 7)
        XCTAssertTrue(tracks.allSatisfy { $0["cues"] == nil && $0["reviewStatus"] as? String == "diagnosticUnreviewed" })
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: captions).count, 8 * 1024)
        do {
            _ = try await service.handleTool(name: "propose_hls_fixture_start", arguments: [
                "profileID": "multilingual-text-vod-v1", "playbackConfiguration": ["presentationMode": "liveLoop", "intent": "deliberateFault", "segmentURIIdentity": "reuseAssetURI"]
            ], client: client)
            XCTFail("Incompatible live text must reject before creating a proposal")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("vodStatic"))
        }
        XCTAssertEqual(service.unresolvedRunCount(forClientID: client.id), 0)

        let substitutionProfiles = try await service.handleTool(
            name: "hls_substitution_profiles_list",
            arguments: [:],
            client: client
        )
        let substitutionPayload = try XCTUnwrap(substitutionProfiles["payload"] as? [String: Any])
        let substitutionItems = try XCTUnwrap(substitutionPayload["items"] as? [[String: Any]])
        let configurationCapabilities = try XCTUnwrap(
            substitutionPayload["playbackConfiguration"] as? [String: Any]
        )
        XCTAssertEqual(configurationCapabilities["deliberateFaultIntentRequired"] as? Bool, true)
        let playerQA = try XCTUnwrap(substitutionItems.first { $0["profileID"] as? String == "player-qa-widescreen-v1" })
        let audioRenditions = try XCTUnwrap(playerQA["audioRenditions"] as? [[String: Any]])
        XCTAssertEqual(audioRenditions.compactMap { $0["language"] as? String }, ["en", "en", "es", "de"])
        let descriptionTrack = try XCTUnwrap(audioRenditions.first { $0["name"] as? String == "English Audio Description" })
        XCTAssertEqual(
            descriptionTrack["characteristics"] as? [String],
            ["public.accessibility.describes-video"]
        )

        let propose = try await service.handleTool(
            name: "propose_hls_fixture_start",
            arguments: [
                "profileID": "baseline-aligned-codecs",
                "playbackConfiguration": [
                    "presentationMode": "liveLoop",
                    "timeShiftMode": "warmDVR"
                ]
            ],
            client: client
        )
        let proposePayload = try XCTUnwrap(propose["payload"] as? [String: Any])
        let proposalToken = try XCTUnwrap(proposePayload["proposalToken"] as? String)
        let reservedHost = try XCTUnwrap(proposePayload["reservedHost"] as? String)
        XCTAssertEqual(
            (proposePayload["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String,
            "liveLoop"
        )
        XCTAssertEqual(
            (proposePayload["playbackConfiguration"] as? [String: Any])?["timeShiftMode"] as? String,
            "warmDVR"
        )
        XCTAssertEqual(
            (proposePayload["playbackConfiguration"] as? [String: Any])?["windowSegmentCount"] as? Int,
            15
        )

        let apply = try await service.handleTool(
            name: "apply_hls_fixture_start",
            arguments: ["proposalToken": proposalToken],
            client: client
        )
        let applyPayload = try XCTUnwrap(apply["payload"] as? [String: Any])
        let runID = try XCTUnwrap(applyPayload["runID"] as? String)
        XCTAssertEqual(applyPayload["isActive"] as? Bool, true)
        XCTAssertEqual(
            (applyPayload["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String,
            "liveLoop"
        )
        XCTAssertEqual(service.unresolvedRunCount(forClientID: client.id), 1)
        let registered = await registry.activeEntry(forHost: reservedHost)
        XCTAssertNotNil(registered)

        let status = try await service.handleTool(
            name: "hls_fixture_status",
            arguments: ["runID": runID],
            client: client
        )
        let statusPayload = try XCTUnwrap(status["payload"] as? [String: Any])
        XCTAssertEqual(statusPayload["reservedHost"] as? String, reservedHost)
        XCTAssertEqual(
            (statusPayload["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String,
            "liveLoop"
        )

        let preview = try await service.handleTool(
            name: "hls_fixture_window_preview",
            arguments: [
                "runID": runID,
                "path": "video-lo/stream.m3u8",
                "elapsedSeconds": 12
            ],
            client: client
        )
        let previewPayload = try XCTUnwrap(preview["payload"] as? [String: Any])
        let playlistText = try XCTUnwrap(previewPayload["playlistText"] as? String)
        XCTAssertEqual(previewPayload["elapsedSeconds"] as? Double, 12)
        XCTAssertEqual(previewPayload["presentationMode"] as? String, "liveLoop")
        XCTAssertEqual(previewPayload["timeShiftMode"] as? String, "warmDVR")
        XCTAssertEqual(previewPayload["clockDependent"] as? Bool, true)
        let segments = try XCTUnwrap(previewPayload["segments"] as? [[String: Any]])
        XCTAssertFalse(segments.isEmpty)

        let runUUID = try XCTUnwrap(UUID(uuidString: runID))
        let liveServer = try XCTUnwrap(runStore.liveServer(id: runUUID))
        let at = liveServer.startedAt.addingTimeInterval(12)
        let expectedWindow = try XCTUnwrap(liveServer.slidingWindow(forPath: "video-lo/stream.m3u8", now: at))
        XCTAssertEqual(playlistText, HLSSlidingPlaylistComputer.render(expectedWindow))
        XCTAssertEqual(previewPayload["mediaSequence"] as? Int, expectedWindow.mediaSequence)
        XCTAssertEqual(previewPayload["discontinuitySequence"] as? Int, expectedWindow.discontinuitySequence)
        XCTAssertEqual(previewPayload["newestPublishedSequence"] as? Int, expectedWindow.newestPublishedSequence)
        XCTAssertEqual(previewPayload["oldestAdvertisedSequence"] as? Int, expectedWindow.oldestAdvertisedSequence)
        XCTAssertEqual(previewPayload["advertisedDurationSeconds"] as? Double, expectedWindow.advertisedDuration)
        XCTAssertNotNil(previewPayload["earliestProgramDateTime"] as? String)
        XCTAssertNotNil(previewPayload["liveEdgeProgramDateTime"] as? String)
        XCTAssertEqual(previewPayload["oldestRetainedButEvictedSequence"] as? Int, 0)

        // Same inputs as response(forPath:) would use for a frozen clock at `at`.
        let mirror = HLSFixtureServer(
            profileDirectory: liveServer.profileDirectory,
            startedAt: liveServer.startedAt,
            playbackConfiguration: liveServer.playbackConfiguration,
            clock: { at }
        )
        let liveResponse = mirror.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertEqual(playlistText, String(decoding: liveResponse.body, as: UTF8.self))

        _ = try await service.handleTool(
            name: "hls_fixture_stop",
            arguments: ["runID": runID],
            client: client
        )
        XCTAssertEqual(service.unresolvedRunCount(forClientID: client.id), 0)
        let afterStop = await registry.activeEntry(forHost: reservedHost)
        XCTAssertNil(afterStop)

        let vodProposal = try await service.handleTool(
            name: "propose_hls_fixture_start",
            arguments: [
                "profileID": "baseline-aligned-codecs",
                "playbackConfiguration": ["presentationMode": "vodStatic"]
            ],
            client: client
        )
        let vodProposalPayload = try XCTUnwrap(vodProposal["payload"] as? [String: Any])
        let vodProposalToken = try XCTUnwrap(vodProposalPayload["proposalToken"] as? String)
        let vodApply = try await service.handleTool(
            name: "apply_hls_fixture_start",
            arguments: ["proposalToken": vodProposalToken],
            client: client
        )
        let vodApplyPayload = try XCTUnwrap(vodApply["payload"] as? [String: Any])
        let vodRunID = try XCTUnwrap(vodApplyPayload["runID"] as? String)
        let vodPreview = try await service.handleTool(
            name: "hls_fixture_window_preview",
            arguments: [
                "runID": vodRunID,
                "path": "video-lo/stream.m3u8",
                "elapsedSeconds": 999
            ],
            client: client
        )
        let vodPreviewPayload = try XCTUnwrap(vodPreview["payload"] as? [String: Any])
        let authoredText = try String(
            contentsOf: baselineProfileDirectory().appendingPathComponent("video-lo/stream.m3u8"),
            encoding: .utf8
        )
        XCTAssertEqual(vodPreviewPayload["presentationMode"] as? String, "vodStatic")
        XCTAssertEqual(vodPreviewPayload["clockDependent"] as? Bool, false)
        XCTAssertEqual(vodPreviewPayload["hasEndList"] as? Bool, true)
        XCTAssertNil(vodPreviewPayload["mediaSequence"])
        XCTAssertEqual(vodPreviewPayload["playlistText"] as? String, authoredText)
        _ = try await service.handleTool(
            name: "hls_fixture_stop",
            arguments: ["runID": vodRunID],
            client: client
        )
    }

    func testFixtureToolsAppearInProductionManifest() {
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.isSuperset(of: [
            "hls_fixture_capabilities",
            "hls_fixture_profiles_list",
            "hls_fixture_status",
            "hls_fixture_window_preview",
            "propose_hls_fixture_start",
            "apply_hls_fixture_start",
            "hls_fixture_stop"
        ]))
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionToolNames.isSuperset(of: [
            "hls_substitution_profiles_list",
            "propose_hls_substitution_start",
            "apply_hls_substitution_start",
            "hls_substitution_status",
            "hls_substitution_stop"
        ]))
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "propose_hls_fixture_start"), .hlsFixtureLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "hls_fixture_status"), .hlsFixtureInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "hls_fixture_window_preview"), .hlsFixtureInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "propose_hls_substitution_start"), .hlsSubstitutionLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "hls_substitution_status"), .hlsFixtureInspect)
    }

    func testCompositeSubstitutionUsesOneApprovalAndReturnsOneExperiment() async throws {
        let registry = HLSFixtureOriginRegistry()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-mcp-\(UUID().uuidString)", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: registry
        )
        runStore.load()
        let coordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: base.appendingPathComponent("experiments.json")
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let service = MCPHLSFixtureService(
            runStore: runStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: MCPPolicyStore(),
            grantStore: MCPClientGrantStore(),
            auditStore: MCPAuditStore(),
            substitutionCoordinator: coordinator
        )
        let client = MCPClientRecord(
            id: "substitution-client",
            displayName: "Player QA Agent",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        var scopedArguments: [String: Any] = ["profileID": "multilingual-text-vod-v1",
            "scope": "selectedPlaylist", "conflictStrategy": "cancel", "scheme": "https",
            "host": "media.example.test", "path": "/master.m3u8?variant=reviewed",
            "sourceClientAddress": "192.0.2.10", "missingTextTrackID": "es"]
        let scopedProposal = try await service.handleTool(name: "propose_hls_substitution_start",
            arguments: scopedArguments, client: client)
        let scopedPayload = try XCTUnwrap(scopedProposal["payload"] as? [String: Any])
        let policy = try XCTUnwrap(scopedPayload["scopePolicy"] as? [String: Any])
        XCTAssertEqual(policy["entryQueryPolicy"] as? String, "exactCanonical")
        XCTAssertEqual(policy["clientAddress"] as? String, "192.0.2.10")
        XCTAssertEqual(policy["missingTextTrackID"] as? String, "es")
        XCTAssertEqual(approvalStore.pendingCount, 0, "Preparation must not activate or grant approval")
        scopedArguments["sourceClientAddress"] = 42
        do {
            _ = try await service.handleTool(name: "propose_hls_substitution_start", arguments: scopedArguments, client: client)
            XCTFail("Malformed client scope must not become a legacy all-client proposal")
        } catch let error as MCPStructuredError { XCTAssertEqual(error.code, .malformedRequest) }
        let proposal = try await service.handleTool(
            name: "propose_hls_substitution_start",
            arguments: [
                "profileID": "player-qa-widescreen-v1",
                "scope": "selectedPlaylist",
                "conflictStrategy": "cancel",
                "scheme": "https",
                "host": "media.example.com",
                "port": 443,
                "path": "/live/master.m3u8?token=redacted",
                "playbackConfiguration": [
                    "presentationMode": "vodStatic",
                    "intent": "deliberateFault",
                    "windowSegmentCount": 6,
                    "loopBoundaryTreatment": "omitDiscontinuity",
                    "segmentURIIdentity": "reuseAssetURI",
                    "programDateTimeTreatment": "omit"
                ]
            ],
            client: client
        )
        let proposalPayload = try XCTUnwrap(proposal["payload"] as? [String: Any])
        XCTAssertEqual(proposalPayload["maxRunDurationSeconds"] as? Int, 1_800)
        XCTAssertEqual(proposalPayload["failOpen"] as? Bool, true)
        XCTAssertFalse(String(describing: proposalPayload).contains("token=redacted"))
        XCTAssertEqual((proposalPayload["conflicts"] as? [String: Any])?["hasConflicts"] as? Bool, false)
        XCTAssertEqual(proposalPayload["isDeliberatelyNonconformant"] as? Bool, true)
        XCTAssertEqual((proposalPayload["recommendationViolations"] as? [[String: Any]])?.count, 3)
        let proposalToken = try XCTUnwrap(proposalPayload["proposalToken"] as? String)
        let applyArguments: [String: Any] = ["proposalToken": proposalToken]

        let authorization: MCPApprovalAuthorization
        do {
            _ = try await service.handleTool(
                name: "apply_hls_substitution_start",
                arguments: applyArguments,
                client: client
            )
            return XCTFail("Expected one approval request")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            XCTAssertEqual(approvalStore.pendingCount, 1)
            let requestID = try XCTUnwrap(error.details?["requestID"])
            authorization = try approvalStore.approve(requestID: requestID)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let authorizationData = try encoder.encode(authorization)
        let authorizationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: authorizationData) as? [String: Any]
        )
        let applied = try await service.handleTool(
            name: "apply_hls_substitution_start",
            arguments: [
                "proposalToken": proposalToken,
                "approval": authorizationObject
            ],
            client: client
        )
        let payload = try XCTUnwrap(applied["payload"] as? [String: Any])
        let experimentID = try XCTUnwrap(payload["experimentID"] as? String)
        XCTAssertEqual(payload["state"] as? String, "active")
        XCTAssertEqual(
            (payload["playbackConfiguration"] as? [String: Any])?["windowSegmentCount"] as? Int,
            6
        )
        XCTAssertEqual(
            (payload["playbackConfiguration"] as? [String: Any])?["presentationMode"] as? String,
            "vodStatic"
        )
        XCTAssertEqual(runStore.activeRuns(ownedBy: client.id).count, 1)
        XCTAssertEqual(approvalStore.pendingCount, 0)
        let routed = await coordinator.routeStore.decision(
            for: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "media.example.com",
                port: 443,
                path: "/live/master.m3u8?new-token=hidden",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        XCTAssertEqual(routed?.mcpProvenance?.clientID, client.id)
        XCTAssertEqual(routed?.mcpProvenance?.capability, .hlsSubstitutionLifecycle)

        let stopped = try await service.handleTool(
            name: "hls_substitution_stop",
            arguments: ["experimentID": experimentID],
            client: client
        )
        XCTAssertEqual((stopped["payload"] as? [String: Any])?["state"] as? String, "stopped")
        XCTAssertTrue(runStore.activeRuns(ownedBy: client.id).isEmpty)
        let scopedToken = try XCTUnwrap(scopedPayload["proposalToken"] as? String)
        do {
            _ = try await service.handleTool(name: "apply_hls_substitution_start",
                arguments: ["proposalToken": scopedToken], client: client)
            XCTFail("Scoped activation still requires approval")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let approved = try approvalStore.approve(requestID: requestID)
            let object = try JSONSerialization.jsonObject(with: encoder.encode(approved))
            let result = try await service.handleTool(name: "apply_hls_substitution_start",
                arguments: ["proposalToken": scopedToken, "approval": object], client: client)
            let body = try XCTUnwrap(result["payload"] as? [String: Any])
            let scopedID = try XCTUnwrap(body["experimentID"] as? String)
            let loaded = await coordinator.experiment(id: try XCTUnwrap(UUID(uuidString: scopedID)))
            XCTAssertEqual(loaded?.requestPolicy, .init(clientAddress: "192.0.2.10", missingTextTrackID: "es"))
            XCTAssertEqual(loaded?.scope, .selectedPlaylist(path: "/master.m3u8?variant=reviewed"))
            _ = try await service.handleTool(name: "hls_substitution_stop", arguments: ["experimentID": scopedID], client: client)
            XCTAssertTrue(runStore.activeRuns(ownedBy: client.id).isEmpty)
        }
    }

    /// P2 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): a caller can
    /// request a longer TTL than the default 1800s at start time, and `hls_substitution_extend` can
    /// push an already-running substitution's expiry out further without restarting it — no
    /// propose/apply/approval step for extend, unlike start.
    func testCustomTTLAndExtendAvoidTheThirtyMinuteReapprovalCeremony() async throws {
        let registry = HLSFixtureOriginRegistry()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-ttl-mcp-\(UUID().uuidString)", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: registry
        )
        runStore.load()
        let coordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: base.appendingPathComponent("experiments.json")
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let service = MCPHLSFixtureService(
            runStore: runStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: MCPPolicyStore(),
            grantStore: MCPClientGrantStore(),
            auditStore: MCPAuditStore(),
            substitutionCoordinator: coordinator
        )
        let client = MCPClientRecord(
            id: "substitution-ttl-client",
            displayName: "Player QA Agent",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        let proposal = try await service.handleTool(
            name: "propose_hls_substitution_start",
            arguments: [
                "profileID": "player-qa-widescreen-v1",
                "scope": "host",
                "conflictStrategy": "cancel",
                "scheme": "https",
                "host": "media.example.com",
                "port": 443,
                "ttlSeconds": 7_200
            ],
            client: client
        )
        let proposalPayload = try XCTUnwrap(proposal["payload"] as? [String: Any])
        XCTAssertEqual(proposalPayload["maxRunDurationSeconds"] as? Int, 7_200)
        let proposalToken = try XCTUnwrap(proposalPayload["proposalToken"] as? String)

        let authorization: MCPApprovalAuthorization
        do {
            _ = try await service.handleTool(
                name: "apply_hls_substitution_start",
                arguments: ["proposalToken": proposalToken],
                client: client
            )
            return XCTFail("Expected one approval request")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            authorization = try approvalStore.approve(requestID: requestID)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let authorizationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try encoder.encode(authorization)
            ) as? [String: Any]
        )
        let applied = try await service.handleTool(
            name: "apply_hls_substitution_start",
            arguments: ["proposalToken": proposalToken, "approval": authorizationObject],
            client: client
        )
        let payload = try XCTUnwrap(applied["payload"] as? [String: Any])
        let experimentID = try XCTUnwrap(payload["experimentID"] as? String)
        let startedAt = try XCTUnwrap(payload["startedAt"] as? String)
        let expiresAt = try XCTUnwrap(payload["expiresAt"] as? String)
        let iso = ISO8601DateFormatter()
        let observedDuration = try XCTUnwrap(iso.date(from: expiresAt))
            .timeIntervalSince(try XCTUnwrap(iso.date(from: startedAt)))
        XCTAssertEqual(observedDuration, 7_200, accuracy: 1)

        // `hls_substitution_extend` needs no proposal/approval — a single call, like stop.
        let extended = try await service.handleTool(
            name: "hls_substitution_extend",
            arguments: ["experimentID": experimentID, "ttlSeconds": 10_800],
            client: client
        )
        let extendedPayload = try XCTUnwrap(extended["payload"] as? [String: Any])
        XCTAssertEqual(extendedPayload["state"] as? String, "active")
        let newExpiresAtString = try XCTUnwrap(extendedPayload["expiresAt"] as? String)
        let newExpiresAt = try XCTUnwrap(iso.date(from: newExpiresAtString))
        XCTAssertTrue(newExpiresAt > (try XCTUnwrap(iso.date(from: expiresAt))))

        _ = try await service.handleTool(
            name: "hls_substitution_stop",
            arguments: ["experimentID": experimentID],
            client: client
        )
    }

    /// P2 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): the stall-class
    /// heuristic surfaces in `hls_substitution_status`'s metrics without any new tool — matcher
    /// miss (zero hits) is distinguishable from a healthy delivery via the same field.
    func testSubstitutionStatusExposesStallClassInMetrics() async throws {
        let registry = HLSFixtureOriginRegistry()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-stall-mcp-\(UUID().uuidString)", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: registry
        )
        runStore.load()
        let routeStore = HLSSubstitutionRouteStore()
        let coordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: routeStore,
            persistenceURL: base.appendingPathComponent("experiments.json")
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let service = MCPHLSFixtureService(
            runStore: runStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: MCPApprovalStore(),
            policyStore: MCPPolicyStore(),
            grantStore: MCPClientGrantStore(),
            auditStore: MCPAuditStore(),
            substitutionCoordinator: coordinator
        )
        let client = MCPClientRecord(
            id: "substitution-stall-client",
            displayName: "Player QA Agent",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        let started = try await coordinator.start(
            owner: .mcpClient(id: client.id, displayName: client.displayName),
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host
        )

        let beforeAnyTraffic = try await service.handleTool(
            name: "hls_substitution_status",
            arguments: ["experimentID": started.id.uuidString],
            client: client
        )
        let metricsBefore = try XCTUnwrap((beforeAnyTraffic["payload"] as? [String: Any])?["metrics"] as? [String: Any])
        XCTAssertEqual(metricsBefore["stallClass"] as? String, "matcherMiss")

        for _ in 0 ..< 4 {
            _ = await routeStore.decision(for: CapturedRequest(
                method: "GET", scheme: .https, host: "media.example.com", port: 443,
                path: "/master.m3u8", headers: [], bodyData: nil, bodySize: nil
            ))
        }

        let afterPlaylistOnlyTraffic = try await service.handleTool(
            name: "hls_substitution_status",
            arguments: ["experimentID": started.id.uuidString],
            client: client
        )
        let metricsAfter = try XCTUnwrap((afterPlaylistOnlyTraffic["payload"] as? [String: Any])?["metrics"] as? [String: Any])
        XCTAssertEqual(metricsAfter["stallClass"] as? String, "likelyClientRejectOrStall")
        XCTAssertEqual(metricsAfter["stallClassBasis"] as? String, "sinceStart")

        _ = try await coordinator.stop(id: started.id)
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): an invalid
    /// `playbackConfiguration` enum value must echo the valid set back rather than just saying
    /// "is invalid" — the field session called this "invalid-flag roulette."
    func testInvalidPlaybackConfigurationEnumValueEchoesValidSet() async throws {
        let registry = HLSFixtureOriginRegistry()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-invalid-enum-\(UUID().uuidString)", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            profileRootURL: profilesRoot(),
            originRegistry: registry
        )
        runStore.load()
        let coordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: base.appendingPathComponent("experiments.json")
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let service = MCPHLSFixtureService(
            runStore: runStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: MCPApprovalStore(),
            policyStore: MCPPolicyStore(),
            grantStore: MCPClientGrantStore(),
            auditStore: MCPAuditStore(),
            substitutionCoordinator: coordinator
        )
        let client = MCPClientRecord(
            id: "substitution-invalid-enum-client",
            displayName: "Player QA Agent",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        do {
            _ = try await service.handleTool(
                name: "propose_hls_substitution_start",
                arguments: [
                    "profileID": "player-qa-widescreen-v1",
                    "scope": "selectedPlaylist",
                    "conflictStrategy": "cancel",
                    "scheme": "https",
                    "host": "media.example.com",
                    "port": 443,
                    "path": "/live/master.m3u8",
                    "playbackConfiguration": ["loopBoundaryTreatment": "resetSilently"]
                ],
                client: client
            )
            XCTFail("Expected malformedRequest for an unrecognized loopBoundaryTreatment value")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertEqual(error.details?["field"], "playbackConfiguration.loopBoundaryTreatment")
            XCTAssertEqual(error.details?["provided"], "resetSilently")
            XCTAssertEqual(error.details?["validValues"], "declareDiscontinuity, omitDiscontinuity")
            XCTAssertTrue(error.message.contains("declareDiscontinuity"))
            XCTAssertTrue(error.message.contains("omitDiscontinuity"))
        }
    }
}
