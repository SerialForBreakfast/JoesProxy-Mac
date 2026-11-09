import Foundation

/// Field classes governed by MCP disclosure profiles (ADR Phase 1 matrix).
enum MCPPolicyFieldClass: String, Equatable, Sendable, Codable, CaseIterable {
    case sessionSequence
    case sessionOpaqueID
    case timestamps
    case duration
    case method
    case statusCode
    case mediaCategory
    case hostCategory
    case sanitizedHost
    case sanitizedPath
    case safeHeaders
    case parserSummaries
    case queryNamesOnly
    case bodyAvailabilityFlags
    /// Which MCP client/operation stamped attribution onto this response (AH-0 provenance).
    case provenance
    /// Post-approval sensitive-read tiers (not profile-assigned; gated by ``MCPApprovalStore``).
    case approvedHeaderValues
    case approvedQueryParameters
    case approvedBodyExcerpt
    /// Scenario observation evidence summaries in test reports (AI-3).
    case scenarioEvidence
    /// Assertion evaluation outcomes in test reports (AI-3).
    case scenarioAssertionResults
}

/// Built-in disclosure profile identifiers.
enum MCPDisclosureProfileID: String, Equatable, Sendable, Codable, CaseIterable {
    case metadataOnly = "metadata_only"
    case shareable
    /// Phase 2 stub — not selectable in Phase 1 UI or client assignment.
    case developerInspection = "developer_inspection"
    case fullLocalInspection = "full_local_inspection"
    case custom
}

/// Immutable disclosure profile document keyed by profile ID and revision.
struct MCPDisclosureProfileDocument: Equatable, Sendable, Codable {
    var id: MCPDisclosureProfileID
    var revision: Int
    var title: String
    var allowedFieldClasses: Set<MCPPolicyFieldClass>
    /// Phase 1 profiles are assignable; Phase 2 stubs exist for forward compatibility only.
    var isSelectableInPhase1: Bool
}

enum MCPPolicyStoreError: Error, Equatable, Sendable {
    case corruptPersistence
    case unknownProfile(MCPDisclosureProfileID)
    case profileNotSelectable(MCPDisclosureProfileID)
    case fieldClassNotAllowed(MCPPolicyFieldClass, MCPDisclosureProfileID)
}

