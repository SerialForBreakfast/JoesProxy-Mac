import Foundation
import XCTest
@testable import JoesProxy

final class MCPContractTests: XCTestCase {
    func testSessionListPageEnvelopeRoundTripAndStrictVersionGate() throws {
        let summary = MCPSessionSummaryDTO(
            id: UUID().uuidString,
            captureSequence: 1,
            method: "GET",
            hostCategory: "api"
        )
        let page = MCPSessionListPageDTO(
            items: [summary],
            nextCursor: "opaque-cursor",
            hasMore: true,
            captureEpoch: .initial,
            policyRevision: .initial,
            truncated: false
        )
        let envelope = MCPDTOEnvelope(payload: page)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try MCPDTOEnvelope<MCPSessionListPageDTO>.decodeStrict(from: data)
        XCTAssertEqual(decoded.payload.items.first?.method, "GET")
        XCTAssertEqual(decoded.payload.nextCursor, "opaque-cursor")
        XCTAssertTrue(decoded.payload.hasMore)

        let futureVersion = MCPDTOEnvelope(
            payload: page,
            schemaVersion: MCPDTOSchema.currentVersion + 1
        )
        let futureData = try JSONEncoder().encode(futureVersion)
        XCTAssertThrowsError(try MCPDTOEnvelope<MCPSessionListPageDTO>.decodeStrict(from: futureData)) { error in
            XCTAssertEqual(
                error as? MCPDTOEnvelopeError,
                MCPDTOEnvelopeError.unsupportedSchemaVersion(
                    requested: MCPDTOSchema.currentVersion + 1,
                    supported: MCPDTOSchema.currentVersion
                )
            )
        }

        let legacyVersion = MCPDTOEnvelope(payload: page, schemaVersion: 0)
        XCTAssertThrowsError(
            try MCPDTOEnvelope<MCPSessionListPageDTO>.decodeStrict(from: JSONEncoder().encode(legacyVersion))
        )
    }

    func testUnknownPayloadFieldsDecodeWithoutFailure() throws {
        let json = """
        {
          "schemaVersion": 1,
          "payload": {
            "items": [],
            "nextCursor": null,
            "captureEpoch": { "rawValue": "capture-epoch-0" },
            "policyRevision": { "rawValue": "policy-v1" },
            "truncated": false,
            "futureField": "ignored-by-decoder"
          }
        }
        """
        struct TolerantPage: Decodable {
            var items: [MCPSessionSummaryDTO]
            var captureEpoch: MCPCaptureEpoch
            var truncated: Bool
        }
        struct TolerantEnvelope: Decodable {
            var schemaVersion: Int
            var payload: TolerantPage
        }
        let decoded = try JSONDecoder().decode(TolerantEnvelope.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.payload.items.isEmpty)
    }

    func testLegacyCursorTypeStillDecodesForFixtureTolerance() throws {
        let json = """
        {"token":"abc","captureRevision":{"rawValue":"capture-epoch-1"}}
        """
        let decoded = try JSONDecoder().decode(MCPCursor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.token, "abc")
        XCTAssertEqual(decoded.captureRevision.rawValue, "capture-epoch-1")
    }

    func testSessionQueryCursorValidationRejectsPolicyRevisionChange() {
        let cursor = MCPSessionQueryCursor(
            token: "t",
            clientID: "client-1",
            policyRevision: .initial,
            captureEpoch: .initial,
            queryDigest: "sessions_list",
            orderingDigest: "sequence_asc",
            highWaterSequence: 10,
            lastSequence: 5
        )
        let error = MCPCursorValidation.validate(
            cursor: cursor,
            clientID: "client-1",
            currentPolicyRevision: MCPPolicyRevision(rawValue: "policy-v2"),
            currentEpoch: .initial,
            queryDigest: "sessions_list",
            orderingDigest: "sequence_asc"
        )
        XCTAssertEqual(error?.code, .staleCursor)
    }

