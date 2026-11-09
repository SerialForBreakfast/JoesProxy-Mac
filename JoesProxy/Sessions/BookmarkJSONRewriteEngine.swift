import Foundation

/// Outcome of applying bookmark JSON field rewrites to a saved response body.
struct BookmarkJSONRewriteResult: Equatable, Sendable {
    let patchedData: Data
    let appliedRuleIDs: [UUID]
    let skippedRuleIDs: [UUID]
}

enum BookmarkJSONRewriteError: LocalizedError, Equatable {
    case invalidJSON
    case invalidPath(String)
    case pathNotFound(String)
    case indexOutOfRange(String)
    case wrongContainerType(String)
    case typeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The saved response body is not valid JSON."
        case .invalidPath(let path):
            return "The JSON path \"\(path)\" is invalid."
        case .pathNotFound(let path):
            return "The JSON path \"\(path)\" was not found in the saved response."
        case .indexOutOfRange(let path):
            return "The array index in \"\(path)\" is out of range."
        case .wrongContainerType(let path):
            return "The JSON path \"\(path)\" targets the wrong container type."
        case .typeMismatch(let path):
            return "The value at \"\(path)\" is not a string."
        }
    }
}

/// Applies dot-path JSON field overrides to bookmark saved-response bodies.
enum BookmarkJSONRewriteEngine {
    private enum PathSegment: Equatable {
        case key(String)
        case index(Int)
        /// `[*]` — every current element of an array. Only ever appears in a locator as parsed;
        /// every value-mutating function operates on a concrete (wildcard-free) path produced by
        /// `resolveConcretePaths`, so encountering `.wildcard` in those functions is a "should
        /// never happen" defensive case, not a reachable runtime state.
        case wildcard
    }

    /// Structured result of applying a neutral `[JSONResponseMutation]` list (AL-2) — one outcome
    /// per mutation `id`, so a caller (real-traffic diagnostics, in particular) knows WHY a
    /// mutation didn't apply, not just that it didn't.
    struct MutationApplyResult: Equatable, Sendable {
        let patchedData: Data
        let outcomes: [UUID: JSONMutationOutcome]
    }

    /// Validates a locator string's syntax using the exact same parser `apply`/`value(at:in:)`
    /// use internally — the single source of truth `MCPMutationValidator` calls, so validation
    /// and execution can never silently disagree about what's a valid locator (a confirmed risk
    /// the validator's own independent string checks previously carried).
    static func validateLocatorSyntax(_ locator: String) throws {
        _ = try parsePath(locator)
    }

    /// Shared syntax check for every operation whose locator terminal must be a single array
    /// index with no `[*]` wildcard anywhere in the path — `.insert`, `.removeIndex`, and `.move`
    /// (its "from" locator) all need exactly this.
    private static func validateIndexTerminalLocatorSyntax(_ locator: String) throws {
        let segments = try parsePath(locator)
        guard let last = segments.last else {
            throw BookmarkJSONRewriteError.invalidPath(locator)
        }
        guard case .index = last else {
            throw BookmarkJSONRewriteError.wrongContainerType(locator)
        }
        guard !segments.contains(where: { if case .wildcard = $0 { return true }; return false }) else {
            throw BookmarkJSONRewriteError.wrongContainerType(locator)
        }
    }

    /// Ensures `locator` ends with an array index segment and contains no `[*]` wildcard anywhere
    /// — required for `.insert` mutations, which need exactly one terminal index to insert at.
    static func validateInsertLocatorSyntax(_ locator: String) throws {
        try validateIndexTerminalLocatorSyntax(locator)
    }

    /// Same syntax requirement as `.insert` — required for `.removeIndex` mutations.
    static func validateRemoveIndexLocatorSyntax(_ locator: String) throws {
        try validateIndexTerminalLocatorSyntax(locator)
    }

