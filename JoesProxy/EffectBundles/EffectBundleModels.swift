import Foundation

enum EffectBundleSchema {
    /// Version 8 permits captured-fixture batches of 1–100 items. Earlier schemas retain the
    /// single-item authoring contract; live collection transformations are unchanged.
    static let currentVersion = 8
}

enum EffectBundleBudget {
    static let maxPackageBytes = 64 * 1_024 * 1_024
    static let maxFileBytes = LocalDirectoryLimits.maxServedFileBytes
    static let maxFileCount = 4_096
    static let maxResponseEffectCount = 64
    // Keep bundle activation within the live HLS run store's per-owner ceiling.
    static let maxHLSSubstitutionCount = 2
    static let maxRetainedBundles = 20
    static let maxNameBytes = 120
    static let maxNotesBytes = 4 * 1_024
    static let maxManifestBytes = 1 * 1_024 * 1_024
    static let defaultTTL: TimeInterval = 3_600
    static let maxTTL: TimeInterval = 86_400
}

enum EffectBundleState: String, Codable, Equatable, Sendable {
    case inactive
    case serving
    case stopped
    case expired
    case cleanupRequired

    var isServing: Bool { self == .serving }
}

enum EffectBundleOwner: Codable, Equatable, Sendable {
    case localUser
    case mcpClient(id: String, displayName: String)

    var ownerID: String {
        switch self {
        case .localUser:
            return "joesproxy-local-user"
        case .mcpClient(let id, _):
            return id
        }
    }
}

struct EffectBundlePrivacyNotice: Codable, Equatable, Sendable {
    static let exactContentWarning = "This package preserves selected response bytes and configuration exactly. Treat it as potentially sensitive and inspect it before sharing."

    var preservesExactContent: Bool
    var warning: String

    static let exactContent = EffectBundlePrivacyNotice(
        preservesExactContent: true,
        warning: exactContentWarning
    )
}

enum EffectBundleAssetRole: String, Codable, Equatable, Sendable {
    case responseBody
    case localFile
    case localDirectoryFile
    case hlsProfileFile
}

struct EffectBundleAsset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: EffectBundleAssetRole
    var logicalPath: String
    var sha256: String
    var byteCount: Int
    var contentType: String?

    var packageRelativePath: String { "assets/\(sha256)" }
}

enum EffectBundleBodyKind: String, Codable, Equatable, Sendable {
    case none
    case inline
    case file
    case directory
}

struct EffectBundleBodySource: Codable, Equatable, Sendable {
    var kind: EffectBundleBodyKind
    var assetIDs: [String]
    var rootLogicalPath: String?

    static let none = EffectBundleBodySource(kind: .none, assetIDs: [], rootLogicalPath: nil)
}

struct EffectBundleResponseEffect: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String?
    var requestMethod: String
    var requestScheme: SessionScheme
    var host: String
    var port: Int?
    var path: String
    var matchMode: ResponseOverrideMatchMode
    var sourceKind: ResponseOverrideSourceKind
    var statusCode: Int
    var headers: [HTTPHeaderField]
    var bodySource: EffectBundleBodySource
    var mapRemoteHost: String?
    var mapRemotePort: Int?
    var mapRemoteScheme: SessionScheme?
    var mapRemotePath: String?
    var mapRemoteQueryPolicy: MapRemoteQueryPolicy
    var mapRemoteQuery: String?
    /// Schema/bundle opt-in allowing `.mapRemote` to target local Mac loopback endpoints (`nil` = `false`).
    var allowLoopbackDestination: Bool? = nil
    /// When `true` on `.mapRemote`, preserves the validated original `Host` authority (`nil` = `false`).
    var preserveHostHeader: Bool? = nil
    var bookmarkRewriteRequest: CapturedRequest?
    var liveResponseRewrites: [BookmarkResponseFieldRewrite]
    var expectedSchemaFingerprint: JSONSchemaShapeFingerprint?
    var dropConnection: Bool
    var forceNoCache: Bool
    var notFoundRelativePath: String?
    var missingFilePolicy: LocalDirectoryMissingFilePolicy
    var graphQLOperationName: String?
    var matchQueryKey: String?
    var matchQueryValue: String?
    var matchHeaderName: String?
    var matchHeaderValue: String?
    var sourceClientAddress: String?
    var ignoredQueryNames: [String]? = nil
    /// Immutable, reviewed collection mutation for a `.collectionMock` response effect.
    /// This is deliberately a plan, not captured source content or an executable closure.
    var collectionMockPlan: CompiledCollectionMock? = nil
}

