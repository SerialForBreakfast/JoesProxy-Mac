import Foundation

/// Explicit paths retain the captured origin and client. No request is made to establish provenance.
enum CapturedMockExplicitTarget {
    static func scope(path: Any, source: CapturedRequest, clientAddress: String,
                      field: String, hasObservedTarget: Bool, hasIgnoredQueryNames: Bool) throws -> CapturedMockScope {
        guard !hasObservedTarget, !hasIgnoredQueryNames else {
            throw CapturedMockPreparationFailure(reason: "conflictingTarget", field: field,
                recovery: "Choose targetPath alone for an exact authored destination, or targetSessionID for an observed destination. Authored paths cannot ignore query names.")
        }
        guard let path = path as? String, !path.isEmpty, path.utf8.count <= 4_096,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              !path.contains("#") else {
            throw CapturedMockPreparationFailure(reason: "invalidTargetPath", field: field,
                recovery: "Supply a root-relative path with an optional exact query, at most 4096 UTF-8 bytes. Use percent-encoded spaces; do not include an origin, fragment or control characters.")
        }
        let scope = CapturedMockScope(host: source.host, scheme: source.scheme,
            port: source.port ?? (source.scheme == .https ? 443 : 80), path: path,
            clients: .address(clientAddress))
        try CapturedMockPreparationFailure.atField(field,
            recovery: "Select a valid captured origin and explicit target client; no upstream request was made.") {
            try CapturedMockPackageCompiler.validate(scope)
        }
        return scope
    }
}