    /// Same syntax requirement as `.insert`, applied to `.move`'s "from" locator. `.move`'s "to"
    /// index rides in the mutation's `value`, not a second locator, so there's no separate syntax
    /// to validate for it.
    static func validateMoveLocatorSyntax(_ locator: String) throws {
        try validateIndexTerminalLocatorSyntax(locator)
    }

    /// Parses `.move`'s "to" index out of a `BookmarkJSONValue`, requiring a whole number — same
    /// integer-first parsing `.jsonObjectValue()` uses for `.number`, but `nil` (not a lossy
    /// double) for anything that isn't a clean integer.
    private static func moveTargetIndex(from value: BookmarkJSONValue) -> Int? {
        guard case .number(let raw) = value else { return nil }
        return Int(raw)
    }

    /// Returns whether `locator` is a valid insert target in `bodyData` (parent array exists,
    /// terminal index in `0...array.count`, never clamped).
    static func locatorIsValidForInsert(_ locator: String, in bodyData: Data?) -> Bool {
        guard
            let bodyData,
            !bodyData.isEmpty,
            let jsonObject = try? JSONTreeParser.parseJSONObject(from: bodyData),
            let segments = try? parsePath(locator),
            !segments.isEmpty
        else {
            return false
        }

        return (try? validateInsertTarget(segments: segments, in: jsonObject, fullPath: locator)) != nil
    }

    /// Returns whether `locator` is a valid removeIndex target in `bodyData` (parent array
    /// exists, terminal index in `0..<array.count` — a real element, never clamped).
    static func locatorIsValidForRemoveIndex(_ locator: String, in bodyData: Data?) -> Bool {
        guard
            let bodyData,
            !bodyData.isEmpty,
            let jsonObject = try? JSONTreeParser.parseJSONObject(from: bodyData),
            let segments = try? parsePath(locator),
            !segments.isEmpty
        else {
            return false
        }

        return (try? validateRemoveIndexTarget(segments: segments, in: jsonObject, fullPath: locator)) != nil
    }

    /// Returns whether `locator` (the "from" position) and `overrideValue` (the "to" position, as
    /// a JSON number) together form a valid move target in `bodyData` — both indices must resolve
    /// to real elements of the SAME array (`0..<array.count`).
    static func locatorIsValidForMove(_ locator: String, overrideValue: BookmarkJSONValue?, in bodyData: Data?) -> Bool {
        guard
            let bodyData,
            !bodyData.isEmpty,
            let jsonObject = try? JSONTreeParser.parseJSONObject(from: bodyData),
            let segments = try? parsePath(locator),
            !segments.isEmpty,
            let overrideValue,
            let toIndex = moveTargetIndex(from: overrideValue)
        else {
            return false
        }

        return (try? validateMoveTarget(toIndex: toIndex, segments: segments, in: jsonObject, fullPath: locator)) != nil
    }

    /// Returns whether a rewrite path is valid for the given operation (set resolves an existing
    /// value; insert satisfies `0...count` array semantics; removeIndex/move's "from" resolve to a
    /// real element at `0..<count`, move additionally needing `overrideValue` to resolve a valid
    /// "to"; appendString/prependString resolve to an existing string value at at least one
    /// concrete path; removeProperty resolves to an existing object key).
    static func rewritePathIsValid(
        operation: JSONMutationOperation,
        path: String,
        overrideValue: BookmarkJSONValue? = nil,
        in bodyData: Data?
    ) -> Bool {
        switch operation {
        case .set, .appendString, .prependString, .removeProperty:
            return value(at: path, in: bodyData) != nil
        case .insert:
            return locatorIsValidForInsert(path, in: bodyData)
        case .removeIndex:
            return locatorIsValidForRemoveIndex(path, in: bodyData)
        case .move:
            return locatorIsValidForMove(path, overrideValue: overrideValue, in: bodyData)
        }
    }

