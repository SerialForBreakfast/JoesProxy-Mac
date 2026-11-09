import Foundation

/// A byte-range edit resolved against one immutable response-body revision.
struct ResolvedPatch: Equatable, Sendable {
    enum Provenance: Equatable, Sendable {
        case exactText
        case matchRef
        case selectorAdapter(name: String, version: Int)
    }

    let patchID: UUID
    let byteRange: Range<Int>
    let expectedOriginalSHA256: String
    let replacementBytes: Data
    let provenance: Provenance
}
