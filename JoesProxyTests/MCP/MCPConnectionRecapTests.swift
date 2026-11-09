import XCTest
@testable import JoesProxy

final class MCPConnectionRecapTests: XCTestCase {
    func testBuildsBoundedRecapFromAuditFixture() {
        let clientID = "client-a"
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let events: [MCPAuditEvent] = [
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: connectedAt.addingTimeInterval(10),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "session_summary",
                detail: nil
            ),
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: connectedAt.addingTimeInterval(20),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "body_read",
                detail: nil
            ),
            MCPAuditEvent(
                id: UUID(),
                kind: .throttleChanged,
                timestamp: connectedAt.addingTimeInterval(30),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "change_throttle",
                detail: nil
            ),
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: connectedAt.addingTimeInterval(40),
                clientID: "client-b",
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "session_summary",
                detail: nil
            )
        ]

        let recap = MCPConnectionRecapBuilder.build(
            clientID: clientID,
            displayName: "Codex",
            events: events,
            connectedAt: connectedAt,
            lastActivityAt: connectedAt.addingTimeInterval(35),
            scenarioNamesByID: ["scenario-1": "Slow network UX"]
        )

        XCTAssertTrue(recap.summaryLines.joined(separator: " ").contains("session summary"))
        XCTAssertTrue(recap.summaryLines.joined(separator: " ").contains("body"))
        XCTAssertTrue(recap.summaryLines.joined(separator: " ").contains("throttle"))
        XCTAssertFalse(recap.proseSummary.contains("client-b"))
        XCTAssertLessThanOrEqual(recap.summaryLines.count, MCPConnectionRecapBuilder.maxLines)
    }

    func testScenarioNamesAppearInRecapWhenPresentInAuditDetail() {
        let clientID = "client-scenario"
        let connectedAt = Date()
        let events = [
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: connectedAt,
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "scenario_tool",
                detail: "scenario:scenario-1"
            )
        ]
        let recap = MCPConnectionRecapBuilder.build(
            clientID: clientID,
            displayName: "Claude",
            events: events,
            connectedAt: connectedAt,
            lastActivityAt: connectedAt,
            scenarioNamesByID: ["scenario-1": "Slow network UX"]
        )
        XCTAssertTrue(recap.summaryLines.joined(separator: " ").contains("Slow network UX"))
    }
}

final class MCPAttentionLevelTests: XCTestCase {
    func testClientCannotLowerAttentionBelowCapabilityTier() {
        XCTAssertFalse(
            MCPAttentionLevel.validatesClientCannotLowerAttention(
                requestedLevel: .ambient,
                capability: .enableRule
            )
        )
        XCTAssertTrue(
            MCPAttentionLevel.validatesClientCannotLowerAttention(
                requestedLevel: .interruptive,
                capability: .enableRule
            )
        )
    }

    func testSensitiveReadMapsToNoticedAttention() {
        XCTAssertEqual(
            MCPAttentionLevel.attentionLevel(for: MCPCapabilityID.bodyRead.riskTier),
            .noticed
        )
    }

    func testPassiveResourceMapsToAmbientAttention() {
        XCTAssertEqual(
            MCPAttentionLevel.attentionLevel(for: MCPCapabilityID.serverResource.riskTier),
            .ambient
        )
    }
}
