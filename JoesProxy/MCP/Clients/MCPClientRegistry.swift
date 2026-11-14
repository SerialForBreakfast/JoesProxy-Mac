import CryptoKit
import Foundation

enum MCPClientCredentialState: String, Equatable, Sendable, Codable {
    case active
    case needsRotation
    case revoked
}

/// Opaque MCP client enrollment record persisted in Application Support.
struct MCPClientRecord: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var displayName: String
    var assignedProfileID: MCPDisclosureProfileID
    var credentialState: MCPClientCredentialState
    var credentialGeneration: Int
    var createdAt: Date
    var lastSeenAt: Date?
    /// Optional for backward-compatible decoding of records written before toolsets existed.
    /// A missing value preserves the former complete-catalog behavior.
    var preferredToolset: MCPToolset? = nil

    var effectiveToolset: MCPToolset { preferredToolset ?? .all }
}

/// Keychain-backed bearer verifier storage keyed by client ID and generation.
protocol MCPClientCredentialStoring: Sendable {
    func saveVerifier(clientID: String, generation: Int, verifier: Data) throws
    func loadVerifier(clientID: String, generation: Int) throws -> Data?
    func deleteVerifier(clientID: String, generation: Int) throws
    func deleteAllVerifiers(clientID: String) throws
}

