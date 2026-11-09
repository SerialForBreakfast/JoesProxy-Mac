import Foundation

/// Stable editor identity, independent of the compiler's positional image-N asset IDs.
struct GuidedMockArtwork: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var bookmark: String
    var generatedPNG: Data? = nil
    var primaryPointer = ""
    var displayName: String { "\(name) · \(id.uuidString.prefix(8))" }
}

struct GuidedMockArtworkBinding: Identifiable, Equatable, Sendable {
    let id = UUID()
    var artworkID: UUID
    var pointer = ""
}

struct GuidedMockArtworkInputs: Sendable {
    let files: [CapturedMockImageFile]
    let assetIDs: [UUID: String]

    init(primary: CapturedMockImageFile?, additional: [GuidedMockArtwork]) throws {
        guard additional.count + (primary == nil ? 0 : 1) <= 16,
              Set(additional.map(\.id)).count == additional.count else { throw CapturedMockPackageError.tooManyImages }
        var files = primary.map { [$0] } ?? []
        var ids: [UUID: String] = [:]
        for artwork in additional {
            ids[artwork.id] = "image-\(files.count)"
            files.append(.init(itemPointer: artwork.primaryPointer.isEmpty ? nil : artwork.primaryPointer,
                               bookmarkRef: artwork.bookmark, originalURL: nil, generatedPNG: artwork.generatedPNG))
        }
        self.files = files
        assetIDs = ids
    }
}
