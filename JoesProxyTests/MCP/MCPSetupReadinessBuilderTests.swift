import XCTest
@testable import JoesProxy

@MainActor
final class MCPSetupReadinessBuilderTests: XCTestCase {
    func testReadinessBuildsFromTypedStateWithoutAPresentationModel() {
        let result = MCPSetupReadinessBuilder.make(
            target: .generic,
            host: MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: false,
                proxyState: "running",
                proxyPort: 9090,
                systemProxyManagementEnabled: false
            ),
            credentialState: .active,
            readinessState: MCPSetupReadinessState(
                localTrustState: .ready,
                profileHealth: .current,
                verificationState: .inspected,
                profileDownloadObserved: true
            )
        )

        XCTAssertEqual(result.state, "ready")
        XCTAssertEqual(result.checks.first(where: { $0.id == "profile.host" })?.state, .observed)
        XCTAssertEqual(result.checks.first(where: { $0.id == "device.profile_delivery" })?.state, .observed)
    }

    func testUnavailableInputsRemainActionableAndNotObservable() {
        let result = MCPSetupReadinessBuilder.make(
            target: .generic,
            host: MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: false,
                proxyState: "stopped",
                proxyPort: nil,
                systemProxyManagementEnabled: false
            ),
            credentialState: .revoked,
            readinessState: MCPSetupReadinessState(
                localTrustState: .notSetUp,
                profileHealth: .unknown,
                verificationState: nil,
                profileDownloadObserved: false
            )
        )

        XCTAssertEqual(result.state, "action_required")
        XCTAssertEqual(result.checks.first(where: { $0.id == "remote_wifi_proxy" })?.state, .notObservable)
        XCTAssertEqual(result.checks.first(where: { $0.id == "traffic" })?.state, .needsUserConfirmation)
    }
}