/// Versioned policy store with built-in profiles and monotonic revision fingerprints.
///
/// Concurrency: isolated on `@MainActor` because it is wired from ``AppCoordinator`` and the
/// management panel; transport handlers receive snapshots at request boundaries.
@MainActor
final class MCPPolicyStore {
    static let persistenceFileName = "mcp-policy-store.json"
    static let persistenceSchemaVersion = 1

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var policyRevision: MCPPolicyRevision
        var defaultProfileID: MCPDisclosureProfileID
    }

    private(set) var policyRevision: MCPPolicyRevision
    private(set) var isLoaded: Bool
    private(set) var loadFailureReason: String?
    private let profilesByID: [MCPDisclosureProfileID: MCPDisclosureProfileDocument]
    private let persistenceURL: URL
    private let fileManager: FileManager

    init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        self.profilesByID = Self.builtInProfiles()
        self.policyRevision = .initial
        self.isLoaded = false
        self.loadFailureReason = nil
    }

    /// Loads persisted revision state or initializes defaults. Corrupt files fail closed.
    func load() {
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported policy schema version.")
                    return
                }
                guard profilesByID[persisted.defaultProfileID] != nil else {
                    failClosed(reason: "Unknown default profile in persistence.")
                    return
                }
                policyRevision = persisted.policyRevision
            } else {
                try persistCurrentState(defaultProfileID: .metadataOnly)
            }
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: error.localizedDescription)
        }
    }

    /// Phase 1 selectable profiles only.
    var selectablePhase1Profiles: [MCPDisclosureProfileDocument] {
        profilesByID.values
            .filter(\.isSelectableInPhase1)
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Resolves a client-assigned profile, failing closed for unknown or non-selectable IDs.
    func resolvedProfile(for id: MCPDisclosureProfileID) throws -> MCPDisclosureProfileDocument {
        guard isLoaded else {
            throw MCPPolicyStoreError.corruptPersistence
        }
        guard let profile = profilesByID[id] else {
            throw MCPPolicyStoreError.unknownProfile(id)
        }
        guard profile.isSelectableInPhase1 else {
            throw MCPPolicyStoreError.profileNotSelectable(id)
        }
        return profile
    }

    /// Ensures a field class is allowed for the profile; unknown rules fail closed.
    func requireField(_ field: MCPPolicyFieldClass, profile: MCPDisclosureProfileDocument) throws {
        guard profile.allowedFieldClasses.contains(field) else {
            throw MCPPolicyStoreError.fieldClassNotAllowed(field, profile.id)
        }
    }

    /// Interim Phase 3 rule: inspect tools require Shareable profile until per-client grant UI (AH-4).
    func allowsInspectTools(for profileID: MCPDisclosureProfileID) -> Bool {
        profileID == .shareable
    }

    /// Interim Phase 3 rule: create-disabled mutating tools require Shareable profile (fail closed).
    func allowsMutatingTools(for profileID: MCPDisclosureProfileID) -> Bool {
        profileID == .shareable
    }

    /// Interim AH-4 rule: active enable/disable/throttle mutations require Shareable profile.
    func allowsActiveMutations(for profileID: MCPDisclosureProfileID) -> Bool {
        profileID == .shareable
    }

    /// Interim AH-5 rule: open-world tools require Shareable profile (fail closed).
    func allowsOpenWorldTools(for profileID: MCPDisclosureProfileID) -> Bool {
        profileID == .shareable
    }

    /// Bumps the monotonic policy revision after a tightening change.
    @discardableResult
    func bumpRevisionForTightening() -> MCPPolicyRevision {
        let next = MCPPolicyRevision(rawValue: "policy-v\(Self.revisionCounter(from: policyRevision) + 1)")
        policyRevision = next
        try? persistCurrentState(defaultProfileID: .metadataOnly)
        return next
    }

    private func failClosed(reason: String) {
        isLoaded = false
        loadFailureReason = reason
    }

    private func persistCurrentState(defaultProfileID: MCPDisclosureProfileID) throws {
        let state = PersistedState(
            schemaVersion: Self.persistenceSchemaVersion,
            policyRevision: policyRevision,
            defaultProfileID: defaultProfileID
        )
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName, isDirectory: false)
    }

    private static func revisionCounter(from revision: MCPPolicyRevision) -> Int {
        let suffix = revision.rawValue.replacingOccurrences(of: "policy-v", with: "")
        return Int(suffix) ?? 1
    }

    private static func builtInProfiles() -> [MCPDisclosureProfileID: MCPDisclosureProfileDocument] {
        let metadataOnlyFields: Set<MCPPolicyFieldClass> = [
            .sessionSequence,
            .sessionOpaqueID,
            .timestamps,
            .duration,
            .method,
            .statusCode,
            .mediaCategory,
            .hostCategory,
            .bodyAvailabilityFlags
        ]
        let shareableFields = metadataOnlyFields.union([
            .sanitizedHost,
            .sanitizedPath,
            .safeHeaders,
            .parserSummaries,
            .queryNamesOnly,
            .provenance,
            .scenarioEvidence,
            .scenarioAssertionResults
        ])
        let phase2Fields = Set(MCPPolicyFieldClass.allCases)

        return [
            .metadataOnly: MCPDisclosureProfileDocument(
                id: .metadataOnly,
                revision: 1,
                title: "Metadata Only",
                allowedFieldClasses: metadataOnlyFields,
                isSelectableInPhase1: true
            ),
            .shareable: MCPDisclosureProfileDocument(
                id: .shareable,
                revision: 1,
                title: "Shareable",
                allowedFieldClasses: shareableFields,
                isSelectableInPhase1: true
            ),
            .developerInspection: MCPDisclosureProfileDocument(
                id: .developerInspection,
                revision: 1,
                title: "Developer Inspection (Automation)",
                allowedFieldClasses: shareableFields,
                isSelectableInPhase1: true
            ),
            .fullLocalInspection: MCPDisclosureProfileDocument(
                id: .fullLocalInspection,
                revision: 0,
                title: "Full Local Inspection",
                allowedFieldClasses: phase2Fields,
                isSelectableInPhase1: false
            ),
            .custom: MCPDisclosureProfileDocument(
                id: .custom,
                revision: 0,
                title: "Custom",
                allowedFieldClasses: phase2Fields,
                isSelectableInPhase1: false
            )
        ]
    }
}
