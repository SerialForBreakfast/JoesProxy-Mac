import Foundation

/// Persisted metadata for one active or recently-stopped HLS fixture run.
///
/// Live ``HLSFixtureServer`` instances are held only in memory by ``HLSFixtureRunStore`` — never
/// encoded into this record.
struct HLSFixtureRunRecord: Equatable, Sendable, Codable, Identifiable {
    /// Opaque run identifier (also embedded in the reserved virtual-origin hostname).
    var id: UUID
    /// Owning MCP client ID.
    var clientID: String
    /// Bundled profile directory name (e.g. `baseline-aligned-codecs`).
    var profileID: String
    /// Profile content version string from catalog metadata when known.
    var profileVersion: String
    /// Optional for schema-v1 decode compatibility. Records written before HF-1 omit this field
    /// and therefore retain the original legacy sliding-live behavior.
    var playbackConfiguration: HLSPlaybackConfiguration?
    /// Reserved host served by the proxy, e.g. `fixture-<uuid>.hls.joesproxy.invalid`.
    var reservedHost: String
    var startedAt: Date
    var expiresAt: Date
    /// When the run was stopped; `nil` while active.
    var stoppedAt: Date?
    /// True while the reserved origin is registered and serving.
    var isActive: Bool
}

/// Failures from ``HLSFixtureRunStore`` load/mutate operations.
enum HLSFixtureRunStoreError: Error, Equatable, Sendable {
    case notLoaded
    case corruptPersistence
    case runNotFound
    case notOwner
    case quotaExceeded(String)
    case profileNotFound(String)
    case alreadyStopped
    case registryUnavailable
}

