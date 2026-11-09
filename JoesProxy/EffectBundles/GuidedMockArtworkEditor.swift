import SwiftUI

struct GuidedMockArtworkEditor: View {
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var draft: CapturedMockAuthoringDraft
    let chooseArtwork: () -> Void
    let replaceArtwork: (UUID) -> Void
    let replaceIcon: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional artwork").appFont(.headline, scale: textScale)
            Text("Each file needs an explicit primary-item, batch-item or related-response binding. Batch image-N IDs follow file order; review them again after adding or removing artwork.")
                .appFont(.caption, scale: textScale)
            Button("Add Artwork…", action: chooseArtwork)
                .disabled(draft.additionalArtwork.count >= 15)
                .accessibilityIdentifier("mockAuthoringAddArtwork")
            ForEach($draft.additionalArtwork) { $artwork in
                VStack(alignment: .leading) {
                    Text(artwork.displayName).textSelection(.enabled)
                    if let index = draft.additionalArtwork.firstIndex(where: { $0.id == artwork.id }) {
                        Text("Batch asset ID: image-\(index + (draft.imageBookmark == nil ? 0 : 1))")
                            .appFont(.caption, scale: textScale)
                    }
                    TextField("Primary item image pointer (optional)", text: $artwork.primaryPointer)
                        .accessibilityIdentifier("mockArtworkPrimary-\(artwork.id)")
                    Text("Leave empty for per-item batch bindings or related-only artwork.")
                        .appFont(.caption, scale: textScale)
                    Text(draft.artworkUsageDescription(id: artwork.id))
                        .appFont(.caption, scale: textScale)
                        .accessibilityIdentifier("mockArtworkUsage-\(artwork.id)")
                    HStack {
                        Button("Replace file…") { replaceArtwork(artwork.id) }
                            .accessibilityIdentifier("mockArtworkReplaceFile-\(artwork.id)")
                        Button("Replace with icon…") { replaceIcon(artwork.id) }
                            .accessibilityIdentifier("mockArtworkReplaceIcon-\(artwork.id)")
                    }
                    Button("Remove \(artwork.name)") {
                        draft.additionalArtwork.removeAll { $0.id == artwork.id }
                    }
                    .accessibilityIdentifier("mockArtworkRemove-\(artwork.id)")
                }
            }
        }
        .appFont(.body, scale: textScale)
        .disabled(draft.busy || draft.discoveringCollections || draft.prepared != nil)
    }
}
