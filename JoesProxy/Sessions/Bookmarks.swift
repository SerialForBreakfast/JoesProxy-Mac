import CryptoKit
import Foundation

/// Coarse JSON type used for bookmark override validation in the UI.
enum BookmarkJSONValueKind: String, Equatable, Sendable, CaseIterable {
    case string
    case number
    case bool
    case null
    case array
    case object

    var title: String {
        switch self {
        case .string:
            return "String"
        case .number:
            return "Number"
        case .bool:
            return "Bool"
        case .null:
            return "Null"
        case .array:
            return "JSON"
        case .object:
            return "JSON"
        }
    }
}

/// User-selectable override value encoding when adding or editing bookmark field rewrites.
enum BookmarkResponseRewriteValueInputMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case string
    case number
    case bool
    case null
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .string:
            return "String"
        case .number:
            return "Number"
        case .bool:
            return "Bool"
        case .null:
            return "Null"
        case .json:
            return "JSON"
        }
    }
}

/// A tagged JSON value used for bookmark response field overrides.
enum BookmarkJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(String)
    case null
    case array([BookmarkJSONValue])
    case object([String: BookmarkJSONValue])

    var kind: BookmarkJSONValueKind {
        switch self {
        case .string:
            return .string
        case .bool:
            return .bool
        case .number:
            return .number
        case .null:
            return .null
        case .array:
            return .array
        case .object:
            return .object
        }
    }

    /// Creates an override value from a parsed JSON object.
    static func from(jsonValue: Any) -> BookmarkJSONValue {
        switch jsonValue {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.stringValue)
        case is NSNull:
            return .null
        case let array as [Any]:
            return .array(array.map(from(jsonValue:)))
        case let object as [String: Any]:
            return .object(Dictionary(uniqueKeysWithValues: object.map { ($0.key, from(jsonValue: $0.value)) }))
        default:
            return .string(String(describing: jsonValue))
        }
    }

    /// Returns the kind of the JSON value at `path` in `bodyData`, when readable.
    static func kind(at path: String, in bodyData: Data?) -> BookmarkJSONValueKind? {
        BookmarkJSONRewriteEngine.value(at: path, in: bodyData)?.kind
    }

    /// Converts back to a Foundation object for ``JSONSerialization``.
    func jsonObjectValue() -> Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .number(let value):
            if let intValue = Int(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return doubleValue
            }
            return value
        case .null:
            return NSNull()
        case .array(let values):
            return values.map { $0.jsonObjectValue() }
        case .object(let values):
            return values.mapValues { $0.jsonObjectValue() }
        }
    }

    /// Parses a user-entered override value, preserving booleans and null when typed literally.
    static func fromUserInput(_ text: String, mode: BookmarkResponseRewriteValueInputMode = .auto) -> BookmarkJSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .null:
            return .null
        case .bool:
            switch trimmed.lowercased() {
            case "true":
                return .bool(true)
            case "false":
                return .bool(false)
            default:
                return .string(trimmed)
            }
        case .string:
            return .string(trimmed)
        case .number:
            if let intValue = Int(trimmed) {
                return .number(String(intValue))
            }
            if Double(trimmed) != nil {
                return .number(trimmed)
            }
            return .string(trimmed)
        case .json:
            return parseJSONFragment(trimmed) ?? .string(trimmed)
        case .auto:
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                if let parsed = parseJSONFragment(trimmed) {
                    return parsed
                }
            }
            switch trimmed.lowercased() {
            case "true":
                return .bool(true)
            case "false":
                return .bool(false)
            case "null":
                return .null
            default:
                if let intValue = Int(trimmed) {
                    return .number(String(intValue))
                }
                if Double(trimmed) != nil {
                    return .number(trimmed)
                }
                return .string(trimmed)
            }
        }
    }

    /// Human-readable value for UI labels.
    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value
        case .null:
            return "null"
        case .array, .object:
            guard let data = try? JSONSerialization.data(withJSONObject: jsonObjectValue(), options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return text
        }
    }

    /// Sanitized disclosure descriptor for MCP approval/summary text: type, byte size, and a
    /// short SHA-256 digest of the canonical JSON encoding. Never echoes the raw value — a
    /// disclosure surface must not assume every override value is safe to display verbatim.
    var disclosureDescriptor: String {
        let object = jsonObjectValue()
        let bytes: Data
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            bytes = data
        } else {
            // Scalars (string/bool/number/null) aren't valid top-level JSONSerialization objects.
            bytes = Data(displayString.utf8)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(kind.title) (\(bytes.count) bytes, sha256:\(digest))"
    }

    init(from decoder: Decoder) throws {
        if let keyedContainer = try? decoder.container(keyedBy: CodingKeys.self),
           let type = try? keyedContainer.decode(String.self, forKey: .type) {
            switch type {
            case "string":
                self = .string(try keyedContainer.decode(String.self, forKey: .value))
            case "bool":
                self = .bool(try keyedContainer.decode(Bool.self, forKey: .value))
            case "number":
                self = .number(try keyedContainer.decode(String.self, forKey: .value))
            case "null":
                self = .null
            case "array":
                self = .array(try keyedContainer.decode([BookmarkJSONValue].self, forKey: .value))
            case "object":
                self = .object(try keyedContainer.decode([String: BookmarkJSONValue].self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: keyedContainer,
                    debugDescription: "Unknown bookmark JSON value type"
                )
            }
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let arrayValue = try? container.decode([BookmarkJSONValue].self) {
            self = .array(arrayValue)
            return
        }
        if let objectValue = try? container.decode([String: BookmarkJSONValue].self) {
            self = .object(objectValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .number(String(doubleValue))
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported bookmark JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var keyedContainer = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try keyedContainer.encode("string", forKey: .type)
            try keyedContainer.encode(value, forKey: .value)
        case .bool(let value):
            try keyedContainer.encode("bool", forKey: .type)
            try keyedContainer.encode(value, forKey: .value)
        case .number(let value):
            try keyedContainer.encode("number", forKey: .type)
            try keyedContainer.encode(value, forKey: .value)
        case .null:
            try keyedContainer.encode("null", forKey: .type)
        case .array(let value):
            try keyedContainer.encode("array", forKey: .type)
            try keyedContainer.encode(value, forKey: .value)
        case .object(let value):
            try keyedContainer.encode("object", forKey: .type)
            try keyedContainer.encode(value, forKey: .value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private static func parseJSONFragment(_ trimmed: String) -> BookmarkJSONValue? {
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return from(jsonValue: object)
    }
}

/// Snapshot of a captured HTTP response stored on a bookmark for response rewriting.
struct BookmarkSavedResponse: Codable, Equatable, Sendable {
    var statusCode: Int
    var headers: [HTTPHeaderField]
    var bodyData: Data?
    var savedAt: Date
}

/// A persisted JSON field override applied to a bookmark's saved response snapshot.
struct BookmarkResponseFieldRewrite: Identifiable, Equatable, Sendable {
    let id: UUID
    var jsonPath: String
    var originalValueSnapshot: String?
    var overrideValue: BookmarkJSONValue
    var operation: JSONMutationOperation
    var isRuleEnabled: Bool
    /// Only consulted by `.appendString`/`.prependString`; ignored otherwise. `nil` on legacy
    /// persisted data decodes as `.always`, matching the only behavior that existed before this
    /// field was added.
    var repeatPolicy: JSONMutationRepeatPolicy?

    init(
        id: UUID = UUID(),
        jsonPath: String,
        originalValueSnapshot: String? = nil,
        overrideValue: BookmarkJSONValue,
        operation: JSONMutationOperation = .set,
        isRuleEnabled: Bool = true,
        repeatPolicy: JSONMutationRepeatPolicy? = nil
    ) {
        self.id = id
        self.jsonPath = jsonPath
        self.originalValueSnapshot = originalValueSnapshot
        self.overrideValue = overrideValue
        self.operation = operation
        self.isRuleEnabled = isRuleEnabled
        self.repeatPolicy = repeatPolicy
    }
}

extension BookmarkResponseFieldRewrite: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, jsonPath, originalValueSnapshot, overrideValue, operation, isRuleEnabled, repeatPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        jsonPath = try container.decode(String.self, forKey: .jsonPath)
        originalValueSnapshot = try container.decodeIfPresent(String.self, forKey: .originalValueSnapshot)
        overrideValue = try container.decode(BookmarkJSONValue.self, forKey: .overrideValue)
        operation = try container.decodeIfPresent(JSONMutationOperation.self, forKey: .operation) ?? .set
        isRuleEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRuleEnabled) ?? true
        repeatPolicy = try container.decodeIfPresent(JSONMutationRepeatPolicy.self, forKey: .repeatPolicy)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jsonPath, forKey: .jsonPath)
        try container.encodeIfPresent(originalValueSnapshot, forKey: .originalValueSnapshot)
        try container.encode(overrideValue, forKey: .overrideValue)
        try container.encode(operation, forKey: .operation)
        try container.encode(isRuleEnabled, forKey: .isRuleEnabled)
        try container.encodeIfPresent(repeatPolicy, forKey: .repeatPolicy)
    }
}

/// How a bookmark response rewrite should be applied at runtime.
enum BookmarkResponseRewriteMode: String, Codable, Equatable, Sendable {
    /// Serve the bookmark's saved response snapshot with configured field overrides applied.
    case savedSnapshot
}

struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var request: CapturedRequest
    var createdAt: Date
    var lastExecutedAt: Date?
    var savedResponse: BookmarkSavedResponse?
    var responseRewrites: [BookmarkResponseFieldRewrite]
    var responseRewriteMode: BookmarkResponseRewriteMode
    var responseMatchMode: ResponseOverrideMatchMode
    /// Origin of the bookmark for MCP recovery flows. Absent on legacy bookmarks.
    var mcpOrigin: MCPObjectOrigin?
    /// MCP client that created or last semantically modified this bookmark.
    var mcpProvenance: MCPProvenance?
    /// Canonical semantic revision used by proposal/apply and recovery.
    var mcpTargetRevision: MCPTargetRevision?

    init(
        id: UUID = UUID(),
        name: String,
        request: CapturedRequest,
        createdAt: Date = Date(),
        lastExecutedAt: Date? = nil,
        savedResponse: BookmarkSavedResponse? = nil,
        responseRewrites: [BookmarkResponseFieldRewrite] = [],
        responseRewriteMode: BookmarkResponseRewriteMode = .savedSnapshot,
        responseMatchMode: ResponseOverrideMatchMode = .ignoreQuery,
        mcpOrigin: MCPObjectOrigin? = nil,
        mcpProvenance: MCPProvenance? = nil,
        mcpTargetRevision: MCPTargetRevision? = nil
    ) {
        self.id = id
        self.name = name
        self.request = request
        self.createdAt = createdAt
        self.lastExecutedAt = lastExecutedAt
        self.savedResponse = savedResponse
        self.responseRewrites = responseRewrites
        self.responseRewriteMode = responseRewriteMode
        self.responseMatchMode = responseMatchMode
        self.mcpOrigin = mcpOrigin
        self.mcpProvenance = mcpProvenance
        self.mcpTargetRevision = mcpTargetRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case request
        case createdAt
        case lastExecutedAt
        case savedResponse
        case responseRewrites
        case responseRewriteMode
        case responseMatchMode
        case mcpOrigin
        case mcpProvenance
        case mcpTargetRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        request = try container.decode(CapturedRequest.self, forKey: .request)
        createdAt = try Self.decodeFlexibleDate(from: container, forKey: .createdAt)
        lastExecutedAt = try Self.decodeOptionalFlexibleDate(from: container, forKey: .lastExecutedAt)
        savedResponse = try container.decodeIfPresent(BookmarkSavedResponse.self, forKey: .savedResponse)
        responseRewrites = try container.decodeIfPresent([BookmarkResponseFieldRewrite].self, forKey: .responseRewrites) ?? []
        responseRewriteMode = try container.decodeIfPresent(BookmarkResponseRewriteMode.self, forKey: .responseRewriteMode) ?? .savedSnapshot
        responseMatchMode = try container.decodeIfPresent(ResponseOverrideMatchMode.self, forKey: .responseMatchMode) ?? .ignoreQuery
        mcpOrigin = try container.decodeIfPresent(MCPObjectOrigin.self, forKey: .mcpOrigin)
        mcpProvenance = try container.decodeIfPresent(MCPProvenance.self, forKey: .mcpProvenance)
        mcpTargetRevision = try container.decodeIfPresent(MCPTargetRevision.self, forKey: .mcpTargetRevision)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(request, forKey: .request)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastExecutedAt, forKey: .lastExecutedAt)
        try container.encodeIfPresent(savedResponse, forKey: .savedResponse)
        try container.encode(responseRewrites, forKey: .responseRewrites)
        try container.encode(responseRewriteMode, forKey: .responseRewriteMode)
        try container.encode(responseMatchMode, forKey: .responseMatchMode)
        try container.encodeIfPresent(mcpOrigin, forKey: .mcpOrigin)
        try container.encodeIfPresent(mcpProvenance, forKey: .mcpProvenance)
        try container.encodeIfPresent(mcpTargetRevision, forKey: .mcpTargetRevision)
    }

    /// Accepts ISO-8601 strings and numeric reference-date timestamps for legacy bookmark files.
    private static func decodeFlexibleDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date {
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }

        if let isoString = try? container.decode(String.self, forKey: key) {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: isoString) {
                return date
            }
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected an ISO-8601 string or numeric date for \(key.rawValue)."
        )
    }

    private static func decodeOptionalFlexibleDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date? {
        guard container.contains(key) else {
            return nil
        }

        if (try? container.decodeNil(forKey: key)) == true {
            return nil
        }

        return try decodeFlexibleDate(from: container, forKey: key)
    }

    /// Number of persisted rewrite rules that are currently enabled in bookmark configuration.
    var enabledResponseRewriteCount: Int {
        responseRewrites.filter(\.isRuleEnabled).count
    }

    /// Whether the bookmark has enough data to configure or enable response rewrites.
    var hasSavedResponse: Bool {
        savedResponse != nil
    }
}

