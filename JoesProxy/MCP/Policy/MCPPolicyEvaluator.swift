import Foundation

/// Pure read-side effective access evaluation: profile baseline AND grants, never profile bypass.
///
/// Grants replace per-call one-use approval friction only; they cannot elevate a Metadata-Only client
/// to Shareable-equivalent tool access.
///
/// Concurrency: `@MainActor` — reads ``MCPPolicyStore`` and ``MCPClientGrantStore`` on the main actor.
@MainActor
struct MCPPolicyEvaluator {
    let policyStore: MCPPolicyStore
    let grantStore: MCPClientGrantStore

    /// Whether the client's disclosure profile permits this capability at all.
    func profileAllows(capability: MCPCapabilityID, profileID: MCPDisclosureProfileID) -> Bool {
        if capability == .artifactSourceRelease { return true }
        if capability == .artifactSourceAccess { return profileID == .metadataOnly || profileID == .shareable }
        if capability == .artifactCalculate || capability == .artifactSearch || capability == .artifactBrief || capability == .artifactCompare { return profileID == .shareable }
        if profileID == .developerInspection {
            return Self.developerInspectionAllows(capability)
        }
        switch capability {
        case .deviceInspect, .bookmarkInspect, .overrideInspect, .httpsRulesInspect, .structuralDiscovery, .transformationPreview,
             .responseContext, .responseTextSearch, .responseDraftInspect, .hlsFixtureInspect,
             .openAPIMockInspect:
            return policyStore.allowsInspectTools(for: profileID)
        case .deviceAliasManage, .createDisabledBookmark, .createDisabledMapLocal, .createDisabledMapRemote,
             .createDisabledBlock, .createDisabledRewrite, .createDisabledLiveRewrite,
             .createDisabledCollectionMock,
             .createResponseDraft:
            return policyStore.allowsMutatingTools(for: profileID)
        case .enableRule, .disableRule, .changeThrottle, .httpsRulesManage:
            return policyStore.allowsActiveMutations(for: profileID)
        case .deleteRule:
            return policyStore.allowsActiveMutations(for: profileID)
        case .executeBookmark, .activateMapRemote, .activateLiveRewrite, .activateCollectionMock,
             .replayRequest, .liveMediaProbe:
            return policyStore.allowsOpenWorldTools(for: profileID)
        case .certificateStatus, .certificateIdentity, .certificateArtifactsList, .certificateCompare,
             .certificateExport:
            return policyStore.allowsInspectTools(for: profileID)
        case .headerRead, .queryRead, .bodyRead:
            return profileID == .shareable
        case .returnToNormal, .runtimeControl, .scenarioLifecycle, .hlsFixtureLifecycle, .hlsSubstitutionLifecycle,
             .openAPIMockLifecycle, .diagnosticRunLifecycle:
            return profileID == .shareable
        case .certificateCleanup:
            return profileID == .shareable
        default:
            return true
        }
    }

    /// Narrow Always-Allow / Always-Deny capability recipe for automation clients (AO Axis 2).
    private static func developerInspectionAllows(_ capability: MCPCapabilityID) -> Bool {
        switch capability {
        case .deviceInspect, .bookmarkInspect, .overrideInspect, .structuralDiscovery, .transformationPreview,
             .responseContext, .responseTextSearch, .responseDraftInspect, .hlsFixtureInspect,
             .openAPIMockInspect, .diagnosticRunInspect, .httpsRulesInspect,
             .certificateStatus, .certificateArtifactsList, .certificateCompare,
             .headerRead, .queryRead, .bodyRead:
            return true
        case .deviceAliasManage, .createDisabledMapLocal, .enableRule, .disableRule:
            return true
        case .hlsFixtureLifecycle, .hlsSubstitutionLifecycle, .scenarioLifecycle, .liveMediaProbe,
             .openAPIMockLifecycle, .diagnosticRunLifecycle:
            return true
        case .certificateCleanup, .runtimeControl, .createDisabledMapRemote, .activateMapRemote,
             .certificateIdentity, .certificateExport, .deleteRule:
            return false
        default:
            return false
        }
    }

    /// Hard precondition for tool dispatch: profile must allow and capability must not be always denied.
    func effectiveAllows(capability: MCPCapabilityID, client: MCPClientRecord, now: Date = Date()) -> Bool {
        if capability == .artifactSourceRelease { return true }
        guard profileAllows(capability: capability, profileID: client.assignedProfileID) else {
            return false
        }
        if grantStore.isAlwaysDenied(capability: capability, clientID: client.id) {
            return false
        }
        return true
    }

    /// When true, the router may skip minting a pending approval / one-use nonce for this capability.
    func skipsApprovalNonce(capability: MCPCapabilityID, client: MCPClientRecord, now: Date = Date()) -> Bool {
        guard effectiveAllows(capability: capability, client: client, now: now) else {
            return false
        }
        return grantStore.activeGrant(capability: capability, clientID: client.id, now: now) != nil
    }
}
