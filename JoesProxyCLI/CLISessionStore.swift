import Foundation

struct CLIPersistedSession: Codable, Equatable {
    var endpoint: String
    var sessionID: String
    var protocolVersion: String
    var updatedAt: Date
}

protocol CLISessionStoring {
    func load(endpoint: URL) throws -> CLIPersistedSession?
    func save(_ session: CLIPersistedSession) throws
    func delete(endpoint: URL) throws
}

struct CLIFileSessionStore: CLISessionStoring {
    private let fileManager: FileManager
    private let persistenceURL: URL

    init(fileManager: FileManager = .default, persistenceURL: URL? = nil) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultURL(fileManager: fileManager)
    }

    func load(endpoint: URL) throws -> CLIPersistedSession? {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return nil }
        let states = try JSONDecoder().decode([CLIPersistedSession].self, from: Data(contentsOf: persistenceURL))
        return states.first { $0.endpoint == endpoint.absoluteString }
    }

    func save(_ session: CLIPersistedSession) throws {
        var states = try loadAll()
        states.removeAll { $0.endpoint == session.endpoint }
        states.append(session)
        try persist(states)
    }

    func delete(endpoint: URL) throws {
        var states = try loadAll()
        states.removeAll { $0.endpoint == endpoint.absoluteString }
        try persist(states)
    }

    private func loadAll() throws -> [CLIPersistedSession] {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return [] }
        return try JSONDecoder().decode([CLIPersistedSession].self, from: Data(contentsOf: persistenceURL))
    }

    private func persist(_ states: [CLIPersistedSession]) throws {
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(states)
        try data.write(to: persistenceURL, options: .atomic)
    }

    private static func defaultURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("CLI", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }
}