/// Builds and validates bookmark saved-response snapshots from captured sessions.
enum BookmarkResponseEditing {
    /// Whether a session response can be copied onto a bookmark.
    static func canSaveResponse(from session: SessionRecord) -> Bool {
        guard session.request.inspectionKind != .tunneledTLS else {
            return false
        }

        guard let response = session.response else {
            return false
        }

        return !response.bodyDeferred && response.recordingBodyOmissionReason == nil
    }

    /// Creates a bookmark response snapshot using decoded analysis bytes when available.
    static func savedResponse(from session: SessionRecord) -> BookmarkSavedResponse? {
        guard canSaveResponse(from: session), let response = session.response else {
            return nil
        }

        let decodedBody = CapturedBodyDecoder.decode(response: response)?.analysisData ?? response.bodyData
        if let decodedBody, decodedBody.count > RecordingConstants.bodySizeLimit {
            return nil
        }

        return BookmarkSavedResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            bodyData: decodedBody,
            savedAt: Date()
        )
    }
}

enum BookmarkUpdatePreset: String, CaseIterable, Equatable, Identifiable, Sendable {
    case authOnly
    case authAndCookies
    case headersOnly
    case queryAndHeaders
    case custom
    case replaceEntireRequest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .authOnly:
            return "Auth Only"
        case .authAndCookies:
            return "Auth + Cookies"
        case .headersOnly:
            return "Headers Only"
        case .queryAndHeaders:
            return "Query + Headers"
        case .custom:
            return "Custom"
        case .replaceEntireRequest:
            return "Replace Entire Request"
        }
    }

    var systemImage: String {
        switch self {
        case .authOnly:
            return "key.fill"
        case .authAndCookies:
            return "person.badge.key.fill"
        case .headersOnly:
            return "list.bullet.rectangle"
        case .queryAndHeaders:
            return "link.badge.plus"
        case .custom:
            return "slider.horizontal.3"
        case .replaceEntireRequest:
            return "arrow.triangle.swap"
        }
    }

    var summary: String {
        switch self {
        case .authOnly:
            return "Refresh token-like headers, query values, and JSON body fields."
        case .authAndCookies:
            return "Refresh auth fields and cookie headers."
        case .headersOnly:
            return "Replace request headers while keeping the current path and body."
        case .queryAndHeaders:
            return "Refresh the URL query string and request headers."
        case .custom:
            return "Choose the exact headers, query items, and JSON body fields to merge."
        case .replaceEntireRequest:
            return "Replace the bookmark request with the selected captured request."
        }
    }
}