    func testPolicyTighteningInvalidatesPendingApproval() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = MCPApprovalRequest(
            requestID: "req-1",
            clientID: "client-1",
            argumentDigest: "digest",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: MCPApprovalPolicy.expiration(from: issuedAt),
            reason: "Sensitive body read",
            capability: .bodyRead
        )
        XCTAssertFalse(
            MCPApprovalPolicy.isInvalidated(
                request: request,
                currentPolicyRevision: .initial,
                now: issuedAt.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(
            MCPApprovalPolicy.isInvalidated(
                request: request,
                currentPolicyRevision: MCPPolicyRevision(rawValue: "policy-v2"),
                now: issuedAt.addingTimeInterval(30)
            )
        )
    }

    func testApprovalRetryValidationMatrix() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = MCPApprovalRequest(
            requestID: "req-1",
            clientID: "client-1",
            argumentDigest: "digest-a",
            policyRevision: .initial,
            targetRevision: MCPTargetRevision(rawValue: "target-1"),
            expiresAt: MCPApprovalPolicy.expiration(from: issuedAt),
            reason: "Read body",
            capability: .bodyRead
        )
        let authorization = MCPApprovalAuthorization(
            requestID: "req-1",
            clientID: "client-1",
            capability: .bodyRead,
            argumentDigest: "digest-a",
            policyRevision: .initial,
            targetRevision: MCPTargetRevision(rawValue: "target-1"),
            nonce: "nonce-1",
            expiresAt: MCPApprovalPolicy.expiration(from: issuedAt)
        )

        XCTAssertNil(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-a",
                currentPolicyRevision: .initial,
                currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
                now: issuedAt.addingTimeInterval(10),
                nonceAlreadyUsed: false
            )
        )
        XCTAssertEqual(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-a",
                currentPolicyRevision: .initial,
                currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
                now: issuedAt.addingTimeInterval(10),
                nonceAlreadyUsed: true
            ),
            .reused
        )
        XCTAssertEqual(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-b",
                currentPolicyRevision: .initial,
                currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
                now: issuedAt.addingTimeInterval(10),
                nonceAlreadyUsed: false
            ),
            .argumentMismatch
        )
        XCTAssertEqual(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-2",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-a",
                currentPolicyRevision: .initial,
                currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
                now: issuedAt.addingTimeInterval(10),
                nonceAlreadyUsed: false
            ),
            .argumentMismatch
        )
        XCTAssertEqual(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-a",
                currentPolicyRevision: .initial,
                currentTargetRevision: nil,
                now: issuedAt.addingTimeInterval(10),
                nonceAlreadyUsed: false
            ),
            .targetRevisionChanged
        )
        XCTAssertEqual(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .bodyRead,
                normalizedArgumentDigest: "digest-a",
                currentPolicyRevision: .initial,
                currentTargetRevision: MCPTargetRevision(rawValue: "target-1"),
                now: issuedAt.addingTimeInterval(MCPApprovalPolicy.defaultLifetime),
                nonceAlreadyUsed: false
            ),
            .expired
        )
    }

    func testEveryPublicErrorCodeSerializes() throws {
        for code in MCPErrorCode.allCases {
            let error = MCPStructuredError(code: code, message: "message-for-\(code.rawValue)")
            let data = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(MCPStructuredError.self, from: data)
            XCTAssertEqual(decoded.code, code)
        }
    }

    func testReturnToNormalIsRecoveryMutationNotDestructiveDeletion() {
        XCTAssertEqual(MCPCapabilityID.returnToNormal.riskTier, .mutatingTool)
    }

    func testApprovalRequiredStructuredErrorIncludesRequestMetadata() {
        let request = MCPApprovalRequest(
            requestID: "req-99",
            clientID: "client-99",
            argumentDigest: "digest",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_120),
            reason: "Approve body read",
            capability: .bodyRead
        )
        let error = MCPStructuredError.approvalRequired(request)
        XCTAssertEqual(error.code, .approvalRequired)
        XCTAssertEqual(error.details?["requestID"], "req-99")
        XCTAssertEqual(error.policyRevision, .initial)
    }

    func testServiceBoundaryInventoryCoversDocumentedSeams() {
        XCTAssertEqual(MCPServiceBoundary.allCases.count, 9)
        XCTAssertTrue(MCPServiceBoundary.sessionStore.existingSeamDescription.contains("SessionStore"))
        XCTAssertTrue(MCPServiceBoundary.sensitiveDataRedaction.existingSeamDescription.contains("SensitiveDataRedaction"))
    }
}