/// Application Support JSON persistence for MCP client records.
@MainActor
final class MCPClientRegistry {
    static let persistenceFileName = "mcp-clients.json"
    static let persistenceSchemaVersion = 1

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var clients: [MCPClientRecord]
    }

    struct EnrollmentResult: Equatable, Sendable {
        var client: MCPClientRecord
        /// One-time plaintext bearer shown only during enrollment.
        var plaintextCredential: String
    }

    private(set) var clients: [MCPClientRecord] = []
    /// On-disk registry location. Tests compare this against ``defaultPersistenceURL`` so isolated
    /// stacks never bind the live Application Support file.
    let persistenceURL: URL
    private let credentialStore: any MCPClientCredentialStoring
    private let fileManager: FileManager
    private var clientIDByVerifier: [Data: String] = [:]
    private var nextVerifierRefresh = ContinuousClock.now
    private var lastSeenPersistenceTask: Task<Void, Never>?

    init(
        persistenceURL: URL? = nil,
        credentialStore: any MCPClientCredentialStoring,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.credentialStore = credentialStore
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    func load() throws {
        guard fileManager.fileExists(atPath: persistenceURL.path) else {
            clients = []
            clientIDByVerifier = [:]
            try persist()
            return
        }
        let data = try Data(contentsOf: persistenceURL)
        let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
        guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
            throw MCPClientRegistryError.unsupportedSchema
        }
        clients = persisted.clients
        try reconcileKeychainVerifiers()
    }

    func client(id: String) -> MCPClientRecord? {
        clients.first { $0.id == id }
    }

    /// Enrolls a client, persists intent, writes Keychain verifier, and returns one-time credential.
    func enroll(
        displayName: String,
        assignedProfileID: MCPDisclosureProfileID = .metadataOnly
    ) throws -> EnrollmentResult {
        let clientID = UUID().uuidString
        let generation = 1
        let credential = Self.generateCredential()
        let verifier = Self.verifier(for: credential)

        let record = MCPClientRecord(
            id: clientID,
            displayName: displayName,
            assignedProfileID: assignedProfileID,
            credentialState: .active,
            credentialGeneration: generation,
            createdAt: Date(),
            lastSeenAt: nil
        )
        clients.append(record)
        try persist()
        try credentialStore.saveVerifier(clientID: clientID, generation: generation, verifier: verifier)
        clientIDByVerifier[verifier] = clientID
        return EnrollmentResult(client: record, plaintextCredential: credential)
    }

    func rotateCredential(clientID: String) throws -> EnrollmentResult {
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else {
            throw MCPClientRegistryError.clientNotFound
        }
        let nextGeneration = clients[index].credentialGeneration + 1
        let credential = Self.generateCredential()
        let verifier = Self.verifier(for: credential)
        clients[index].credentialGeneration = nextGeneration
        clients[index].credentialState = .active
        try persist()
        try credentialStore.saveVerifier(clientID: clientID, generation: nextGeneration, verifier: verifier)
        try credentialStore.deleteVerifier(clientID: clientID, generation: nextGeneration - 1)
        clientIDByVerifier = clientIDByVerifier.filter { $0.value != clientID }
        clientIDByVerifier[verifier] = clientID
        return EnrollmentResult(client: clients[index], plaintextCredential: credential)
    }

    func setPreferredToolset(clientID: String, toolset: MCPToolset) throws -> MCPClientRecord {
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else {
            throw MCPClientRegistryError.clientNotFound
        }
        clients[index].preferredToolset = toolset
        try persist()
        return clients[index]
    }

    func revoke(clientID: String) throws {
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else {
            throw MCPClientRegistryError.clientNotFound
        }
        clients[index].credentialState = .revoked
        try persist()
        try credentialStore.deleteAllVerifiers(clientID: clientID)
        clientIDByVerifier = clientIDByVerifier.filter { $0.value != clientID }
    }

    /// Revokes every enrolled client in one persistence write (AH-7 batch revoke).
    ///
    /// Persists the revoked state first, matching ``revoke(clientID:)``'s ordering — so a Keychain
    /// failure while clearing verifiers below leaves disk state correctly showing every client
    /// revoked (fail toward "revoked but cleanup incomplete", never the reverse). Keychain cleanup
    /// is then best-effort per client: one client's deletion failure must not abort the batch, leave
    /// `clientIDByVerifier` half-cleared, or prevent the caller from recording that revocation
    /// happened at all.
    func revokeAll() throws {
        guard !clients.isEmpty else { return }
        for index in clients.indices {
            clients[index].credentialState = .revoked
        }
        try persist()
        clientIDByVerifier.removeAll()
        for client in clients {
            try? credentialStore.deleteAllVerifiers(clientID: client.id)
        }
    }

    /// Removes enrolled client records from persistence (UI batch cleanup; distinct from revoke).
    ///
    /// Active clients are removed without a separate revoke step — callers must invalidate MCP
    /// sessions and clear grants first. Keychain verifier deletion is best-effort per client.
    func remove(clientIDs: Set<String>) throws {
        guard !clientIDs.isEmpty else { return }
        clients.removeAll { clientIDs.contains($0.id) }
        clientIDByVerifier = clientIDByVerifier.filter { !clientIDs.contains($0.value) }
        try persist()
        for clientID in clientIDs {
            try? credentialStore.deleteAllVerifiers(clientID: clientID)
        }
    }

    /// Verifies bearer credential and returns authenticated client on success.
    ///
    /// Compares against every loaded verifier with ``MCPConstantTimeCompare`` rather than doing a
    /// `Dictionary` lookup on the raw digest — `Data`'s default `==`/`Hashable` short-circuits on
    /// the first differing byte, which would leak timing information about a client's verifier.
    /// Client counts here are small (an operator's own enrolled MCP tools), so the O(n) scan this
    /// requires is negligible.
    func authenticate(bearerToken: String) throws -> MCPClientRecord {
        let digest = Self.verifier(for: bearerToken)
        if clients.contains(where: { $0.credentialState == .needsRotation }), ContinuousClock.now >= nextVerifierRefresh {
            nextVerifierRefresh = .now.advanced(by: .seconds(30))
            for index in clients.indices where clients[index].credentialState == .needsRotation {
                let record = clients[index]
                guard let verifier = try? credentialStore.loadVerifier(clientID: record.id, generation: record.credentialGeneration) else { continue }
                clients[index].credentialState = .active
                clientIDByVerifier[verifier] = record.id
                scheduleLastSeenPersistence()
            }
        }
        guard let clientID = clientIDByVerifier.first(where: { MCPConstantTimeCompare.equal($0.key, digest) })?.value,
              let index = clients.firstIndex(where: { $0.id == clientID }),
              clients[index].credentialState == .active else {
            throw MCPClientRegistryError.invalidCredential
        }
        clients[index].lastSeenAt = Date()
        scheduleLastSeenPersistence()
        return clients[index]
    }

    /// Removes orphan Keychain verifiers and marks clients missing verifiers for rotation.
    func reconcileKeychainVerifiers() throws {
        clientIDByVerifier = [:]
        for index in clients.indices {
            let record = clients[index]
            if record.credentialState == .revoked {
                try credentialStore.deleteAllVerifiers(clientID: record.id)
                continue
            }
            let verifier = try credentialStore.loadVerifier(
                clientID: record.id,
                generation: record.credentialGeneration
            )
            if verifier == nil {
                clients[index].credentialState = .needsRotation
            } else if let verifier {
                clients[index].credentialState = .active
                clientIDByVerifier[verifier] = record.id
            }
        }
        try persist()
    }

    /// `lastSeenAt` is diagnostic metadata, so frequent authenticated calls coalesce their disk
    /// update instead of synchronously rewriting the complete registry on the UI actor.
    private func scheduleLastSeenPersistence() {
        guard lastSeenPersistenceTask == nil else { return }
        lastSeenPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lastSeenPersistenceTask = nil
            try? self.persist()
        }
    }

    private func persist() throws {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, clients: clients)
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    static func generateCredential() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }

    static func verifier(for credential: String) -> Data {
        SHA256.hash(data: Data(credential.utf8)).data
    }

    /// Live operator path (`Application Support/JoesProxy/mcp-clients.json`). Automated tests must
    /// pass a temporary `persistenceURL` instead of relying on this default.
    static func defaultPersistenceURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName, isDirectory: false)
    }
}

enum MCPClientRegistryError: Error, Equatable, Sendable {
    case unsupportedSchema
    case clientNotFound
    case invalidCredential
}

private extension SHA256.Digest {
    var data: Data { Data(self) }
}