struct BookmarkCustomMergeOptions: Equatable, Sendable {
    var headerNames: Set<String> = []
    var queryItemNames: Set<String> = []
    var jsonBodyKeys: Set<String> = []
}

protocol BookmarkStore: AnyObject {
    func loadBookmarks() -> [Bookmark]
    func saveBookmarks(_ bookmarks: [Bookmark]) throws
}

/// Bookmark persistence helpers for MCP provenance and semantic revision tracking.
enum MCPBookmarkStoreSupport {
    /// Saves bookmarks after applying semantic revision tokens and optional MCP provenance.
    static func saveBookmarks(
        _ bookmarks: [Bookmark],
        to store: any BookmarkStore,
        applyingRevisionToUpdated updated: Bookmark? = nil,
        provenance: MCPProvenance? = nil,
        origin: MCPObjectOrigin? = nil
    ) throws {
        let normalized = bookmarks.map { bookmark in
            var copy = bookmark
            if let updated, updated.id == bookmark.id {
                copy = updated
            }
            if let provenance, copy.id == updated?.id {
                copy.mcpProvenance = provenance
                copy.mcpOrigin = origin ?? .mcp
            }
            return MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(copy)
        }
        try store.saveBookmarks(normalized)
    }
}

final class UserDefaultsBookmarkStore: BookmarkStore {
    private enum Keys {
        static let bookmarks = "bookmarks"
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadBookmarks() -> [Bookmark] {
        guard let data = userDefaults.data(forKey: Keys.bookmarks) else {
            return []
        }

        do {
            // Recompute rather than trust whatever was on disk — a file written before revision
            // recomputation was moved into `saveBookmarks` (or by any future path that bypasses it)
            // could carry a stale or missing revision.
            return try decoder.decode([Bookmark].self, from: data)
                .map(MCPTargetRevisionFingerprint.bookmarkByApplyingRevision)
        } catch {
            return []
        }
    }

