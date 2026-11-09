import Foundation

/// Keeps every non-exempt query item, including duplicate values and nil-versus-empty values.
enum CapturedQueryMatcher {
    static func canonicalPath(_ path: String, ignoring names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return canonical(path, ignoring: names)
    }

    static func exactCanonicalPath(_ path: String) -> String? {
        canonical(path, ignoring: [])
    }

    private static func canonical(_ path: String, ignoring names: [String]) -> String? {
        guard names.count <= 16, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              path.hasPrefix("/"), !path.hasPrefix("//"),
              var parts = URLComponents(string: path), parts.host == nil,
              parts.scheme == nil, parts.fragment == nil else { return nil }
        let ignored = Set(names)
        let retained = (parts.queryItems ?? []).filter { !ignored.contains($0.name) }.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.value == nil { return $1.value != nil }
            if $1.value == nil { return false }
            return $0.value! < $1.value!
        }
        parts.queryItems = retained.isEmpty ? nil : retained
        return parts.string
    }

    static func matches(_ request: String, baseline: String, ignoring names: [String]) -> Bool {
        guard let expected = canonicalPath(baseline, ignoring: names),
              let actual = canonicalPath(request, ignoring: names) else { return false }
        return expected == actual
    }
}
