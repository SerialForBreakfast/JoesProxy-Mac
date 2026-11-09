//
//  MCPAutomationClientGrantRecipe.swift
//  JoesProxy
//
/// Standing-grant recipe for the Phase-1 ``developerInspection`` automation profile (AO Axis 2).
///
/// Seeds durable Always-Allow grants for the ADR narrow capability set and Always-Deny entries for
/// high-blast-radius tools. Reuses ``MCPClientGrantStore`` — no new grant schema.
///

import Foundation

/// Capability lists and apply helper for unattended automation clients.
enum MCPAutomationClientGrantRecipe {
    /// Capabilities that should skip interactive approval once durable grants are present.
    static let alwaysAllowCapabilities: [MCPCapabilityID] = [
        .bookmarkInspect,
        .overrideInspect,
        .structuralDiscovery,
        .transformationPreview,
        .responseContext,
        .responseTextSearch,
        .responseDraftInspect,
        .hlsFixtureInspect,
        .hlsFixtureLifecycle,
        .hlsSubstitutionLifecycle,
        .openAPIMockInspect,
        .openAPIMockLifecycle,
        .diagnosticRunInspect,
        .diagnosticRunLifecycle,
        .scenarioLifecycle,
        .liveMediaProbe,
        .createDisabledMapLocal,
        .enableRule,
        .disableRule,
        .headerRead,
        .queryRead,
        .bodyRead,
        .certificateStatus,
        .certificateArtifactsList,
        .certificateCompare
    ]

    /// Capabilities that remain blocked even if a mistaken durable grant is added later.
    static let alwaysDenyCapabilities: [MCPCapabilityID] = [
        .certificateCleanup,
        .runtimeControl,
        .createDisabledMapRemote,
        .activateMapRemote,
        .certificateIdentity,
        .deleteRule
    ]

    /// Applies durable grants and Always-Deny entries for one enrolled client.
    ///
    /// Concurrency: `@MainActor` — writes ``MCPClientGrantStore`` on the main actor.
    @MainActor
    @discardableResult
    static func apply(to grantStore: MCPClientGrantStore, clientID: String) throws -> (
        grants: [MCPClientCapabilityGrant],
        denials: [MCPClientCapabilityDenial]
    ) {
        var grants: [MCPClientCapabilityGrant] = []
        for capability in alwaysAllowCapabilities {
            let grant = try grantStore.addGrant(
                clientID: clientID,
                capability: capability,
                mode: .durablePolicy
            )
            grants.append(grant)
        }
        var denials: [MCPClientCapabilityDenial] = []
        for capability in alwaysDenyCapabilities {
            denials.append(grantStore.addDenial(clientID: clientID, capability: capability))
        }
        return (grants, denials)
    }
}
