//
//  MCPSyntheticInjectionService.swift
//  JoesProxy
//
//  MCP tool endpoints for schema-inferred collection injection and synthetic asset binding.
//

import Foundation

@MainActor
final class MCPSyntheticInjectionService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - List Synthetic Assets

    func listSyntheticAssets(policyRevision: MCPPolicyRevision) throws -> MCPListSyntheticAssetsResponseDTO {
        let assets = SyntheticAssetCatalog.availableAssets()
        let dtos = assets.map { a in
            MCPSyntheticAssetDescriptorDTO(
                id: a.id,
                kind: a.kind.rawValue,
                displayName: a.displayName,
                description: a.description,
                localURL: a.localURL,
                contentType: a.contentType,
                isDRMFree: a.isDRMFree
            )
        }

        return MCPListSyntheticAssetsResponseDTO(
            assets: dtos,
            defaultProxyPort: SyntheticAssetCatalog.defaultProxyPort,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Inject Synthetic Item in Collection

    func injectSyntheticItemInCollection(
        name: String,
        urlPattern: String,
        collectionKeypath: String = "$",
        position: String = "prepend",
        boundAssetKind: String? = "clearLiveHLS",
        customAssetURL: String? = nil,
        fieldOverrides: [String: String] = [:],
        clientScope: String = "simulatorOnly",
        policyRevision: MCPPolicyRevision
    ) throws -> MCPInjectSyntheticItemResultDTO {
        let pos: CollectionInjectionPosition
        let cleanPos = position.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPos.contains("append") {
            pos = .append
        } else if cleanPos.contains("replace") {
            pos = .replaceIndex(0)
        } else {
            pos = .prepend
        }

        let scope: ClientScope
        let cleanScope = clientScope.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanScope.contains("all") {
            scope = .allClients
        } else {
            scope = .simulatorOnly
        }

        let kind: SyntheticAssetKind?
        if let bk = boundAssetKind {
            let cleanKind = bk.lowercased()
            if cleanKind.contains("vod") {
                kind = .clearVODHLS
            } else if cleanKind.contains("image") || cleanKind.contains("pattern") {
                kind = .testPatternImage
            } else if cleanKind.contains("vast") || cleanKind.contains("ad") {
                kind = .syntheticVASTAd
            } else {
                kind = .clearLiveHLS
            }
        } else {
            kind = nil
        }

        let plan = SyntheticCollectionInjectionPlan(
            name: name,
            urlPattern: urlPattern,
            collectionKeypath: collectionKeypath,
            position: pos,
            boundAssetKind: kind,
            customAssetURL: customAssetURL,
            fieldOverrides: fieldOverrides,
            clientScope: scope,
            isEnabled: true
        )

        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)

        let resolvedAssetURL = customAssetURL ?? (kind != nil ? SyntheticAssetCatalog.availableAssets().first(where: { $0.kind == kind! })?.localURL : nil)

        return MCPInjectSyntheticItemResultDTO(
            planID: plan.id.uuidString,
            status: "Active schema-inferred collection injection plan armed",
            urlPattern: plan.urlPattern,
            collectionKeypath: plan.collectionKeypath,
            position: plan.position.title,
            boundAssetURL: resolvedAssetURL,
            clientScope: plan.clientScope.title,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - List / Remove Injection Plans

    /// Lists currently armed injection plans. The engine is in-memory only (no persistence), so
    /// this list — and every plan on it — is cleared automatically when the app quits or restarts.
    func listInjectionPlans(policyRevision: MCPPolicyRevision) -> MCPListSyntheticInjectionPlansResponseDTO {
        let dtos = SyntheticCollectionInjectionEngine.shared.allPlans().map { plan in
            MCPSyntheticInjectionPlanDTO(
                id: plan.id.uuidString,
                name: plan.name,
                urlPattern: plan.urlPattern,
                collectionKeypath: plan.collectionKeypath,
                position: plan.position.title,
                boundAssetKind: plan.boundAssetKind?.rawValue,
                customAssetURL: plan.customAssetURL,
                fieldOverrides: plan.fieldOverrides,
                clientScope: plan.clientScope.title,
                isEnabled: plan.isEnabled,
                diagnostics: SyntheticCollectionInjectionEngine.shared.diagnostics(planID: plan.id)
            )
        }
        return MCPListSyntheticInjectionPlansResponseDTO(plans: dtos, disclosure: makeDisclosure(policyRevision: policyRevision))
    }

    /// Permanently removes one armed injection plan. Matching traffic is unaffected from the next
    /// request onward — there is no separate "disable" state to reason about.
    func removeInjectionPlan(planID: UUID) -> Bool {
        let existed = SyntheticCollectionInjectionEngine.shared.allPlans().contains { $0.id == planID }
        SyntheticCollectionInjectionEngine.shared.removePlan(id: planID)
        return existed
    }

    // MARK: - Helpers

    private func makeDisclosure(policyRevision: MCPPolicyRevision) -> MCPMediaDisclosureContextDTO {
        MCPMediaDisclosureContextDTO(
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyRevision,
            generatedAt: Date(),
            removedFields: [],
            partialResultReason: nil,
            truncated: false
        )
    }
}
