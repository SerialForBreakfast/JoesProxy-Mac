import XCTest
@testable import JoesProxy

/// AW-1 budgets, bookmark encoding, schema subset, activation, and relaunch recovery.
final class OpenAPIMockPackContractTests: XCTestCase {
    func testBudgetRejectsWithoutTruncation() {
        XCTAssertThrowsError(
            try OpenAPIMockPackBudget.validateDocumentBytes(OpenAPIMockPackBudget.maxDocumentBytes + 1)
        ) { error in
            XCTAssertEqual(
                error as? OpenAPIMockPackError,
                .documentTooLarge(byteCount: OpenAPIMockPackBudget.maxDocumentBytes + 1)
            )
        }
        XCTAssertNoThrow(try OpenAPIMockPackBudget.validateDocumentBytes(OpenAPIMockPackBudget.maxDocumentBytes))

        XCTAssertThrowsError(
            try OpenAPIMockPackBudget.validateOperationCount(OpenAPIMockPackBudget.maxOperationsPerPack + 1)
        )
        XCTAssertThrowsError(
            try OpenAPIMockPackBudget.validateVariantCount(operation: "listItems", count: 9)
        )
        XCTAssertThrowsError(
            try OpenAPIMockPackBudget.validateCompiledBodyBytes(OpenAPIMockPackBudget.maxCompiledBodyBytes + 1)
        )
        XCTAssertThrowsError(try OpenAPIMockPackBudget.validateRefDepth(9))
        XCTAssertThrowsError(try OpenAPIMockPackBudget.validateTTL(0))
        XCTAssertThrowsError(try OpenAPIMockPackBudget.validateTTL(OpenAPIMockPackBudget.maxTTL + 1))
        XCTAssertNoThrow(try OpenAPIMockPackBudget.validateTTL(OpenAPIMockPackBudget.defaultTTL))
        XCTAssertThrowsError(
            try OpenAPIMockPackBudget.validateRetainedPackCount(OpenAPIMockPackBudget.maxRetainedPackRecords)
        )
        XCTAssertNoThrow(
            try OpenAPIMockPackBudget.validateRetainedPackCount(OpenAPIMockPackBudget.maxRetainedPackRecords - 1)
        )
        XCTAssertEqual(OpenAPIMockPackBudget.maxCompiledBodyBytes, MCPResourceBudget.maxDisclosedItemBytes)
    }

    func testBookmarkCodableIsDataOnlyNotAPath() throws {
        let bookmark = OpenAPIDocumentBookmark(data: Data((0..<32).map { UInt8($0) }))
        let encoded = try JSONEncoder().encode(bookmark)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        XCTAssertTrue(jsonObject is String, "Bookmark Codable must be a single-value Data payload, not a keyed object.")
        XCTAssertFalse(jsonObject is [String: Any])
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("file://"))

        let decoded = try JSONDecoder().decode(OpenAPIDocumentBookmark.self, from: encoded)
        XCTAssertEqual(decoded.data, bookmark.data)