struct EffectBundleHLSSubstitution: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var profileID: String
    var profileVersion: String
    var profileAssetIDs: [String]
    var profileRootLogicalPath: String
    var origin: HLSSubstitutionOrigin
    var scope: HLSSubstitutionScope
    var playbackConfiguration: HLSPlaybackConfiguration
    /// Schema 6: prepared replacement media for an existing first-phase substitution.
    var replacesSubstitutionID: UUID? = nil
    var requestPolicy: HLSRequestPolicy? = nil
}

/// A reviewed JSON timestamp projection. Resolution is intentionally deferred until activation,
/// when the run's wall-clock anchor is known; bundles never control device time.
struct EffectBundleTimestampBinding: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var responseEffectID: UUID
    var jsonPointer: String
    var offsetSeconds: TimeInterval
}

/// One ordered, immutable routing generation of a guided experiment.
struct EffectBundlePhase: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var durationSeconds: TimeInterval
    var responseEffectIDs: [UUID]
    var hlsSubstitutionIDs: [UUID]
    var timestampBindings: [EffectBundleTimestampBinding]
    /// Schema 6: complete an earlier live fixture without stopping its server or retained media.
    var completeHLSSubstitutionIDs: [UUID]? = nil
}

struct EffectBundleManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var appVersion: String
    var privacy: EffectBundlePrivacyNotice
    var defaultTTLSeconds: TimeInterval
    var assets: [EffectBundleAsset]
    var responseEffects: [EffectBundleResponseEffect]
    var hlsSubstitutions: [EffectBundleHLSSubstitution]
    var authoring: EffectBundleAuthoringMetadata? = nil
    /// Schema 5 optional lifecycle contract. Absence preserves the legacy single-generation
    /// activation behavior for older and non-phased bundles.
    var phases: [EffectBundlePhase]? = nil
}

struct EffectBundleAuthoringMetadata: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case capturedFixture }
    let mode: Mode
    let revisionID: UUID
    let sourceDigest: String
    let responseAssetID: String
    let beforeCount: Int
    let afterCount: Int
    var relatedResponses: [RelatedResponse]? = nil
    /// Optional reviewed metadata; older packages remain inspectable without decoding their assets.
    var artwork: [CapturedMockImagePreview]? = nil
    /// Reviewed intent only; this is not an independently observed response-body diff.
    var reviewedChanges: [String]? = nil
    var reviewedChangesTruncated: Bool? = nil

    struct RelatedResponse: Codable, Equatable, Sendable {
        let assetID: String
        let sourceSessionID: UUID?
        var targetSessionID: UUID? = nil
        let sourceDigest: String
        let changedPointers: [String]
        let images: [CapturedRelatedResponse.ImageBinding]
        let identityLinks: [CapturedRelatedResponse.IdentityLink]
    }
}

enum EffectBundleTerminationReason: String, Codable, Sendable {
    case stopped, completed, expired, sleep, transitionConflict
}

struct EffectBundleRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var owner: EffectBundleOwner
    var manifest: EffectBundleManifest
    var managedPackagePath: String
    var state: EffectBundleState
    var importedAt: Date
    var activatedAt: Date?
    var expiresAt: Date?
    var stoppedAt: Date?
    var cleanupMessage: String?
    var terminationReason: EffectBundleTerminationReason? = nil

    var isServing: Bool { state.isServing }
}

enum EffectBundleError: Error, Equatable, LocalizedError {
    case packageNotFound
    case packageIsNotDirectory
    case destinationExists
    case manifestMissing
    case manifestTooLarge(Int)
    case unsupportedSchema(Int)
    case invalidName
    case notesTooLarge
    case invalidTTL
    case tooManyResponseEffects(Int)
    case tooManyHLSSubstitutions(Int)
    case tooManyFiles(Int)
    case packageTooLarge(Int)
    case fileTooLarge(path: String, byteCount: Int)
    case unsafePath(String)
    case symbolicLink(String)
    case unexpectedFile(String)
    case duplicateIdentifier(String)
    case duplicateLogicalPath(String)
    case invalidDigest(String)
    case assetMissing(String)
    case assetSizeMismatch(String)
    case assetDigestMismatch(String)
    case missingAssetReference(String)
    case invalidBodySource(String)
    case unsupportedInternalRule
    case retainedBundleLimitReached
    case bundleNotFound
    case notOwner
    case bundleIsServing
    case activationConflict
    case unsupportedPhaseFeature(String)
    case stalePhase
    case loopbackMapRemoteDenied(UUID, String)
    case cleanupRequired(String)