    /// Applies a neutral list of JSON mutations to `bodyData`, returning patched bytes plus a
    /// structured outcome per mutation. The primary entry point going forward — `apply(bodyData:
    /// rewrites:)` below adapts `[BookmarkResponseFieldRewrite]` into this model rather than
    /// duplicating the mutation algorithm.
    static func apply(bodyData: Data?, mutations: [JSONResponseMutation]) throws -> MutationApplyResult {
        guard let bodyData, !bodyData.isEmpty else {
            throw BookmarkJSONRewriteError.invalidJSON
        }

        let parseState = LiveRewritePerformanceSignposts.beginParseJSON(bodyBytes: bodyData.count)
        var mutableRoot = try JSONTreeParser.parseJSONObject(from: bodyData)
        LiveRewritePerformanceSignposts.endParseJSON(parseState)
        var outcomes: [UUID: JSONMutationOutcome] = [:]

        let mutationLoopState = LiveRewritePerformanceSignposts.beginMutationLoop(mutationCount: mutations.count)
        for mutation in mutations {
            do {
                let segments = try parsePath(mutation.locator)
                guard !segments.isEmpty else {
                    throw BookmarkJSONRewriteError.invalidPath(mutation.locator)
                }
                let hasWildcard = segments.contains { if case .wildcard = $0 { return true }; return false }

                if hasWildcard {
                    // Wildcard fan-out combined with an index-mutating (not index-reading)
                    // operation is nonsensical for the same reason across all three: `.insert`,
                    // `.removeIndex`, and `.move` each need exactly one concrete terminal index,
                    // not "every matching index."
                    guard mutation.operation != .insert,
                          mutation.operation != .removeIndex,
                          mutation.operation != .move else {
                        throw BookmarkJSONRewriteError.wrongContainerType(mutation.locator)
                    }
                    let concretePaths = try resolveConcretePaths(
                        segments: segments,
                        in: mutableRoot,
                        fullPath: mutation.locator
                    )
                    if concretePaths.isEmpty {
                        outcomes[mutation.id] = .wildcardMatchedNothing
                        continue
                    }
                    var appliedAny = false
                    var lastOutcome: JSONMutationOutcome?
                    for concretePath in concretePaths {
                        do {
                            try applyOneOperation(mutation: mutation, segments: concretePath, in: &mutableRoot)
                            appliedAny = true
                        } catch let error as BookmarkJSONRewriteError {
                            lastOutcome = outcome(for: error)
                        } catch {
                            lastOutcome = .invalidLocator
                        }
                    }
                    outcomes[mutation.id] = appliedAny ? .applied : (lastOutcome ?? .wildcardMatchedNothing)
                } else {
                    try applyOneOperation(mutation: mutation, segments: segments, in: &mutableRoot)
                    outcomes[mutation.id] = .applied
                }
            } catch let error as BookmarkJSONRewriteError {
                outcomes[mutation.id] = outcome(for: error)
            } catch {
                outcomes[mutation.id] = .invalidLocator
            }
        }
        LiveRewritePerformanceSignposts.endMutationLoop(mutationLoopState)

        let serializeState = LiveRewritePerformanceSignposts.beginSerializeJSON()
        let patchedData = try JSONSerialization.data(withJSONObject: mutableRoot, options: [])
        LiveRewritePerformanceSignposts.endSerializeJSON(serializeState)
        return MutationApplyResult(patchedData: patchedData, outcomes: outcomes)
    }

    private static func outcome(for error: BookmarkJSONRewriteError) -> JSONMutationOutcome {
        switch error {
        case .invalidJSON:
            return .unsupportedResponse
        case .invalidPath:
            return .invalidLocator
        case .pathNotFound:
            return .parentMissing
        case .indexOutOfRange:
            return .indexOutOfRange
        case .wrongContainerType:
            return .wrongContainerType
        case .typeMismatch:
            return .typeMismatch
        }
    }

