import Foundation

/// Resolves local JSON Pointer `$ref` values. Never fetches the network.
struct OpenAPIMockRefResolver {
    let root: [String: Any]

    /// Follows `#/…` pointers with cycle detection and ``OpenAPIMockPackBudget/maxRefDepth``.
    ///
    /// - Parameters:
    ///   - ref: OpenAPI `$ref` string.
    ///   - stack: Pointers already being resolved; mutated for the duration of the call.
    /// - Returns: The referenced JSON value.
    func resolve(_ ref: String, stack: inout [String]) throws -> Any {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "#" || trimmed.hasPrefix("#/") else {
            throw OpenAPIMockCompilerError.remoteRef(trimmed)
        }
        if stack.contains(trimmed) {
            throw OpenAPIMockCompilerError.refCycle(trimmed)
        }
        let nextDepth = stack.count + 1
        do {
            try OpenAPIMockPackBudget.validateRefDepth(nextDepth)
        } catch let error as OpenAPIMockPackError {
            throw OpenAPIMockCompilerError.pack(error)
        }
        stack.append(trimmed)
        defer { _ = stack.popLast() }

        var current: Any = root
        if trimmed != "#" {
            let pointer = String(trimmed.dropFirst())
            for rawToken in pointer.split(separator: "/", omittingEmptySubsequences: true) {
                let token = Self.unescape(String(rawToken))
                if let dictionary = current as? [String: Any], let next = dictionary[token] {
                    current = next
                } else if let array = current as? [Any], let index = Int(token), array.indices.contains(index) {
                    current = array[index]
                } else {
                    throw OpenAPIMockCompilerError.refNotFound(trimmed)
                }
            }
        }

        if let dictionary = current as? [String: Any], let nested = dictionary["$ref"] as? String {
            return try resolve(nested, stack: &stack)
        }
        return current
    }

    /// Resolves `$ref` when `node` is a wrapper object; otherwise returns `node`.
    func resolveNode(_ node: Any, stack: inout [String]) throws -> Any {
        guard let dictionary = node as? [String: Any], let ref = dictionary["$ref"] as? String else {
            return node
        }
        return try resolve(ref, stack: &stack)
    }

    /// Resolves a schema object, following `$ref` until a concrete schema remains.
    func resolveSchema(_ schema: [String: Any], stack: inout [String]) throws -> [String: Any] {
        let resolved = try resolveNode(schema, stack: &stack)
        guard let dictionary = resolved as? [String: Any] else {
            throw OpenAPIMockCompilerError.refNotFound("$ref did not resolve to an object")
        }
        if dictionary["$ref"] is String {
            return try resolveSchema(dictionary, stack: &stack)
        }
        return dictionary
    }

    private static func unescape(_ token: String) -> String {
        token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}