    func saveBookmarks(_ bookmarks: [Bookmark]) throws {
        // Recompute here, not just in MCPBookmarkStoreSupport's opt-in wrapper — every legacy
        // (non-MCP) edit path in the app calls this method directly, so if revision recomputation
        // only happened in the wrapper, `mcpTargetRevision` would silently go stale on every edit
        // made through the normal UI, defeating the MCP proposal system's staleness check entirely.
        let normalized = bookmarks.map(MCPTargetRevisionFingerprint.bookmarkByApplyingRevision)
        let data = try encoder.encode(normalized)
        userDefaults.set(data, forKey: Keys.bookmarks)
    }
}

final class InMemoryBookmarkStore: BookmarkStore {
    private var bookmarks: [Bookmark]

    init(bookmarks: [Bookmark] = []) {
        self.bookmarks = bookmarks
    }

    func loadBookmarks() -> [Bookmark] {
        bookmarks
    }

    func saveBookmarks(_ bookmarks: [Bookmark]) throws {
        self.bookmarks = bookmarks.map(MCPTargetRevisionFingerprint.bookmarkByApplyingRevision)
    }
}

enum BookmarkRequestEditing {
    private static let headerTokenCharacterSet = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    private static let excludedTransportHeaderNames: Set<String> = [
        "host",
        "content-length",
        "connection",
        "proxy-connection"
    ]
    private static let authTokenKeywords = ["auth", "authorization", "token", "session", "csrf", "cookie"]

