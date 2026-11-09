import CryptoKit
import Foundation

struct MCPRuntimeIdentityDTO: Codable, Equatable, Sendable {
    var appBuildFingerprint: String
    var marketingVersion: String
    var buildVersion: String
    var capabilitiesBundleVersion: String
    var capabilitiesManifestDigest: String
    var skillVersion: String
}

struct MCPRuntimeCompatibilityExpectationDTO: Codable, Equatable, Sendable {
    var appBuildFingerprint: String?
    var marketingVersion: String?
    var buildVersion: String?
    var capabilitiesBundleVersion: String?
    var capabilitiesManifestDigest: String?
    var skillVersion: String?
}

struct MCPRuntimeCompatibilityDTO: Codable, Equatable, Sendable {
    var state: String
    var compatible: Bool?
    var reasonCodes: [String]
    var recommendedActions: [String]
}

enum MCPRuntimeIdentityBuilder {
    private static let unavailableDigest = "unavailable"

    static func current(
        bundle: Bundle = .main,
        manifest: MCPCapabilitiesManifest = MCPCapabilitiesManifestBuilder.buildManifest()
    ) -> MCPRuntimeIdentityDTO {
        identity(
            marketingVersion: bundle.marketingVersionOrDev,
            buildVersion: bundle.buildNumber.isEmpty ? "dev" : bundle.buildNumber,
            manifest: manifest,
            skillVersion: bundle.marketingVersionOrDev
        )
    }

    static func identity(
        marketingVersion: String,
        buildVersion: String,
        manifest: MCPCapabilitiesManifest,
        skillVersion: String
    ) -> MCPRuntimeIdentityDTO {
        let manifestDigest = digest(for: manifest)
        let fingerprintSource = [
            marketingVersion,
            buildVersion,
            manifest.bundleVersion,
            manifestDigest,
            skillVersion
        ].joined(separator: "\u{1f}")
        return MCPRuntimeIdentityDTO(
            appBuildFingerprint: sha256(Data(fingerprintSource.utf8)),
            marketingVersion: marketingVersion,
            buildVersion: buildVersion,
            capabilitiesBundleVersion: manifest.bundleVersion,
            capabilitiesManifestDigest: manifestDigest,
            skillVersion: skillVersion
        )
    }

