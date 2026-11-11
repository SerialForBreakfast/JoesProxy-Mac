import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPMediaDiscoveryTests: XCTestCase {
    func testAnalysisDiscoverySharesBudgetsWithManifestAndExportedGuide() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Analysis budget discovery")
        let client = enrollment.client
        let descriptors = stack.protocolService.toolDescriptors(for: client)
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let guide = MCPAgentExportService.generateGuideMarkdown(manifest: manifest)
        var bytes = 0, count = 0
        var unavailable = Set<String>()
        for tool in manifest.tools {
            guard let analysis = tool.analysis else { continue }
            guard let descriptor = descriptors.first(where: { $0["name"] as? String == tool.name }) else {
                unavailable.insert(tool.name)
                continue
            }
            let metadata = try XCTUnwrap((descriptor["_meta"] as? [String: Any])?["joesproxy.analysis"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: metadata)
            XCTAssertEqual(try JSONDecoder().decode(MCPAnalysisDescriptor.self, from: data), analysis)
            XCTAssertTrue(guide.contains(analysis.method))
            XCTAssertTrue(guide.contains(analysis.coverage))
            XCTAssertTrue(analysis.availability.contains("per call"))
            XCTAssertFalse(analysis.nextAction.isEmpty)
            bytes += data.count
            count += 1
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(unavailable, ["diagnostic_run_brief", "capture_calculate", "artifact_calculate", "artifact_inventory", "artifact_search", "artifact_response_brief", "artifact_compare_responses"])
        XCTAssertLessThan(bytes, 4096, "Budget discovery must remain compact")
        XCTAssertNil(MCPCapabilitiesManifestBuilder.analysis(for: "vision_ocr"))
        XCTAssertTrue(guide.contains("OCR and semantic artifact retrieval are unavailable"))
        let sessionID = try await initializeSession(protocolService: stack.protocolService, bearer: enrollment.plaintextCredential, structuredOnly: true)
        let response = await stack.protocolService.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"agent_toolset_status","arguments":{}}}"#.utf8))
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let status = try JSONDecoder().decode(MCPToolsetStatusDTO.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(status.analysis.count, 3)
        XCTAssertTrue(status.unavailableAnalyses.contains("diagnostic_run_brief"))
        XCTAssertTrue(unavailable.isSubset(of: Set(status.unavailableAnalyses)))
        XCTAssertTrue(status.unavailableAnalyses.contains("vision_ocr"))
        for (name, analysis) in status.analysis { XCTAssertEqual(analysis, MCPCapabilitiesManifestBuilder.analysis(for: name)) }
        let metrics: [String: Any] = ["fixture": "analysis-discovery-v1", "descriptors": count, "metadataBytes": bytes,
            "catalogCalls": 1, "additionalBodyReads": 0,
            "fullCatalogBytes": try JSONSerialization.data(withJSONObject: descriptors).count,
            "statusResultBytes": try JSONSerialization.data(withJSONObject: result).count]
        print("ANALYSIS_DISCOVERY_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
    func testCapabilitiesRevisionReflectsCurrentToolAndDTOContract() {
        XCTAssertEqual(MCPCapabilitiesRevision.current, 30)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "https_rules_get"), .httpsRulesInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "https_rules_set"), .httpsRulesManage)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "effect_bundle_advance"), .enableRule)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "agent_toolset_status"), .agentResource)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "agent_toolset_select"), .agentResource)
        let mismatchedRoutes = MCPCapabilitiesManifestBuilder.productionTools.compactMap { tool -> String? in
            MCPCapabilityRouter.capability(forTool: tool.name) == tool.capability ? nil : tool.name
        }
        XCTAssertEqual(mismatchedRoutes, [], "every advertised tool must route to its declared capability")
        let names = MCPCapabilitiesManifestBuilder.productionTools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "canonical registry tool names must be unique")
        XCTAssertTrue(
            MCPCapabilitiesManifestBuilder.productionTools.allSatisfy {
                $0.discoveryToolsets.contains(.all) && !$0.discoveryToolsets.isEmpty
            },
            "every production tool must have canonical discovery membership"
        )
    }

    func testMediaReadinessHLSManifestRecommendsWorkflow() throws {
        let body = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        https://cdn.example.com/video.m3u8?token=secret
        """.utf8)
        let store = InMemorySessionStore()
        let session = makeSession(path: "/master.m3u8", mimeType: "application/vnd.apple.mpegurl", body: body)
        store.append(session)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let readiness = try service.mediaReadiness(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(readiness.mediaType, "hls")
        XCTAssertEqual(readiness.bodyEligibility, .available)
        XCTAssertEqual(readiness.recommendedWorkflowID, "hls_manifest_analysis")
        XCTAssertTrue(readiness.supportedTools.contains("media_manifest_structure"))
        XCTAssertTrue(readiness.supportedTools.contains("media_inspection_start"))
    }

    func testHLSAliasesQueryPathsAndSignatureSniffingShareClassification() {
        let alias = makeSession(
            path: "/guide/playlist?token=secret",
            mimeType: "audio/x-mpegurl; charset=utf-8",
            body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:6".utf8)
        )
        let signedPath = makeSession(
            path: "/guide/live.m3u8?Policy=opaque#fragment",
            mimeType: "application/octet-stream",
            body: Data("ignored".utf8)
        )
        let sniffed = makeSession(
            path: "/guide/manifest",
            mimeType: "text/plain",
            body: Data("\u{feff}  #EXTM3U\n#EXT-X-VERSION:7".utf8)
        )

        XCTAssertEqual(MediaDetector.mediaType(for: alias), .hls)
        XCTAssertEqual(MediaDetector.mediaType(for: signedPath), .hls)
        XCTAssertEqual(MediaDetector.mediaType(for: sniffed), .hls)
    }

    func testManifestSniffingSurvivesMultibyteCharacterSplitAtPrefixBoundary() {
        func bodyWithSplitUTF8Prefix(_ marker: String) -> Data {
            var body = Data(marker.utf8)
            body.append(Data(repeating: 0x20, count: 4_095 - body.count))
            body.append(0xC3)
            body.append(0xA9)
            return body
        }

        let hls = makeSession(
            path: "/stream",
            mimeType: "text/plain",
            body: bodyWithSplitUTF8Prefix("#EXTM3U\n")
        )
        let dash = makeSession(
            path: "/manifest",
            mimeType: "text/plain",
            body: bodyWithSplitUTF8Prefix("<MPD>")
        )

        XCTAssertEqual(MediaDetector.mediaType(for: hls), .hls)
        XCTAssertEqual(MediaDetector.mediaType(for: dash), .dash)
    }

    func testMediaReadinessDeferredBodyBlocksInspection() throws {
        let store = InMemorySessionStore()
        let session = makeSession(
            path: "/master.m3u8",
            mimeType: "application/vnd.apple.mpegurl",
            body: nil,
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: nil,
                bodySize: 10,
                bodyDeferred: true
            )
        )
        store.append(session)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let readiness = try service.mediaReadiness(sessionID: session.id, policyRevision: .initial)

        XCTAssertEqual(readiness.bodyEligibility, .deferred)
        XCTAssertFalse(readiness.supportedTools.contains("media_inspection_start"))
        XCTAssertFalse(readiness.supportedTools.contains("media_manifest_structure"))
        let captureAnalyses = readiness.supportedAnalyses.filter {
            $0.kind != MCPMediaAnalysisKind.liveMediaEngine.rawValue
        }
        XCTAssertTrue(captureAnalyses.allSatisfy { !$0.eligible })
        XCTAssertTrue(captureAnalyses.allSatisfy { $0.reason == "captured_body_deferred" })
    }

    func testMediaContextIncludesLabelsWithoutRawURLs() throws {
        let body = Data("""
        {"streamingUrl":"https://cdn.example.com/live/master.m3u8?token=secret","contentId":"abc123"}
        """.utf8)
        let store = InMemorySessionStore()
        let session = makeSession(path: "/playback.json", mimeType: "application/json", body: body)
        store.append(session)
        let service = MCPMediaInspectionService(
            sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store)
        )

        let context = try service.mediaContext(sessionID: session.id, policyRevision: .initial)

        XCTAssertFalse(context.contextLabels.isEmpty)
        XCTAssertNotNil(context.hlsDiscovery)
        let encoded = try JSONEncoder().encode(context)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("cdn.example.com"))
        XCTAssertNotNil(context.hlsDiscovery)
        XCTAssertEqual(context.hlsDiscovery?.hasContentID, true)
    }

    func testCapabilitiesManifestListsOnlyProfileAndServiceAvailableTools() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Manifest parity")
        let sessionID = try await initializeSession(protocolService: stack.protocolService, bearer: enrollment.plaintextCredential)

        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let listedNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(listedNames.contains("sessions_list"))
        XCTAssertTrue(listedNames.contains("capture_digest"))
        XCTAssertTrue(listedNames.contains("client_cleanup_status"))
        XCTAssertTrue(listedNames.contains("media_summary"))
        XCTAssertFalse(listedNames.contains("mcp_slow"))
        XCTAssertFalse(listedNames.contains("record_test_marker"))
        XCTAssertFalse(listedNames.contains("bookmarks_list"))
        XCTAssertFalse(listedNames.contains("return_to_normal"))
        XCTAssertTrue(tools.allSatisfy { $0["outputSchema"] != nil })

        let sessionList = try XCTUnwrap(tools.first { $0["name"] as? String == "sessions_list" })
        let sessionInput = try XCTUnwrap(sessionList["inputSchema"] as? [String: Any])
        let sessionProperties = try XCTUnwrap(sessionInput["properties"] as? [String: Any])
        XCTAssertNotNil(sessionProperties["projection"])
        XCTAssertNotNil(sessionProperties["sinceSequence"])
        XCTAssertNotNil(sessionProperties["ifStateToken"])
        XCTAssertNotNil(sessionProperties["maxResponseBytes"])

        let inspection = try XCTUnwrap(tools.first { $0["name"] as? String == "media_inspection_start" })
        let input = try XCTUnwrap(inspection["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let analyses = try XCTUnwrap(properties["analyses"] as? [String: Any])
        let items = try XCTUnwrap(analyses["items"] as? [String: Any])
        let values = try XCTUnwrap(items["enum"] as? [String])
        XCTAssertFalse(values.contains(MCPMediaAnalysisKind.liveMediaEngine.rawValue))
    }

    /// Proves the AG-1..AG-6 / MF-2..MF-5 / etc. tool families are actually dispatchable through
    /// the live JSON-RPC handler, not merely present as source with passing isolated unit tests.
    /// A representative tool from every newly-wired family is called end-to-end; each must return
    /// a structured result, never the "Unknown or unavailable tool" -32601 the dispatcher returns
    /// for anything absent from the capability manifest or the top-level switch.
    func testNewlyWiredToolFamiliesAreDispatchable() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Wiring parity", assignedProfileID: .shareable)
        let sessionID = try await initializeSession(protocolService: stack.protocolService, bearer: enrollment.plaintextCredential)

        func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let argsData = try JSONSerialization.data(withJSONObject: arguments)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
            let response = await stack.protocolService.handleHTTPRequest(
                method: "POST",
                path: MCPNetworkConstants.endpointPath,
                headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
                body: Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(argsJSON)}}"#.utf8)
            )
            let object = try response.jsonBodyObject()
            XCTAssertNil(object["error"], "\(name) unexpectedly errored: \(object["error"] ?? "")")
            return try XCTUnwrap(object["result"] as? [String: Any], "\(name) returned no result")
        }

        // One read-only call per newly-wired family, chosen to need no prior state.
        _ = try await call("localization_mock_list_presets")
        _ = try await call("stateful_mock_list_backends")
        _ = try await call("stateful_mock_list_presets")
        _ = try await call("list_semantic_mock_rules")

        // No active fault-isolation session exists yet, so this must fail with a real, specific
        // MCPStructuredError from inside the handler — proving it reached the service and was
        // rejected on the merits, not a -32601 "Unknown or unavailable tool" from a missing
        // dispatch case or manifest entry.
        let isolationResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"fault_isolation_report","arguments":{}}}"#.utf8)
        )
        let isolationObject = try isolationResponse.jsonBodyObject()
        let isolationError = try XCTUnwrap(isolationObject["error"] as? [String: Any])
        XCTAssertNotEqual(isolationError["code"] as? Int, -32601, "fault_isolation_report should not be an unknown/unavailable tool")
        let isolationData = try XCTUnwrap(isolationError["data"] as? [String: Any])
        XCTAssertEqual(isolationData["message"] as? String, "No active bisection report found.")

        // A full propose -> step -> report lifecycle for the hypothesis-DAG family, proving
        // argument decoding (including the nested nodeInputs array) round-trips correctly.
        let dagResult = try await call("propose_hypothesis_dag", [
            "name": "Wiring test plan",
            "targetBug": "checkout 500s intermittently",
            "nodeInputs": [
                [
                    "id": "n1",
                    "title": "Upstream timeout",
                    "explanation": "Payments gateway may be slow under load",
                    "mutationType": "latencyInjection",
                    "mutationTarget": "https://payments.example.com/*",
                    "expectedOutcome": "Client should surface a timeout error, not hang indefinitely."
                ]
            ]
        ])
        let dagStructured = try XCTUnwrap(dagResult["structuredContent"] as? [String: Any])
        let graphID = try XCTUnwrap(dagStructured["id"] as? String)

        // The report isn't generated until the graph is stepped to completion, so this call is
        // expected to fail on the merits — but it must be a real, specific error from inside the
        // handler, not a -32601 "Unknown or unavailable tool" from a missing dispatch case.
        let reportResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_fault_bisection_report","arguments":{"graphID":"\#(graphID)"}}}"#.utf8)
        )
        let reportObject = try reportResponse.jsonBodyObject()
        let reportError = try XCTUnwrap(reportObject["error"] as? [String: Any])
        XCTAssertNotEqual(reportError["code"] as? Int, -32601, "get_fault_bisection_report should not be an unknown/unavailable tool")

        // A read-only media-family tool that reads real (empty) captured state, proving the
        // MCPMediaInspectionService additions dispatch through the same path as the pre-existing
        // media tools rather than a disconnected MCPMediaAnalysisKind pipeline.
        let cmcdResult = try await call("cmcd_telemetry_inspection", ["sessionIDs": [] as [String]])
        XCTAssertNotNil(cmcdResult["structuredContent"])
    }

    func testCapabilitiesResourceReadable() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Capabilities resource")
        let sessionID = try await initializeSession(protocolService: stack.protocolService, bearer: enrollment.plaintextCredential)

        let response = await resourcesRead(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            uri: "joesproxy://agent/capabilities"
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents[0]["text"] as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(MCPDTOEnvelope<MCPCapabilitiesManifest>.self, from: data)
        XCTAssertEqual(envelope.payload.bundleVersion, MCPCapabilitiesRevision.bundleVersion())
        XCTAssertFalse(envelope.payload.tools.map(\.name).contains("record_test_marker"))
        XCTAssertFalse(envelope.payload.tools.map(\.name).contains("bookmarks_list"))
    }

    func testCoreToolsetReducesSerializedCatalogWithoutChangingFullCatalog() throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Toolset byte budget")
        let legacyClient = enrollment.client
        var explicitAllClient = legacyClient
        explicitAllClient.preferredToolset = .all
        var coreClient = legacyClient
        coreClient.preferredToolset = .core

        let legacyDescriptors = stack.protocolService.toolDescriptors(for: legacyClient)
        let allDescriptors = stack.protocolService.toolDescriptors(for: explicitAllClient)
        let coreDescriptors = stack.protocolService.toolDescriptors(for: coreClient)
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDescriptors, options: [.sortedKeys])
        let allData = try JSONSerialization.data(withJSONObject: allDescriptors, options: [.sortedKeys])
        let coreData = try JSONSerialization.data(withJSONObject: coreDescriptors, options: [.sortedKeys])

        XCTAssertEqual(legacyData, allData, "records created before toolsets must retain the complete catalog")
        XCTAssertLessThan(coreDescriptors.count, allDescriptors.count)
        XCTAssertLessThan(coreData.count, allData.count)
        XCTAssertLessThan(
            Double(coreData.count) / Double(allData.count),
            0.75,
            "the compact catalog must provide a material serialized-byte reduction"
        )
        let coreNames = Set(coreDescriptors.compactMap { $0["name"] as? String })
        XCTAssertTrue(coreNames.contains("agent_toolset_select"))
        XCTAssertTrue(coreNames.contains("sessions_list"))
        XCTAssertTrue(coreNames.contains("client_cleanup_status"))
        XCTAssertFalse(coreNames.contains("media_context"))
    }

    func testCanonicalDescriptorCacheIsCompleteAndStableAcrossRepeatedDiscovery() throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Descriptor cache")
        let client = enrollment.client

        let first = stack.protocolService.toolDescriptors(for: client)
        let second = stack.protocolService.toolDescriptors(for: client)
        let firstBytes = try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys])
        let secondBytes = try JSONSerialization.data(withJSONObject: second, options: [.sortedKeys])

        XCTAssertEqual(
            stack.protocolService.cachedProductionToolDescriptorCount,
            MCPCapabilitiesManifestBuilder.productionTools.count
        )
        XCTAssertEqual(firstBytes, secondBytes)
    }

    func testLegacyClientRecordWithoutToolsetDecodesAsAll() throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Legacy toolset record")
        let data = try JSONEncoder().encode(enrollment.client)
        let decoded = try JSONDecoder().decode(MCPClientRecord.self, from: data)

        XCTAssertNil(decoded.preferredToolset)
        XCTAssertEqual(decoded.effectiveToolset, .all)
    }

    func testSelectingCoreToolsetPersistsAndDoesNotMakeHiddenPolicyToolUncallable() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Toolset compatibility")
        let sessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )
        let headers = authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID)

        let selection = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agent_toolset_select","arguments":{"toolset":"core"}}}"#.utf8)
        )
        let selectionObject = try selection.jsonBodyObject()
        XCTAssertNil(selectionObject["error"])
        XCTAssertEqual(stack.clientRegistry.client(id: enrollment.client.id)?.effectiveToolset, .core)

        let listResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#.utf8)
        )
        let listObject = try listResponse.jsonBodyObject()
        let result = try XCTUnwrap(listObject["result"] as? [String: Any])
        let listedTools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertFalse(listedTools.contains { $0["name"] as? String == "media_context" })

        let hiddenCall = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"media_context","arguments":{"sessionID":"00000000-0000-0000-0000-000000000001"}}}"#.utf8)
        )
        let hiddenObject = try hiddenCall.jsonBodyObject()
        let rpcError = hiddenObject["error"] as? [String: Any]
        XCTAssertNotEqual(rpcError?["code"] as? Int, -32601, "toolsets must never become an authorization boundary")
    }

    func testCompactListDefaultPreservesExplicitBroaderRead() async throws {
        let stack = try makeProtocolStack()
        for index in 0..<25 {
            stack.sessionStore.append(
                makeSession(
                    path: "/item/\(index)",
                    mimeType: "application/json",
                    body: Data("{}".utf8)
                )
            )
        }
        let enrollment = try stack.clientRegistry.enroll(displayName: "List budget compatibility")
        let sessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )
        let headers = authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID)

        let defaultResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sessions_list","arguments":{}}}"#.utf8)
        )
        let explicitResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sessions_list","arguments":{"limit":25}}}"#.utf8)
        )

        let defaultItems = try sessionItems(from: defaultResponse)
        let explicitItems = try sessionItems(from: explicitResponse)
        XCTAssertEqual(defaultItems.count, 10)
        XCTAssertEqual(explicitItems.count, 25)
        XCTAssertEqual(
            defaultItems.compactMap { $0["id"] as? String },
            Array(explicitItems.compactMap { $0["id"] as? String }.prefix(10))
        )
    }

    func testInvestigationSnapshotIssuesResolvableClientScopedEvidence() async throws {
        let stack = try makeProtocolStack()
        for index in 0..<4 {
            stack.sessionStore.append(
                makeSession(
                    path: "/snapshot/\(index)",
                    mimeType: "application/json",
                    body: Data("{}".utf8),
                    response: CapturedResponse(
                        statusCode: index == 3 ? 503 : 200,
                        headers: [],
                        bodyData: nil,
                        bodySize: nil
                    )
                )
            )
        }
        let enrollment = try stack.clientRegistry.enroll(displayName: "Snapshot evidence")
        let sessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )
        let headers = authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID)
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"investigation_snapshot","arguments":{"limit":2}}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        XCTAssertEqual(payload["unchanged"] as? Bool, false)
        let evidence = try XCTUnwrap(payload["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.count, 2)
        let stateToken = try XCTUnwrap(payload["stateToken"] as? String)
        let reference = try XCTUnwrap(evidence.first?["reference"] as? [String: Any])
        let evidenceRef = try XCTUnwrap(reference["evidenceRef"] as? String)

        let unchangedResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data("""
            {"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"investigation_snapshot","arguments":{"limit":2,"ifStateToken":"\(stateToken)"}}}
            """.utf8)
        )
        let unchangedObject = try unchangedResponse.jsonBodyObject()
        let unchangedResult = try XCTUnwrap(unchangedObject["result"] as? [String: Any])
        let unchangedStructured = try XCTUnwrap(unchangedResult["structuredContent"] as? [String: Any])
        let unchangedPayload = try XCTUnwrap(unchangedStructured["payload"] as? [String: Any])
        XCTAssertEqual(unchangedPayload["unchanged"] as? Bool, true)
        XCTAssertEqual((unchangedPayload["evidence"] as? [[String: Any]])?.count, 0)
        XCTAssertLessThan(unchangedResponse.body.count, response.body.count)

        var updatedSession = try XCTUnwrap(stack.sessionStore.sessions.last)
        updatedSession.response = CapturedResponse(
            statusCode: 418,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        stack.sessionStore.update(updatedSession)
        let refreshedResponse = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data("""
            {"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"investigation_snapshot","arguments":{"limit":2,"ifStateToken":"\(stateToken)"}}}
            """.utf8)
        )
        let refreshedObject = try refreshedResponse.jsonBodyObject()
        let refreshedResult = try XCTUnwrap(refreshedObject["result"] as? [String: Any])
        let refreshedStructured = try XCTUnwrap(refreshedResult["structuredContent"] as? [String: Any])
        let refreshedPayload = try XCTUnwrap(refreshedStructured["payload"] as? [String: Any])
        XCTAssertEqual(refreshedPayload["unchanged"] as? Bool, false)
        XCTAssertEqual((refreshedPayload["evidence"] as? [[String: Any]])?.count, 2)

        let resolved = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data("""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"evidence_get","arguments":{"evidenceRef":"\(evidenceRef)"}}}
            """.utf8)
        )
        let resolvedObject = try resolved.jsonBodyObject()
        XCTAssertNil(resolvedObject["error"])

        let second = try stack.clientRegistry.enroll(displayName: "Other evidence client")
        let secondSessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: second.plaintextCredential
        )
        let denied = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: second.plaintextCredential, sessionID: secondSessionID),
            body: Data("""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"evidence_get","arguments":{"evidenceRef":"\(evidenceRef)"}}}
            """.utf8)
        )
        XCTAssertNotNil(try denied.jsonBodyObject()["error"])
    }

    func testReadBatchAllowsBoundedReadsAndRejectsMutations() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Read batch")
        let sessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )
        let headers = authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID)
        let allowed = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_batch","arguments":{"requests":[{"name":"capture_digest"},{"name":"investigation_snapshot","arguments":{"limit":1}}]}}}"#.utf8)
        )
        let allowedObject = try allowed.jsonBodyObject()
        let allowedResult = try XCTUnwrap(allowedObject["result"] as? [String: Any])
        let allowedStructured = try XCTUnwrap(allowedResult["structuredContent"] as? [String: Any])
        XCTAssertEqual((allowedStructured["results"] as? [[String: Any]])?.count, 2)

        let rejected = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_batch","arguments":{"requests":[{"name":"proxy_stop"}]}}}"#.utf8)
        )
        XCTAssertNotNil(try rejected.jsonBodyObject()["error"])
    }

    func testStructuredOnlyNegotiationRemovesTextFallbackWithoutChangingLegacy() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Structured negotiation")
        let legacySession = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )
        let compactSession = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            structuredOnly: true
        )

        func digest(sessionID: String, requestID: Int) async throws -> [String: Any] {
            let response = await stack.protocolService.handleHTTPRequest(
                method: "POST",
                path: MCPNetworkConstants.endpointPath,
                headers: authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
                body: Data("""
                {"jsonrpc":"2.0","id":\(requestID),"method":"tools/call","params":{"name":"capture_digest","arguments":{}}}
                """.utf8)
            )
            let object = try response.jsonBodyObject()
            return try XCTUnwrap(object["result"] as? [String: Any])
        }

        let legacy = try await digest(sessionID: legacySession, requestID: 2)
        let compact = try await digest(sessionID: compactSession, requestID: 3)
        XCTAssertNotNil(legacy["content"])
        XCTAssertNotNil(legacy["structuredContent"])
        XCTAssertEqual((compact["content"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(compact["structuredContent"])
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]).count
        let compactBytes = try JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys]).count
        XCTAssertLessThan(compactBytes, legacyBytes)
    }

    func testServerStatusIncludesBundleVersionAndToolCount() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Status")
        let sessionID = try await initializeSession(protocolService: stack.protocolService, bearer: enrollment.plaintextCredential)

        let response = await resourcesRead(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            uri: "joesproxy://server/status"
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents[0]["text"] as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        let envelope = try JSONDecoder().decode(MCPDTOEnvelope<MCPServerStatusDTO>.self, from: data)
        XCTAssertEqual(envelope.payload.capabilitiesBundleVersion, MCPCapabilitiesRevision.bundleVersion())
        XCTAssertLessThan(envelope.payload.toolCount, MCPCapabilitiesManifestBuilder.productionToolCount)
        XCTAssertEqual(envelope.payload.appVersion, Bundle.main.marketingVersionOrDev)
        XCTAssertEqual(envelope.payload.runtime.effectState, "unknown")
    }

    func testRecentAuditResourceOnlyReturnsCallingClientEvents() async throws {
        let stack = try makeProtocolStack()
        let first = try stack.clientRegistry.enroll(displayName: "Audit First")
        let second = try stack.clientRegistry.enroll(displayName: "Audit Second")
        let firstSession = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: first.plaintextCredential
        )
        _ = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: second.plaintextCredential
        )

        let response = await resourcesRead(
            protocolService: stack.protocolService,
            bearer: first.plaintextCredential,
            sessionID: firstSession,
            uri: "joesproxy://audit/recent"
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents.first?["text"] as? String)
        XCTAssertFalse(text.contains(second.client.id))
        XCTAssertFalse(text.contains("detail"))
        XCTAssertFalse(text.contains("credentialFingerprint"))

        let data = try XCTUnwrap(text.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(MCPDTOEnvelope<MCPClientAuditSummaryDTO>.self, from: data)
        XCTAssertFalse(envelope.payload.events.isEmpty)
    }

    func testShareableSessionSummaryIncludesParserSummaries() throws {
        let body = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1200000
        stream.m3u8
        """.utf8)
        let record = makeSession(path: "/master.m3u8", mimeType: "application/vnd.apple.mpegurl", body: body)
        let serializer = MCPDisclosureSerializer()
        let profile = MCPDisclosureProfileDocument(
            id: .shareable,
            revision: 1,
            title: "Shareable",
            allowedFieldClasses: [.parserSummaries, .sessionOpaqueID, .sessionSequence],
            isSelectableInPhase1: true
        )
        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: 1,
            profile: profile
        )
        XCTAssertEqual(summary.parserSummaries, ["hls_master"])
    }

    private struct ProtocolStack {
        var protocolService: MCPProtocolService
        var clientRegistry: MCPClientRegistry
        var sessionStore: InMemorySessionStore
    }

    private func makeProtocolStack() throws -> ProtocolStack {
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
        let sessionStore = InMemorySessionStore()
        let protocolService = MCPProtocolService(
            policyStore: policy,
            clientRegistry: clients,
            auditStore: audit,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore),
            approvalStore: MCPApprovalStore()
        )
        return ProtocolStack(protocolService: protocolService, clientRegistry: clients, sessionStore: sessionStore)
    }

    private func sessionItems(from response: MCPHTTPResponse) throws -> [[String: Any]] {
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        return try XCTUnwrap(payload["items"] as? [[String: Any]])
    }

    private func temporaryURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-ak1-\(UUID().uuidString)-\(suffix).json")
    }

    private func initializeSession(
        protocolService: MCPProtocolService,
        bearer: String,
        structuredOnly: Bool = false
    ) async throws -> String {
        let capabilities = structuredOnly
            ? #"{"experimental":{"joesproxy":{"structuredResultsOnly":true}}}"#
            : #"{}"#
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
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":\(capabilities)}}
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

    private func resourcesRead(
        protocolService: MCPProtocolService,
        bearer: String,
        sessionID: String,
        uri: String
    ) async -> MCPHTTPResponse {
        let body = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\(uri)"}}
        """.utf8)
        return await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: body
        )
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
