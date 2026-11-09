import Foundation

/// How a compiled variant was chosen. Disclosure may show this; it must not include body bytes.
enum OpenAPIMockResponseSourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case declaredExample
    case schemaExample
    case schemaDefault
    case schemaEnum
    case synthetic
    case namedError
}

/// Compiled response candidate. Body bytes live in the AW-2 fixture store, not here.
struct OpenAPIMockResponseVariant: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var status: Int
    var contentType: String
    var sourceKind: OpenAPIMockResponseSourceKind
    var name: String?
    var bodyDigest: String?
}

/// Selector output. `.unsupported` means the operation is not a compiled route (fail-open later).
enum OpenAPIMockSelectionResult: Equatable, Sendable {
    case selected(OpenAPIMockResponseVariant)
    case unsupported
}

/// Deterministic response selection and stable seed material (AW-0 order).
enum OpenAPIMockResponseSelector {
    /// Picks one variant from already-normalized candidates.
    ///
    /// When `requestedVariant` matches a candidate name, that candidate wins (covers named
    /// examples and named errors). Otherwise walks declared example → schema example →
    /// default → first enum → synthetic. Named errors are not chosen unless requested.
    static func select(
        candidates: [OpenAPIMockResponseVariant],
        requestedVariant: String? = nil
    ) -> OpenAPIMockSelectionResult {
        if let requestedVariant {
            let named = candidates.filter { $0.name == requestedVariant }
            if let match = named.sorted(by: Self.isOrderedBefore).first {
                return .selected(match)
            }
        }

        let ranked = candidates
            .filter { rank($0.sourceKind) != nil }
            .sorted { lhs, rhs in
                let leftRank = rank(lhs.sourceKind) ?? .max
                let rightRank = rank(rhs.sourceKind) ?? .max
                if leftRank != rightRank { return leftRank < rightRank }
                return isOrderedBefore(lhs, rhs)
            }
        guard let winner = ranked.first else { return .unsupported }
        return .selected(winner)
    }

    /// Stable seed string for AW-2 synthetic generation. Same inputs always produce the same string.
    static func seedMaterial(
        packID: OpenAPIMockPackID,
        method: String,
        template: String,
        status: Int,
        contentType: String,
        variantName: String?
    ) -> String {
        [
            packID.rawValue.uuidString.lowercased(),
            method.uppercased(),
            template,
            String(status),
            contentType.lowercased(),
            variantName ?? ""
        ].joined(separator: "|")
    }

    private static func rank(_ kind: OpenAPIMockResponseSourceKind) -> Int? {
        switch kind {
        case .declaredExample: return 0
        case .schemaExample: return 1
        case .schemaDefault: return 2
        case .schemaEnum: return 3
        case .synthetic: return 4
        case .namedError: return nil
        }
    }

    private static func isOrderedBefore(
        _ lhs: OpenAPIMockResponseVariant,
        _ rhs: OpenAPIMockResponseVariant
    ) -> Bool {
        let left = lhs.name ?? lhs.id
        let right = rhs.name ?? rhs.id
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}
