import Foundation
@testable import JoesProxy

/// Builds an `MCPServerController` whose Application Support-backed stores all live under unique
/// temporary URLs. Automated tests must use this (or an equivalent temp registry) instead of the
/// controller's default stores, which write the live operator `mcp-clients.json`.
///
/// Concurrency: `@MainActor` — matches `MCPServerController` and the grant/policy stores.
@MainActor
enum MCPIsolatedControllerStack {
    struct Result {
        let controller: MCPServerController
        let clientRegistry: MCPClientRegistry
        let clientRegistryPersistenceURL: URL
        let credentialStore: MCPInMemoryCredentialStore
    }

    /// Isolated controller plus the temp client-registry URL for leak assertions.
    static func make(
        sessionStore: (any SessionStore)? = nil,
        port: UInt16 = UInt16.random(in: 20_000...60_000),
        userDefaults: UserDefaults = .standard
    ) throws -> Result {
        let credentialStore = MCPInMemoryCredentialStore()
        let clientsURL = temporaryURL(named: "mcp-clients.json")
        let clientRegistry = MCPClientRegistry(
            persistenceURL: clientsURL,
            credentialStore: credentialStore
        )
        try clientRegistry.load()

        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "mcp-policy.json"))
        policyStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "mcp-grants.json"))
        grantStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "mcp-audit.json"))
        auditStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(
            journalStore: MCPEffectJournalStore(persistenceURL: temporaryURL(named: "mcp-journal.json"))
        )

        let controller = MCPServerController(
            sessionStore: sessionStore ?? InMemorySessionStore(),
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            grantStore: grantStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "mcp-scenarios.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "mcp-drafts.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "mcp-fixture-runs.json")),
            userDefaults: userDefaults
        )
        return Result(
            controller: controller,
            clientRegistry: clientRegistry,
            clientRegistryPersistenceURL: clientsURL,
            credentialStore: credentialStore
        )
    }

    static func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}