    static func preparedRequest(forExecution request: CapturedRequest) -> CapturedRequest {
        let normalizedHeaders = request.headers.compactMap(preparedHeader)
        let normalizedBodyData = normalizedBodyData(from: request.bodyData)

        return CapturedRequest(
            method: request.method,
            scheme: request.scheme,
            inspectionKind: request.inspectionKind,
            inspectionReason: request.inspectionReason,
            host: request.host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            port: request.port,
            path: normalizedPath(request.path),
            headers: normalizedHeaders,
            bodyData: normalizedBodyData,
            bodySize: normalizedBodyData?.count
        )
    }

    static func validationMessage(for request: CapturedRequest) -> String? {
        let normalizedHost = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHost.isEmpty {
            return "Enter a host before running this bookmark."
        }

        if normalizedHost.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "Hosts cannot contain spaces."
        }

        for header in request.headers {
            let trimmedName = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = normalizedHeaderValue(header.value)

            if trimmedName.isEmpty && trimmedValue.isEmpty {
                continue
            }

            if trimmedName.isEmpty {
                return "Remove the blank header value or enter a header name."
            }

            if !isValidHeaderName(trimmedName) {
                return "Header names can only use standard HTTP token characters."
            }
        }

        let normalizedRequest = preparedRequest(forExecution: request)
        guard MediaDetector.absoluteURL(for: normalizedRequest) != nil else {
            return "The bookmark URL is invalid. Check the scheme, host, and path."
        }

        if let bodyData = normalizedRequest.bodyData,
           !bodyData.isEmpty,
           isLikelyJSON(headers: normalizedRequest.headers),
           !canParseJSON(bodyData) {
            return "The request body is not valid JSON for the current Content-Type."
        }

        return nil
    }

    static func supportsTextBodyEditing(for request: CapturedRequest) -> Bool {
        guard let bodyData = request.bodyData, !bodyData.isEmpty else {
            return true
        }

        if String(data: bodyData, encoding: .utf8) != nil {
            return true
        }

        guard let mimeType = normalizedMimeType(from: request.headers) else {
            return false
        }

        return mimeType.hasPrefix("text/") ||
            mimeType == "application/json" ||
            mimeType.hasSuffix("+json") ||
            mimeType == "application/x-www-form-urlencoded" ||
            mimeType == "application/xml" ||
            mimeType == "text/xml" ||
            mimeType.hasSuffix("+xml")
    }

    static func bodyEditorText(for request: CapturedRequest) -> String {
        guard let bodyData = request.bodyData, !bodyData.isEmpty else {
            return ""
        }

        return String(data: bodyData, encoding: .utf8) ?? ""
    }

    static func bodyData(from editorText: String) -> Data? {
        guard !editorText.isEmpty else {
            return nil
        }

        return Data(editorText.utf8)
    }

    static func prettyPrintedJSONText(for request: CapturedRequest) -> String? {
        guard let bodyData = preparedRequest(forExecution: request).bodyData,
              !bodyData.isEmpty,
              let jsonObject = try? JSONSerialization.jsonObject(with: bodyData),
              let formattedData = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }

