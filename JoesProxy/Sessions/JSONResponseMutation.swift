import Foundation

/// Neutral request to mutate one JSON value in an HTTP response body — the model every rewrite
/// mechanism (today: bookmark-saved-snapshot rewrites; later: a live-response rewrite fault that
/// patches a real backend's response) adapts into at its own boundary, so the core mutation engine
/// (`BookmarkJSONRewriteEngine`) has no dependency on bookmark-specific persistence types. See
/// `.claude/plans/we-must-do-aj-2-jazzy-galaxy.md` (AL-2) for the design rationale.
struct JSONResponseMutation: Equatable, Sendable {
    /// Correlates this mutation back to whatever the caller identifies it by — a bookmark
    /// rewrite's own `id`, or a synthetic per-call identifier for a caller with no natural one.
    var id: UUID
    /// Restricted dot/bracket locator grammar (e.g. `$.data.items[0].name`) — deliberately NOT
    /// called "JSONPath": there is no support for wildcards, filters, quoted keys, recursive
    /// descent, or escaped property names. `BookmarkJSONRewriteEngine.validateLocatorSyntax(_:)`
    /// is the single parser both this engine and `MCPMutationValidator` use, so validation and
    /// execution can never silently disagree about what's a valid locator.
    var locator: String
    var operation: JSONMutationOperation
    var value: BookmarkJSONValue
    /// Only consulted by `.appendString`/`.prependString`; ignored otherwise.
    var repeatPolicy: JSONMutationRepeatPolicy

    init(
        id: UUID = UUID(),
        locator: String,
        operation: JSONMutationOperation = .set,
        value: BookmarkJSONValue,
        repeatPolicy: JSONMutationRepeatPolicy = .always
    ) {
        self.id = id
        self.locator = locator
        self.operation = operation
        self.value = value
        self.repeatPolicy = repeatPolicy
    }
}

enum JSONMutationOperation: String, Equatable, Sendable, Codable, CaseIterable {
    /// Overwrite the value at an existing object key or array index.
    case set
    /// Insert a new element at an array index (see AL-3 for precise `0...count` semantics);
    /// unsupported for object keys. MCP callers may also spell this `insertArrayElement` — see
    /// `MCPMutationValidator.parseRewriteOperation` for that translation; there is no separate
    /// internal case, to avoid doubling every exhaustive switch for identical behavior.
    case insert
    /// Append a literal string to an existing string value. Type mismatch on a non-string value
    /// is reported as `.typeMismatch` and never silently coerced.
    case appendString
    /// Prepend a literal string to an existing string value. Same type-mismatch contract as
    /// `.appendString`.
    case prependString
    /// Remove an object key. Unsupported for array-index terminals — removing "an index" is not
    /// a well-defined operation in this model (use `.set` with a rebuilt array instead).
    case removeProperty
    /// Remove the array element at the locator's terminal index. Symmetric to `.insert` but the
    /// reverse: strict `0..<count` (an existing element, not an insertion slot — unlike
    /// `.insert`'s `0...count`). Unsupported for object keys; rejects a supplied value, like
    /// `.removeProperty`.
    case removeIndex
    /// Move the array element at the locator's terminal index (the "from" position) to a
    /// different index within the SAME array — the "to" position, carried in `value` as a JSON
    /// number rather than a second locator, so this stays a plain `String`-backed case with no
    /// associated values. Both `from` and `to` are strict `0..<count`. Applied as a single
    /// remove-then-insert against one local array copy so the edit stays atomic even though a
    /// batch of mutations is not (see `BookmarkJSONRewriteEngine.apply(bodyData:mutations:)`).
    case move

    var title: String {
        switch self {
        case .set:
            return "Set"
        case .insert:
            return "Insert"
        case .appendString:
            return "Append String"
        case .prependString:
            return "Prepend String"
        case .removeProperty:
            return "Remove Property"
        case .removeIndex:
            return "Remove Index"
        case .move:
            return "Move"
        }
    }
}

/// Governs whether `.appendString`/`.prependString` mutates unconditionally or only when the
/// current value doesn't already carry the literal — the latter is what makes repeated
/// application to a response that's never mutated at its origin idempotent by choice, rather
/// than accumulating "!!!" across repeated live-traffic hits.
enum JSONMutationRepeatPolicy: String, Equatable, Sendable, Codable, CaseIterable {
    /// Always mutate, even if the value already carries the literal.
    case always
    /// For `.appendString`, skip when the value already ends with the literal; for
    /// `.prependString`, skip when it already starts with the literal.
    case ifMissingSuffix
}

/// Structured result of attempting one `JSONResponseMutation`. Real-traffic diagnostics need to
/// know WHY a mutation didn't apply, not just that it didn't — the pre-AL-2 engine only tracked
/// applied/skipped IDs and discarded the reason.
enum JSONMutationOutcome: Equatable, Sendable {
    case applied
    /// The locator string itself failed to parse (malformed bracket syntax, empty segment, etc).
    case invalidLocator
    /// A non-terminal segment's container (object key or array index) does not exist.
    case parentMissing
    /// A segment expected one container type (object or array) but found the other.
    case wrongContainerType
    /// The terminal array index does not exist for `.set`/`.removeIndex`, is out of the valid
    /// insert range for `.insert`, or (for `.move`) either the `from` or `to` index is out of range.
    case indexOutOfRange
    /// The response body itself could not be treated as JSON at all.
    case unsupportedResponse
    /// The response body exceeded a size limit before mutation was attempted.
    case bodyTooLarge
    /// `.appendString`/`.prependString` targeted a non-string value. Never silently coerced.
    case typeMismatch
    /// A `[*]` wildcard segment resolved to zero array elements (empty array, or a prefix
    /// container that itself didn't exist deep enough to reach the wildcard). Distinct from
    /// `.applied` — a wildcard matching nothing must never be reported as success.
    case wildcardMatchedNothing
}