        let ref = try XCTUnwrap(OpenAPIDocumentBookmark(ref: bookmark.ref))
        XCTAssertEqual(ref.data, bookmark.data)
        XCTAssertNil(OpenAPIDocumentBookmark(ref: "/tmp/openapi.json"))
    }

    func testPackCodableDoesNotStoreDocumentPath() throws {
        let pack = OpenAPIMockPack(
            id: OpenAPIMockPackID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            owner: .localUser,
            origin: OpenAPIMockOrigin(scheme: .http, host: "catalog.example.invalid"),
            documentBookmark: OpenAPIDocumentBookmark(data: Data([1, 2, 3, 4])),
            state: .inactive,
            startedAt: nil,
            expiresAt: nil,
            stoppedAt: nil,
            metrics: OpenAPIMockPackMetrics(),
            coverage: OpenAPIMockCoverageSummary(
                supportedOperationCount: 4,
                variantCount: 5,
                generatedVariantCount: 0,
                declaredExampleCount: 4,
                unsupportedFeatureCount: 1,
                conflictCount: 0
            ),
            mcpProvenance: nil
        )
        let encoded = try JSONEncoder().encode(pack)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("openapi.json"))
        let decoded = try JSONDecoder().decode(OpenAPIMockPack.self, from: encoded)
        XCTAssertEqual(decoded.documentBookmark.data, pack.documentBookmark.data)
        XCTAssertEqual(decoded.state, .inactive)
    }

    func testSchemaSupportReportsUnsupportedWithoutGuessing() {
        let report = OpenAPIMockSchemaSupport.classify([
            .object, .properties, .required, .string, .enum,
            .oneOf, .eventStream, .remoteRef, .openAPI31
        ])
        XCTAssertTrue(report.supported.contains(.object))
        XCTAssertTrue(report.supported.contains(.enum))
        XCTAssertEqual(report.unsupported, [.oneOf, .eventStream, .remoteRef, .openAPI31])
        XCTAssertFalse(report.isFullySupported)

        let supportedOnly = OpenAPIMockSchemaSupport.classify([.array, .items, .formatUUID])
        XCTAssertTrue(supportedOnly.isFullySupported)
        XCTAssertTrue(supportedOnly.unsupported.isEmpty)
    }

    func testActivationAllowsOnePackAndDisclosesNoBodies() throws {
        let packID = OpenAPIMockPackID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let allowed = OpenAPIMockPackActivationPolicy.evaluate(
            OpenAPIMockActivationRequest(
                packID: packID,
                owner: .localUser,
                origin: OpenAPIMockOrigin(scheme: .http, host: "catalog.example.invalid"),
                routeCount: 4,
                documentByteCount: 1_024,
                ttl: OpenAPIMockPackBudget.defaultTTL,
                activePackCountForOwner: 0,
                retainedPackCount: 0,
                overlappingRules: [],
                conflictStrategy: .refuse
            )
        )
        guard case .allowed(let disclosure) = allowed else {
            return XCTFail("expected allowed, got \(allowed)")
        }
        XCTAssertEqual(disclosure.routeCount, 4)
        XCTAssertEqual(disclosure.originDisplay, "http://catalog.example.invalid")
        XCTAssertEqual(disclosure.conflictCount, 0)
        let encoded = try JSONEncoder().encode(disclosure)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("body"))
        XCTAssertFalse(json.contains("/Users/"))
    }

    func testActivationRefusesBusyOwnerSlot() {
        let decision = OpenAPIMockPackActivationPolicy.evaluate(activationRequest(activePackCountForOwner: 1))
        XCTAssertEqual(decision, .refusedBusy)
    }

    func testActivationRefusesOverlapsUnlessReplaceConflicts() {
        let overlap = OpenAPIMockOverlappingRule(
            ruleID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            method: "GET",
            pathDescription: "/v1/catalog"
        )
        let refused = OpenAPIMockPackActivationPolicy.evaluate(
            activationRequest(overlappingRules: [overlap], conflictStrategy: .refuse)
        )
        XCTAssertEqual(refused, .refusedConflicts([overlap]))

        let replaced = OpenAPIMockPackActivationPolicy.evaluate(
            activationRequest(overlappingRules: [overlap], conflictStrategy: .replaceConflicts)
        )
        guard case .allowed(let disclosure) = replaced else {
            return XCTFail("expected allowed with replaceConflicts")
        }
        XCTAssertEqual(disclosure.conflictCount, 1)
    }

    func testActivationRefusesBudgetBreaches() {
        let tooBig = OpenAPIMockPackActivationPolicy.evaluate(
            activationRequest(documentByteCount: OpenAPIMockPackBudget.maxDocumentBytes + 1)
        )
        XCTAssertEqual(
            tooBig,
            .refusedBudget(.documentTooLarge(byteCount: OpenAPIMockPackBudget.maxDocumentBytes + 1))
        )
        let tooMany = OpenAPIMockPackActivationPolicy.evaluate(
            activationRequest(retainedPackCount: OpenAPIMockPackBudget.maxRetainedPackRecords)
        )
        XCTAssertEqual(tooMany, .refusedBudget(.retainedPackLimitExceeded))
    }

    func testRelaunchNeverRestoresServing() {
        XCTAssertEqual(OpenAPIMockPackActivationPolicy.relaunchState(from: .serving), .stopped)
        XCTAssertEqual(OpenAPIMockPackActivationPolicy.relaunchState(from: .stopped), .stopped)
        XCTAssertEqual(OpenAPIMockPackActivationPolicy.relaunchState(from: .inactive), .inactive)
        XCTAssertEqual(OpenAPIMockPackActivationPolicy.relaunchState(from: .expired), .expired)
        XCTAssertEqual(OpenAPIMockPackActivationPolicy.relaunchState(from: .cleanupRequired), .cleanupRequired)
    }

    func testOriginCanonicalPort() {
        let https = OpenAPIMockOrigin(scheme: .https, host: " Catalog.Example.Invalid ")
        XCTAssertEqual(https.host, "catalog.example.invalid")
        XCTAssertEqual(https.port, 443)
        XCTAssertEqual(https.displayString, "https://catalog.example.invalid")
        let custom = OpenAPIMockOrigin(scheme: .http, host: "catalog.example.invalid", port: 9090)
        XCTAssertEqual(custom.displayString, "http://catalog.example.invalid:9090")
    }

    private func activationRequest(
        documentByteCount: Int = 1_024,
        activePackCountForOwner: Int = 0,
        retainedPackCount: Int = 0,
        overlappingRules: [OpenAPIMockOverlappingRule] = [],
        conflictStrategy: OpenAPIMockConflictStrategy = .refuse
    ) -> OpenAPIMockActivationRequest {
        OpenAPIMockActivationRequest(
            packID: OpenAPIMockPackID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            owner: .localUser,
            origin: OpenAPIMockOrigin(scheme: .http, host: "catalog.example.invalid"),
            routeCount: 4,
            documentByteCount: documentByteCount,
            ttl: OpenAPIMockPackBudget.defaultTTL,
            activePackCountForOwner: activePackCountForOwner,
            retainedPackCount: retainedPackCount,
            overlappingRules: overlappingRules,
            conflictStrategy: conflictStrategy
        )
    }
}
