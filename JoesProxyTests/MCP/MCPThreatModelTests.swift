import XCTest
@testable import JoesProxy

final class MCPThreatModelTests: XCTestCase {
    func testPromptInjectionFixturesRemainInertAuthorizationInput() {
        XCTAssertTrue(MCPThreatModelFixtures.allPromptInjectionSamplesAreInert())
        for sample in MCPThreatModelFixtures.promptInjectionSamples {
            XCTAssertFalse(MCPAuthorizationInputValidator.isValidAuthorization(fromCapturedContent: sample.text))
        }
    }

    func testCapturedAuthorizationLikeStringsAreFlaggedButStillInert() {
        for sample in MCPThreatModelFixtures.promptInjectionSamples {
            XCTAssertTrue(sample.isAuthorizationLike())
        }
        for sample in MCPThreatModelFixtures.benignCapturedSamples {
            XCTAssertFalse(sample.isAuthorizationLike())
        }
    }

    func testExplicitApprovalObjectCanValidateWhenMatchingRequest() {
        let issuedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let request = MCPApprovalRequest(
            requestID: "req-1",
            clientID: "client-1",
            argumentDigest: "digest",
            policyRevision: .initial,
            targetRevision: nil,
            expiresAt: MCPApprovalPolicy.expiration(from: issuedAt),
            reason: "Approve",
            capability: .headerRead
        )
        let authorization = MCPApprovalAuthorization(
            requestID: "req-1",
            clientID: "client-1",
            capability: .headerRead,
            argumentDigest: "digest",
            policyRevision: .initial,
            targetRevision: nil,
            nonce: "once",
            expiresAt: MCPApprovalPolicy.expiration(from: issuedAt)
        )
        XCTAssertNil(
            MCPApprovalValidation.validateRetry(
                request: request,
                authorization: authorization,
                currentClientID: "client-1",
                currentCapability: .headerRead,
                normalizedArgumentDigest: request.argumentDigest,
                currentPolicyRevision: request.policyRevision,
                currentTargetRevision: authorization.targetRevision,
                now: issuedAt.addingTimeInterval(30),
                nonceAlreadyUsed: false
            )
        )
        XCTAssertTrue(MCPAuthorizationInputValidator.isValidAuthorization(authorization: authorization, request: request))
    }

    func testThreatCategoryInventoryMatchesADRSet() {
        XCTAssertTrue(MCPThreatCategory.allCases.contains(.diagnosticMisattribution))
        XCTAssertTrue(MCPThreatCategory.allCases.contains(.promptInjectionThroughCapturedTraffic))
    }
}
