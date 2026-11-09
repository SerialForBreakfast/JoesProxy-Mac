import Foundation
import XCTest
@testable import JoesProxy

final class MCPRuntimeIdentityTests: XCTestCase {
    func testManifestDigestIgnoresGenerationTimeButChangesWithContract() {
        let first = MCPCapabilitiesManifestBuilder.buildManifest(
            appVersion: "1.4.1",
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        let second = MCPCapabilitiesManifestBuilder.buildManifest(
            appVersion: "1.4.1",
            generatedAt: Date(timeIntervalSince1970: 9_999)
        )
        var changed = second
        changed.tools.removeLast()

        XCTAssertEqual(MCPRuntimeIdentityBuilder.digest(for: first), MCPRuntimeIdentityBuilder.digest(for: second))
        XCTAssertNotEqual(MCPRuntimeIdentityBuilder.digest(for: first), MCPRuntimeIdentityBuilder.digest(for: changed))
    }

    func testRuntimeFingerprintBindsBuildManifestAndSkill() {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest(appVersion: "1.4.1")
        let baseline = MCPRuntimeIdentityBuilder.identity(
            marketingVersion: "1.4.1",
            buildVersion: "12",
            manifest: manifest,
            skillVersion: "1.4.1"
        )
        let newerBuild = MCPRuntimeIdentityBuilder.identity(
            marketingVersion: "1.4.1",
            buildVersion: "13",
            manifest: manifest,
            skillVersion: "1.4.1"
        )

        XCTAssertEqual(baseline.appBuildFingerprint.count, 64)
        XCTAssertEqual(baseline.capabilitiesManifestDigest.count, 64)
        XCTAssertNotEqual(baseline.appBuildFingerprint, newerBuild.appBuildFingerprint)
    }

    func testCompatibilityDistinguishesStaleAndNewerCapabilityBundles() {
        let runtime = runtimeIdentity(capabilityBundleVersion: "1.4.1+8")
        let stale = MCPRuntimeCompatibilityEvaluator.evaluate(
            runtime: runtime,
            expectation: expectation(capabilityBundleVersion: "1.4.1+7")
        )
        let newer = MCPRuntimeCompatibilityEvaluator.evaluate(
            runtime: runtime,
            expectation: expectation(capabilityBundleVersion: "1.4.1+9")
        )

        XCTAssertEqual(stale.state, "incompatible")
        XCTAssertEqual(stale.compatible, false)
        XCTAssertTrue(stale.reasonCodes.contains("client_capabilities_stale"))
        XCTAssertTrue(newer.reasonCodes.contains("server_capabilities_stale"))
    }

    func testCompatibilityRequiresObservedRuntimeIdentityAndBoundsActions() {
        let runtime = runtimeIdentity(capabilityBundleVersion: "1.4.1+8")
        let unknown = MCPRuntimeCompatibilityEvaluator.evaluate(runtime: runtime, expectation: nil)
        let mismatch = MCPRuntimeCompatibilityEvaluator.evaluate(
            runtime: runtime,
            expectation: MCPRuntimeCompatibilityExpectationDTO(
                appBuildFingerprint: "different",
                marketingVersion: "2.0.0",
                buildVersion: "99",
                capabilitiesBundleVersion: "2.0.0+99",
                capabilitiesManifestDigest: "different",
                skillVersion: "2.0.0"
            )
        )

        XCTAssertEqual(unknown.state, "not_evaluated")
        XCTAssertNil(unknown.compatible)
        XCTAssertLessThanOrEqual(mismatch.recommendedActions.count, MCPRuntimeCompatibilityEvaluator.maximumRecommendedActions)
    }

    func testBundledCLICompatibilityRevisionCannotDriftFromAppContract() {
        XCTAssertEqual(CLIRuntimeIdentity.capabilitiesRevision, MCPCapabilitiesRevision.current)
    }

    private func runtimeIdentity(capabilityBundleVersion: String) -> MCPRuntimeIdentityDTO {
        MCPRuntimeIdentityDTO(
            appBuildFingerprint: "fingerprint",
            marketingVersion: "1.4.1",
            buildVersion: "12",
            capabilitiesBundleVersion: capabilityBundleVersion,
            capabilitiesManifestDigest: "manifest",
            skillVersion: "1.4.1"
        )
    }

    private func expectation(capabilityBundleVersion: String) -> MCPRuntimeCompatibilityExpectationDTO {
        MCPRuntimeCompatibilityExpectationDTO(
            appBuildFingerprint: nil,
            marketingVersion: nil,
            buildVersion: nil,
            capabilitiesBundleVersion: capabilityBundleVersion,
            capabilitiesManifestDigest: nil,
            skillVersion: nil
        )
    }
}
