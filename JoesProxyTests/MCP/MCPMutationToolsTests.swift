import XCTest
@testable import JoesProxy

@MainActor
final class MCPMutationToolsTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let proposalCoordinator: MCPProposalCoordinator
        let recoveryCoordinator: MCPRecoveryCoordinator
        let journalStore: MCPEffectJournalStore
        let responseOverrideStore: ResponseOverrideStore
        let bookmarkStore: InMemoryBookmarkStore
        let approvalStore: MCPApprovalStore
        let auditStore: MCPAuditStore
        let policyStore: MCPPolicyStore
        let client: MCPClientRecord
    }

    func testInspectBookmarksRedactsLegacyEntries() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(
            name: "legacy",
            request: sampleRequest(),
            mcpOrigin: nil,
            mcpProvenance: nil
        )
        try stack.bookmarkStore.saveBookmarks([bookmark])

        let payload = try await stack.mutationService.handleTool(
            name: "bookmark_get",
            arguments: ["bookmarkID": bookmark.id.uuidString],
            client: stack.client
        )
        XCTAssertEqual(payload["name"] as? String, "legacy")
        XCTAssertNil(payload["mcpClientID"])
    }

    func testBookmarkListDefaultsToDecisionProjectionAndFullRemainsAvailable() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(
            name: "projection",
            request: sampleRequest(),
            mcpOrigin: nil,
            mcpProvenance: nil
        )
        try stack.bookmarkStore.saveBookmarks([bookmark])

        let compact = try await stack.mutationService.handleTool(
            name: "bookmarks_list",
            arguments: [:],
            client: stack.client
        )
        let compactItems = try XCTUnwrap(compact["items"] as? [[String: Any]])
        XCTAssertEqual(compact["projection"] as? String, "minimal")
        XCTAssertEqual(compactItems.first?["name"] as? String, "projection")
        XCTAssertNil(compactItems.first?["host"])
        XCTAssertNil(compactItems.first?["createdAt"])

        let full = try await stack.mutationService.handleTool(
            name: "bookmarks_list",
            arguments: ["projection": "full"],
            client: stack.client
        )
        let fullItems = try XCTUnwrap(full["items"] as? [[String: Any]])
        XCTAssertEqual(full["projection"] as? String, "full")
        XCTAssertNotNil(fullItems.first?["host"])
        XCTAssertNotNil(fullItems.first?["createdAt"])
    }

    func testInspectDeniedForMetadataOnlyProfile() async {
        let stack = try? makeStack(profile: .metadataOnly)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "bookmarks_list",
                arguments: [:],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testProposeBlockRejectsOverbroadPathPrefix() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_block",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/",
                    "matchMode": "pathPrefix"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testApplyBlockRequiresApprovalThenCreatesDisabledRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposeArgs: [String: Any] = [
            "method": "GET",
            "host": "api.example.com",
            "path": "/blocked",
            "matchMode": "exactPath",
            "statusCode": 403
        ]
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: proposeArgs,
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let applyArgs: [String: Any] = ["proposalToken": token]

        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_block",
                arguments: applyArgs,
                client: stack.client
            )
            XCTFail("expected approval required")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retryArgs = applyArgs
            retryArgs["approval"] = try authorizationDictionary(authorization)
            let applied = try await stack.mutationService.handleTool(
                name: "apply_create_block",
                arguments: retryArgs,
                client: stack.client
            )
            XCTAssertEqual(applied["isEnabled"] as? Bool, false)
        }

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
        let decision = try await stack.responseOverrideStore.ruleDecision(for: sampleRequest(path: "/blocked"))
        if case .noMatch = decision {
            // expected — disabled rules must not match traffic
        } else {
            XCTFail("disabled rule must not affect traffic")
        }
        XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .proposalCreated })
        XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .proposalApplied })
        XCTAssertEqual(stack.journalStore.entries.last?.phase, .committed)
    }

    func testMapLocalHappyPathCreatesDisabledInlineRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let token = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/asset.js",
                "bodyText": "{\"ok\":true}",
                "contentType": "application/json"
            ]
        )
        XCTAssertFalse(token.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.sourceKind, .inlineText)
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
    }

    /// AR: `forceNoCache` is an opt-in argument on `propose_create_map_local` that persists onto
    /// the created rule, so an MCP agent can force `no-store`/stripped caching headers on a Map
    /// Local response without needing the app UI.
    func testMapLocalForceNoCacheArgumentPersistsOntoCreatedRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let token = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/asset.js",
                "bodyText": "{\"ok\":true}",
                "contentType": "application/json",
                "forceNoCache": true
            ]
        )
        XCTAssertFalse(token.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first?.forceNoCache))
    }

    /// Baseline: omitting `forceNoCache` defaults to `false`, matching every rule created before
    /// this argument existed.
    func testMapLocalOmittingForceNoCacheDefaultsToFalse() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/asset.js",
                "bodyText": "{\"ok\":true}",
                "contentType": "application/json"
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first?.forceNoCache))
    }

    // MARK: - Local Directory Map Local (AS)

    private func makeLocalDirectoryBookmarkRef() throws -> (directory: URL, bookmarkRef: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPLocalDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<html>ok</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
        // Plain (not security-scoped) — matches production: JoesProxy isn't sandboxed, and a
        // security-scoped bookmark minted by the separate joesproxyctl CLI process failed to
        // resolve here across that process boundary (confirmed live 2026-08-10).
        let bookmarkData = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (directory, bookmarkData.base64EncodedString())
    }

    /// Happy path: opaque bookmark ref + pathPrefix creates a disabled `.localDirectory` rule whose
    /// inspect DTO exposes only the folder name, never a full filesystem path.
    func testProposeCreateMapLocalLocalDirectoryBookmarkRefPersistsDirectoryRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/site",
                "matchMode": "pathPrefix",
                "localDirectoryBookmarkRef": prepared.bookmarkRef,
                "notFoundRelativePath": "index.html",
                "forceNoCache": true
            ]
        )

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.sourceKind, .localDirectory)
        XCTAssertEqual(rule.matchMode, .pathPrefix)
        XCTAssertEqual(rule.notFoundRelativePath, "index.html")
        XCTAssertTrue(rule.forceNoCache)
        XCTAssertFalse(rule.isEnabled)
        if case .directory(let url) = rule.bodySource {
            XCTAssertEqual(url.lastPathComponent, prepared.directory.lastPathComponent)
        } else {
            XCTFail("expected directory body source")
        }

        let summary = try await stack.mutationService.handleTool(
            name: "override_get",
            arguments: ["overrideID": rule.id.uuidString],
            client: stack.client
        )
        let encoded = try JSONSerialization.data(withJSONObject: summary)
        let decoded = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decoded.contains(prepared.directory.path), "MCP DTO must not leak the full directory path")
        XCTAssertEqual(summary["localDirectoryName"] as? String, prepared.directory.lastPathComponent)
        XCTAssertEqual(summary["sourceKind"] as? String, ResponseOverrideSourceKind.localDirectory.rawValue)
    }

    /// Mutual exclusion: bookmark ref cannot be combined with bodyText / fixtureRunID / digests.
    func testProposeCreateMapLocalLocalDirectoryRejectsBodyTextCombination() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "www.example.com",
                    "path": "/site",
                    "matchMode": "pathPrefix",
                    "localDirectoryBookmarkRef": prepared.bookmarkRef,
                    "bodyText": "nope",
                    "contentType": "text/plain"
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("localDirectoryBookmarkRef"))
        }
    }

    func testProposeCreateMapLocalLocalDirectoryRequiresPathPrefix() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "www.example.com",
                    "path": "/site/index.html",
                    "matchMode": "exactPath",
                    "localDirectoryBookmarkRef": prepared.bookmarkRef
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("pathPrefix"))
        }
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): the directory
    /// missing-file policy — a rule can request `overlayFailOpen` explicitly, and it persists.
    func testProposeCreateMapLocalLocalDirectoryPersistsMissingFilePolicy() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/site",
                "matchMode": "pathPrefix",
                "localDirectoryBookmarkRef": prepared.bookmarkRef,
                "missingFilePolicy": "overlayFailOpen"
            ]
        )

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.missingFilePolicy, .overlayFailOpen)

        let summary = try await stack.mutationService.handleTool(
            name: "override_get",
            arguments: ["overrideID": rule.id.uuidString],
            client: stack.client
        )
        XCTAssertEqual(summary["missingFilePolicy"] as? String, "overlayFailOpen")
    }

    /// A directory rule with no explicit policy defaults to `strictLocal` — today's original,
    /// only-ever behavior — rather than silently changing behavior for existing callers.
    func testProposeCreateMapLocalLocalDirectoryDefaultsToStrictLocal() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/site",
                "matchMode": "pathPrefix",
                "localDirectoryBookmarkRef": prepared.bookmarkRef
            ]
        )

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.missingFilePolicy, .strictLocal)
    }

    func testProposeCreateMapLocalLocalDirectoryRejectsUnknownMissingFilePolicy() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "www.example.com",
                    "path": "/site",
                    "matchMode": "pathPrefix",
                    "localDirectoryBookmarkRef": prepared.bookmarkRef,
                    "missingFilePolicy": "bogus"
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest for an unrecognized missingFilePolicy value")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertEqual(error.details?["field"], "missingFilePolicy")
            XCTAssertTrue(error.message.contains("strictLocal"))
        }
    }

    /// `configuredFallback` without a `notFoundRelativePath` has nothing configured to fall back
    /// to — reject at propose time rather than silently behaving like a bare 404.
    func testProposeCreateMapLocalLocalDirectoryConfiguredFallbackRequiresNotFoundPath() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "www.example.com",
                    "path": "/site",
                    "matchMode": "pathPrefix",
                    "localDirectoryBookmarkRef": prepared.bookmarkRef,
                    "missingFilePolicy": "configuredFallback"
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("notFoundRelativePath"))
        }
    }

    /// Pre-activation disclosure: captured sessions under this rule's prefix with no matching local
    /// file are surfaced so an agent sees the gap before approving — the preview half of this item.
    /// Uses a bespoke local stack (not the shared `makeStack`) since this is the only test in this
    /// file that needs a real, snapshot-indexed `SessionStore` wired into `MCPMutationService`.
    func testProposeCreateMapLocalLocalDirectoryDisclosesMissingSiblings() async throws {
        let prepared = try makeLocalDirectoryBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        sessionStore.append(makeMissingSiblingsTestSession(host: "www.example.com", path: "/site/index.html"))
        sessionStore.append(makeMissingSiblingsTestSession(host: "www.example.com", path: "/site/other-asset.png"))

        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "missing-siblings-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "missing-siblings-policy.json"))
        policyStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let mutationService = MCPMutationService(
            bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: ResponseOverrideStore(),
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: MCPApprovalStore(),
            policyStore: policyStore,
            auditStore: MCPAuditStore(),
            snapshotService: snapshotService,
            enforcesLiveRewritePreview: false
        )
        let client = MCPClientRecord(
            id: "client-missing-siblings-test",
            displayName: "missing-siblings-test",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        let proposal = try await mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/site",
                "matchMode": "pathPrefix",
                "localDirectoryBookmarkRef": prepared.bookmarkRef
            ],
            client: client
        )

        let disclosure = try XCTUnwrap(proposal["capturedSiblingsNotOnDisk"] as? [String: Any])
        XCTAssertEqual(disclosure["count"] as? Int, 1)
        let relativePaths = try XCTUnwrap(disclosure["relativePaths"] as? [String])
        XCTAssertEqual(relativePaths, ["other-asset.png"])
    }

    private func makeMissingSiblingsTestSession(host: String, path: String) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }

    // MARK: - Single-file Map Local (P1)

    private func makeLocalFileBookmarkRef(extension fileExtension: String = "png") throws -> (fileURL: URL, bookmarkRef: String) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPLocalFile-\(UUID().uuidString).\(fileExtension)")
        try Data("binary-bytes".utf8).write(to: fileURL)
        // Plain (not security-scoped) — matches the directory bookmark rationale above.
        let bookmarkData = try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (fileURL, bookmarkData.base64EncodedString())
    }

    /// Happy path: opaque single-file bookmark ref creates a disabled `.localFile` rule, does NOT
    /// force `matchMode: pathPrefix` (unlike directory), and infers Content-Type from the file
    /// extension when the caller doesn't supply one.
    func testProposeCreateMapLocalLocalFileBookmarkRefPersistsFileRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalFileBookmarkRef(extension: "png")
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/logo.png",
                "matchMode": "exactPath",
                "localFileBookmarkRef": prepared.bookmarkRef
            ]
        )

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.sourceKind, .localFile)
        XCTAssertEqual(rule.matchMode, .exactPath)
        XCTAssertEqual(rule.statusCode, 200)
        XCTAssertFalse(rule.isEnabled)
        XCTAssertEqual(rule.headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value, "image/png")
        if case .file(let url) = rule.bodySource {
            XCTAssertEqual(url.lastPathComponent, prepared.fileURL.lastPathComponent)
        } else {
            XCTFail("expected file body source")
        }

        let summary = try await stack.mutationService.handleTool(
            name: "override_get",
            arguments: ["overrideID": rule.id.uuidString],
            client: stack.client
        )
        let encoded = try JSONSerialization.data(withJSONObject: summary)
        let decoded = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decoded.contains(prepared.fileURL.path), "MCP DTO must not leak the full file path")
        XCTAssertEqual(summary["localFileName"] as? String, prepared.fileURL.lastPathComponent)
        XCTAssertEqual(summary["sourceKind"] as? String, ResponseOverrideSourceKind.localFile.rawValue)
    }

    /// An explicit `contentType` overrides extension-based inference.
    func testProposeCreateMapLocalLocalFileRespectsExplicitContentType() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalFileBookmarkRef(extension: "png")
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/logo.png",
                "localFileBookmarkRef": prepared.bookmarkRef,
                "contentType": "application/octet-stream"
            ]
        )

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value, "application/octet-stream")
    }

    /// Mutual exclusion: file bookmark ref cannot be combined with bodyText, and cannot be combined
    /// with a directory bookmark ref in the same call (the directory branch wins first since it's
    /// checked first — this asserts the file branch's own bodyText guard).
    func testProposeCreateMapLocalLocalFileRejectsBodyTextCombination() async throws {
        let stack = try makeStack(profile: .shareable)
        let prepared = try makeLocalFileBookmarkRef()
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "cdn.example.com",
                    "path": "/logo.png",
                    "localFileBookmarkRef": prepared.bookmarkRef,
                    "bodyText": "nope"
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("localFileBookmarkRef"))
        }
    }

    func testProposeCreateMapLocalLocalFileRejectsBookmarkPointingAtDirectory() async throws {
        let stack = try makeStack(profile: .shareable)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPLocalFileRejectsDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarkData = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "cdn.example.com",
                    "path": "/logo.png",
                    "localFileBookmarkRef": bookmarkData.base64EncodedString()
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("regular file"))
        }
    }

    func testMapLocalEnableAfterApplyMintsEnableRuleApprovalAndActivatesAtomically() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/bundled.js",
                "bodyText": "{\"bundled\":true}",
                "contentType": "application/json"
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let applyArgs: [String: Any] = [
            "proposalToken": token,
            "enableAfterApply": true
        ]

        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: applyArgs,
                client: stack.client
            )
            XCTFail("expected approval required")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
            let pending = try XCTUnwrap(stack.approvalStore.pendingRequests.first)
            XCTAssertEqual(pending.capability, .enableRule)
            XCTAssertTrue(pending.reason.contains("becomes live"))
            let authorization = try stack.approvalStore.approve(requestID: pending.requestID)
            var retryArgs = applyArgs
            retryArgs["approval"] = try authorizationDictionary(authorization)
            let applied = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: retryArgs,
                client: stack.client
            )
            XCTAssertEqual(applied["isEnabled"] as? Bool, true)
        }

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertTrue(rule.isEnabled)
        let decision = try await stack.responseOverrideStore.ruleDecision(
            for: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: "/bundled.js",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        if case .mapLocal = decision {
            // expected — bundled create+enable is live
        } else {
            XCTFail("enabled map-local must match traffic, got \(decision)")
        }

        let appliedReasons = stack.auditStore.events
            .filter { $0.kind == .proposalApplied }
            .map(\.reasonCode)
        XCTAssertTrue(appliedReasons.contains(where: { $0.hasPrefix("createDisabledMapLocal:") }))
        XCTAssertTrue(appliedReasons.contains(where: { $0.hasPrefix("enableRule:") }))
    }

    func testMapLocalEnableAfterApplyDurableEnableGrantCoversLaterStandaloneEnable() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try stack.mutationService.grantStore.addGrant(
            clientID: stack.client.id,
            capability: .enableRule,
            mode: .durablePolicy
        )

        let firstProposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/grant-a.js",
                "bodyText": "{\"a\":1}",
                "contentType": "application/json"
            ],
            client: stack.client
        )
        let firstToken = try XCTUnwrap(firstProposal["proposalToken"] as? String)
        let firstApplied = try await stack.mutationService.handleTool(
            name: "apply_create_map_local",
            arguments: [
                "proposalToken": firstToken,
                "enableAfterApply": true
            ],
            client: stack.client
        )
        XCTAssertEqual(firstApplied["isEnabled"] as? Bool, true)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)

        // Create a second disabled rule without enableAfterApply, then enable standalone —
        // durable enableRule grant must skip the enable approval nonce.
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/grant-b.js",
                "bodyText": "{\"b\":2}",
                "contentType": "application/json"
            ]
        )
        let secondRules = await stack.responseOverrideStore.rules()
        let secondRuleID = try XCTUnwrap(secondRules.first(where: { $0.path == "/grant-b.js" })?.id)
        let enableProposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": secondRuleID.uuidString],
            client: stack.client
        )
        let enableToken = try XCTUnwrap(enableProposal["proposalToken"] as? String)
        let enabled = try await stack.mutationService.handleTool(
            name: "apply_enable_rule",
            arguments: ["proposalToken": enableToken],
            client: stack.client
        )
        XCTAssertEqual(enabled["isEnabled"] as? Bool, true)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)

        // Unrelated capability is unaffected by the enableRule grant.
        XCTAssertNil(
            stack.mutationService.grantStore.activeGrant(
                capability: .certificateCleanup,
                clientID: stack.client.id
            )
        )
        XCTAssertFalse(
            stack.mutationService.policyEvaluator.skipsApprovalNonce(
                capability: .certificateCleanup,
                client: stack.client
            )
        )
    }

    func testMapLocalEnableAfterApplyFailsClosedWhenEnableRuleAlwaysDenied() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = stack.mutationService.grantStore.addDenial(
            clientID: stack.client.id,
            capability: .enableRule
        )
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "GET",
                "host": "cdn.example.com",
                "path": "/denied.js",
                "bodyText": "{\"x\":1}",
                "contentType": "application/json"
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: [
                    "proposalToken": token,
                    "enableAfterApply": true
                ],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty, "fail-closed must not create a rule when enable is denied")
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }


    // G6-02: reproduced live on 2026-08-05 — creating a second Map Local rule for a scope an
    // existing rule already covers exactly must fail closed by default, and succeed only with an
    // explicit allowDuplicateScope opt-in. See Live-NOBLENDER-Audit-2026-08-05.md.
    func testProposeCreateMapLocalRejectsExactScopeDuplicateUnlessAllowed() async throws {
        let stack = try makeStack(profile: .shareable)
        let firstArgs: [String: Any] = [
            "method": "GET",
            "host": "www.example.com",
            "path": "/",
            "matchMode": "ignoreQuery",
            "bodyText": "<html>original</html>",
            "contentType": "text/html"
        ]
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: firstArgs
        )

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "host": "www.example.com",
                    "path": "/",
                    "matchMode": "ignoreQuery",
                    "bodyText": "<html>duplicate</html>",
                    "contentType": "text/html"
                ],
                client: stack.client
            )
            XCTFail("expected exact-scope duplicate rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("already covers this exact scope"))
        }

        // allowDuplicateScope: true proceeds anyway.
        let secondToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/",
                "matchMode": "ignoreQuery",
                "bodyText": "<html>duplicate</html>",
                "contentType": "text/html",
                "allowDuplicateScope": true
            ]
        )
        XCTAssertFalse(secondToken.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.filter { $0.sourceKind == .inlineText }.count, 2)
    }

    // G6-02 option 2: when the conflicting rule is not just the same scope but the exact same
    // content, the rejection should say so plainly and point at the existing rule as fully
    // redundant, distinct from the "same scope, different content" case above.
    func testProposeCreateMapLocalReportsBodyIdenticalWhenDuplicateContentMatchesExactly() async throws {
        let stack = try makeStack(profile: .shareable)
        let args: [String: Any] = [
            "method": "GET",
            "host": "www.example.com",
            "path": "/",
            "matchMode": "ignoreQuery",
            "bodyText": "<html>same</html>",
            "contentType": "text/html"
        ]
        let firstToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: args
        )
        XCTAssertFalse(firstToken.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        let existingID = try XCTUnwrap(rules.first?.id.uuidString)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: args,
                client: stack.client
            )
            XCTFail("expected body-identical duplicate rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("identical Map Local rule"))
            XCTAssertTrue(error.message.contains("No new rule is needed"))
            XCTAssertEqual(error.details?["existingRuleID"], existingID)
            XCTAssertEqual(error.details?["bodyIdentical"], "true")
        }
    }

    // A different path (not scope) must not be rejected as a duplicate.
    func testProposeCreateMapLocalAllowsDifferentPathForSameHost() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/",
                "bodyText": "a",
                "contentType": "text/plain"
            ]
        )
        let secondToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: [
                "method": "GET",
                "host": "www.example.com",
                "path": "/other",
                "bodyText": "b",
                "contentType": "text/plain"
            ]
        )
        XCTAssertFalse(secondToken.isEmpty)
    }

    // MARK: - GraphQL operationName matching

    func testProposeCreateBlockAndMapLocalEchoGraphQLOperationNameInMatchScope() async throws {
        let stack = try makeStack(profile: .shareable)

        let blockProposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "POST",
                "host": "api.example.com",
                "path": "/graphql",
                "graphqlOperationName": "GetUser"
            ],
            client: stack.client
        )
        let blockScope = try XCTUnwrap(blockProposal["matchScope"] as? [String: Any])
        XCTAssertEqual(blockScope["graphqlOperationName"] as? String, "GetUser")

        let mapLocalProposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "POST",
                "host": "api.example.com",
                "path": "/graphql",
                "bodyText": "{\"data\":{}}",
                "contentType": "application/json",
                "graphqlOperationName": "GetPosts"
            ],
            client: stack.client
        )
        let mapLocalScope = try XCTUnwrap(mapLocalProposal["matchScope"] as? [String: Any])
        XCTAssertEqual(mapLocalScope["graphqlOperationName"] as? String, "GetPosts")
    }

    /// Regression test: `exactScopeMapLocalConflict` must treat two rules with different
    /// `graphqlOperationName` values as distinct, not a false-positive "exact scope" duplicate —
    /// otherwise the whole point of operation-scoped Map Local rules is defeated.
    func testProposeCreateMapLocalWithDifferentGraphQLOperationNamesOnSameScopeBothSucceed() async throws {
        let stack = try makeStack(profile: .shareable)
        let baseArgs: [String: Any] = [
            "method": "POST",
            "host": "api.example.com",
            "path": "/graphql",
            "contentType": "application/json"
        ]

        var firstArgs = baseArgs
        firstArgs["bodyText"] = "{\"data\":{\"user\":true}}"
        firstArgs["graphqlOperationName"] = "GetUser"
        let firstToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: firstArgs
        )
        XCTAssertFalse(firstToken.isEmpty)

        var secondArgs = baseArgs
        secondArgs["bodyText"] = "{\"data\":{\"posts\":[]}}"
        secondArgs["graphqlOperationName"] = "GetPosts"
        let secondToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: secondArgs
        )
        XCTAssertFalse(secondToken.isEmpty)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.filter { $0.sourceKind == .inlineText }.count, 2)
    }

    func testOverrideGetRoundTripsGraphQLOperationName() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_block",
            applyTool: "apply_create_block",
            proposeArgs: [
                "method": "POST",
                "host": "api.example.com",
                "path": "/graphql",
                "graphqlOperationName": "GetUser"
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)

        let summary = try await stack.mutationService.handleTool(
            name: "override_get",
            arguments: ["overrideID": rule.id.uuidString],
            client: stack.client
        )
        XCTAssertEqual(summary["graphqlOperationName"] as? String, "GetUser")
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): query-parameter
    /// predicate — mirrors the graphqlOperationName echo test above.
    func testProposeCreateBlockAndMapLocalEchoMatchQueryPredicateInMatchScope() async throws {
        let stack = try makeStack(profile: .shareable)

        let blockProposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/catalog/item",
                "matchMode": "ignoreQuery",
                "matchQueryKey": "contentId",
                "matchQueryValue": "1234"
            ],
            client: stack.client
        )
        let blockScope = try XCTUnwrap(blockProposal["matchScope"] as? [String: Any])
        XCTAssertEqual(blockScope["matchQueryKey"] as? String, "contentId")
        XCTAssertEqual(blockScope["matchQueryValue"] as? String, "1234")

        let mapLocalProposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/catalog/item",
                "matchMode": "ignoreQuery",
                "bodyText": "{}",
                "contentType": "application/json",
                "matchQueryKey": "contentId",
                "matchQueryValue": "5678"
            ],
            client: stack.client
        )
        let mapLocalScope = try XCTUnwrap(mapLocalProposal["matchScope"] as? [String: Any])
        XCTAssertEqual(mapLocalScope["matchQueryKey"] as? String, "contentId")
        XCTAssertEqual(mapLocalScope["matchQueryValue"] as? String, "5678")
    }

    /// Regression-style test mirroring the GraphQL-operation-name equivalent: two rules scoped to
    /// different values of the same query key on the same path must both succeed, not
    /// false-positive as an "exact scope" duplicate.
    func testProposeCreateMapLocalWithDifferentMatchQueryValuesOnSameScopeBothSucceed() async throws {
        let stack = try makeStack(profile: .shareable)
        let baseArgs: [String: Any] = [
            "method": "GET",
            "host": "api.example.com",
            "path": "/catalog/item",
            "matchMode": "ignoreQuery",
            "contentType": "application/json"
        ]

        var firstArgs = baseArgs
        firstArgs["bodyText"] = "{\"id\":1234}"
        firstArgs["matchQueryKey"] = "contentId"
        firstArgs["matchQueryValue"] = "1234"
        let firstToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: firstArgs
        )
        XCTAssertFalse(firstToken.isEmpty)

        var secondArgs = baseArgs
        secondArgs["bodyText"] = "{\"id\":5678}"
        secondArgs["matchQueryKey"] = "contentId"
        secondArgs["matchQueryValue"] = "5678"
        let secondToken = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_local",
            applyTool: "apply_create_map_local",
            proposeArgs: secondArgs
        )
        XCTAssertFalse(secondToken.isEmpty)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.filter { $0.sourceKind == .inlineText }.count, 2)
    }

    func testOverrideGetRoundTripsMatchQueryPredicate() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_block",
            applyTool: "apply_create_block",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/catalog/item",
                "matchMode": "ignoreQuery",
                "matchQueryKey": "contentId",
                "matchQueryValue": "1234"
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)

        let summary = try await stack.mutationService.handleTool(
            name: "override_get",
            arguments: ["overrideID": rule.id.uuidString],
            client: stack.client
        )
        XCTAssertEqual(summary["matchQueryKey"] as? String, "contentId")
        XCTAssertEqual(summary["matchQueryValue"] as? String, "1234")
    }

    func testProposeCreateBlockRejectsMatchQueryKeyWithoutMatchQueryValue() async throws {
        let stack = try makeStack(profile: .shareable)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_block",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/catalog/item",
                    "matchMode": "ignoreQuery",
                    "matchQueryKey": "contentId"
                ],
                client: stack.client
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("matchQueryKey and matchQueryValue must be supplied together"))
        }
    }

    /// Regression test for a confirmed bug (found while building AI-6 self-validation): the
    /// loopback check only matched the literal string `"127.0.0.1"`, so any other address in the
    /// same `127.0.0.0/8` range — which routes to this same machine exactly like `127.0.0.1` does —
    /// slipped straight through Map Remote's destination validation.
    func testMapRemoteRejectsNonCanonicalLoopbackAddress() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/x",
                    "remoteHost": "127.0.0.2"
                ],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsLoopbackDestination() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/x",
                    "remoteHost": "127.0.0.1"
                ],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteHappyPathCreatesDisabledRule() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_remote",
            applyTool: "apply_create_map_remote",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/proxy",
                "remoteHost": "staging.example.com",
                "remoteScheme": "https"
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.sourceKind, .mapRemote)
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
    }

    func testLiveRewriteHappyPathCreatesDisabledRule() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_live_rewrite",
            applyTool: "apply_create_live_rewrite",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/live.json",
                "jsonPath": "$.flag",
                "overrideValue": ["type": "bool", "value": true]
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.sourceKind, .liveResponseRewrite)
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
        XCTAssertEqual(rules.first?.liveResponseRewrites.first?.jsonPath, "$.flag")
    }

    func testLiveRewriteRejectsInvalidJSONPath() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/live.json",
                    "jsonPath": "flag",
                    "overrideValue": ["type": "bool", "value": true]
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testLiveRewriteProposalListsOverlappingOverrideWhenBlockEnabled() async throws {
        let stack = try makeStack(profile: .shareable)
        let blockRuleID = try await blockRuleIDAfterCreate(stack: stack, path: "/live.json")
        _ = try await enableBlockRule(stack: stack, overrideID: blockRuleID)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/live.json",
                "matchMode": "exactPath",
                "jsonPath": "$.flag",
                "overrideValue": ["type": "bool", "value": true]
            ],
            client: stack.client
        )
        let conflicts = try XCTUnwrap(proposal["conflicts"] as? [String])
        XCTAssertFalse(conflicts.isEmpty)
    }

    func testMapRemoteHappyPathWithPathOverrideCreatesDisabledRule() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_map_remote",
            applyTool: "apply_create_map_remote",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/proxy",
                "remoteHost": "staging.example.com",
                "remoteScheme": "https",
                "remotePath": "/v2/proxy",
                "remoteQueryPolicy": "drop"
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.mapRemotePath, "/v2/proxy")
        XCTAssertEqual(rules.first?.mapRemoteQueryPolicy, .drop)
    }

    func testMapRemoteRejectsPathWithoutLeadingSlash() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remotePath": "no-leading-slash"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsPathWithSchemeAuthority() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remotePath": "/foo://attacker.example.com/x"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsPathWithControlCharacters() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remotePath": "/x\r\nInjected-Header: evil"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsMalformedPercentEncoding() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remotePath": "/x%2"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsOversizedPath() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        let oversizedPath = "/" + String(repeating: "a", count: 2100)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remotePath": oversizedPath
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapRemoteRejectsInvalidQueryPolicy() async {
        let stack = try? makeStack(profile: .shareable)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/proxy",
                    "remoteHost": "staging.example.com",
                    "remoteQueryPolicy": "not-a-real-policy"
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRewriteRejectsInvalidJSONPath() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(name: "b1", request: sampleRequest(), savedResponse: BookmarkSavedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("{}".utf8),
            savedAt: Date()
        ))
        try stack.bookmarkStore.saveBookmarks([bookmark])
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_rewrite",
                arguments: [
                    "bookmarkID": bookmark.id.uuidString,
                    "jsonPath": "invalid",
                    "overrideValue": ["type": "string", "value": "x"]
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testRewriteHappyPathAddsDisabledFieldRewrite() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(name: "b1", request: sampleRequest(), savedResponse: BookmarkSavedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("{\"id\":1}".utf8),
            savedAt: Date()
        ))
        try stack.bookmarkStore.saveBookmarks([bookmark])
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_rewrite",
            applyTool: "apply_create_rewrite",
            proposeArgs: [
                "bookmarkID": bookmark.id.uuidString,
                "jsonPath": "$.id",
                "overrideValue": ["type": "number", "value": "2"]
            ]
        )
        let updated = stack.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmark.id })
        XCTAssertEqual(updated?.responseRewrites.count, 1)
        XCTAssertFalse(try XCTUnwrap(updated?.responseRewrites.first?.isRuleEnabled))
    }

    func testRewriteInsertHappyPathAddsDisabledInsertRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(name: "b1", request: sampleRequest(), savedResponse: BookmarkSavedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("{\"tags\":[\"a\",\"b\"]}".utf8),
            savedAt: Date()
        ))
        try stack.bookmarkStore.saveBookmarks([bookmark])
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_rewrite",
            applyTool: "apply_create_rewrite",
            proposeArgs: [
                "bookmarkID": bookmark.id.uuidString,
                "jsonPath": "$.tags[1]",
                "operation": "insert",
                "overrideValue": ["type": "string", "value": "c"]
            ]
        )
        let updated = stack.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmark.id })
        let rewrite = try XCTUnwrap(updated?.responseRewrites.first)
        XCTAssertEqual(rewrite.operation, .insert)
        XCTAssertEqual(rewrite.jsonPath, "$.tags[1]")
    }

    func testBookmarkCreateHappyPath() async throws {
        let stack = try makeStack(profile: .shareable)
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_bookmark",
            applyTool: "apply_create_bookmark",
            proposeArgs: [
                "method": "POST",
                "host": "api.example.com",
                "path": "/create",
                "name": "Create item"
            ]
        )
        let bookmarks = stack.bookmarkStore.loadBookmarks()
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.mcpOrigin, .mcp)
    }

    func testMutatingToolsDeniedForMetadataOnlyProfile() async {
        let stack = try? makeStack(profile: .metadataOnly)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_block",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/x"
                ],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStaleBookmarkRevisionRejectedOnApply() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(name: "b1", request: sampleRequest(), savedResponse: BookmarkSavedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("{}".utf8),
            savedAt: Date()
        ))
        try stack.bookmarkStore.saveBookmarks([bookmark])
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_rewrite",
            arguments: [
                "bookmarkID": bookmark.id.uuidString,
                "jsonPath": "$.a",
                "overrideValue": ["type": "string", "value": "b"]
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        var edited = bookmark
        edited.responseMatchMode = .exactPath
        try stack.bookmarkStore.saveBookmarks([edited])
        do {
            _ = try await approvedApply(
                stack: stack,
                tool: "apply_create_rewrite",
                args: ["proposalToken": token]
            )
            XCTFail("expected stale proposal")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testIdempotencyKeyReturnsSameTransaction() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposeArgs: [String: Any] = [
            "method": "GET",
            "host": "api.example.com",
            "path": "/idem",
            "statusCode": 404,
            "idempotencyKey": "idem-block-1"
        ]
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: proposeArgs,
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let first = try await approvedApply(
            stack: stack,
            tool: "apply_create_block",
            args: ["proposalToken": token, "idempotencyKey": "idem-block-1"]
        )
        let second = try await approvedApply(
            stack: stack,
            tool: "apply_create_block",
            args: ["proposalToken": token, "idempotencyKey": "idem-block-1"]
        )
        XCTAssertEqual(first["transactionID"] as? String, second["transactionID"] as? String)
    }

    func testInvalidProposalTokensDoNotCreateApprovalRequests() async throws {
        let stack = try makeStack(profile: .shareable)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_block",
                arguments: ["proposalToken": "unknown"],
                client: stack.client
            )
            XCTFail("expected unknown proposal to fail")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal, "unknown token")
        }
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)

        let expired = try stack.proposalCoordinator.createProposal(
            clientID: stack.client.id,
            capability: .createDisabledBlock,
            argumentDigest: "expired",
            targetRevision: nil,
            targetLockKey: "expired",
            lifetime: -1
        )
        stack.mutationService.plansByProposalToken[expired.token] = MCPMutationPlan(
            capability: .createDisabledBlock,
            proposedTargetID: UUID(),
            effectKind: .block,
            effectSummary: "Expired proposal"
        )
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_block",
                arguments: ["proposalToken": expired.token],
                client: stack.client
            )
            XCTFail("expected expired proposal to fail")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal, "expired token")
        }
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/consumed",
                "statusCode": 404
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let firstApply = try await approvedApply(
            stack: stack,
            tool: "apply_create_block",
            args: ["proposalToken": token]
        )
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        let cachedRetry = try await stack.mutationService.handleTool(
            name: "apply_create_block",
            arguments: ["proposalToken": token],
            client: stack.client
        )
        XCTAssertEqual(cachedRetry["transactionID"] as? String, firstApply["transactionID"] as? String)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
    }

    // MARK: - Helpers

    private func makeStack(profile: MCPDisclosureProfileID) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "mutation-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "mutation-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "mutation-audit.json"))
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
            enforcesLiveRewritePreview: false
        )
        let client = MCPClientRecord(
            id: "client-mutation-test",
            displayName: "mutation-test",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            mutationService: mutationService,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            journalStore: journalStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            approvalStore: approvalStore,
            auditStore: auditStore,
            policyStore: policyStore,
            client: client
        )
    }

    private func blockRuleIDAfterCreate(stack: Stack, path: String) async throws -> UUID {
        _ = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_block",
            applyTool: "apply_create_block",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "statusCode": 503
            ]
        )
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first?.id)
    }

    private func enableBlockRule(stack: Stack, overrideID: UUID) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": overrideID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await approvedApply(stack: stack, tool: "apply_enable_rule", args: ["proposalToken": token])
    }

    private func proposeAndApply(
        stack: Stack,
        proposeTool: String,
        applyTool: String,
        proposeArgs: [String: Any],
        existingToken: String? = nil
    ) async throws -> String {
        let token: String
        if let existingToken {
            token = existingToken
        } else {
            let proposal = try await stack.mutationService.handleTool(
                name: proposeTool,
                arguments: proposeArgs,
                client: stack.client
            )
            token = try XCTUnwrap(proposal["proposalToken"] as? String)
        }
        _ = try await approvedApply(stack: stack, tool: applyTool, args: ["proposalToken": token])
        return token
    }

    private func approvedApply(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            return try await stack.mutationService.handleTool(name: tool, arguments: args, client: stack.client)
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retryArgs = args
            retryArgs["approval"] = try authorizationDictionary(authorization)
            return try await stack.mutationService.handleTool(name: tool, arguments: retryArgs, client: stack.client)
        }
    }

    private func authorizationDictionary(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "authorization encoding failed")
        }
        return object
    }

    private func sampleRequest(path: String = "/test") -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
