import XCTest
@testable import JoesProxy

@MainActor
final class MCPMutationModelMigrationTests: XCTestCase {
    func testLegacyBookmarkJSONLoadsWithoutMCPFields() throws {
        let json = """
        [{
          "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
          "name": "Legacy",
          "request": {
            "method": "GET",
            "scheme": "https",
            "host": "api.example.com",
            "port": 443,
            "path": "/legacy",
            "headers": []
          },
          "createdAt": "2026-01-01T00:00:00Z",
          "responseRewrites": [],
          "responseRewriteMode": "savedSnapshot",
          "responseMatchMode": "ignoreQuery"
        }]
        """.data(using: .utf8)!
        let bookmarks = try JSONDecoder().decode([Bookmark].self, from: json)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertNil(bookmarks[0].mcpOrigin)
        XCTAssertNil(bookmarks[0].mcpProvenance)
        XCTAssertNil(bookmarks[0].mcpTargetRevision)
    }

    /// Regression test for a CRITICAL bug: every legacy (non-MCP) bookmark edit path in the app
    /// calls `BookmarkStore.saveBookmarks(_:)` directly — none of them called
    /// `MCPTargetRevisionFingerprint.bookmarkByApplyingRevision` before this fix, so
    /// `mcpTargetRevision` stayed frozen at its old value across a real content edit, silently
    /// defeating the MCP proposal system's staleness check. The fix moved recomputation into the
    /// concrete stores' `saveBookmarks` itself, so every caller gets it for free.
    func testSavingBookmarkThroughStoreRecomputesStaleRevision() throws {
        var bookmark = Bookmark(
            name: "Test",
            request: CapturedRequest(
                method: "GET", scheme: .https, host: "api.example.com", port: 443,
                path: "/original", headers: [], bodyData: nil, bodySize: nil
            )
        )
        bookmark.mcpTargetRevision = MCPTargetRevision(rawValue: "stale-revision-from-before-edit")

        let store = InMemoryBookmarkStore()
        try store.saveBookmarks([bookmark])
        let saved = try XCTUnwrap(store.loadBookmarks().first)

        XCTAssertNotEqual(
            saved.mcpTargetRevision, MCPTargetRevision(rawValue: "stale-revision-from-before-edit"),
            "the store must recompute the revision from current content, not trust whatever the caller passed in"
        )
        XCTAssertEqual(saved.mcpTargetRevision, MCPTargetRevisionFingerprint.revision(for: bookmark))
    }

    /// Same regression, for `ResponseOverrideRule` — every legacy edit method in
    /// `ResponseOverrideStore` (setEnabled, updateBlockRule, etc.) wrote directly to `rulesByID`
    /// without recomputing the revision. The fix routes every write through a single `store(_:)`
    /// helper that always recomputes.
    func testResponseOverrideStoreRecomputesRevisionOnEdit() async throws {
        let store = ResponseOverrideStore()
        let rule = try await store.addBlockRule(
            from: CapturedRequest(
                method: "GET", scheme: .https, host: "api.example.com", port: 443,
                path: "/block", headers: [], bodyData: nil, bodySize: nil
            ),
            statusCode: 403,
            label: nil
        )
        let initialRevision = rule.mcpTargetRevision
        XCTAssertNotNil(initialRevision)

        // Toggling enabled is a semantic change (it affects matching behavior) — the revision must
        // change to reflect it.
        try await store.setEnabled(false, for: rule.id)
        let allRules = await store.rules()
        let updated = try XCTUnwrap(allRules.first { $0.id == rule.id })

        XCTAssertNotEqual(updated.mcpTargetRevision, initialRevision)
        XCTAssertEqual(updated.mcpTargetRevision, MCPTargetRevisionFingerprint.revision(for: updated))
    }

    func testAttributionSurvivesRuleDeletionAndRecordingRoundTrip() throws {
        let provenance = MCPProvenance(
            clientID: "client-1",
            operationID: "op-1",
            capability: .createDisabledBlock,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let attribution = MCPCaptureAttribution(
            provenance: provenance,
            effectKinds: [.responseOverride],
            scenarioID: nil,
            measurementContext: nil
        )
        let response = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("ok".utf8),
            bodySize: 2,
            mcpAttribution: attribution
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/attributed",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )

        let wrapped = try MCPRecordingAttributionSupport.wrappedRecordingPayload([session])
        let unwrapped = try MCPRecordingAttributionSupport.unwrappedRecordingPayload(wrapped)
        let decoded = try MCPRecordingAttributionSupport.decodeSessions(from: unwrapped)
        XCTAssertEqual(decoded.first?.response?.mcpAttribution, attribution)

        var rule = ResponseOverrideRule(
            id: UUID(),
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/attributed",
            sourceKind: .block,
            sourceDescription: "Blocked",
            statusCode: 403,
            headers: [],
            bodySource: .inline(Data()),
            mcpOrigin: .mcp,
            mcpProvenance: provenance
        )
        rule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule)
        _ = MCPResponseOverrideStoreSupport.normalizedRules([rule], applyingRevisionToUpdated: nil)
        XCTAssertEqual(decoded.first?.response?.mcpAttribution?.provenance.clientID, "client-1")
    }