/// JSON-backed, quota-bound repository for HLS fixture runs plus in-memory live servers.
///
/// Concurrency: `@MainActor` — wired beside other MCP persistence stores; registry register/
/// unregister hops to the ``HLSFixtureOriginRegistry`` actor.
@MainActor
final class HLSFixtureRunStore {
    static let persistenceFileName = "hls-fixture-run-store.json"
    static let persistenceSchemaVersion = 1
    /// Max concurrently active runs per MCP client.
    static let maxActiveRunsPerClient = 2
    /// Hard maximum wall-clock duration for one run before forced stop. The default when a caller
    /// doesn't request a longer `duration` explicitly (`startRun`'s `duration` parameter) — plain
    /// `hls_fixture_start` runs never pass one and so stay capped here unconditionally.
    static let maxRunDuration: TimeInterval = 30 * 60
    /// How long stopped run metadata is retained for status/audit.
    static let terminalRetention: TimeInterval = 10 * 60
    static let reservedHostSuffix = ".hls.joesproxy.invalid"
    static let routingModeReservedVirtualOrigin = "reservedVirtualOrigin"

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var runs: [HLSFixtureRunRecord]
    }

    private(set) var runs: [HLSFixtureRunRecord] = []
    private(set) var isLoaded = false
    private(set) var loadFailureReason: String?

    private let persistenceURL: URL
    private let fileManager: FileManager
    private let profileRootURL: URL
    private let originRegistry: HLSFixtureOriginRegistry?
    private var liveServersByRunID: [UUID: HLSFixtureServer] = [:]
    private let clock: () -> Date

    /// - Parameters:
    ///   - persistenceURL: Override for tests; default Application Support path.
    ///   - profileRootURL: Directory containing profile folders (`Fixtures/HLS`).
    ///   - originRegistry: Shared proxy registry; `nil` only for persistence-unit tests.
    ///   - clock: Injected clock for expiry/tests.
    init(
        persistenceURL: URL? = nil,
        profileRootURL: URL? = nil,
        originRegistry: HLSFixtureOriginRegistry? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        self.profileRootURL = profileRootURL ?? Self.resolveDefaultProfileRoot(fileManager: fileManager)
        self.originRegistry = originRegistry
        self.clock = clock
    }

    /// Root directory that should contain one subdirectory per profile ID.
    var profilesRoot: URL { profileRootURL }

    func load() {
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported HLS fixture-run store schema version.")
                    return
                }
                // Live servers never survive process restart — mark previously-active runs stopped.
                let now = clock()
                runs = persisted.runs.map { run in
                    var copy = run
                    if copy.isActive {
                        copy.isActive = false
                        copy.stoppedAt = now
                    }
                    return copy
                }
            } else {
                runs = []
            }
            isLoaded = true
            loadFailureReason = nil
            pruneTerminal(now: clock())
        } catch {
            failClosed(reason: "HLS fixture-run store failed to load.")
        }
    }

    func persist() throws {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, runs: runs)
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func run(id: UUID) -> HLSFixtureRunRecord? {
        runs.first(where: { $0.id == id })
    }

    /// In-memory live server for an active run, if this process still owns it.
    func liveServer(id: UUID) -> HLSFixtureServer? {
        liveServersByRunID[id]
    }

    func activeRuns(ownedBy clientID: String) -> [HLSFixtureRunRecord] {
        runs.filter { $0.clientID == clientID && $0.isActive }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func runs(ownedBy clientID: String) -> [HLSFixtureRunRecord] {
        runs.filter { $0.clientID == clientID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Active run IDs for cleanup status (`active_fixture_runs`).
    func unresolvedRunIDs(forClientID clientID: String) -> [String] {
        activeRuns(ownedBy: clientID).map(\.id.uuidString)
    }

    var unresolvedRunCount: Int {
        runs.filter(\.isActive).count
    }

    /// Lists bundled profile directories that exist on disk under ``profilesRoot``.
    func availableProfiles() -> [(id: String, version: String, path: URL)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: profileRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.compactMap { url -> (id: String, version: String, path: URL)? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: url.appendingPathComponent("master.m3u8").path) else {
                return nil
            }
            let version = Self.profileVersion(at: url) ?? "1"
            return (id: url.lastPathComponent, version: version, path: url)
        }
        .sorted { $0.id < $1.id }
    }

    /// Rich catalog used by the guided UI and composite MCP workflow. Legacy fixture directories
    /// without `profile.json` remain discoverable through a deterministic fallback descriptor.
    func availableProfileDescriptors() -> [HLSFixtureProfileDescriptor] {
        availableProfiles()
            .map { HLSFixtureProfileDescriptor.load(from: $0.path) }
            .sorted {
                if $0.isRecommended != $1.isRecommended { return $0.isRecommended }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    func profileDirectory(forProfileID profileID: String) throws -> URL {
        let sanitized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty,
              !sanitized.contains("/"),
              !sanitized.contains("..") else {
            throw HLSFixtureRunStoreError.profileNotFound(profileID)
        }
        let directory = profileRootURL.appendingPathComponent(sanitized, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("master.m3u8").path) else {
            throw HLSFixtureRunStoreError.profileNotFound(profileID)
        }
        return directory
    }

    func validateProfileConfiguration(profileID: String, configuration: HLSPlaybackConfiguration) throws {
        let descriptor = HLSFixtureProfileDescriptor.load(from: try profileDirectory(forProfileID: profileID))
        if descriptor.textFixture != nil { try HLSWebVTTFixture.validateConfiguration(configuration) }
    }

    /// Starts a run: constructs a server, registers the reserved host, persists metadata.
    @discardableResult
    func startRun(
        id: UUID = UUID(),
        clientID: String,
        profileID: String,
        profileDirectoryOverride: URL? = nil,
        playbackConfiguration: HLSPlaybackConfiguration = .legacyCompatible,
        permitsDirectAccess: Bool = true,
        duration: TimeInterval? = nil,
        now: Date? = nil
    ) async throws -> HLSFixtureRunRecord {
        try requireLoaded()
        let startedAt = now ?? clock()
        try await expireOverdueRuns(now: startedAt)
        let activeOwned = activeRuns(ownedBy: clientID)
        guard activeOwned.count < Self.maxActiveRunsPerClient else {
            throw HLSFixtureRunStoreError.quotaExceeded(
                "Client already has \(Self.maxActiveRunsPerClient) active fixture runs."
            )
        }
        let profileDirectory: URL
        if let profileDirectoryOverride {
            let values = try profileDirectoryOverride.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  fileManager.fileExists(
                    atPath: profileDirectoryOverride.appendingPathComponent("master.m3u8").path
                  ) else {
                throw HLSFixtureRunStoreError.profileNotFound(profileID)
            }
            profileDirectory = profileDirectoryOverride
        } else {
            profileDirectory = try self.profileDirectory(forProfileID: profileID)
        }
        let profileVersion = Self.profileVersion(at: profileDirectory) ?? "1"
        guard let registry = originRegistry else {
            throw HLSFixtureRunStoreError.registryUnavailable
        }
        let reservedHost = Self.reservedHost(for: id)
        let server = try await HLSFixtureServer.make(
            profileDirectory: profileDirectory,
            startedAt: startedAt,
            playbackConfiguration: playbackConfiguration,
            clock: clock
        )
        await registry.register(host: reservedHost, runID: id, server: server, permitsDirectAccess: permitsDirectAccess)
        liveServersByRunID[id] = server
        let record = HLSFixtureRunRecord(
            id: id,
            clientID: clientID,
            profileID: profileID,
            profileVersion: profileVersion,
            playbackConfiguration: playbackConfiguration,
            reservedHost: reservedHost,
            startedAt: startedAt,
            expiresAt: startedAt.addingTimeInterval(duration ?? Self.maxRunDuration),
            stoppedAt: nil,
            isActive: true
        )
        runs.append(record)
        do {
            try persist()
        } catch {
            runs.removeLast()
            liveServersByRunID.removeValue(forKey: id)
            await registry.unregister(host: reservedHost, runID: id)
            throw error
        }
        return record
    }

    /// Stops an owned active run and unregisters its reserved origin.
    @discardableResult
    func stopRun(id: UUID, clientID: String, now: Date? = nil) async throws -> HLSFixtureRunRecord {
        try requireLoaded()
        let stoppedAt = now ?? clock()
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            throw HLSFixtureRunStoreError.runNotFound
        }
        guard runs[index].clientID == clientID else {
            throw HLSFixtureRunStoreError.notOwner
        }
        guard runs[index].isActive else {
            throw HLSFixtureRunStoreError.alreadyStopped
        }
        await tearDownLiveServer(runID: id, host: runs[index].reservedHost)
        runs[index].isActive = false
        runs[index].stoppedAt = stoppedAt
        try persist()
        // Capture the value before pruning: `pruneTerminal` can remove OTHER terminal entries
        // positioned earlier in `runs` (their own `terminalRetention` window can elapse during
        // this very run's lifetime, independent of this stop), which shifts or shrinks the array
        // and invalidates `index` captured above. Re-indexing with the stale `index` afterward
        // crashed live with an out-of-range fatal error — see HLSFixtureRunStoreTests
        // .testStopRunSurvivesPruningOfEarlierStaleEntry.
        let stoppedRecord = runs[index]
        pruneTerminal(now: stoppedAt)
        return stoppedRecord
    }

    /// Bumps an active run's `expiresAt` forward. Must stay in lockstep with any owning
    /// substitution experiment's own `expiresAt` (see `HLSSubstitutionCoordinator.extend`) — this
    /// run record is what `expireOverdueRuns` actually tears down; extending only the experiment's
    /// copy without this would let the underlying run (and its live server/reserved host) expire out
    /// from under an experiment that still believes itself active.
    @discardableResult
    func extendRun(id: UUID, clientID: String, expiresAt: Date) throws -> HLSFixtureRunRecord {
        try requireLoaded()
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            throw HLSFixtureRunStoreError.runNotFound
        }
        guard runs[index].clientID == clientID else {
            throw HLSFixtureRunStoreError.notOwner
        }
        guard runs[index].isActive else {
            throw HLSFixtureRunStoreError.alreadyStopped
        }
        runs[index].expiresAt = expiresAt
        try persist()
        return runs[index]
    }

    /// Stops every active run owned by `clientID` (session teardown / cleanup).
    func stopAll(ownedBy clientID: String, now: Date? = nil) async throws {
        try requireLoaded()
        let stoppedAt = now ?? clock()
        let activeIDs = activeRuns(ownedBy: clientID).map(\.id)
        for id in activeIDs {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
            await tearDownLiveServer(runID: id, host: runs[index].reservedHost)
            runs[index].isActive = false
            runs[index].stoppedAt = stoppedAt
        }
        if !activeIDs.isEmpty {
            try persist()
        }
        pruneTerminal(now: stoppedAt)
    }

    /// Stops every active run regardless of owner (global Return To Normal).
    func stopAllActiveRuns(now: Date? = nil) async {
        guard isLoaded else { return }
        let stoppedAt = now ?? clock()
        let activeIDs = runs.filter(\.isActive).map(\.id)
        for id in activeIDs {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
            await tearDownLiveServer(runID: id, host: runs[index].reservedHost)
            runs[index].isActive = false
            runs[index].stoppedAt = stoppedAt
        }
        if !activeIDs.isEmpty {
            try? persist()
        }
        pruneTerminal(now: stoppedAt)
    }

    /// Forces expiry stop for any active run past ``expiresAt``.
    func expireOverdueRuns(now: Date? = nil) async throws {
        try requireLoaded()
        let moment = now ?? clock()
        let overdue = runs.filter { $0.isActive && moment >= $0.expiresAt }
        for run in overdue {
            if let index = runs.firstIndex(where: { $0.id == run.id }) {
                await tearDownLiveServer(runID: run.id, host: run.reservedHost)
                runs[index].isActive = false
                runs[index].stoppedAt = moment
            }
        }
        if !overdue.isEmpty {
            try persist()
        }
        pruneTerminal(now: moment)
    }

    static func reservedHost(for runID: UUID) -> String {
        "fixture-\(runID.uuidString.lowercased())\(reservedHostSuffix)"
    }

    static func resolveDefaultProfileRoot(fileManager: FileManager = .default) -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/HLS", isDirectory: true),
           fileManager.fileExists(atPath: resource.path) {
            return resource
        }
        var url = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("Fixtures/HLS", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("Fixtures/HLS", isDirectory: true)
    }

    private static func profileVersion(at directory: URL) -> String? {
        let hashes = directory.appendingPathComponent("expected-hashes.json")
        guard let data = try? Data(contentsOf: hashes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let version = object["version"] as? String { return version }
        if let version = object["profileVersion"] as? String { return version }
        return nil
    }

    private func tearDownLiveServer(runID: UUID, host: String) async {
        if let server = liveServersByRunID.removeValue(forKey: runID) {
            await server.stop()
        }
        await originRegistry?.unregister(host: host, runID: runID)
    }

    private func pruneTerminal(now: Date) {
        runs.removeAll { run in
            guard let stoppedAt = run.stoppedAt, !run.isActive else { return false }
            return now.timeIntervalSince(stoppedAt) > Self.terminalRetention
        }
    }

    private func requireLoaded() throws {
        guard isLoaded else {
            throw HLSFixtureRunStoreError.notLoaded
        }
    }

    private func failClosed(reason: String) {
        runs = []
        liveServersByRunID = [:]
        isLoaded = false
        loadFailureReason = reason
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }
}