    var errorDescription: String? {
        switch self {
        case .packageNotFound: return "The effect bundle was not found."
        case .packageIsNotDirectory: return "The effect bundle must be a .jproxy-effects directory package."
        case .destinationExists: return "An effect bundle already exists at the selected destination."
        case .manifestMissing: return "The effect bundle is missing manifest.json."
        case .manifestTooLarge(let count): return "The effect-bundle manifest is too large (\(count) bytes)."
        case .unsupportedSchema(let version): return "Effect-bundle schema version \(version) requires a newer JoesProxy build."
        case .invalidName: return "The effect-bundle name is empty or exceeds \(EffectBundleBudget.maxNameBytes) UTF-8 bytes."
        case .notesTooLarge: return "Effect-bundle notes exceed \(EffectBundleBudget.maxNotesBytes) UTF-8 bytes."
        case .invalidTTL: return "Effect-bundle TTL must be greater than zero and at most \(Int(EffectBundleBudget.maxTTL)) seconds."
        case .tooManyResponseEffects(let count): return "Effect bundle has \(count) response effects; maximum is \(EffectBundleBudget.maxResponseEffectCount)."
        case .tooManyHLSSubstitutions(let count): return "Effect bundle has \(count) HLS substitutions; maximum is \(EffectBundleBudget.maxHLSSubstitutionCount)."
        case .tooManyFiles(let count): return "Effect bundle has \(count) files; maximum is \(EffectBundleBudget.maxFileCount)."
        case .packageTooLarge(let count): return "Effect bundle is \(count) bytes; maximum is \(EffectBundleBudget.maxPackageBytes)."
        case .fileTooLarge(let path, let count): return "Effect-bundle file \(path) is \(count) bytes; maximum is \(EffectBundleBudget.maxFileBytes)."
        case .unsafePath(let path): return "Effect-bundle path is unsafe: \(path)."
        case .symbolicLink(let path): return "Effect bundles do not allow symbolic links: \(path)."
        case .unexpectedFile(let path): return "Effect bundle contains an unlisted file: \(path)."
        case .duplicateIdentifier(let id): return "Effect bundle contains duplicate identifier \(id)."
        case .duplicateLogicalPath(let path): return "Effect bundle contains duplicate logical path \(path)."
        case .invalidDigest(let digest): return "Effect bundle contains invalid SHA-256 digest \(digest)."
        case .assetMissing(let id): return "Effect-bundle asset is missing: \(id)."
        case .assetSizeMismatch(let id): return "Effect-bundle asset size does not match its manifest: \(id)."
        case .assetDigestMismatch(let id): return "Effect-bundle asset digest does not match its manifest: \(id)."
        case .missingAssetReference(let id): return "Effect bundle references unknown asset \(id)."
        case .invalidBodySource(let id): return "Effect-bundle response effect \(id) has an invalid body-source configuration."
        case .unsupportedInternalRule: return "Generated fixture-routing rules must be exported through their HLS substitution, not as response rules."
        case .retainedBundleLimitReached: return "The retained effect-bundle limit has been reached."
        case .bundleNotFound: return "The effect bundle could not be found."
        case .notOwner: return "The effect bundle belongs to another client."
        case .bundleIsServing: return "Stop the effect bundle before discarding it."
        case .activationConflict: return "An enabled effect overlaps this bundle. Review conflicts or explicitly replace them."
        case .unsupportedPhaseFeature(let feature): return "This build cannot safely activate phased \(feature). Keep the bundle inactive until that lifecycle capability is available."
        case .stalePhase: return "The active phase changed or the run ended. Inspect the current activation and phase before advancing."
        case .loopbackMapRemoteDenied(let id, let reason): return "Effect-bundle Map Remote rule \(id.uuidString) is blocked by local-server policy: \(reason)"
        case .cleanupRequired(let message): return "Effect-bundle cleanup requires attention: \(message)"
        }
    }
}
