import Foundation

/// Schema version for persisted mock-pack records. Bump when Codable shape changes.
enum OpenAPIMockPackSchemaVersion {
    static let current = 1
}

/// Hard caps for OpenAPI mock packs (AW-1). Exceeding a cap is a reject, never silent truncation.
enum OpenAPIMockPackBudget {
    static let maxDocumentBytes = 262_144
    static let maxOperationsPerPack = 32
    static let maxVariantsPerOperation = 8
    static let maxCompiledBodyBytes = MCPResourceBudget.maxDisclosedItemBytes
    static let maxRefDepth = 8
    static let maxPathSegments = 16
    static let maxActivePacksPerOwner = 1
    static let maxRetainedPackRecords = 20
    static let defaultTTL: TimeInterval = 3_600
    static let maxTTL: TimeInterval = 86_400

    /// Rejects an OpenAPI document larger than ``maxDocumentBytes``.
    static func validateDocumentBytes(_ byteCount: Int) throws {
        guard byteCount <= maxDocumentBytes else {
            throw OpenAPIMockPackError.documentTooLarge(byteCount: byteCount)
        }
    }

    /// Rejects a pack with more compiled operations than ``maxOperationsPerPack``.
    static func validateOperationCount(_ count: Int) throws {
        guard count <= maxOperationsPerPack else {
            throw OpenAPIMockPackError.tooManyOperations(count: count)
        }
    }

    /// Rejects an operation with more response variants than ``maxVariantsPerOperation``.
    static func validateVariantCount(operation: String, count: Int) throws {
        guard count <= maxVariantsPerOperation else {
            throw OpenAPIMockPackError.tooManyVariants(operation: operation, count: count)
        }
    }

    /// Rejects a compiled fixture body larger than ``maxCompiledBodyBytes``.
    static func validateCompiledBodyBytes(_ byteCount: Int) throws {
        guard byteCount <= maxCompiledBodyBytes else {
            throw OpenAPIMockPackError.compiledBodyTooLarge(byteCount: byteCount)
        }
    }

    /// Rejects `$ref` chains deeper than ``maxRefDepth``.
    static func validateRefDepth(_ depth: Int) throws {
        guard depth <= maxRefDepth else {
            throw OpenAPIMockPackError.refDepthExceeded(depth: depth)
        }
    }

    /// Rejects a path template with more segments than ``maxPathSegments``.
    static func validatePathSegmentCount(_ count: Int) throws {
        guard count <= maxPathSegments else {
            throw OpenAPIMockPackError.tooManyPathSegments(count: count)
        }
    }

    /// Rejects a TTL of zero or greater than ``maxTTL``.
    static func validateTTL(_ ttl: TimeInterval) throws {
        guard ttl > 0, ttl <= maxTTL else {
            throw OpenAPIMockPackError.ttlOutOfRange(ttl)
        }
    }

    /// Rejects a store that already holds ``maxRetainedPackRecords`` definitions.
    static func validateRetainedPackCount(_ count: Int) throws {
        guard count < maxRetainedPackRecords else {
            throw OpenAPIMockPackError.retainedPackLimitExceeded
        }
    }
}

/// Contract-level failures for mock-pack validation and activation.
enum OpenAPIMockPackError: Error, Equatable, LocalizedError {
    case documentTooLarge(byteCount: Int)
    case tooManyOperations(count: Int)
    case tooManyVariants(operation: String, count: Int)
    case compiledBodyTooLarge(byteCount: Int)
    case refDepthExceeded(depth: Int)
    case tooManyPathSegments(count: Int)
    case invalidPathTemplate(String)
    case ownerSlotBusy
    case retainedPackLimitExceeded
    case ttlOutOfRange(TimeInterval)
    case remainingTieConflict
    case overlappingRules([OpenAPIMockOverlappingRule])
    case packNotFound
    case notOwner
    case inactivePack
    case missingFixture
    case packIsServing
    case bookmarkUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .documentTooLarge(let byteCount):
            return "OpenAPI document is \(byteCount) bytes; maximum is \(OpenAPIMockPackBudget.maxDocumentBytes)."
        case .tooManyOperations(let count):
            return "Pack has \(count) operations; maximum is \(OpenAPIMockPackBudget.maxOperationsPerPack)."
        case .tooManyVariants(let operation, let count):
            return "Operation \(operation) has \(count) variants; maximum is \(OpenAPIMockPackBudget.maxVariantsPerOperation)."
        case .compiledBodyTooLarge(let byteCount):
            return "Compiled body is \(byteCount) bytes; maximum is \(OpenAPIMockPackBudget.maxCompiledBodyBytes)."
        case .refDepthExceeded(let depth):
            return "$ref depth \(depth) exceeds maximum \(OpenAPIMockPackBudget.maxRefDepth)."
        case .tooManyPathSegments(let count):
            return "Path template has \(count) segments; maximum is \(OpenAPIMockPackBudget.maxPathSegments)."
        case .invalidPathTemplate(let raw):
            return "Path template is not a supported v1 template: \(raw)."
        case .ownerSlotBusy:
            return "This owner already has an active mock pack."
        case .retainedPackLimitExceeded:
            return "Retained mock-pack limit (\(OpenAPIMockPackBudget.maxRetainedPackRecords)) reached."
        case .ttlOutOfRange(let ttl):
            return "TTL \(ttl) is outside (0, \(OpenAPIMockPackBudget.maxTTL)]."
        case .remainingTieConflict:
            return "Two mock-pack routes still tie after precedence rules; refuse rather than guess."
        case .overlappingRules(let rules):
            let count = rules.count
            return "Enabled overrides overlap this pack (\(count)); refuse unless replaceConflicts is set."
        case .packNotFound:
            return "The OpenAPI mock pack could not be found."
        case .notOwner:
            return "This OpenAPI mock pack belongs to another client."
        case .inactivePack:
            return "The OpenAPI mock pack is not serving."
        case .missingFixture:
            return "A compiled route is missing its immutable response fixture."
        case .packIsServing:
            return "Stop the OpenAPI mock pack before discarding it."
        case .bookmarkUnreadable(let detail):
            return "OpenAPI document bookmark could not be read: \(detail)"
        }
    }
}