    /// AJ-2 exit criterion: attribution stamped through the real production path
    /// (`MCPActiveEffectAttributionResolver` reading a real, enabled `ResponseOverrideStore` rule)
    /// must remain on the already-captured response after the rule is disabled and deleted from
    /// the live store — it must never be re-derived by looking the rule back up.
    func testAttributionSurvivesLiveRuleDisableAndDelete() async throws {
        let store = ResponseOverrideStore()
        let provenance = MCPProvenance(
            clientID: "client-1",
            operationID: "op-1",
            capability: .createDisabledBlock,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var rule = ResponseOverrideRule(
            id: UUID(),
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/attributed",
            sourceKind: .block,
            sourceDescription: "Blocked",
            statusCode: 403,
            headers: [],
            bodySource: .inline(Data()),
            mcpOrigin: .mcp,
            mcpProvenance: provenance
        )
        rule.isEnabled = true
        try await store.addRule(rule)
        let allRules = await store.rules()
        let addedRule = try XCTUnwrap(allRules.first { $0.id == rule.id })

        let attribution = try XCTUnwrap(MCPActiveEffectAttributionResolver.attribution(for: addedRule))
        let stampedResponse = MCPActiveEffectAttributionResolver.stampedResponse(
            CapturedResponse(statusCode: 403, headers: [], bodyData: nil, bodySize: 0),
            overrideAttribution: attribution,
            throttleAttribution: nil
        )
        XCTAssertEqual(stampedResponse.mcpAttribution, attribution)

        try await store.setEnabled(false, for: addedRule.id)
        await store.removeRule(id: addedRule.id)
        let remainingRules = await store.rules()
        XCTAssertTrue(remainingRules.isEmpty)

        // The already-stamped response is a value-type snapshot; deleting the live rule must not
        // reach back and mutate or invalidate it.
        XCTAssertEqual(stampedResponse.mcpAttribution, attribution)
    }

    func testDisclosureSerializerProjectsResponseAttributionProvenance() throws {
        let provenance = MCPProvenance(
            clientID: "client-2",
            operationID: "op-2",
            capability: .sessionList,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/x",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: nil,
                bodySize: nil,
                mcpAttribution: MCPCaptureAttribution(
                    provenance: provenance,
                    effectKinds: [.block],
                    scenarioID: nil,
                    measurementContext: nil
                )
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        let serializer = MCPDisclosureSerializer()
        // Provenance is gated like every other field — a profile that doesn't allow `.provenance`
        // must not receive it (see testProvenanceIsGatedByDisclosureProfile below). This profile
        // includes it explicitly, so this test verifies the projection itself actually works when
        // the profile permits it, not that it bypasses the gate.
        let permissiveProfile = MCPDisclosureProfileDocument(
            id: .metadataOnly,
            revision: 1,
            title: "Metadata Only",
            allowedFieldClasses: [.method, .statusCode, .provenance],
            isSelectableInPhase1: true
        )
        let summary = try serializer.sessionSummary(record: session, captureSequence: 1, profile: permissiveProfile)
        XCTAssertEqual(summary.provenance, provenance)
        XCTAssertEqual(summary.mcpEffectKinds, [.block])
    }

    /// Regression test for a confirmed HIGH disclosure leak: `sessionSummary` used to set
    /// `summary.provenance` unconditionally, bypassing the `include(_:profile:)` gate every other
    /// field goes through — a client on a restrictive profile (e.g. Metadata Only) still received
    /// full attribution (originating MCP clientID, operationID, capability, timestamp) regardless
    /// of what their profile actually permitted.
    func testProvenanceIsGatedByDisclosureProfile() throws {
        let provenance = MCPProvenance(
            clientID: "client-3",
            operationID: "op-3",
            capability: .sessionList,
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .https, host: "api.example.com", port: 443,
                path: "/y", headers: [], bodyData: nil, bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200, headers: [], bodyData: nil, bodySize: nil,
                mcpAttribution: MCPCaptureAttribution(
                    provenance: provenance, effectKinds: [.block], scenarioID: nil, measurementContext: nil
                )
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        let serializer = MCPDisclosureSerializer()
        let restrictiveProfile = MCPDisclosureProfileDocument(
            id: .metadataOnly,
            revision: 1,
            title: "Metadata Only",
            allowedFieldClasses: [.method, .statusCode],
            isSelectableInPhase1: true
        )
        let summary = try serializer.sessionSummary(record: session, captureSequence: 1, profile: restrictiveProfile)
        XCTAssertNil(
            summary.provenance,
            "a profile that doesn't allow .provenance must not receive attribution data, matching every other gated field"
        )
        XCTAssertNil(
            summary.mcpEffectKinds,
            "mcpEffectKinds is gated identically to provenance — a restrictive profile must not receive it either"
        )
    }
}
