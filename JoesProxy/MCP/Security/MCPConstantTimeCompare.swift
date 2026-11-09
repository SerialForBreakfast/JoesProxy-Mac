import Foundation

/// Constant-time byte comparison for authentication material (credential digests, verifiers).
/// Shared by the production client registry and the AG-0 transport spike so both compare
/// credential-derived values the same, timing-safe way rather than via `Data`'s default `==`,
/// which short-circuits on the first differing byte.
enum MCPConstantTimeCompare {
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
