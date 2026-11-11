import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPClientRegistryTests: XCTestCase {
    func testEnrollmentAndAuthentication() throws {
        let store = MCPInMemoryCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients.json"),
            credentialStore: store
        )
        try registry.load()
        let enrollment = try registry.enroll(displayName: "Codex")
        let authenticated = try registry.authenticate(bearerToken: enrollment.plaintextCredential)
        XCTAssertEqual(authenticated.id, enrollment.client.id)
    }

    func testReturningCurrentVerifierRecoversEnrollmentWithoutRotation() throws {
        let store = MCPInMemoryCredentialStore()
        let url = temporaryURL(named: "recover.json")
        let registry = MCPClientRegistry(persistenceURL: url, credentialStore: store)
        try registry.load()
        let enrollment = try registry.enroll(displayName: "Synthetic CLI")
        let record = enrollment.client
        let verifier = try XCTUnwrap(store.loadVerifier(clientID: record.id, generation: record.credentialGeneration))
        try store.deleteVerifier(clientID: record.id, generation: record.credentialGeneration)
        try registry.load()
        XCTAssertEqual(registry.client(id: record.id)?.credentialState, .needsRotation)
        try store.saveVerifier(clientID: record.id, generation: record.credentialGeneration, verifier: verifier)
        XCTAssertThrowsError(try registry.authenticate(bearerToken: "incorrect"))
        XCTAssertEqual(try registry.authenticate(bearerToken: enrollment.plaintextCredential).id, record.id)
        try registry.load()
        XCTAssertEqual(try registry.authenticate(bearerToken: enrollment.plaintextCredential).credentialGeneration, record.credentialGeneration)
    }

    func testRevokedCredentialFails() throws {
        let store = MCPInMemoryCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-revoke.json"),
            credentialStore: store
        )
        try registry.load()
        let enrollment = try registry.enroll(displayName: "Claude")
        try registry.revoke(clientID: enrollment.client.id)
        XCTAssertThrowsError(try registry.authenticate(bearerToken: enrollment.plaintextCredential))
    }

    func testRotateCredentialRemovesPreviousGenerationFromStore() throws {
        let store = MCPInMemoryCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-rotate.json"),
            credentialStore: store
        )
        try registry.load()
        let enrollment = try registry.enroll(displayName: "RotateMe")
        let firstGeneration = enrollment.client.credentialGeneration
        let rotated = try registry.rotateCredential(clientID: enrollment.client.id)
        XCTAssertEqual(rotated.client.credentialGeneration, firstGeneration + 1)
        XCTAssertNil(try store.loadVerifier(clientID: enrollment.client.id, generation: firstGeneration))
        XCTAssertNotNil(try store.loadVerifier(clientID: enrollment.client.id, generation: rotated.client.credentialGeneration))
        _ = try registry.authenticate(bearerToken: rotated.plaintextCredential)
        XCTAssertThrowsError(try registry.authenticate(bearerToken: enrollment.plaintextCredential))
    }

    func testAuthenticationUsesLoadedVerifierIndexWithoutRepeatedStoreReads() throws {
        let store = MCPCountingCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-index.json"),
            credentialStore: store
        )
        try registry.load()
        let enrollment = try registry.enroll(displayName: "Indexed")

        _ = try registry.authenticate(bearerToken: enrollment.plaintextCredential)
        _ = try registry.authenticate(bearerToken: enrollment.plaintextCredential)

        XCTAssertEqual(store.loadCount, 0)
    }

    func testRemoveClientsDeletesSelectedRecordsOnly() throws {
        let store = MCPInMemoryCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-remove-batch.json"),
            credentialStore: store
        )
        try registry.load()
        let keep = try registry.enroll(displayName: "Keep")
        let removeA = try registry.enroll(displayName: "RemoveA")
        _ = try registry.enroll(displayName: "RemoveB")

        try registry.remove(clientIDs: [removeA.client.id, registry.clients.last!.id])

        XCTAssertEqual(registry.clients.count, 1)
        XCTAssertEqual(registry.clients.first?.id, keep.client.id)
        XCTAssertThrowsError(try registry.authenticate(bearerToken: removeA.plaintextCredential))
        _ = try registry.authenticate(bearerToken: keep.plaintextCredential)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}

private final class MCPCountingCredentialStore: MCPClientCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var verifiers: [String: Data] = [:]
    private(set) var loadCount = 0

    func saveVerifier(clientID: String, generation: Int, verifier: Data) throws {
        lock.withLock {
            verifiers["\(clientID)#\(generation)"] = verifier
        }
    }

    func loadVerifier(clientID: String, generation: Int) throws -> Data? {
        lock.withLock {
            loadCount += 1
            return verifiers["\(clientID)#\(generation)"]
        }
    }

    func deleteVerifier(clientID: String, generation: Int) throws {
        _ = lock.withLock {
            verifiers.removeValue(forKey: "\(clientID)#\(generation)")
        }
    }

    func deleteAllVerifiers(clientID: String) throws {
        lock.withLock {
            verifiers = verifiers.filter { !$0.key.hasPrefix("\(clientID)#") }
        }
    }
}
