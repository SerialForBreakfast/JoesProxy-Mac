import Foundation

enum ArtifactSourceUITestFixture {
    @MainActor static func fileCoordinator() -> ArtifactSourceFileCoordinator {
        guard UITestLaunchConfiguration.current != nil,
              ProcessInfo.processInfo.arguments.contains("--ui-artifact-review") else { return ArtifactSourceFileCoordinator() }
        let fixture = #"""
        {"log":{"entries":[{"startedDateTime":"2026-11-07T00:00:00Z","time":1,
        "request":{"method":"GET","url":"https://example.invalid/items"},
        "response":{"status":200,"content":{"size":2,"mimeType":"application/json","text":"[]"}}}]}}
        """#
        return ArtifactSourceFileCoordinator(syntheticSelection: Data(fixture.utf8))
    }

    @MainActor static func seed(controller: MCPServerController) -> Bool {
        guard UITestLaunchConfiguration.current != nil,
              ProcessInfo.processInfo.arguments.contains("--ui-artifact-review"),
              let registry = controller.artifactSources else { return false }
        let owner = ArtifactSourceRegistry.Owner(clientID: "synthetic-artifact-review", generation: 1,
            policyRevision: controller.policyStore.policyRevision, profile: .shareable)
        let previousOwner = registry.currentOwner
        let previousBrief = registry.currentBriefPermission
        registry.currentBriefPermission = { $0 == owner.clientID ? true : previousBrief?($0) ?? false }
        let previousSearch = registry.currentSearchPermission
        registry.currentSearchPermission = { $0 == owner.clientID ? true : previousSearch?($0) ?? false }
        let previousPermission = registry.currentCalculationPermission
        registry.currentOwner = { $0 == owner.clientID ? owner : previousOwner?($0) }
        registry.currentCalculationPermission = { $0 == owner.clientID ? true : previousPermission?($0) ?? false }
        if ProcessInfo.processInfo.arguments.contains("--ui-artifact-pair") {
            let previousCompare = registry.currentComparePermission
            registry.currentComparePermission = { $0 == owner.clientID ? true : previousCompare?($0) ?? false }
            Task { try await seedPair(registry, owner: owner) }
            return true
        }
        _ = try? registry.register(key: "00000000-0000-4000-8000-000000000005", kind: .har,
            scopes: ["metadata-v1", "calculations-v1", "search-v1", "brief-v1"], ttl: 1800, owner: owner,
            argumentDigest: "synthetic-artifact-review-only", sessionID: nil)
        return true
    }

    @MainActor private static func seedPair(_ registry: ArtifactSourceRegistry, owner: ArtifactSourceRegistry.Owner) async throws {
        let key = UUID().uuidString
        let request = try registry.register(key: key, kind: .har, scopes: ["metadata-v1", "brief-v1"], ttl: 1800,
            owner: owner, argumentDigest: key, sessionID: nil)
        let entry: [String: Any] = ["startedDateTime": "2026-11-07T00:00:00Z", "time": 0,
            "request": ["method": "GET", "url": "https://example.invalid/items"],
            "response": ["status": 200, "content": ["mimeType": "application/json", "text": "{\"items\":[]}", "size": 12]]]
        let data = try JSONSerialization.data(withJSONObject: ["log": ["entries": [entry, entry]]])
        registry.prepare(id: request.id, selection: .synthetic(data))
        await registry.waitForPreparation(id: request.id)
        try registry.share(id: request.id)
        let ready = try registry.publish(id: request.id, owner: owner)
        guard let handle = ready.handle, let revision = ready.revision else { return }
        func side(_ index: Int) -> [String: Any] { ["handle": handle, "snapshotRevision": revision, "recordIndex": index] }
        let pair = try SavedResponsePair(["baseline": side(0), "candidate": side(1), "selectionPointer": "/items"])
        _ = try registry.admitPair(pair, owner: owner, session: key, clientName: "Synthetic review client", baseline: ready, candidate: ready)
    }
}
