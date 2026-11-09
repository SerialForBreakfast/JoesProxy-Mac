import XCTest
@testable import JoesProxy

@MainActor
final class MCPResponseEditToolsTests: XCTestCase {
    private struct Stack {
        let responseEditService: MCPResponseEditService
        let sessionStore: InMemorySessionStore
        let client: MCPClientRecord
    }

    private func makeStack(profile: MCPDisclosureProfileID = .shareable) throws -> Stack {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "response-edit-policy.json"))
        policyStore.load()
        let responseEditService = MCPResponseEditService(
            snapshotService: snapshotService,
            policyStore: policyStore,
            grantStore: MCPClientGrantStore()
        )
        let client = MCPClientRecord(
            id: "client-response-edit",
            displayName: "response-edit",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            responseEditService: responseEditService,
            sessionStore: sessionStore,
            client: client
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeSession(body: String, contentType: String = "text/html; charset=utf-8") -> SessionRecord {
        let bodyData = Data(body.utf8)
        return SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "showblender.example",
                port: 443,
                path: "/",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: bodyData,
                bodySize: bodyData.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    func testResponseContextReportsEditableHTMLWithoutBodyContent() throws {
        let stack = try makeStack()
        let session = makeSession(body: "<title>Showblender LLC</title>")
        stack.sessionStore.append(session)

        let context = try stack.responseEditService.responseContext(
            sessionID: session.id,
            client: stack.client
        )

        XCTAssertTrue(context.isUTF8TextEditable)
        XCTAssertEqual(context.completeness, "complete")
        XCTAssertEqual(context.contentTrust, "metadata_only")
        XCTAssertEqual(context.recommendedNextAction, "response_text_search")
        XCTAssertFalse(String(describing: context).contains("Showblender"))
    }

    func testResponseTextSearchReturnsOpaqueMatchRefsWithoutContext() throws {
        let stack = try makeStack()
        let session = makeSession(body: "aaa Showblender LLC bbb Showblender LLC ccc")
        stack.sessionStore.append(session)

        let search = try stack.responseEditService.responseTextSearch(
            sessionID: session.id,
            find: "Showblender LLC",
            includeContext: false,
            client: stack.client,
            mcpSessionID: "mcp-1"
        )

        XCTAssertEqual(search.matchCount, 2)
        XCTAssertEqual(search.matches.count, 2)
        XCTAssertEqual(search.contentTrust, "metadata_only")
        XCTAssertTrue(search.matches.allSatisfy { $0.matchRef.hasPrefix("match-") })
        XCTAssertTrue(search.matches.allSatisfy { $0.context == nil })
        let resolved = try stack.responseEditService.resolvedMatchRef(
            search.matches[0].matchRef,
            client: stack.client,
            mcpSessionID: "mcp-1"
        )
        XCTAssertEqual(resolved.sessionID, session.id)
        XCTAssertEqual(resolved.byteRange.count, Data("Showblender LLC".utf8).count)
    }

    func testExplicitRetentionFlagsPreventEditingEvenWhenRetainedBytesLookComplete() throws {
        for reason in ["captureTruncated", "bodyDeferred", "bodyOmitted"] {
            let stack = try makeStack()
            var session = makeSession(body: "{\"item\":\"secret-value\"}")
            let original = try XCTUnwrap(session.response)
            session.response = CapturedResponse(
                statusCode: 200, headers: original.headers, bodyData: original.bodyData,
                bodySize: original.bodyData?.count, bodyTruncated: reason == "captureTruncated",
                recordingBodyOmissionReason: reason == "bodyOmitted" ? .metadataOnly : nil,
                bodyDeferred: reason == "bodyDeferred")
            stack.sessionStore.append(session)
            let context = try stack.responseEditService.responseContext(sessionID: session.id, client: stack.client)
            XCTAssertEqual(context.completeness, reason)
            XCTAssertFalse(context.isUTF8TextEditable)
            XCTAssertThrowsError(try stack.responseEditService.responseTextRead(
                sessionID: session.id, offset: 0, length: 64, cursor: nil,
                client: stack.client, mcpSessionID: "retention")) { error in
                XCTAssertTrue(String(describing: error).contains(reason))
                XCTAssertFalse(String(describing: error).contains("secret-value"))
            }
        }
    }

    func testMalformedGzipIsDecodeFailureNotInvalidUTF8() throws {
        let stack = try makeStack()
        var session = makeSession(body: "not a gzip stream")
        session.response = CapturedResponse(statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json"),
                      HTTPHeaderField(name: "Content-Encoding", value: "gzip")],
            bodyData: Data("not a gzip stream".utf8), bodySize: 17)
        stack.sessionStore.append(session)
        let context = try stack.responseEditService.responseContext(sessionID: session.id, client: stack.client)
        XCTAssertEqual(context.completeness, "decodeFailed")
        XCTAssertFalse(context.isUTF8TextEditable)
    }

    func testAbsentBodyContextReturnsAvailabilityWithoutInventingHashOrReadingBytes() throws {
        for reason in ["bodyDeferred", "bodyOmitted", "captureTruncated", "bodyUnavailable"] {
            let stack = try makeStack()
            var session = makeSession(body: "unused")
            session.response = CapturedResponse(statusCode: 200, headers: [], bodyData: nil,
                bodySize: 100, bodyTruncated: reason == "captureTruncated",
                recordingBodyOmissionReason: reason == "bodyOmitted" ? .metadataOnly : nil,
                bodyDeferred: reason == "bodyDeferred")
            stack.sessionStore.append(session)
            let context = try stack.responseEditService.responseContext(sessionID: session.id, client: stack.client)
            XCTAssertEqual(context.completeness, reason)
            XCTAssertEqual(context.representation, "unavailable")
            XCTAssertNil(context.bodySHA256)
            XCTAssertFalse(context.isUTF8TextEditable)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any]
            XCTAssertNil(encoded?["bodySHA256"])
        }
    }

    func testResponseTextSearchWithContextLabelsUntrustedText() throws {
        let stack = try makeStack()
        let session = makeSession(body: "prefix Showblender LLC suffix")
        stack.sessionStore.append(session)

        let search = try stack.responseEditService.responseTextSearch(
            sessionID: session.id,
            find: "Showblender LLC",
            includeContext: true,
            client: stack.client,
            mcpSessionID: "mcp-1"
        )

        XCTAssertEqual(search.contentTrust, "captured_untrusted")
        let context = try XCTUnwrap(search.matches.first?.context?.captured_untrusted)
        XCTAssertTrue(context.contains("Showblender LLC"))
    }

    // G6-03: reproduced live on 2026-08-05 — an exact search for a plausible-but-wrong-cased
    // literal correctly returns 0 exact matches, but should hint that a differently-cased version
    // is present so an agent doesn't conclude the text is absent. See
    // Live-NOBLENDER-Audit-2026-08-05.md.
    func testResponseTextSearchHintsCaseInsensitiveCountOnZeroExactMatches() throws {
        let stack = try makeStack()
        let session = makeSession(body: "aaa ShowBlender LLC bbb")
        stack.sessionStore.append(session)

        let search = try stack.responseEditService.responseTextSearch(
            sessionID: session.id,
            find: "Showblender LLC",
            includeContext: false,
            client: stack.client,
            mcpSessionID: "mcp-1"
        )

        XCTAssertEqual(search.matchCount, 0)
        XCTAssertEqual(search.caseInsensitiveMatchCount, 1)
        XCTAssertFalse(String(describing: search).contains("ShowBlender"))
    }

    func testResponseTextSearchOmitsCaseInsensitiveHintWhenExactMatchesExist() throws {
        let stack = try makeStack()
        let session = makeSession(body: "Showblender LLC")
        stack.sessionStore.append(session)

        let search = try stack.responseEditService.responseTextSearch(
            sessionID: session.id,
            find: "Showblender LLC",
            includeContext: false,
            client: stack.client,
            mcpSessionID: "mcp-1"
        )

        XCTAssertEqual(search.matchCount, 1)
        XCTAssertNil(search.caseInsensitiveMatchCount)
    }

    func testResponseTextSearchRejectsShortFindAndForgedMatchRef() throws {
        let stack = try makeStack()
        let session = makeSession(body: "Showblender LLC")
        stack.sessionStore.append(session)

        XCTAssertThrowsError(
            try stack.responseEditService.responseTextSearch(
                sessionID: session.id,
                find: "ab",
                includeContext: false,
                client: stack.client,
                mcpSessionID: nil
            )
        ) { error in
            XCTAssertEqual((error as? MCPStructuredError)?.code, .malformedRequest)
        }

        XCTAssertThrowsError(
            try stack.responseEditService.resolvedMatchRef(
                "match-forged",
                client: stack.client,
                mcpSessionID: nil
            )
        ) { error in
            XCTAssertEqual((error as? MCPStructuredError)?.code, .staleProposal)
        }
    }

    func testResponseTextReadReturnsUntrustedLabeledPage() throws {
        let stack = try makeStack()
        let session = makeSession(body: String(repeating: "A", count: 200) + "Showblender LLC")
        stack.sessionStore.append(session)

        let page = try stack.responseEditService.responseTextRead(
            sessionID: session.id,
            offset: 0,
            length: 64,
            cursor: nil,
            client: stack.client,
            mcpSessionID: "mcp-read"
        )

        XCTAssertEqual(page.byteOffset, 0)
        XCTAssertEqual(page.byteLength, 64)
        XCTAssertEqual(page.contentTrust, "captured_untrusted")
        XCTAssertEqual(page.text.captured_untrusted, String(repeating: "A", count: 64))
        XCTAssertTrue(page.truncated)
        XCTAssertNotNil(page.nextCursor)

        let next = try stack.responseEditService.responseTextRead(
            sessionID: session.id,
            offset: nil,
            length: 200,
            cursor: page.nextCursor,
            client: stack.client,
            mcpSessionID: "mcp-read"
        )
        XCTAssertTrue(next.text.captured_untrusted.contains("Showblender LLC"))
    }

    func testMetadataOnlyProfileCannotUseResponseContext() throws {
        let stack = try makeStack(profile: .metadataOnly)
        let session = makeSession(body: "Showblender LLC")
        stack.sessionStore.append(session)

        XCTAssertThrowsError(
            try stack.responseEditService.responseContext(sessionID: session.id, client: stack.client)
        ) { error in
            XCTAssertEqual((error as? MCPStructuredError)?.code, .policyDenied)
        }
    }

    func testCapabilityCatalogIncludesResponseEditTools() {
        let names = Set(MCPCapabilitiesManifestBuilder.productionTools.map(\.name))
        XCTAssertTrue(names.contains("response_context"))
        XCTAssertTrue(names.contains("response_text_search"))
        XCTAssertTrue(names.contains("response_text_read"))
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "response_text_read"),
            .bodyRead
        )
        XCTAssertEqual(
            MCPCapabilityRouter.capability(forTool: "response_context"),
            .responseContext
        )
    }
}
