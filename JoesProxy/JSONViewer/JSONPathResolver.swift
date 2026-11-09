//
//  JSONPathResolver.swift
//  JoesProxy
//
//  Resolves dot-path strings for JSON field rewrite rules from tree selection or
//  prettified-line context menus.
//

import Foundation

/// Builds and searches bookmark-style JSON dot paths (e.g. `movie.shortDescription`, `items[0].title`).
enum JSONPathResolver {
    /// Builds the dot path for a child node given its parent's path and segment key.
    static func childPath(parentPath: String, segmentKey: String?) -> String {
        guard let segmentKey, !segmentKey.isEmpty else {
            return parentPath
        }

        if segmentKey.hasPrefix("[") {
            return parentPath.isEmpty ? segmentKey : parentPath + segmentKey
        }

        if parentPath.isEmpty {
            return segmentKey
        }

        return "\(parentPath).\(segmentKey)"
    }

    /// Finds all dot paths whose final object key matches `leafKey`.
    static func paths(forLeafKey leafKey: String, in data: Data) -> [String] {
        guard let root = try? JSONTreeParser.parseJSONObject(from: data) else {
            return []
        }

        var results: [String] = []
        collectPaths(forLeafKey: leafKey, value: root, currentPath: "", results: &results)
        return results
    }

    /// Finds dot paths matching both the leaf key and an expected string value (for disambiguation).
    static func paths(forLeafKey leafKey: String, matchingValue: String, in data: Data) -> [String] {
        let candidates = paths(forLeafKey: leafKey, in: data)
        let trimmedValue = matchingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return candidates
        }

        let valueMatches = candidates.filter { path in
            guard let resolved = BookmarkJSONRewriteEngine.value(at: path, in: data) else {
                return false
            }
            return resolved.displayString == trimmedValue
        }

        return valueMatches.isEmpty ? candidates : valueMatches
    }

    /// Parses a prettified JSON line like `"shortDescription" : "Cher's world…",` into key/value tokens.
    static func parsePrettifiedLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\"") else {
            return nil
        }

        guard let closingQuote = trimmed[trimmed.index(after: trimmed.startIndex)...].firstIndex(of: "\"") else {
            return nil
        }

        let keyStart = trimmed.index(after: trimmed.startIndex)
        let key = String(trimmed[keyStart..<closingQuote])
        guard !key.isEmpty else {
            return nil
        }

        let afterKey = trimmed[trimmed.index(after: closingQuote)...]
        guard let colonRange = afterKey.range(of: ":") else {
            return (key, "")
        }

        var rawValue = String(afterKey[colonRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rawValue.hasSuffix(",") {
            rawValue.removeLast()
        }
        rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
            let start = rawValue.index(after: rawValue.startIndex)
            let end = rawValue.index(before: rawValue.endIndex)
            return (key, String(rawValue[start..<end]))
        }

        return (key, rawValue)
    }

    private static func collectPaths(
        forLeafKey leafKey: String,
        value: Any,
        currentPath: String,
        results: inout [String]
    ) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                let childPath = childPath(parentPath: currentPath, segmentKey: key)
                if key == leafKey {
                    results.append(childPath)
                }
                collectPaths(forLeafKey: leafKey, value: child, currentPath: childPath, results: &results)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() {
                let childPath = childPath(parentPath: currentPath, segmentKey: "[\(index)]")
                collectPaths(forLeafKey: leafKey, value: child, currentPath: childPath, results: &results)
            }
        default:
            break
        }
    }
}

extension JSONTreeNode {
    /// The object/array key for this node, when present.
    var segmentKey: String? {
        switch self {
        case .object(let key, _), .array(let key, _), .string(let key, _), .number(let key, _),
             .bool(let key, _), .null(let key):
            return key
        }
    }

    /// Display string for bookmark rewrite override prefill on leaf nodes.
    var leafRewriteValue: String? {
        switch self {
        case .string(_, let value):
            return value
        case .number(_, let value):
            return value
        case .bool(_, let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .object, .array:
            return nil
        }
    }

    /// Whether this node represents a rewriteable JSON scalar leaf.
    var isRewriteableLeaf: Bool {
        switch self {
        case .string, .number, .bool, .null:
            return true
        case .object, .array:
            return false
        }
    }
}
