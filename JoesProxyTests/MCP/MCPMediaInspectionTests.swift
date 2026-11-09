import Foundation
import XCTest
import zlib
@testable import JoesProxy

@MainActor
final class MCPMediaInspectionTests: XCTestCase {
    func testMediaToolsHaveStableCapabilityRouting() {
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_summary"), .mediaSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_readiness"), .mediaSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_context"), .mediaSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_manifest_structure"), .mediaSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_related_sessions"), .mediaSummary)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "media_inspection_start"), .mediaInspection)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "operation_status"), .mediaInspection)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "operation_cancel"), .mediaInspection)
    }

    /// Regression test for a confirmed bug: `inspect()`'s CPU-heavy analyses run via
    /// `Task.detached`, which never inherits cancellation from its creating task. The two parsers
    /// that accept a `shouldCancel` closure (`MPEGTransportStreamVideoAnalyzer`,
    /// `TimedMetadataID3Parser`) were wired to `{ Task.isCancelled }` of that detached task — which
    /// nothing ever actually cancelled, so an in-progress analysis on a large captured file would
    /// keep running to completion long after the coordinator had already reported the operation
    /// cancelled. This exercises the fix (`runDetachedCancellable`, bridging via
    /// `withTaskCancellationHandler`) directly with a synthetic busy-loop, independent of any real
    /// parser's timing, so the test is fast and deterministic either way.
    func testRunDetachedCancellablePropagatesCancellationPromptly() async throws {
        let service = MCPMediaInspectionService(
            sessionStore: InMemorySessionStore(),
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore())
        )
        let outerTask = Task {
            await service.runDetachedCancellable(priority: .utility) { () -> Int in
                var iterations = 0
                // A huge bound with no cancellation checking would take a very long time to
                // finish on its own — if the fix regresses, this test times out instead of
                // finishing fast, rather than silently passing.
                while !Task.isCancelled && iterations < 2_000_000_000 {
                    iterations += 1
                }
                return iterations
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = Date()
        outerTask.cancel()
        let iterationsCompleted = await outerTask.value
        let elapsed = Date().timeIntervalSince(cancelledAt)
        XCTAssertLessThan(elapsed, 2.0, "cancellation must stop the detached work promptly, not wait for it to run to completion")
        XCTAssertLessThan(iterationsCompleted, 2_000_000_000, "the busy-loop must have observed cancellation before its natural bound")
    }

    func testToolDiscoveryIncludesExplicitMediaSchemas() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policy = MCPPolicyStore(persistenceURL: temporaryURL("discovery-policy"))
        policy.load()
        let clients = MCPClientRegistry(
            persistenceURL: temporaryURL("discovery-clients"),
            credentialStore: credentialStore
        )
        try clients.load()
        let audit = MCPAuditStore(persistenceURL: temporaryURL("discovery-audit"))
        audit.load()
        let protocolService = MCPProtocolService(
            policyStore: policy,
            clientRegistry: clients,
            auditStore: audit,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clients.enroll(displayName: "Media schema test")
        let sessionID = try await initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )

        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: enrollment.plaintextCredential,
                sessionID: sessionID
            ),
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
            guard let name = tool["name"] as? String else { return nil }
            return (name, tool)
        })

        for name in [
            "media_summary", "media_manifest_structure", "media_related_sessions",
            "media_inspection_start", "operation_status", "operation_cancel"
        ] {
            let tool = try XCTUnwrap(toolsByName[name])
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }

        let start = try XCTUnwrap(toolsByName["media_inspection_start"])
        let startSchema = try XCTUnwrap(start["inputSchema"] as? [String: Any])
        let startProperties = try XCTUnwrap(startSchema["properties"] as? [String: Any])
        let analyses = try XCTUnwrap(startProperties["analyses"] as? [String: Any])
        XCTAssertEqual(analyses["uniqueItems"] as? Bool, true)
        XCTAssertEqual(
            analyses["maxItems"] as? Int,
            MCPMediaAnalysisKind.allCases.filter { $0 != .liveMediaEngine }.count
        )
        let itemSchema = try XCTUnwrap(analyses["items"] as? [String: Any])
        let values = try XCTUnwrap(itemSchema["enum"] as? [String])
        XCTAssertFalse(values.contains(MCPMediaAnalysisKind.liveMediaEngine.rawValue))
    }

    func testSummaryClassifiesManifestWithoutDisclosingBodyOrURLs() throws {
        let body = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        https://cdn.example.com/video.m3u8?token=secret
        """.utf8)
        let store = InMemorySessionStore()
        let session = makeSession(path: "/master.m3u8?token=secret", mimeType: "application/vnd.apple.mpegurl", body: body)
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let summary = try service.summary(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(summary.mediaType, "hls")
        XCTAssertEqual(summary.manifestKind, "hls_master")
        XCTAssertEqual(summary.aggregateCounts["variants"], 1)
        XCTAssertNil(summary.containerKind)
        XCTAssertTrue(summary.disclosure.removedFields.contains("rawBodies"))
        let encoded = try JSONEncoder().encode(summary)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("cdn.example.com"))
    }

    func testSummaryInfersTransportContainerWithoutParsingBinaryBodyAsText() throws {
        let store = InMemorySessionStore()
        let session = makeSession(
            path: "/segment.ts",
            mimeType: "video/mp2t",
            body: Data([0x47, 0xFF, 0x00, 0x80])
        )
        store.append(session)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let summary = try service.summary(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(summary.mediaType, "video")
        XCTAssertEqual(summary.containerKind, "mpeg_transport_stream")
        XCTAssertTrue(summary.aggregateCounts.isEmpty)
    }

    func testManifestStructureRedactsSignedURLsAndReturnsSafeHLSFacts() throws {
        let body = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        https://cdn.example.com/video.m3u8?token=secret
        """.utf8)
        let store = InMemorySessionStore()
        let session = makeSession(path: "/master.m3u8", mimeType: "application/vnd.apple.mpegurl", body: body)
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let structure = try service.manifestStructure(sessionID: session.id, policyRevision: .initial)
        let repeatedStructure = try service.manifestStructure(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(structure.kind, "hls")
        XCTAssertEqual(structure.playlistKind, "master")
        XCTAssertEqual(structure.bandwidths, [1_200_000])
        XCTAssertEqual(structure.resolutions, ["1280x720"])
        XCTAssertEqual(structure.hlsVariants.first?.frameRate, nil)
        XCTAssertEqual(structure.hlsVariants.first?.codecs, ["avc1.4d401f"])
        XCTAssertTrue(structure.hlsVariants.first?.variantRef.hasPrefix("hls-variant-") == true)
        XCTAssertEqual(structure.hlsVariants.first?.variantRef, repeatedStructure.hlsVariants.first?.variantRef)
        XCTAssertEqual(structure.unsupportedVariantCount, 0)
        let encoded = try JSONEncoder().encode(structure)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("cdn.example.com"))
    }

    func testDASHManifestStructureOmitsProtectionSecrets() throws {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             xmlns:cenc="urn:mpeg:cenc:2013"
             type="static"
             mediaPresentationDuration="PT10S">
          <ContentProtection
              schemeIdUri="urn:mpeg:dash:mp4protection:2011"
              cenc:default_KID="SECRET-KEY-ID">
            <cenc:pssh>TOP-SECRET-PSSH</cenc:pssh>
          </ContentProtection>
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401f">
              <Representation id="video-secret-id" bandwidth="1200000" width="1280" height="720">
                <SegmentTemplate media="segment-$Number$.m4s?token=SECRET-TOKEN"
                                 initialization="init.mp4?token=SECRET-TOKEN"
                                 duration="2"
                                 timescale="1"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """.utf8)
        let store = InMemorySessionStore()
        let session = makeSession(path: "/manifest.mpd", mimeType: "application/dash+xml", body: body)
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let structure = try service.manifestStructure(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(structure.kind, "dash")
        XCTAssertEqual(structure.protectionSchemes, ["urn:mpeg:dash:mp4protection:2011"])
        XCTAssertEqual(structure.dashRepresentations.first?.bandwidth, 1_200_000)
        XCTAssertEqual(structure.segmentTemplates.first?.hasMediaPattern, true)
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(structure), encoding: .utf8))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("video-secret-id"))
        XCTAssertFalse(text.contains("segment-$Number$"))
    }

    func testID3InspectionReturnsStructureWithoutPayloadText() async throws {
        let secret = "TOP-SECRET-ID3-PAYLOAD"
        let source = MCPMediaInspectionSource(
            sessionID: UUID(),
            data: makeID3Tag(frames: [makeTextFrame(identifier: "TXXX", text: secret)]),
            fileExtension: "ts",
            displayName: "Captured media item"
        )
        let store = InMemorySessionStore()
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let result = try await service.inspect(
            source: source,
            analyses: [.id3TimedMetadata],
            sampleTime: 1,
            policyRevision: .initial
        ) { _, _ in }

        let marker = try XCTUnwrap(result.id3?.markers.first)
        XCTAssertEqual(marker.frameIdentifiers, ["TXXX"])
        XCTAssertTrue(marker.payloadPresent)
        XCTAssertTrue(marker.payloadRedacted)
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(result), encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
    }

    func testInspectionRejectsUnavailableBodiesAndInsufficientTruncatedPrefix() {
        let cases: [(CapturedResponse, String)] = [
            (
                CapturedResponse(
                    statusCode: 200,
                    headers: [],
                    bodyData: nil,
                    bodySize: 10,
                    bodyDeferred: true
                ),
                "captured_body_deferred"
            ),
            (
                CapturedResponse(
                    statusCode: 200,
                    headers: [],
                    bodyData: Data([0]),
                    bodySize: 10,
                    bodyTruncated: true
                ),
                "insufficient_prefix_bytes"
            ),
            (
                CapturedResponse(
                    statusCode: 200,
                    headers: [],
                    bodyData: nil,
                    bodySize: 10,
                    recordingBodyOmissionReason: .metadataOnly
                ),
                "captured_body_omitted"
            ),
            (
                CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
                "captured_body_unavailable"
            )
        ]

        for (response, expectedReason) in cases {
            let store = InMemorySessionStore()
            let session = makeSession(path: "/segment.ts", mimeType: "video/mp2t", body: nil, response: response)
            store.append(session)
            let snapshot = MCPSessionSnapshotService(sessionStore: store)
            let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

            XCTAssertThrowsError(
                try service.inspectionSource(sessionID: session.id, analyses: [.gopFrames])
            ) { error in
                let structured = error as? MCPStructuredError
                XCTAssertEqual(structured?.details?["reason"], expectedReason)
            }
        }
    }

    func testCapturedMediaEngineRejectsManifestBodies() {
        let store = InMemorySessionStore()
        let session = makeSession(
            path: "/master.m3u8",
            mimeType: "application/vnd.apple.mpegurl",
            body: Data("#EXTM3U".utf8)
        )
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        XCTAssertThrowsError(
            try service.inspectionSource(
                sessionID: session.id,
                analyses: [.capturedMediaEngine]
            )
        ) {
            XCTAssertEqual(($0 as? MCPStructuredError)?.code, .malformedRequest)
        }
    }

    func testTruncatedTransportPrefixRemainsEligibleForBoundedStructureAndID3Analysis() throws {
        var prefix = Data(repeating: 0xFF, count: 376)
        prefix[0] = 0x47
        prefix[188] = 0x47
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: prefix,
            bodySize: 2_000_000,
            bodyTruncated: true
        )
        let store = InMemorySessionStore()
        let session = makeSession(path: "/segment.ts", mimeType: "video/mp2t", body: nil, response: response)
        store.append(session)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let readiness = try service.mediaReadiness(sessionID: session.id, policyRevision: .initial)
        XCTAssertEqual(readiness.bodyEligibility, .truncated)
        XCTAssertEqual(readiness.supportedAnalyses.first { $0.kind == "transport_structure" }?.eligible, true)
        XCTAssertEqual(readiness.supportedAnalyses.first { $0.kind == "id3_timed_metadata" }?.eligible, true)
        XCTAssertEqual(readiness.supportedAnalyses.first { $0.kind == "captured_media_engine" }?.eligible, false)
        let source = try service.inspectionSource(
            sessionID: session.id,
            analyses: [.transportStructure, .id3TimedMetadata]
        )
        XCTAssertTrue(source.bodyTruncated)
        XCTAssertEqual(source.reportedOriginalBytes, 2_000_000)
    }

    func testOperationLimitsOwnershipProgressAndCancellation() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let policy = MCPPolicyStore(persistenceURL: temporaryURL("policy"))
        policy.load()
        let audit = MCPAuditStore(persistenceURL: temporaryURL("audit"))
        audit.load()
        let service = SuspendedMediaOperationService()
        var currentDate = Date()
        let coordinator = MCPOperationCoordinator(
            sessionStore: store,
            mediaService: service,
            snapshotService: snapshot,
            policyStore: policy,
            auditStore: audit,
            now: { currentDate }
        )

        var authorizationCount = 0
        let first = try coordinator.startMediaInspection(
            clientID: "client-a",
            mcpSessionID: "session-a",
            sourceSessionID: UUID(),
            analyses: [.gopFrames],
            sampleTime: 1,
            argumentDigest: "first"
        ) {
            authorizationCount += 1
        }
        XCTAssertEqual(authorizationCount, 1)
        XCTAssertEqual(coordinator.activeAnalysisCount, 1)

        XCTAssertThrowsError(
            try coordinator.startMediaInspection(
                clientID: "client-a",
                mcpSessionID: "session-a",
                sourceSessionID: UUID(),
                analyses: [.id3TimedMetadata],
                sampleTime: 1,
                argumentDigest: "duplicate"
            ) {
                XCTFail("Busy work must be rejected before consuming authorization.")
            }
        ) {
            XCTAssertEqual(($0 as? MCPStructuredError)?.code, .busy)
        }

        _ = try coordinator.startMediaInspection(
            clientID: "client-b",
            mcpSessionID: "session-b",
            sourceSessionID: UUID(),
            analyses: [.binaryContainer],
            sampleTime: 1,
            argumentDigest: "second"
        ) {
            authorizationCount += 1
        }
        XCTAssertEqual(authorizationCount, 2)
        XCTAssertEqual(coordinator.activeAnalysisCount, 2)

        XCTAssertThrowsError(
            try coordinator.startMediaInspection(
                clientID: "client-c",
                mcpSessionID: "session-c",
                sourceSessionID: UUID(),
                analyses: [.transportStructure],
                sampleTime: 1,
                argumentDigest: "global"
            ) {
                XCTFail("Global busy work must be rejected before consuming authorization.")
            }
        ) {
            XCTAssertEqual(($0 as? MCPStructuredError)?.code, .busy)
        }

        XCTAssertThrowsError(
            try coordinator.descriptor(
                operationID: first.operationID,
                clientID: "client-b",
                mcpSessionID: "session-b"
            )
        )

        _ = try coordinator.cancel(
            operationID: first.operationID,
            clientID: "client-a",
            mcpSessionID: "session-a"
        )
        let cancelled = try await waitForTerminalDescriptor(
            coordinator: coordinator,
            operationID: first.operationID,
            clientID: "client-a",
            mcpSessionID: "session-a"
        )
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.failureCode, .cancelled)
        XCTAssertFalse(cancelled.stages.isEmpty)
        XCTAssertEqual(coordinator.activeAnalysisCount, 1)
        currentDate = currentDate.addingTimeInterval(MCPOperationCoordinator.completedRetention + 1)
        let expired = try coordinator.descriptor(
            operationID: first.operationID,
            clientID: "client-a",
            mcpSessionID: "session-a"
        )
        XCTAssertEqual(expired.status, .expired)
        XCTAssertNil(expired.result)
        coordinator.cancelAll()
    }

    func testDASHSummaryAndManifestStructureRedactURLsAndProtectionData() throws {
        let xml = """
        <MPD type="dynamic" mediaPresentationDuration="PT32S">
          <BaseURL>https://cdn.example.com/root/?token=secret</BaseURL>
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
            <cenc:pssh>secret-pssh-bytes</cenc:pssh>
          </ContentProtection>
          <Period>
            <AdaptationSet contentType="video" codecs="avc1.640028">
              <SegmentTemplate initialization="init.mp4" media="chunk-$Number$.m4s" timescale="1" duration="4" />
              <Representation bandwidth="2500000" width="1920" height="1080" />
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let store = InMemorySessionStore()
        let session = makeSession(
            path: "/manifest.mpd?token=secret",
            mimeType: "application/dash+xml",
            body: Data(xml.utf8)
        )
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let summary = try service.summary(sessionID: session.id, policyRevision: .initial)
        XCTAssertEqual(summary.mediaType, "dash")
        XCTAssertEqual(summary.manifestKind, "dash")
        XCTAssertEqual(summary.aggregateCounts["representations"], 1)

        let structure = try service.manifestStructure(sessionID: session.id, policyRevision: .initial)
        XCTAssertEqual(structure.kind, "dash")
        XCTAssertEqual(structure.presentationType, "dynamic")
        XCTAssertTrue(structure.hasSegmentTemplate)
        XCTAssertEqual(structure.protectionSchemes, ["urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"])

        let encoded = try JSONEncoder().encode(structure)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("cdn.example.com"))
        XCTAssertTrue(structure.disclosure.removedFields.contains("pssh"))
    }

    func testManifestStructureDecodesGzipEncodedCapturedBody() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        segment.ts
        """
        let gzipped = try XCTUnwrap(gzipCompress(Data(manifest.utf8)))
        let store = InMemorySessionStore()
        let session = makeSession(
            path: "/media.m3u8",
            mimeType: "application/vnd.apple.mpegurl",
            body: gzipped,
            response: CapturedResponse(
                statusCode: 200,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl"),
                    HTTPHeaderField(name: "Content-Encoding", value: "gzip")
                ],
                bodyData: gzipped,
                bodySize: gzipped.count
            )
        )
        store.append(session)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let structure = try service.manifestStructure(sessionID: session.id, policyRevision: .initial)
        XCTAssertEqual(structure.kind, "hls")
        XCTAssertEqual(structure.playlistKind, "media")
        XCTAssertEqual(structure.counts["segments"], 1)
    }

    func testCompletedOperationRetentionCapsPerClient() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let policy = MCPPolicyStore(persistenceURL: temporaryURL("retention-policy"))
        policy.load()
        let audit = MCPAuditStore(persistenceURL: temporaryURL("retention-audit"))
        audit.load()
        let mediaService = FastCompleteMediaOperationService()
        let coordinator = MCPOperationCoordinator(
            sessionStore: store,
            mediaService: mediaService,
            snapshotService: snapshot,
            policyStore: policy,
            auditStore: audit
        )

        var operationIDs: [String] = []
        for index in 0..<(MCPOperationCoordinator.maximumCompletedPerClient + 2) {
            let descriptor = try coordinator.startMediaInspection(
                clientID: "client-a",
                mcpSessionID: "session-a",
                sourceSessionID: UUID(),
                analyses: [.binaryContainer],
                sampleTime: 1,
                argumentDigest: "op-\(index)"
            ) {}
            operationIDs.append(descriptor.operationID)
            _ = try await waitForTerminalDescriptor(
                coordinator: coordinator,
                operationID: descriptor.operationID,
                clientID: "client-a",
                mcpSessionID: "session-a",
                allowedStatuses: [.completed]
            )
        }

        XCTAssertThrowsError(
            try coordinator.descriptor(
                operationID: try XCTUnwrap(operationIDs.first),
                clientID: "client-a",
                mcpSessionID: "session-a"
            )
        )
        let latest = try coordinator.descriptor(
            operationID: try XCTUnwrap(operationIDs.last),
            clientID: "client-a",
            mcpSessionID: "session-a"
        )
        XCTAssertEqual(latest.status, .completed)
    }

    /// Regression coverage for a flagged gap: `MCPOperationCoordinator.operationTimeout` (60s) had
    /// no injection seam, so the timeout path (`runWithTimeout`'s race against `Task.sleep`) was
    /// never actually exercised by any test — exactly the kind of path that regresses silently.
    func testOperationTimesOutAndTransitionsToFailed() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let policy = MCPPolicyStore(persistenceURL: temporaryURL("timeout-policy"))
        policy.load()
        let audit = MCPAuditStore(persistenceURL: temporaryURL("timeout-audit"))
        audit.load()
        let coordinator = MCPOperationCoordinator(
            sessionStore: store,
            mediaService: SuspendedMediaOperationService(),
            snapshotService: snapshot,
            policyStore: policy,
            auditStore: audit,
            operationTimeout: 0.1
        )
        let descriptor = try coordinator.startMediaInspection(
            clientID: "client-timeout",
            mcpSessionID: "session-timeout",
            sourceSessionID: UUID(),
            analyses: [.gopFrames],
            sampleTime: 1,
            argumentDigest: "timeout"
        ) {}

        var finished: MCPOperationDescriptorDTO?
        for _ in 0..<50 {
            let current = try coordinator.descriptor(
                operationID: descriptor.operationID,
                clientID: "client-timeout",
                mcpSessionID: "session-timeout"
            )
            if current.status == .failed {
                finished = current
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try XCTUnwrap(finished, "operation must transition to failed after the injected timeout")
        XCTAssertEqual(result.failureCode, .timeout)
    }

    /// Regression coverage for a flagged gap: nothing proved that policy tightening actually
    /// invalidates a media-inspection operation's result before disclosure, even though
    /// `descriptor()` re-checks `policyRevision` on every read (matching the pattern already
    /// covered for session queries and approvals).
    func testCompletedOperationResultIsInvalidatedByPolicyTightening() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let policy = MCPPolicyStore(persistenceURL: temporaryURL("policy-tighten-op"))
        policy.load()
        let audit = MCPAuditStore(persistenceURL: temporaryURL("audit-tighten-op"))
        audit.load()
        let coordinator = MCPOperationCoordinator(
            sessionStore: store,
            mediaService: FastCompleteMediaOperationService(),
            snapshotService: snapshot,
            policyStore: policy,
            auditStore: audit
        )
        let descriptor = try coordinator.startMediaInspection(
            clientID: "client-policy",
            mcpSessionID: "session-policy",
            sourceSessionID: UUID(),
            analyses: [.binaryContainer],
            sampleTime: 1,
            argumentDigest: "policy-tighten"
        ) {}
        let completed = try await waitForTerminalDescriptor(
            coordinator: coordinator,
            operationID: descriptor.operationID,
            clientID: "client-policy",
            mcpSessionID: "session-policy",
            allowedStatuses: [.completed]
        )
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNotNil(completed.result, "sanity check: the operation must have actually produced a disclosable result")

        _ = policy.bumpRevisionForTightening()

        XCTAssertThrowsError(
            try coordinator.descriptor(
                operationID: descriptor.operationID,
                clientID: "client-policy",
                mcpSessionID: "session-policy"
            )
        ) {
            XCTAssertEqual(($0 as? MCPStructuredError)?.code, .policyDenied, "a tightened policy must invalidate the completed result, not silently keep serving it")
        }
    }

    private func gzipCompress(_ data: Data) -> Data? {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))
        stream.avail_in = uInt(data.count)
        var output = Data()
        var status: Int32 = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let chunkSize = 16_384
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        repeat {
            stream.next_out = UnsafeMutablePointer<Bytef>(&buffer)
            stream.avail_out = uInt(chunkSize)
            status = deflate(&stream, Z_FINISH)
            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(buffer, count: produced)
            }
        } while status == Z_OK
        return status == Z_STREAM_END ? output : nil
    }

    private func waitForTerminalDescriptor(
        coordinator: MCPOperationCoordinator,
        operationID: String,
        clientID: String,
        mcpSessionID: String,
        allowedStatuses: Set<MCPOperationStatus>? = nil
    ) async throws -> MCPOperationDescriptorDTO {
        for _ in 0..<100 {
            let descriptor = try coordinator.descriptor(
                operationID: operationID,
                clientID: clientID,
                mcpSessionID: mcpSessionID
            )
            if let allowedStatuses {
                if allowedStatuses.contains(descriptor.status) {
                    return descriptor
                }
            } else if descriptor.status == .cancelled || descriptor.status == .failed {
                return descriptor
            }
            await Task.yield()
        }
        return try coordinator.descriptor(
            operationID: operationID,
            clientID: clientID,
            mcpSessionID: mcpSessionID
        )
    }

    private func temporaryURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-ag8-\(UUID().uuidString)-\(suffix).json")
    }

    private func initializeSession(
        protocolService: MCPProtocolService,
        bearer: String
    ) async throws -> String {
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let sessionID = try XCTUnwrap(response.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private func authenticatedHeaders(bearer: String, sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer \(bearer)",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            "accept": "application/json, text/event-stream",
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
            MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID
        ]
    }
    private func makeID3Tag(frames: [Data]) -> Data {
        let frameData = frames.reduce(into: Data()) { $0.append($1) }
        var data = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        data.append(synchsafeBytes(frameData.count))
        data.append(frameData)
        return data
    }

    private func makeTextFrame(identifier: String, text: String) -> Data {
        var payload = Data([0x03])
        payload.append(Data(text.utf8))
        var frame = Data(identifier.utf8)
        frame.append(uint32Bytes(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func synchsafeBytes(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    func testCorrelationRetriesDeferredManifestWhenItsBodyArrives() throws {
        let store = InMemorySessionStore()
        let deferredManifest = makeSession(
            path: "/live/index.m3u8",
            mimeType: "application/vnd.apple.mpegurl",
            body: nil,
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: nil,
                bodySize: 80,
                bodyDeferred: true
            )
        )
        let segment = makeSession(
            path: "/live/segment001.ts",
            mimeType: "video/mp2t",
            body: Data(repeating: 0, count: 376)
        )
        store.append(deferredManifest)
        store.append(segment)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let partial = try service.relatedSessions(sessionID: segment.id)
        XCTAssertEqual(partial.status, "partial")
        XCTAssertEqual(partial.skippedBodyReasons["body_deferred"], 1)

        var completedManifest = deferredManifest
        let body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment001.ts\n".utf8)
        completedManifest.response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: body,
            bodySize: body.count
        )
        store.update(completedManifest)

        let matched = try service.relatedSessions(sessionID: segment.id)
        XCTAssertEqual(matched.status, "matched")
        XCTAssertEqual(matched.items.first?.sessionID, deferredManifest.id)
        XCTAssertNil(matched.skippedBodyReasons["body_deferred"])
    }

    private func makeSession(
        path: String,
        mimeType: String,
        body: Data?,
        response explicitResponse: CapturedResponse? = nil
    ) -> SessionRecord {
        let response = explicitResponse ?? CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: mimeType)],
            bodyData: body,
            bodySize: body?.count
        )
        return SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "media.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }
}

@MainActor
private final class FastCompleteMediaOperationService: MCPMediaOperationServicing {
    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        MCPMediaInspectionSource(
            sessionID: sessionID,
            data: Data([0]),
            fileExtension: "ts",
            displayName: "Fixture"
        )
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        progress(1, "complete")
        return MCPMediaInspectionResultDTO(
            sessionID: source.sessionID.uuidString,
            analyses: analyses,
            binaryStructure: nil,
            gop: nil,
            id3: nil,
            mediaEngine: nil,
            diagnostics: [],
            warnings: [],
            disclosure: MCPMediaDisclosureContextDTO(
                captureEpoch: .initial,
                policyRevision: policyRevision,
                generatedAt: Date(),
                removedFields: ["rawBody"],
                partialResultReason: nil,
                truncated: false
            )
        )
    }
}

@MainActor
private final class SuspendedMediaOperationService: MCPMediaOperationServicing {
    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        MCPMediaInspectionSource(
            sessionID: sessionID,
            data: Data([0]),
            fileExtension: "ts",
            displayName: "Fixture"
        )
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        progress(0.5, analyses[0].rawValue)
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