/// Stable pack identifier.
struct OpenAPIMockPackID: Equatable, Sendable, Codable, Hashable {
    var rawValue: UUID
}

/// Who owns a mock pack. Stop and the active-slot quota are scoped to this identity.
enum OpenAPIMockPackOwner: Codable, Equatable, Sendable {
    case localUser
    case mcpClient(id: String, displayName: String)

    /// Stable owner key used for the one-active-pack quota.
    var ownerID: String {
        switch self {
        case .localUser: return "joesproxy-local-user"
        case .mcpClient(let id, _): return id
        }
    }
}

/// Exact origin a pack may intercept. Port defaults to 443/80 from scheme.
struct OpenAPIMockOrigin: Codable, Equatable, Hashable, Sendable {
    var scheme: SessionScheme
    var host: String
    var port: Int

    /// Normalizes host and fills the canonical port when omitted.
    init(scheme: SessionScheme, host: String, port: Int? = nil) {
        self.scheme = scheme
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port ?? (scheme == .https ? 443 : 80)
    }

    /// Origin string for activation disclosure (no path, no query).
    var displayString: String {
        let canonicalPort = scheme == .https ? 443 : 80
        return port == canonicalPort
            ? "\(scheme.rawValue)://\(host)"
            : "\(scheme.rawValue)://\(host):\(port)"
    }
}

/// Live and retained pack phases. `serving` is the only state that may intercept.
enum OpenAPIMockPackState: String, Codable, Equatable, Sendable, CaseIterable {
    case inactive
    case serving
    case stopped
    case expired
    case cleanupRequired

    /// Whether this pack currently owns live intercept.
    var isServing: Bool { self == .serving }
}

/// Hit/miss counters for a serving pack. Counts only; no URLs or bodies.
struct OpenAPIMockPackMetrics: Codable, Equatable, Sendable {
    var hits = 0
    var misses = 0
    var lastMatchedAt: Date?
    /// Hit counts keyed by compiled route id (method + template), never by a concrete URL.
    var operationHits: [String: Int] = [:]
}

/// Coverage counts for disclosure and UI. No operation URLs or fixture bytes.
struct OpenAPIMockCoverageSummary: Codable, Equatable, Sendable {
    var supportedOperationCount: Int
    var variantCount: Int
    var generatedVariantCount: Int
    var declaredExampleCount: Int
    var unsupportedFeatureCount: Int
    var conflictCount: Int
}

/// Opaque security-scoped bookmark for a local OpenAPI 3.0 JSON document.
///
/// UI and CLI mint the bookmark on the host. MCP receives only
/// ``openapiDocumentBookmarkRef`` (base64 of ``data``). Codable stores `Data`
/// as a single-value payload — never a filesystem path string.
struct OpenAPIDocumentBookmark: Equatable, Sendable, Hashable {
    var data: Data

    /// Base64 token for MCP/CLI. Not a path.
    var ref: String { data.base64EncodedString() }

    /// Accepts a base64 bookmark token. Returns nil for empty or non-base64 input.
    init?(ref: String) {
        guard let decoded = Data(base64Encoded: ref), !decoded.isEmpty else { return nil }
        self.data = decoded
    }

    /// Stores already-minted bookmark bytes.
    init(data: Data) {
        self.data = data
    }
}

extension OpenAPIDocumentBookmark: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        data = try container.decode(Data.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

/// Persisted mock-pack record. AW-3 owns I/O; this type is the Codable shape.
struct OpenAPIMockPack: Equatable, Sendable, Codable, Identifiable {
    var id: OpenAPIMockPackID
    var owner: OpenAPIMockPackOwner
    var origin: OpenAPIMockOrigin
    var documentBookmark: OpenAPIDocumentBookmark
    var state: OpenAPIMockPackState
    var startedAt: Date?
    var expiresAt: Date?
    var stoppedAt: Date?
    var metrics: OpenAPIMockPackMetrics
    var coverage: OpenAPIMockCoverageSummary
    var mcpProvenance: MCPProvenance?

    /// Whether intercept may consult this pack.
    var isServing: Bool { state.isServing }
}