    /// Applies enabled rewrite rules to `bodyData` and returns patched JSON bytes. Adapts
    /// `[BookmarkResponseFieldRewrite]` into the neutral `[JSONResponseMutation]` model and
    /// delegates to `apply(bodyData:mutations:)` — existing callers keep this exact signature and
    /// behavior; only the internals are now expressed in terms of the neutral model.
    static func apply(
        bodyData: Data?,
        rewrites: [BookmarkResponseFieldRewrite]
    ) throws -> BookmarkJSONRewriteResult {
        let enabledRewrites = rewrites.filter(\.isRuleEnabled)
        let mutations = enabledRewrites.map {
            JSONResponseMutation(
                id: $0.id,
                locator: $0.jsonPath,
                operation: $0.operation,
                value: $0.overrideValue,
                repeatPolicy: $0.repeatPolicy ?? .always
            )
        }
        let result = try apply(bodyData: bodyData, mutations: mutations)
        let appliedRuleIDs = mutations.compactMap { result.outcomes[$0.id] == .applied ? $0.id : nil }
        let skippedRuleIDs = mutations.compactMap { result.outcomes[$0.id] != .applied ? $0.id : nil }
        return BookmarkJSONRewriteResult(
            patchedData: result.patchedData,
            appliedRuleIDs: appliedRuleIDs,
            skippedRuleIDs: skippedRuleIDs
        )
    }

    /// Reads the JSON value at `path` for UI prefill when creating a rewrite rule.
    static func value(at path: String, in bodyData: Data?) -> BookmarkJSONValue? {
        guard
            let bodyData,
            !bodyData.isEmpty,
            let jsonObject = try? JSONTreeParser.parseJSONObject(from: bodyData),
            let rawValue = try? readValue(at: path, from: jsonObject)
        else {
            return nil
        }

        return BookmarkJSONValue.from(jsonValue: rawValue)
    }

    private static func setValue(_ value: Any, at path: String, in root: inout Any) throws {
        let segments = try parsePath(path)
        guard !segments.isEmpty else {
            throw BookmarkJSONRewriteError.invalidPath(path)
        }

        try setValue(value, segments: segments, in: &root, fullPath: path)
    }

    private static func insertValue(_ value: Any, at path: String, in root: inout Any) throws {
        let segments = try parsePath(path)
        guard !segments.isEmpty else {
            throw BookmarkJSONRewriteError.invalidPath(path)
        }

        try insertValue(value, segments: segments, in: &root, fullPath: path)
    }

    private static func setValue(
        _ value: Any,
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            return
        }

        if segments.count == 1 {
            try assignSetValue(value, to: first, in: &root, fullPath: fullPath)
            return
        }

