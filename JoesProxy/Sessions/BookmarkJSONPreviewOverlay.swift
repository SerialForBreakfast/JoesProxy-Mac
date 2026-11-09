import Foundation

/// Surgical in-viewer preview for bookmark response field rewrites without re-parsing the full body.
enum BookmarkJSONPreviewOverlay {
    /// Above this count of enabled rewrites, preview falls back to full ``BookmarkJSONRewriteEngine`` apply.
    static let fullBodyPreviewRewriteThreshold = 10

    /// Returns whether preview should replace the entire saved response body (large rewrite sets).
    static func shouldUseFullBodyPreview(enabledRewriteCount: Int) -> Bool {
        enabledRewriteCount > fullBodyPreviewRewriteThreshold
    }

    /// Returns whether any enabled rewrite uses array insert semantics.
    static func containsInsertOperations(_ rewrites: [BookmarkResponseFieldRewrite]) -> Bool {
        rewrites.contains { $0.isRuleEnabled && $0.operation == .insert }
    }

    /// Returns whether preview should run the full rewrite engine (insert rules or large rewrite sets).
    static func shouldUseEngineBackedPreview(for rewrites: [BookmarkResponseFieldRewrite]) -> Bool {
        let enabledCount = rewrites.filter(\.isRuleEnabled).count
        return shouldUseFullBodyPreview(enabledRewriteCount: enabledCount)
            || containsInsertOperations(rewrites)
    }

    /// Applies enabled rewrites through the engine when insert semantics or rewrite count require it.
    static func previewBodyData(base: Data?, rewrites: [BookmarkResponseFieldRewrite]) -> Data? {
        guard let base else { return nil }
        guard shouldUseEngineBackedPreview(for: rewrites) else {
            return base
        }

        return try? BookmarkJSONRewriteEngine.apply(bodyData: base, rewrites: rewrites).patchedData
    }

    /// Maps enabled rewrite dot paths to override values for surgical preview display.
    static func overrides(from rewrites: [BookmarkResponseFieldRewrite]) -> [String: BookmarkJSONValue] {
        guard !shouldUseEngineBackedPreview(for: rewrites) else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: rewrites
                .filter(\.isRuleEnabled)
                .filter { $0.operation == .set }
                .map { rewrite in
                    (
                        rewrite.jsonPath.trimmingCharacters(in: .whitespacesAndNewlines),
                        rewrite.overrideValue
                    )
                }
                .filter { !$0.0.isEmpty }
        )
    }

    /// Applies override values to a prettified JSON string by replacing matching key lines.
    static func patchedPrettifiedText(
        base: String,
        bodyData: Data,
        overrides: [String: BookmarkJSONValue]
    ) -> String {
        guard !overrides.isEmpty else {
            return base
        }

        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (path, override) in overrides {
            guard let original = BookmarkJSONRewriteEngine.value(at: path, in: bodyData) else {
                continue
            }

            let leafKey = leafKey(from: path)
            let formattedOverride = prettifiedToken(for: override)
            for index in lines.indices {
                guard let parsed = JSONPathResolver.parsePrettifiedLine(lines[index]),
                      parsed.key == leafKey,
                      parsed.value == original.displayString else {
                    continue
                }

                lines[index] = replaceValue(inPrettifiedLine: lines[index], formattedValue: formattedOverride)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a folder-tree label with the override value substituted when `dotPath` matches.
    static func patchedTreeLabel(
        for node: JSONTreeNode,
        dotPath: String,
        override: BookmarkJSONValue
    ) -> String {
        switch node {
        case .string(let key, _):
            return scalarTreeLabel(key: key, formattedValue: "\"\(escapeString(override.displayString))\"")
        case .number(let key, _):
            return scalarTreeLabel(key: key, formattedValue: override.displayString)
        case .bool(let key, _):
            let boolText: String
            switch override {
            case .bool(let value):
                boolText = String(value)
            default:
                boolText = override.displayString
            }
            return scalarTreeLabel(key: key, formattedValue: boolText)
        case .null(let key):
            return scalarTreeLabel(key: key, formattedValue: "null")
        case .array(_, _), .object(_, _):
            return node.label
        }
    }

    private static func scalarTreeLabel(key: String?, formattedValue: String) -> String {
        if let key {
            let truncated = formattedValue.count > 60 ? String(formattedValue.prefix(60)) + "…" : formattedValue
            return "\(key): \(truncated)"
        }
        return formattedValue
    }

    private static func leafKey(from path: String) -> String {
        if let bracketRange = path.range(of: #"\[\d+\]$"#, options: .regularExpression) {
            let beforeBracket = String(path[..<bracketRange.lowerBound])
            return beforeBracket.split(separator: ".").last.map(String.init) ?? beforeBracket
        }
        return path.split(separator: ".").last.map(String.init) ?? path
    }

    private static func prettifiedToken(for value: BookmarkJSONValue) -> String {
        switch value {
        case .string(let string):
            return "\"\(escapeString(string))\""
        case .bool(let bool):
            return bool ? "true" : "false"
        case .number(let number):
            return number
        case .null:
            return "null"
        case .array, .object:
            return value.displayString
        }
    }

    private static func escapeString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func replaceValue(inPrettifiedLine line: String, formattedValue: String) -> String {
        guard let parsed = JSONPathResolver.parsePrettifiedLine(line) else {
            return line
        }

        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        return "\(indent)\"\(parsed.key)\" : \(formattedValue),"
    }
}
