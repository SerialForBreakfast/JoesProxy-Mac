import CryptoKit
import Foundation

/// A stable hash of a `JSONShape`'s structure — property names, scalar types, and array
/// element shape — explicitly never values, key order, or whitespace. Two structurally-identical
/// bodies with different values produce the same fingerprint; a body with an added, removed, or
/// renamed property produces a different one. Cardinality (element count) is deliberately excluded
/// from the hash — an array growing from 2 to 3 elements is not a schema change.
///
/// Follows `MCPTargetRevisionFingerprint`'s SHA256-over-canonical-representation → prefixed-token
/// pattern as its own sibling type — this fingerprints response *body shape*, an unrelated concern
/// from that type's persisted-rule-target revisions.
struct JSONSchemaShapeFingerprint: Equatable, Sendable, Codable {
    let rawValue: String

    static func compute(for shape: JSONShape) -> JSONSchemaShapeFingerprint {
        let canonical = canonicalDescription(of: shape)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return JSONSchemaShapeFingerprint(rawValue: "schema-\(hex.prefix(16))")
    }

    /// Canonical structural description — sorted object keys (dictionary iteration order is not
    /// stable), array cardinality deliberately omitted, `.mixed` alternatives sorted so encounter
    /// order never affects the hash.
    private static func canonicalDescription(of shape: JSONShape) -> String {
        switch shape {
        case .string:
            return "string"
        case .number:
            return "number"
        case .bool:
            return "bool"
        case .null:
            return "null"
        case .object(let properties):
            let parts = properties.keys.sorted().map { key in
                "\(key):\(canonicalDescription(of: properties[key]!))"
            }
            return "{\(parts.joined(separator: ","))}"
        case .array(let elementShape, _, _):
            let elementDescription = elementShape.map(canonicalDescription(of:)) ?? "empty"
            return "[\(elementDescription)]"
        case .mixed(let alternatives):
            let parts = alternatives.map(canonicalDescription(of:)).sorted()
            return "mixed(\(parts.joined(separator: "|")))"
        }
    }
}
