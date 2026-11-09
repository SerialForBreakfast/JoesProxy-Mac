import SwiftUI

struct GuidedRelatedMockEditor: View {
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var draft: CapturedMockAuthoringDraft
    let candidates: [SessionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related detail responses").appFont(.headline, scale: textScale)
            Text("Select retained GET captures explicitly. All resources use the target client above; no upstream request is made. Only the most recent 100 captures are offered.")
                .appFont(.caption, scale: textScale)
            Menu("Add Related Captured Response…") {
                ForEach(candidates.filter { candidate in
                    candidate.request.method == "GET" && candidate.response != nil && candidate.id != draft.source?.id
                        && !draft.relatedDrafts.contains(where: { $0.source.id == candidate.id })
                }) { session in
                    Button("\(session.request.host)\(session.request.path) · \(session.id.uuidString.prefix(8))") {
                        draft.addRelatedSource(session)
                    }
                }
            }
            .disabled(draft.relatedDrafts.count >= 8)
            .accessibilityIdentifier("mockAuthoringAddRelated")
            .accessibilityHint("Adds a frozen captured response to this draft without sending traffic")
            ForEach($draft.relatedDrafts) { $related in
                DisclosureGroup("GET \(related.source.request.host)\(related.targetPath)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frozen source: \(related.source.request.path)").textSelection(.enabled)
                        TextField("Target path and exact query", text: $related.targetPath)
                            .accessibilityIdentifier("mockRelatedTarget-\(related.id)")
                        Text("The captured scheme, host and port are retained. Query parameters match exactly. Changing this path does not prove that the client requests it.")
                            .appFont(.caption, scale: textScale)
                        ForEach($related.edits) { $edit in
                            TextField("Related field JSON Pointer", text: $edit.pointer)
                                .accessibilityLabel("Related field JSON Pointer")
                                .accessibilityIdentifier("mockRelatedField-\(edit.id)")
                            TextField("Typed JSON value", text: $edit.valueJSON)
                                .accessibilityLabel("Related field value as JSON")
                                .accessibilityIdentifier("mockRelatedValue-\(edit.id)")
                            Button("Remove Related Field Edit") { related.edits.removeAll { $0.id == edit.id } }
                        }
                        Button("Add Related Field Edit") { related.edits.append(.init()) }
                            .disabled(related.edits.count >= 100)
                            .accessibilityIdentifier("mockRelatedAddField-\(related.id)")
                        Text("Identity links compare values after your edits. They never copy or change identities automatically.")
                            .appFont(.caption, scale: textScale)
                        ForEach($related.identityLinks) { $link in
                            TextField("Identity pointer in related response", text: $link.pointer)
                                .accessibilityLabel("Related response identity pointer")
                                .accessibilityIdentifier("mockRelatedIdentity-\(link.id)")
                            TextField("Matching pointer in prepared primary response", text: $link.primaryPointer)
                                .accessibilityLabel("Prepared primary response identity pointer")
                                .accessibilityIdentifier("mockRelatedPrimaryIdentity-\(link.id)")
                            Button("Remove Identity Link") { related.identityLinks.removeAll { $0.id == link.id } }
                        }
                        Button("Add Identity Link") { related.identityLinks.append(.init()) }
                            .disabled(related.identityLinks.count >= 32)
                            .accessibilityIdentifier("mockRelatedAddIdentity-\(related.id)")
                        TextField("Chosen image pointer in this response (optional)", text: $related.imagePointer)
                            .accessibilityLabel("Related response pointer for the chosen image")
                            .accessibilityIdentifier("mockRelatedImage-\(related.id)")
                        Text("An image pointer reuses the chosen image. Leave it empty to keep this response's artwork unchanged.")
                            .appFont(.caption, scale: textScale)
                        Menu("Bind Additional Artwork…") {
                            ForEach(draft.additionalArtwork) { artwork in
                                Button(artwork.displayName) { related.artworkBindings.append(.init(artworkID: artwork.id)) }
                            }
                        }
                        .disabled(draft.additionalArtwork.isEmpty || related.artworkBindings.count >= 15)
                        .accessibilityIdentifier("mockRelatedBindArtwork-\(related.id)")
                        ForEach($related.artworkBindings) { $binding in
                            Text(draft.additionalArtwork.first(where: { $0.id == binding.artworkID })?.displayName ?? "Artwork removed — remove this binding and select a replacement")
                                .appFont(.caption, scale: textScale)
                            TextField("Related response artwork pointer", text: $binding.pointer)
                                .accessibilityLabel("Related response artwork JSON Pointer")
                                .accessibilityIdentifier("mockRelatedArtworkPointer-\(binding.id)")
                            Button("Remove Artwork Binding") { related.artworkBindings.removeAll { $0.id == binding.id } }
                                .accessibilityIdentifier("mockRelatedArtworkRemove-\(binding.id)")
                        }
                        Button("Remove Related Response") { draft.relatedDrafts.removeAll { $0.id == related.id } }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mockAuthoringRelated-\(related.id)")
            }
        }
        .appFont(.body, scale: textScale)
        .disabled(draft.busy || draft.discoveringCollections || draft.prepared != nil)
    }
}
