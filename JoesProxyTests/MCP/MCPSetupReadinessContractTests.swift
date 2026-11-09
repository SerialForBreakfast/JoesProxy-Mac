import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPSetupReadinessContractTests: XCTestCase {
    func testReadinessTargetsAndStatesHaveStableWireValues() throws {
        XCTAssertEqual(MCPSetupReadinessTarget.allCases.map(\.rawValue), ["macOS", "iOS/iPadOS", "tvOS", "Simulator", "generic"])
        XCTAssertEqual(MCPSetupReadinessCheckState.needsUserConfirmation.rawValue, "needs_user_confirmation")
        XCTAssertEqual(MCPSetupReadinessCheckState.notObservable.rawValue, "not_observable")

        let dto = MCPSetupReadinessDTO(
            schemaVersion: 1,
            target: .iOSiPadOS,
            state: "action_required",
            checks: [MCPSetupReadinessCheckDTO(
                id: "remote_profile_installation",
                state: .notObservable,
                detail: "Remote profile installation cannot be observed.",
                evidence: nil,
                actor: .user,
                nextHumanAction: "Confirm installation on the device.",
                confidenceBoundary: "Download is not proof of installation."
            )],
            recommendedNextActions: ["Confirm installation on the device."],
            remoteTrustNotObservable: true
        )
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(MCPSetupReadinessDTO.self, from: data)
        XCTAssertEqual(decoded, dto)
    }

    func testManifestAndRouterExposeReadinessAndPortableGuide() {
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "setup_readiness"), .setupReadiness)
        XCTAssertEqual(MCPCapabilityRouter.capability(forResource: "joesproxy://setup/guide"), .agentResource)
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionTools.contains { $0.name == "setup_readiness" })
        XCTAssertTrue(MCPCapabilitiesManifestBuilder.productionResources.contains { $0.uri == "joesproxy://setup/guide" })
    }

    func testPortableGuideContainsNoLiveValues() {
        let guide = MCPSetupGuideContent.markdown
        XCTAssertTrue(guide.contains("JoesProxy Setup Guide"))
        XCTAssertTrue(guide.contains("bootstrap-only"))
        XCTAssertFalse(guide.contains("Bearer "))
        XCTAssertFalse(guide.contains("192.168."))
        XCTAssertFalse(guide.contains("http://127.0.0.1:"))
        XCTAssertFalse(guide.contains("sha256:"))
        XCTAssertFalse(guide.contains("MIIC"))
    }
}