        guard var container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try setValue(value, segments: Array(segments.dropFirst()), in: &container, fullPath: fullPath)
        try assignSetValue(container, to: first, in: &root, fullPath: fullPath)
    }

    private static func insertValue(
        _ value: Any,
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            return
        }

        if segments.count == 1 {
            try assignInsertValue(value, to: first, in: &root, fullPath: fullPath)
            return
        }

        guard var container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try insertValue(value, segments: Array(segments.dropFirst()), in: &container, fullPath: fullPath)
        try assignSetValue(container, to: first, in: &root, fullPath: fullPath)
    }

    private static func removeIndexValue(
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try assignRemoveIndexValue(to: first, in: &root, fullPath: fullPath)
            return
        }

        guard var container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try removeIndexValue(segments: Array(segments.dropFirst()), in: &container, fullPath: fullPath)
        try assignSetValue(container, to: first, in: &root, fullPath: fullPath)
    }

    /// Entry point matching `applyOneOperation`'s call shape — parses `value` into a "to" index,
    /// then delegates to the segment-recursing overload below.
    private static func moveValue(
        _ value: BookmarkJSONValue,
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let toIndex = moveTargetIndex(from: value) else {
            throw BookmarkJSONRewriteError.typeMismatch(fullPath)
        }
        try moveValue(toIndex: toIndex, segments: segments, in: &root, fullPath: fullPath)
    }

    private static func moveValue(
        toIndex: Int,
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try assignMoveValue(toIndex: toIndex, from: first, in: &root, fullPath: fullPath)
            return
        }

        guard var container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try moveValue(toIndex: toIndex, segments: Array(segments.dropFirst()), in: &container, fullPath: fullPath)
        try assignSetValue(container, to: first, in: &root, fullPath: fullPath)
    }

    private static func readValue(at path: String, from root: Any) throws -> Any {
        let segments = try parsePath(path)
        return try readValue(segments: segments, from: root, fullPath: path)
    }

    private static func readValue(segments: [PathSegment], from root: Any, fullPath: String) throws -> Any {
        var cursor = root

        for segment in segments {
            guard let next = try containerValue(for: segment, in: cursor, fullPath: fullPath) else {
                throw BookmarkJSONRewriteError.pathNotFound(fullPath)
            }
            cursor = next
        }

        return cursor
    }

    /// Dispatches one mutation's operation against a concrete (wildcard-free) segment path.
    private static func applyOneOperation(
        mutation: JSONResponseMutation,
        segments: [PathSegment],
        in root: inout Any
    ) throws {
        switch mutation.operation {
        case .set:
            try setValue(mutation.value.jsonObjectValue(), segments: segments, in: &root, fullPath: mutation.locator)
        case .insert:
            try insertValue(mutation.value.jsonObjectValue(), segments: segments, in: &root, fullPath: mutation.locator)
        case .appendString, .prependString:
            try applyStringEdit(
                literal: mutation.value.jsonObjectValue(),
                operation: mutation.operation,
                repeatPolicy: mutation.repeatPolicy,
                segments: segments,
                in: &root,
                fullPath: mutation.locator
            )
        case .removeProperty:
            try removeProperty(segments: segments, in: &root, fullPath: mutation.locator)
        case .removeIndex:
            try removeIndexValue(segments: segments, in: &root, fullPath: mutation.locator)
        case .move:
            try moveValue(mutation.value, segments: segments, in: &root, fullPath: mutation.locator)
        }
    }

    /// Expands any `[*]` wildcard segments in `segments` into every concrete `.index` combination
    /// actually present in `root`, by walking to each wildcard's array and fanning out over its
    /// current indices — recursing into each element for any further wildcard deeper in the path
    /// (handles nested wildcards like `$.channels[*].programs[*].title`). An empty result means
    /// the wildcard(s) matched zero elements, not an error — callers must report this distinctly
    /// from `.applied`, never silently as success.
    private static func resolveConcretePaths(
        segments: [PathSegment],
        in root: Any,
        fullPath: String
    ) throws -> [[PathSegment]] {
        guard let wildcardIndex = segments.firstIndex(where: { if case .wildcard = $0 { return true }; return false }) else {
            return [segments]
        }

        let prefix = Array(segments[..<wildcardIndex])
        let suffix = Array(segments[(wildcardIndex + 1)...])

        let container = try readValue(segments: prefix, from: root, fullPath: fullPath)
        guard let array = container as? [Any] else {
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        }

        var results: [[PathSegment]] = []
        for elementIndex in array.indices {
            let concretePrefix = prefix + [.index(elementIndex)]
            let expandedSuffixes = try resolveConcretePaths(segments: suffix, in: array[elementIndex], fullPath: fullPath)
            for expandedSuffix in expandedSuffixes {
                results.append(concretePrefix + expandedSuffix)
            }
        }
        return results
    }

    /// Applies `.appendString`/`.prependString` to the string value at `segments`. Never coerces
    /// a non-string value — reports `.typeMismatch` instead.
    private static func applyStringEdit(
        literal: Any,
        operation: JSONMutationOperation,
        repeatPolicy: JSONMutationRepeatPolicy,
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let literalString = literal as? String else {
            throw BookmarkJSONRewriteError.typeMismatch(fullPath)
        }
        let currentValue = try readValue(segments: segments, from: root, fullPath: fullPath)
        guard let currentString = currentValue as? String else {
            throw BookmarkJSONRewriteError.typeMismatch(fullPath)
        }

        let newString: String
        switch operation {
        case .appendString:
            if repeatPolicy == .ifMissingSuffix, currentString.hasSuffix(literalString) {
                newString = currentString
            } else {
                newString = currentString + literalString
            }
        case .prependString:
            if repeatPolicy == .ifMissingSuffix, currentString.hasPrefix(literalString) {
                newString = currentString
            } else {
                newString = literalString + currentString
            }
        case .set, .insert, .removeProperty, .removeIndex, .move:
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        try setValue(newString, segments: segments, in: &root, fullPath: fullPath)
    }

    /// Removes an object key. Rejects an array-index terminal — removing "an index" isn't a
    /// well-defined operation in this model (use `.set` with a rebuilt array instead).
    private static func removeProperty(
        segments: [PathSegment],
        in root: inout Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try assignRemoveValue(to: first, in: &root, fullPath: fullPath)
            return
        }

        guard var container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try removeProperty(segments: Array(segments.dropFirst()), in: &container, fullPath: fullPath)
        try assignSetValue(container, to: first, in: &root, fullPath: fullPath)
    }

    private static func assignRemoveValue(
        to segment: PathSegment,
        in root: inout Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key(let key):
            guard var object = root as? [String: Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard object.keys.contains(key) else {
                throw BookmarkJSONRewriteError.pathNotFound(fullPath)
            }
            object.removeValue(forKey: key)
            root = object
        case .index, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        }
    }

    private static func validateInsertTarget(
        segments: [PathSegment],
        in root: Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try validateInsertTerminal(first, in: root, fullPath: fullPath)
            return
        }

        guard let container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try validateInsertTarget(
            segments: Array(segments.dropFirst()),
            in: container,
            fullPath: fullPath
        )
    }

    private static func validateInsertTerminal(
        _ segment: PathSegment,
        in root: Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let index):
            guard var array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard index >= 0, index <= array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            _ = array
        }
    }

    private static func validateRemoveIndexTarget(
        segments: [PathSegment],
        in root: Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try validateRemoveIndexTerminal(first, in: root, fullPath: fullPath)
            return
        }

        guard let container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try validateRemoveIndexTarget(
            segments: Array(segments.dropFirst()),
            in: container,
            fullPath: fullPath
        )
    }

    private static func validateRemoveIndexTerminal(
        _ segment: PathSegment,
        in root: Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let index):
            guard let array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard index >= 0, index < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
        }
    }

    private static func validateMoveTarget(
        toIndex: Int,
        segments: [PathSegment],
        in root: Any,
        fullPath: String
    ) throws {
        guard let first = segments.first else {
            throw BookmarkJSONRewriteError.invalidPath(fullPath)
        }

        if segments.count == 1 {
            try validateMoveTerminal(toIndex: toIndex, first, in: root, fullPath: fullPath)
            return
        }

        guard let container = try containerValue(for: first, in: root, fullPath: fullPath) else {
            throw BookmarkJSONRewriteError.pathNotFound(fullPath)
        }

        try validateMoveTarget(
            toIndex: toIndex,
            segments: Array(segments.dropFirst()),
            in: container,
            fullPath: fullPath
        )
    }

    /// Both `from` (the locator's terminal index) and `to` must resolve to a real element of the
    /// SAME array — bounds are evaluated against the array's length before any removal, since a
    /// valid "to" position is expressed in terms of the array as it exists now, not the
    /// transiently-shorter array mid-move (see `assignMoveValue` for why the apply-time bound
    /// must use this same pre-removal count).
    private static func validateMoveTerminal(
        toIndex: Int,
        _ segment: PathSegment,
        in root: Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let fromIndex):
            guard let array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard fromIndex >= 0, fromIndex < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            guard toIndex >= 0, toIndex < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
        }
    }

    private static func parsePath(_ path: String) throws -> [PathSegment] {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else {
            return []
        }

        var segments: [PathSegment] = []
        var currentKey = ""
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "." {
                if !currentKey.isEmpty {
                    segments.append(.key(currentKey))
                    currentKey = ""
                }
                index = trimmed.index(after: index)
                continue
            }

            if character == "[" {
                if !currentKey.isEmpty {
                    segments.append(.key(currentKey))
                    currentKey = ""
                }
                guard let closingIndex = trimmed[index...].firstIndex(of: "]") else {
                    throw BookmarkJSONRewriteError.invalidPath(path)
                }
                let indexToken = trimmed[trimmed.index(after: index)..<closingIndex]
                if indexToken == "*" {
                    segments.append(.wildcard)
                } else {
                    guard let arrayIndex = Int(indexToken), arrayIndex >= 0 else {
                        throw BookmarkJSONRewriteError.invalidPath(path)
                    }
                    segments.append(.index(arrayIndex))
                }
                index = trimmed.index(after: closingIndex)
                continue
            }

            currentKey.append(character)
            index = trimmed.index(after: index)
        }

        if !currentKey.isEmpty {
            segments.append(.key(currentKey))
        }

        return segments
    }

    private static func containerValue(
        for segment: PathSegment,
        in value: Any,
        fullPath: String
    ) throws -> Any? {
        switch segment {
        case .key(let key):
            guard let object = value as? [String: Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            return object[key]
        case .index(let index):
            guard let array = value as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard array.indices.contains(index) else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            return array[index]
        case .wildcard:
            // Concrete-path callers never pass a `.wildcard` here — `resolveConcretePaths` is the
            // only place that inspects a wildcard segment itself, via `readValue`'s prefix walk.
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        }
    }

    private static func assignSetValue(
        _ value: Any,
        to segment: PathSegment,
        in root: inout Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key(let key):
            var object = root as? [String: Any] ?? [:]
            object[key] = value
            root = object
        case .index(let index):
            guard var array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard array.indices.contains(index) else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            array[index] = value
            root = array
        case .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        }
    }

    private static func assignInsertValue(
        _ value: Any,
        to segment: PathSegment,
        in root: inout Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let index):
            guard var array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard index >= 0, index <= array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            array.insert(value, at: index)
            root = array
        }
    }

    private static func assignRemoveIndexValue(
        to segment: PathSegment,
        in root: inout Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let index):
            guard var array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard index >= 0, index < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            array.remove(at: index)
            root = array
        }
    }

    /// Moves the element at `from` (the locator's terminal index) to `toIndex` within the same
    /// array — a single remove-then-insert against one local `array` copy, so this stays atomic
    /// even though a batch of mutations is not (see `apply(bodyData:mutations:)`). Both bounds are
    /// checked against `array.count` BEFORE the removal: `toIndex` is "where this element should
    /// end up in the array as it exists now," not an index into the transiently-shorter array —
    /// checking post-removal would wrongly reject moving an element to the last position (e.g.
    /// moving index 0 to index 3 in a 4-element array is valid; after removal the array has only
    /// 3 elements, so a post-removal `0..<3` bound would incorrectly reject `toIndex: 3`).
    private static func assignMoveValue(
        toIndex: Int,
        from segment: PathSegment,
        in root: inout Any,
        fullPath: String
    ) throws {
        switch segment {
        case .key, .wildcard:
            throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
        case .index(let fromIndex):
            guard var array = root as? [Any] else {
                throw BookmarkJSONRewriteError.wrongContainerType(fullPath)
            }
            guard fromIndex >= 0, fromIndex < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            guard toIndex >= 0, toIndex < array.count else {
                throw BookmarkJSONRewriteError.indexOutOfRange(fullPath)
            }
            let element = array.remove(at: fromIndex)
            array.insert(element, at: toIndex)
            root = array
        }
    }
}