    /// Hashes the manifest contract while deliberately excluding `generatedAt`, which describes
    /// export time rather than capability compatibility.
    static func digest(for manifest: MCPCapabilitiesManifest) -> String {
        let stableManifest = MCPCapabilitiesManifest(
            schemaVersion: manifest.schemaVersion,
            bundleVersion: manifest.bundleVersion,
            appVersion: manifest.appVersion,
            mcpProtocolVersion: manifest.mcpProtocolVersion,
            generatedAt: Date(timeIntervalSince1970: 0),
            tools: manifest.tools,
            resources: manifest.resources,
            mediaWorkflows: manifest.mediaWorkflows,
            policyProfiles: manifest.policyProfiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stableManifest) else { return unavailableDigest }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum MCPRuntimeCompatibilityEvaluator {
    static let maximumRecommendedActions = 3

    static func evaluate(
        runtime: MCPRuntimeIdentityDTO,
        expectation: MCPRuntimeCompatibilityExpectationDTO?
    ) -> MCPRuntimeCompatibilityDTO {
        guard let expectation, hasExpectation(expectation) else {
            return MCPRuntimeCompatibilityDTO(
                state: "not_evaluated",
                compatible: nil,
                reasonCodes: ["client_identity_not_supplied"],
                recommendedActions: [
                    "Supply the identity from the exported agent bundle or use the bundled joesproxyctl doctor command."
                ]
            )
        }

        var reasons: [String] = []
        var actions: [String] = []
        var incompatible = false

        compareCapabilityBundle(
            expected: expectation.capabilitiesBundleVersion,
            actual: runtime.capabilitiesBundleVersion,
            reasons: &reasons,
            actions: &actions,
            incompatible: &incompatible
        )
        compare(
            expected: expectation.capabilitiesManifestDigest,
            actual: runtime.capabilitiesManifestDigest,
            mismatchReason: "capabilities_manifest_digest_mismatch",
            action: "Re-export the JoesProxy agent bundle from the running app and reload it in the client.",
            reasons: &reasons,
            actions: &actions,
            incompatible: &incompatible
        )
        compare(
            expected: expectation.skillVersion,
            actual: runtime.skillVersion,
            mismatchReason: "skill_version_mismatch",
            action: "Replace the client skill with the version exported by the running app.",
            reasons: &reasons,
            actions: &actions,
            incompatible: &incompatible
        )

        let buildDiffers = differs(expectation.appBuildFingerprint, runtime.appBuildFingerprint)
            || differs(expectation.marketingVersion, runtime.marketingVersion)
            || differs(expectation.buildVersion, runtime.buildVersion)
        if buildDiffers {
            reasons.append("app_build_mismatch")
            appendUnique(
                "Confirm that the CLI or agent is connected to the intended running JoesProxy app instance.",
                to: &actions
            )
        }

        if incompatible {
            return result(state: "incompatible", compatible: false, reasons: reasons, actions: actions)
        }
        if buildDiffers {
            return result(state: "compatible_build_differs", compatible: true, reasons: reasons, actions: actions)
        }
        return result(state: "compatible", compatible: true, reasons: ["identity_match"], actions: [])
    }

    private static func compareCapabilityBundle(
        expected: String?,
        actual: String,
        reasons: inout [String],
        actions: inout [String],
        incompatible: inout Bool
    ) {
        guard let expected, expected != actual else { return }
        incompatible = true
        let expectedRevision = capabilityRevision(expected)
        let actualRevision = capabilityRevision(actual)
        if let expectedRevision, let actualRevision, expectedRevision < actualRevision {
            reasons.append("client_capabilities_stale")
            appendUnique("Re-export the JoesProxy agent bundle from the running app and reload it in the client.", to: &actions)
        } else if let expectedRevision, let actualRevision, expectedRevision > actualRevision {
            reasons.append("server_capabilities_stale")
            appendUnique("Launch the JoesProxy app bundled with this CLI or update the running app before continuing.", to: &actions)
        } else {
            reasons.append("capabilities_bundle_mismatch")
            appendUnique("Use matching JoesProxy app, CLI, capability manifest, and skill versions.", to: &actions)
        }
    }

    private static func compare(
        expected: String?,
        actual: String,
        mismatchReason: String,
        action: String,
        reasons: inout [String],
        actions: inout [String],
        incompatible: inout Bool
    ) {
        guard differs(expected, actual) else { return }
        incompatible = true
        reasons.append(mismatchReason)
        appendUnique(action, to: &actions)
    }

    private static func differs(_ expected: String?, _ actual: String) -> Bool {
        guard let expected else { return false }
        return expected != actual
    }

    private static func hasExpectation(_ expectation: MCPRuntimeCompatibilityExpectationDTO) -> Bool {
        expectation.appBuildFingerprint != nil
            || expectation.marketingVersion != nil
            || expectation.buildVersion != nil
            || expectation.capabilitiesBundleVersion != nil
            || expectation.capabilitiesManifestDigest != nil
            || expectation.skillVersion != nil
    }

    private static func capabilityRevision(_ bundleVersion: String) -> Int? {
        guard let suffix = bundleVersion.split(separator: "+", omittingEmptySubsequences: false).last else {
            return nil
        }
        return Int(suffix)
    }

    private static func appendUnique(_ action: String, to actions: inout [String]) {
        guard !actions.contains(action) else { return }
        actions.append(action)
    }

    private static func result(
        state: String,
        compatible: Bool,
        reasons: [String],
        actions: [String]
    ) -> MCPRuntimeCompatibilityDTO {
        MCPRuntimeCompatibilityDTO(
            state: state,
            compatible: compatible,
            reasonCodes: Array(reasons.prefix(6)),
            recommendedActions: Array(actions.prefix(maximumRecommendedActions))
        )
    }
}