        return String(data: formattedData, encoding: .utf8)
    }

    static func bodyFormatLabel(for request: CapturedRequest) -> String {
        guard let mimeType = normalizedMimeType(from: request.headers) else {
            return "Text"
        }

        if mimeType == "application/json" || mimeType.hasSuffix("+json") {
            return "JSON"
        }

        if mimeType == "application/x-www-form-urlencoded" {
            return "Form URL Encoded"
        }

        if mimeType.hasPrefix("text/") {
            return "Text"
        }

        return mimeType
    }

    static func bodyValidationMessage(for request: CapturedRequest) -> String? {
        guard let bodyData = preparedRequest(forExecution: request).bodyData,
              !bodyData.isEmpty,
              isLikelyJSON(headers: request.headers),
              !canParseJSON(bodyData) else {
            return nil
        }

        return "This body is marked as JSON, but it does not parse as valid JSON yet."
    }

    static func merge(
        bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest,
        preset: BookmarkUpdatePreset,
        customOptions: BookmarkCustomMergeOptions? = nil
    ) -> CapturedRequest {
        switch preset {
        case .authOnly:
            return mergeAuthFields(
                into: bookmarkRequest,
                sourceRequest: sourceRequest,
                includeCookies: false
            )
        case .authAndCookies:
            return mergeAuthFields(
                into: bookmarkRequest,
                sourceRequest: sourceRequest,
                includeCookies: true
            )
        case .headersOnly:
            return mergeHeaders(into: bookmarkRequest, sourceRequest: sourceRequest)
        case .queryAndHeaders:
            return mergeQueryAndHeaders(into: bookmarkRequest, sourceRequest: sourceRequest)
        case .custom:
            return mergeCustom(
                into: bookmarkRequest,
                sourceRequest: sourceRequest,
                options: customOptions ?? suggestedCustomMergeOptions(
                    bookmarkRequest: bookmarkRequest,
                    sourceRequest: sourceRequest
                )
            )
        case .replaceEntireRequest:
            return sourceRequest
        }
    }

    static func availableHeaderNames(for request: CapturedRequest) -> [String] {
        preparedHeadersForMerge(request.headers)
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func availableQueryItemNames(for request: CapturedRequest) -> [String] {
        guard let components = URLComponents(string: normalizedPath(request.path)) else {
            return []
        }

        return Array(Set((components.queryItems ?? []).map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func availableJSONBodyKeys(for request: CapturedRequest) -> [String] {
        guard
            let bodyData = request.bodyData,
            let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return []
        }

        return object.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func suggestedCustomMergeOptions(
        bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest
    ) -> BookmarkCustomMergeOptions {
        let headerNames = availableHeaderNames(for: sourceRequest).filter { isTokenLike(name: $0) || $0.caseInsensitiveCompare("Cookie") == .orderedSame }
        let queryItemNames = availableQueryItemNames(for: sourceRequest).filter(isTokenLike)
        let jsonBodyKeys = availableJSONBodyKeys(for: sourceRequest).filter(isTokenLike)

        return BookmarkCustomMergeOptions(
            headerNames: Set(headerNames),
            queryItemNames: Set(queryItemNames),
            jsonBodyKeys: Set(jsonBodyKeys)
        )
    }

    static func canUseAsBookmarkUpdateSource(_ sourceRequest: CapturedRequest) -> Bool {
        sourceRequest.inspectionKind != .tunneledTLS
    }

    static func bookmarkUpdateLimitationMessage(for sourceRequest: CapturedRequest) -> String? {
        guard sourceRequest.inspectionKind == .tunneledTLS else {
            return nil
        }

        return "This session was tunneled without TLS decryption, so its request details are not safe to merge into a bookmark."
    }

    private static func preparedHeader(_ header: HTTPHeaderField) -> HTTPHeaderField? {
        let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalizedHeaderValue(header.value)

        if name.isEmpty && value.isEmpty {
            return nil
        }

        return HTTPHeaderField(name: name, value: value)
    }

    private static func mergeAuthFields(
        into bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest,
        includeCookies: Bool
    ) -> CapturedRequest {
        let sourceHeaders = Dictionary(
            uniqueKeysWithValues: preparedHeadersForMerge(sourceRequest.headers).map { ($0.name.lowercased(), $0.value) }
        )
        let mergedHeaders = bookmarkRequest.headers.compactMap { existingHeader in
            let key = existingHeader.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isAuthLikeHeaderName(key, includeCookies: includeCookies) else {
                return preparedHeader(existingHeader)
            }

            if let replacementValue = sourceHeaders[key] {
                return preparedHeader(HTTPHeaderField(name: existingHeader.name, value: replacementValue))
            }

            return preparedHeader(existingHeader)
        }

        let mergedPath = mergeQuery(
            existingPath: bookmarkRequest.path,
            sourcePath: sourceRequest.path,
            onlyTokenLikeItems: true
        )
        let mergedBodyData = mergeJSONBodyTokens(
            existingBody: bookmarkRequest.bodyData,
            sourceBody: sourceRequest.bodyData
        ) ?? bookmarkRequest.bodyData

        return CapturedRequest(
            method: bookmarkRequest.method,
            scheme: bookmarkRequest.scheme,
            inspectionKind: bookmarkRequest.inspectionKind,
            inspectionReason: bookmarkRequest.inspectionReason,
            host: bookmarkRequest.host,
            port: bookmarkRequest.port,
            path: mergedPath,
            headers: mergedHeaders,
            bodyData: mergedBodyData,
            bodySize: mergedBodyData?.count
        )
    }

    private static func mergeHeaders(
        into bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest
    ) -> CapturedRequest {
        let mergedHeaders = preparedHeadersForMerge(sourceRequest.headers)

        return CapturedRequest(
            method: bookmarkRequest.method,
            scheme: bookmarkRequest.scheme,
            inspectionKind: bookmarkRequest.inspectionKind,
            inspectionReason: bookmarkRequest.inspectionReason,
            host: bookmarkRequest.host,
            port: bookmarkRequest.port,
            path: bookmarkRequest.path,
            headers: mergedHeaders,
            bodyData: bookmarkRequest.bodyData,
            bodySize: bookmarkRequest.bodySize
        )
    }

    private static func mergeCustom(
        into bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest,
        options: BookmarkCustomMergeOptions
    ) -> CapturedRequest {
        let sourceHeadersByName = Dictionary(
            uniqueKeysWithValues: preparedHeadersForMerge(sourceRequest.headers).map { ($0.name.lowercased(), $0) }
        )

        var mergedHeadersByName = Dictionary(
            uniqueKeysWithValues: preparedHeadersForMerge(bookmarkRequest.headers).map { ($0.name.lowercased(), $0) }
        )
        for selectedName in options.headerNames {
            let key = selectedName.lowercased()
            if let sourceHeader = sourceHeadersByName[key] {
                mergedHeadersByName[key] = sourceHeader
            }
        }

        let mergedPath = mergeSelectedQueryItems(
            existingPath: bookmarkRequest.path,
            sourcePath: sourceRequest.path,
            selectedItemNames: options.queryItemNames
        )
        let mergedBodyData = mergeSelectedJSONFields(
            existingBody: bookmarkRequest.bodyData,
            sourceBody: sourceRequest.bodyData,
            selectedKeys: options.jsonBodyKeys
        ) ?? bookmarkRequest.bodyData

        return CapturedRequest(
            method: bookmarkRequest.method,
            scheme: bookmarkRequest.scheme,
            inspectionKind: bookmarkRequest.inspectionKind,
            inspectionReason: bookmarkRequest.inspectionReason,
            host: bookmarkRequest.host,
            port: bookmarkRequest.port,
            path: mergedPath,
            headers: mergedHeadersByName.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            bodyData: mergedBodyData,
            bodySize: mergedBodyData?.count
        )
    }

    private static func mergeQueryAndHeaders(
        into bookmarkRequest: CapturedRequest,
        sourceRequest: CapturedRequest
    ) -> CapturedRequest {
        let mergedHeaders = preparedHeadersForMerge(sourceRequest.headers)
        let mergedPath = mergeQuery(
            existingPath: bookmarkRequest.path,
            sourcePath: sourceRequest.path,
            onlyTokenLikeItems: false
        )

        return CapturedRequest(
            method: bookmarkRequest.method,
            scheme: bookmarkRequest.scheme,
            inspectionKind: bookmarkRequest.inspectionKind,
            inspectionReason: bookmarkRequest.inspectionReason,
            host: bookmarkRequest.host,
            port: bookmarkRequest.port,
            path: mergedPath,
            headers: mergedHeaders,
            bodyData: bookmarkRequest.bodyData,
            bodySize: bookmarkRequest.bodySize
        )
    }

    private static func preparedHeadersForMerge(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        headers.compactMap(preparedHeader).filter { header in
            !excludedTransportHeaderNames.contains(header.name.lowercased())
        }
    }

    private static func mergeQuery(
        existingPath: String,
        sourcePath: String,
        onlyTokenLikeItems: Bool
    ) -> String {
        let existingComponents = URLComponents(string: normalizedPath(existingPath))
        let sourceComponents = URLComponents(string: normalizedPath(sourcePath))

        guard let sourceQueryItems = sourceComponents?.queryItems, !sourceQueryItems.isEmpty else {
            return normalizedPath(existingPath)
        }

        if !onlyTokenLikeItems {
            var mergedComponents = existingComponents ?? URLComponents()
            mergedComponents.path = (existingComponents?.path.isEmpty == false ? existingComponents?.path : sourceComponents?.path) ?? "/"
            mergedComponents.queryItems = sourceQueryItems
            return mergedComponents.string ?? normalizedPath(existingPath)
        }

        var existingByName = Dictionary(
            uniqueKeysWithValues: (existingComponents?.queryItems ?? []).map { ($0.name.lowercased(), $0) }
        )

        for item in sourceQueryItems where isTokenLike(name: item.name) {
            existingByName[item.name.lowercased()] = item
        }

        var mergedComponents = existingComponents ?? URLComponents()
        mergedComponents.path = existingComponents?.path ?? "/"
        mergedComponents.queryItems = existingByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return mergedComponents.string ?? normalizedPath(existingPath)
    }

    private static func mergeSelectedQueryItems(
        existingPath: String,
        sourcePath: String,
        selectedItemNames: Set<String>
    ) -> String {
        guard !selectedItemNames.isEmpty else {
            return normalizedPath(existingPath)
        }

        let normalizedSelectedNames = Set(selectedItemNames.map { $0.lowercased() })
        let existingComponents = URLComponents(string: normalizedPath(existingPath))
        let sourceComponents = URLComponents(string: normalizedPath(sourcePath))
        let sourceQueryItems = sourceComponents?.queryItems ?? []

        var existingByName = Dictionary(
            uniqueKeysWithValues: (existingComponents?.queryItems ?? []).map { ($0.name.lowercased(), $0) }
        )
        for item in sourceQueryItems where normalizedSelectedNames.contains(item.name.lowercased()) {
            existingByName[item.name.lowercased()] = item
        }

        var mergedComponents = existingComponents ?? URLComponents()
        mergedComponents.path = existingComponents?.path ?? "/"
        mergedComponents.queryItems = existingByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return mergedComponents.string ?? normalizedPath(existingPath)
    }

    private static func mergeJSONBodyTokens(existingBody: Data?, sourceBody: Data?) -> Data? {
        guard
            let existingBody,
            let sourceBody,
            let existingObject = try? JSONSerialization.jsonObject(with: existingBody) as? [String: Any],
            let sourceObject = try? JSONSerialization.jsonObject(with: sourceBody) as? [String: Any]
        else {
            return nil
        }

        var mergedObject = existingObject
        for (key, value) in sourceObject where isTokenLike(name: key) {
            mergedObject[key] = value
        }

        return try? JSONSerialization.data(withJSONObject: mergedObject, options: [.sortedKeys])
    }

    private static func mergeSelectedJSONFields(
        existingBody: Data?,
        sourceBody: Data?,
        selectedKeys: Set<String>
    ) -> Data? {
        guard
            !selectedKeys.isEmpty,
            let existingBody,
            let sourceBody,
            let existingObject = try? JSONSerialization.jsonObject(with: existingBody) as? [String: Any],
            let sourceObject = try? JSONSerialization.jsonObject(with: sourceBody) as? [String: Any]
        else {
            return nil
        }

        let normalizedSelectedKeys = Set(selectedKeys.map { $0.lowercased() })
        var mergedObject = existingObject
        for (key, value) in sourceObject where normalizedSelectedKeys.contains(key.lowercased()) {
            mergedObject[key] = value
        }

        return try? JSONSerialization.data(withJSONObject: mergedObject, options: [.sortedKeys])
    }

    private static func isAuthLikeHeaderName(_ name: String, includeCookies: Bool) -> Bool {
        if !includeCookies, name == "cookie" {
            return false
        }

        return authTokenKeywords.contains { name.contains($0) }
    }

    private static func isTokenLike(name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return authTokenKeywords.contains { normalized.contains($0) }
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            return "/"
        }

        if trimmedPath.hasPrefix("/") {
            return trimmedPath
        }

        if trimmedPath.hasPrefix("?") {
            return "/\(trimmedPath)"
        }

        return "/\(trimmedPath)"
    }

    private static func normalizedBodyData(from bodyData: Data?) -> Data? {
        guard let bodyData, !bodyData.isEmpty else {
            return nil
        }

        return bodyData
    }

    private static func normalizedHeaderValue(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedMimeType(from headers: [HTTPHeaderField]) -> String? {
        guard let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() else {
            return nil
        }

        return contentType
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isLikelyJSON(headers: [HTTPHeaderField]) -> Bool {
        guard let mimeType = normalizedMimeType(from: headers) else {
            return false
        }

        return mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    private static func canParseJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        let unicodeScalars = name.unicodeScalars
        guard !unicodeScalars.isEmpty else {
            return false
        }

        return unicodeScalars.allSatisfy { headerTokenCharacterSet.contains($0) }
    }
}
