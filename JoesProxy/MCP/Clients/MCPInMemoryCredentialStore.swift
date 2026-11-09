import Foundation

/// In-memory credential store for unit tests and preview builds.
final class MCPInMemoryCredentialStore: MCPClientCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var verifiers: [String: Data] = [:]

    func saveVerifier(clientID: String, generation: Int, verifier: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        verifiers[key(clientID: clientID, generation: generation)] = verifier
    }

    func loadVerifier(clientID: String, generation: Int) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return verifiers[key(clientID: clientID, generation: generation)]
    }

    func deleteVerifier(clientID: String, generation: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        verifiers.removeValue(forKey: key(clientID: clientID, generation: generation))
    }

    func deleteAllVerifiers(clientID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        verifiers = verifiers.filter { !$0.key.hasPrefix("\(clientID)#") }
    }

    private func key(clientID: String, generation: Int) -> String {
        "\(clientID)#\(generation)"
    }
}
