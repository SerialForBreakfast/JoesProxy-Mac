import SwiftUI
import UniformTypeIdentifiers

/// Embedded in the existing overrides surface. Source identity is frozen when authoring begins.
struct CapturedMockAuthoringView: View {
    @Environment(\.appTextScale) private var textScale
    @EnvironmentObject private var presentationState: AppPresentationState
    let source: SessionRecord
    let service: CollectionMockAuthoringService
    let iconSuggestions: any MockIconSuggesting
    let textSuggestions: any SimilarItemTextGenerating
    @ObservedObject var repository: EffectBundleRepository
    let onClose: () -> Void
    /// Called after the inactive bundle is saved; the owner retires the draft.
    let onSaved: () -> Void
    let preflightRevision: (UUID) async throws -> CapturedMockPreflight
    let relatedCandidates: [SessionRecord]
    @ObservedObject private var draft: CapturedMockAuthoringDraft
    @State private var choosingImage = false
    @State private var addingArtwork = false
    @State private var replacingArtworkID: UUID?
    @Binding private var name: String
    @Binding private var clientAddress: String
    @Binding private var guidedDraft: GuidedCollectionMockDraft
    @Binding private var advanced: Bool
    @Binding private var draftJSON: String
    @Binding private var imagePointer: String
    @Binding private var imageBookmark: String?
    @Binding private var imageName: String?
    @Binding private var busy: Bool
    @Binding private var prepared: PreparedCapturedMockPackage?
    @Binding private var reviewed: Bool
    @Binding private var errorMessage: String?

    init(
        source: SessionRecord, draft: CapturedMockAuthoringDraft, service: CollectionMockAuthoringService,
        iconSuggestions: any MockIconSuggesting,
        textSuggestions: any SimilarItemTextGenerating,
        repository: EffectBundleRepository, relatedCandidates: [SessionRecord] = [],
        preflightRevision: @escaping (UUID) async throws -> CapturedMockPreflight,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.source = source
        self.draft = draft
        self.service = service
        self.iconSuggestions = iconSuggestions
        self.textSuggestions = textSuggestions
        self.repository = repository
        self.relatedCandidates = Array(relatedCandidates.suffix(100))
        self.onClose = onClose
        self.onSaved = onSaved
        self.preflightRevision = preflightRevision
        self._name = Binding(get: { draft.name }, set: { draft.name = $0 })
        self._clientAddress = Binding(get: { draft.clientAddress }, set: { draft.clientAddress = $0 })
        self._guidedDraft = Binding(get: { draft.guidedDraft }, set: { draft.guidedDraft = $0 })
        self._advanced = Binding(get: { draft.advanced }, set: { draft.advanced = $0 })
        self._draftJSON = Binding(get: { draft.draftJSON }, set: { draft.draftJSON = $0 })
        self._imagePointer = Binding(get: { draft.imagePointer }, set: { draft.imagePointer = $0 })
        self._imageBookmark = Binding(get: { draft.imageBookmark }, set: { draft.imageBookmark = $0 })
        self._imageName = Binding(get: { draft.imageName }, set: { draft.imageName = $0 })
        self._busy = Binding(get: { draft.busy }, set: { draft.busy = $0 })
        self._prepared = Binding(get: { draft.prepared }, set: { draft.prepared = $0 })
        self._reviewed = Binding(get: { draft.reviewed }, set: { draft.reviewed = $0 })
        self._errorMessage = Binding(get: { draft.errorMessage }, set: { draft.errorMessage = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Append JSON + Image").appFont(.headline, scale: textScale)
                if GuidedMockDriftUITestScenario.isEnabled() {
                    GuidedMockDriftUITestControls(draft: draft)
                }
                if let revision = draft.replacementRevisionID {
                    Text(
                        "Replacement proposal for revision \(revision). The source was explicitly selected, not recovered from the receipt. Existing serving bundles remain unchanged."
                    )
                    .appFont(.caption, scale: textScale).textSelection(.enabled)
                }
                Text("Captured fixture · GET \(source.request.host)\(source.request.path)")
                    .appFont(.subheadline, scale: textScale).textSelection(.enabled)
                Text(
                    "Prepare freezes the primary JSON, related responses and chosen image together. Saving creates an inactive bundle; activation is a separate action."
                )
                .appFont(.caption, scale: textScale)
                Group {
                    TextField("Bundle name", text: $name).accessibilityIdentifier("mockAuthoringName")
                    TextField("Target client address (required)", text: $clientAddress)
                        .accessibilityIdentifier("mockAuthoringClientAddress")
                    Toggle("Advanced: use a complete JSON draft", isOn: $advanced)
                        .accessibilityIdentifier("mockAuthoringAdvanced")
                    if advanced {
                        Text("Advanced and guided drafts are kept separately. Only the visible mode is prepared.")
                            .appFont(.caption, scale: textScale)
                        AuthoringJSONEditor(text: $draftJSON, label: "Typed JSON draft", identifier: "mockAuthoringDraft")
                            .frame(minHeight: 140)
                    } else {
                        Button("Find Collections in Capture") {
                            Task { await draft.discoverCollections() }
                        }
                        .accessibilityHint("Lists captured array paths and counts without changing your draft")
                        .accessibilityIdentifier("mockAuthoringFindCollections")
                        if let discovery = draft.collectionDiscovery {
                            Menu("Choose Captured Collection…") {
                                ForEach(discovery.collections) { candidate in
                                    Button(
                                        "\(candidate.pointer.isEmpty ? "Document root" : candidate.pointer) — \(candidate.count) items"
                                    ) {
                                        draft.selectCollection(candidate)
                                    }
                                }
                            }
                            .disabled(discovery.collections.isEmpty)
                            .accessibilityIdentifier("mockAuthoringChooseCollection")
                            Text(
                                discovery.collections.isEmpty
                                    ? "No arrays found in the inspected portion. You can enter a path manually."
                                    : "Choose a path explicitly. Item values, identity fields, and counts are not edited by discovery."
                            )
                            .appFont(.caption, scale: textScale)
                            if discovery.truncated {
                                Text(
                                    "Discovery is bounded; additional collections may exist. Manual paths remain available."
                                )
                                .appFont(.caption, scale: textScale)
                            }
                        }
                        TextField("Collection JSON Pointer", text: $guidedDraft.collectionPointer)
                            .accessibilityIdentifier("mockAuthoringCollection")
                        Toggle("Use a captured item as the template", isOn: $guidedDraft.useTemplate)
                            .accessibilityIdentifier("mockAuthoringUseTemplate")
                        if guidedDraft.useTemplate {
                            TextField(
                                "Template item index (0 is first)", value: $guidedDraft.templateIndex, format: .number
                            )
                            .accessibilityIdentifier("mockAuthoringTemplateIndex")
                            Text(
                                "Select an existing item index in this captured collection. Add explicit field edits below, including a new identity. Template values remain unchanged unless edited."
                            )
                            .appFont(.caption, scale: textScale)
                            Toggle("Expand template into multiple items", isOn: $guidedDraft.expandTemplate)
                                .accessibilityIdentifier("mockAuthoringExpandTemplate")
                            if guidedDraft.expandTemplate {
                                Text("Batch items (1–100, in insertion order)").appFont(.subheadline, scale: textScale)
                                AuthoringJSONEditor(text: $guidedDraft.expansionItemsJSON,
                                    label: "Batch item edits and artwork bindings as JSON", identifier: "mockAuthoringExpansionItems")
                                    .frame(minHeight: 140)
                                Text("Each entry supplies edits with a new identity. Optional images bind a pointer to an image-N asset ID shown below. Shared field edits apply to every copy; do not repeat their pointers. Use Prepare Preview to review the complete frozen batch.")
                                    .appFont(.caption, scale: textScale)
                            }
                        } else {
                            Text("New item (typed JSON object)").appFont(.subheadline, scale: textScale)
                            AuthoringJSONEditor(text: $guidedDraft.itemJSON, label: "New item JSON", identifier: "mockAuthoringItem")
                                .frame(minHeight: 100)
                        }
                        ForEach($guidedDraft.edits) { $edit in
                            VStack(alignment: .leading) {
                                TextField("Field JSON Pointer", text: $edit.pointer)
                                    .accessibilityLabel("Edit field JSON Pointer")
                                TextField("Typed JSON value", text: $edit.valueJSON, axis: .vertical)
                                    .accessibilityLabel("Edit value as JSON")
                                Button("Remove Field Edit") { guidedDraft.edits.removeAll { $0.id == edit.id } }
                            }
                        }
                        Button("Add Typed Field Edit") { guidedDraft.edits.append(.init()) }
                            .disabled(guidedDraft.edits.count >= 100)
                            .accessibilityIdentifier("mockAuthoringAddFieldEdit")
                        Text(
                            "Use JSON values: \"text\", 42, true, null, objects or arrays. Field edits apply only to the new item."
                        )
                        .appFont(.caption, scale: textScale)
                        TextField(
                            "Identity field pointers, one per line", text: $guidedDraft.identityPointers,
                            axis: .vertical
                        )
                        .accessibilityIdentifier("mockAuthoringIdentity")
                        TextField(
                            "Count field pointers, optional, one per line", text: $guidedDraft.countPointers,
                            axis: .vertical
                        )
                        .accessibilityIdentifier("mockAuthoringCounts")
                        Text(
                            "Each identity must be unique. Count fields are unchanged unless you explicitly list them."
                        )
                        .appFont(.caption, scale: textScale)
                        Toggle("Insert at the beginning", isOn: $guidedDraft.prepend)
                            .accessibilityIdentifier("mockAuthoringPrepend")
                        Button("Preview Item Changes") { Task { await draft.previewItem() } }
                            .disabled(guidedDraft.useTemplate && guidedDraft.expandTemplate)
                            .accessibilityIdentifier("mockAuthoringPreviewItem")
                        Button("Suggest similar-item text…") {
                            presentationState.similarItemTextReview = .init(draft: draft)
                        }
                        .disabled(!guidedDraft.useTemplate || guidedDraft.expandTemplate)
                        .accessibilityIdentifier("mockAuthoringSuggestText")
                        .sheet(item: $presentationState.similarItemTextReview) { request in
                            SimilarItemTextReview(request: request, service: textSuggestions, draft: request.draft)
                                .environment(\.appTextScale, textScale)
                        }
                        if let preview = draft.itemPreview {
                            DisclosureGroup("Before / after item JSON") {
                                Text("Before edits").appFont(.headline, scale: textScale)
                                Text(preview.before).textSelection(.enabled)
                                Text("After edits").appFont(.headline, scale: textScale)
                                Text(preview.after).textSelection(.enabled)
                                if preview.truncated { Text("Text preview truncated to 4 KB per item; it may not be complete JSON.") }
                                Text("New item pointer in prepared response: \(preview.insertedItemPointer)")
                                    .textSelection(.enabled)
                                Text("Changed item fields: \(preview.changedPointers.joined(separator: ", "))")
                                Text("Other template fields stay unchanged. Artwork references are generated during Prepare, not this preview.")
                            }
                            .appFont(.caption, scale: textScale, design: .monospaced)
                            .accessibilityIdentifier("mockAuthoringItemDiff")
                        }
                    }
                    HStack {
                        Button("Choose Image…") { replacingArtworkID = nil; addingArtwork = false; choosingImage = true }
                            .accessibilityIdentifier("mockAuthoringChooseImage")
                        if let imageName {
                            Text(imageName).lineLimit(1)
                            Text("Batch asset ID: image-0").appFont(.caption, scale: textScale)
                            Button("Remove Image") {
                                imageBookmark = nil
                                self.imageName = nil
                                draft.replacementImageSelected = false
                            }
                        }
                    }
                    if imageBookmark != nil {
                        Toggle("Bind chosen image to the primary item", isOn: $draft.bindImageToPrimaryItem)
                            .accessibilityIdentifier("mockAuthoringBindPrimaryImage")
                        Text("Turn this off for artwork bound per batch item or only by related responses. At least one explicit image binding is required.")
                            .appFont(.caption, scale: textScale)
                        TextField("Image field JSON Pointer", text: $imagePointer)
                            .disabled(!draft.bindImageToPrimaryItem)
                            .accessibilityIdentifier("mockAuthoringImagePointer")
                        Text("A versioned image URL replaces this existing string field in the item.")
                            .appFont(.caption, scale: textScale)
                    }
                }
                .appFont(.body, scale: textScale)
                .disabled(busy || draft.discoveringCollections || prepared != nil)

                GuidedMockArtworkEditor(draft: draft, chooseArtwork: {
                    replacingArtworkID = nil; addingArtwork = true; choosingImage = true
                }, replaceArtwork: { id in
                    replacingArtworkID = id; choosingImage = true
                }, replaceIcon: { id in
                    presentationState.mockIconPicker = .init(draft: draft, replacingArtworkID: id)
                })
                Button("I need an icon…") {
                    presentationState.mockIconPicker = .init(draft: draft)
                }
                .disabled(busy || draft.discoveringCollections || prepared != nil ||
                    draft.additionalArtwork.count + (draft.imageBookmark == nil ? 0 : 1) >= 16)
                .accessibilityIdentifier("mockAuthoringCreateIcon")
                .sheet(item: $presentationState.mockIconPicker) { request in
                    MockIconPicker(request: request, suggestions: iconSuggestions)
                        .environment(\.appTextScale, textScale)
                }
                GuidedRelatedMockEditor(draft: draft, candidates: relatedCandidates)

                if let package = prepared {
                    review(package)
                    Toggle("I reviewed every resource's scope, counts, identity links and image metadata", isOn: $reviewed)
                        .appFont(.body, scale: textScale).accessibilityIdentifier("mockAuthoringReviewed")
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .accessibilityHint("Command-Option-R changes review confirmation. Enables saving an inactive bundle; it does not activate a modification.")
                    HStack {
                        Button("Edit Draft") {
                            Task { _ = await draft.editPreparedRevision() }
                        }
                        .accessibilityIdentifier("mockAuthoringEditPrepared")
                        Button("Save Inactive Bundle") { save(package) }
                            .disabled(!reviewed || busy).accessibilityIdentifier("mockAuthoringSave")
                    }
                    .disabled(busy)
                } else {
                    Button("Prepare Preview") { prepare() }
                        .disabled(
                            busy || draft.discoveringCollections
                                || clientAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.isEmpty
                        )
                        .accessibilityIdentifier("mockAuthoringPrepare")
                }
                if busy { ProgressView("Working on the fixture…") }
                if draft.discoveringCollections { ProgressView("Finding collections in captured JSON…") }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                        .appFont(.body, scale: textScale).accessibilityIdentifier("mockAuthoringError")
                }
                Button("Back to Overrides", action: onClose).disabled(busy)
                    .accessibilityIdentifier("mockAuthoringBack")
            }
            .padding()
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                if let id = replacingArtworkID {
                    guard draft.replaceArtwork(id: id, name: url.lastPathComponent,
                                               bookmark: bookmark.base64EncodedString()) else { return }
                } else if addingArtwork {
                    guard draft.additionalArtwork.count < 15 else { return }
                    draft.additionalArtwork.append(.init(name: url.lastPathComponent, bookmark: bookmark.base64EncodedString()))
                } else {
                    imageBookmark = bookmark.base64EncodedString()
                    imageName = url.lastPathComponent
                }
                draft.replacementImageSelected = true
                errorMessage = nil
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain, failure.code == NSUserCancelledError { return }
                errorMessage = "Image selection failed. Choose a readable PNG, JPEG, or WebP file."
            }
        }
    }

    private func review(_ package: PreparedCapturedMockPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prepared · not serving").appFont(.headline, scale: textScale)
            Text("Revision: \(package.manifest.id.uuidString)").textSelection(.enabled)
                .accessibilityIdentifier("mockAuthoringPreparedRevision")
            Text("Client: \(clientAddress) · GET \(source.request.host)\(source.request.path)")
            if let metadata = package.manifest.authoring {
                Text(verbatim: "Collection: \(metadata.beforeCount) → \(metadata.afterCount) items")
                    .accessibilityIdentifier("mockAuthoringPreparedCounts")
                ForEach(Array((metadata.reviewedChanges ?? []).enumerated()), id: \.offset) { _, change in
                    Text(change).textSelection(.enabled)
                }
                if metadata.reviewedChangesTruncated == true {
                    Text("Change list truncated. Review the batch draft and prepared response before saving.")
                }
                ForEach(metadata.relatedResponses ?? [], id: \.assetID) { related in
                    Text("Related response \(related.assetID): \(related.changedPointers.joined(separator: ", "))")
                    ForEach(Array(related.identityLinks.enumerated()), id: \.offset) { _, link in
                        Text("Verified identity: \(link.pointer) matches primary \(link.primaryPointer)")
                            .textSelection(.enabled)
                    }
                }
            }
            ForEach(package.manifest.responseEffects, id: \.id) { effect in
                Text("GET \(effect.requestScheme.rawValue)://\(effect.host):\(effect.port ?? (effect.requestScheme == .https ? 443 : 80))\(effect.path)")
                    .textSelection(.enabled)
            }
            ForEach(draft.relatedPreviews) { preview in
                DisclosureGroup("Related response \(preview.id) — before / after") {
                    Text("Captured before").appFont(.headline, scale: textScale)
                    Text(preview.before).textSelection(.enabled)
                        .accessibilityIdentifier("mockRelatedBefore-\(preview.id)")
                    Text("Prepared after, including artwork").appFont(.headline, scale: textScale)
                    Text(preview.after).textSelection(.enabled)
                        .accessibilityIdentifier("mockRelatedAfter-\(preview.id)")
                    Text("Formatting may differ. Changed field pointers and identity links are listed above.")
                    if preview.truncated {
                        Text("Preview truncated to 4 KB per response side; this is not complete JSON.")
                    }
                }
                .appFont(.caption, scale: textScale, design: .monospaced)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mockRelatedPreview-\(preview.id)")
            }
            Text(verbatim: "Default activation lifetime: \(Int(package.manifest.defaultTTLSeconds)) seconds")
            if let responseID = package.manifest.authoring?.responseAssetID,
                let bytes = package.assetDataByID[responseID]
            {
                DisclosureGroup("Prepared response preview (first 4 KB)") {
                    Text(String(decoding: bytes.prefix(4096), as: UTF8.self))
                        .accessibilityIdentifier("mockAuthoringResponseJSON")
                        .appFont(.caption, scale: textScale, design: .monospaced)
                        .textSelection(.enabled)
                    if bytes.count > 4096 {
                        Text("Preview truncated; the saved response retains the complete prepared bytes.")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mockAuthoringResponsePreview")
            }
            ForEach(package.images, id: \.assetID) { image in
                Text("\(image.assetID): \(draft.preparedArtworkNames[image.assetID] ?? "Artwork")")
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mockArtworkReviewName-\(image.assetID)")
                Text(
                    verbatim:
                        "HTTP 200 · \(image.contentType) · \(image.width) × \(image.height) · \(image.byteCount) bytes")
                    .accessibilityIdentifier("mockArtworkReviewMetadata-\(image.assetID)")
                Text(image.url).textSelection(.enabled)
                    .accessibilityIdentifier("mockArtworkReviewURL-\(image.assetID)")
                if let reference = image.imageReference {
                    Text("JSON image reference: \(reference)").textSelection(.enabled)
                }
                Text("SHA-256: \(image.sha256)").textSelection(.enabled)
            }
            ForEach(package.reviewAdvisories) { advisory in
                VStack(alignment: .leading, spacing: 4) {
                    Label(advisory.message, systemImage: "exclamationmark.triangle")
                    Text(advisory.recovery)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mockAuthoringAdvisory-\(advisory.code.rawValue)")
            }
            Text(package.manifest.privacy.warning)
            if let report = draft.preflight, report.revisionID == package.manifest.id {
                Text("Historical matcher preflight").appFont(.headline, scale: textScale)
                Text(
                    verbatim:
                        "Checked \(report.inspectedCount) of \(report.retainedCount) retained requests · \(report.droppedCount) retention drops"
                )
                if report.incomplete {
                    Text("Coverage is incomplete. More matching requests may exist outside this sample.")
                }
                ForEach(report.resources) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.assetIDs.joined(separator: ", "))
                        Text(
                            verbatim:
                                "\(resource.matchedCount) matches · \(resource.otherClientCount) other-client matches · \(resource.siblingMatchCount) additional paths · \(resource.unavailableBodyCount) unavailable bodies"
                        )
                        Text(resource.nextAction)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(CapturedMockPreflight.limitations)
            }
            Button("Refresh Historical Matcher Check") {
                Task { await draft.refreshPreflight(using: preflightRevision) }
            }
            .disabled(busy)
            .accessibilityIdentifier("mockAuthoringPreflight")
        }
        .appFont(.caption, scale: textScale)
    }

    private func prepare() {
        Task {
            await draft.prepare(service: service)
            await draft.refreshPreflight(using: preflightRevision)
        }
    }

    private func save(_ package: PreparedCapturedMockPackage) {
        Task {
            if await draft.save(package, repository: repository, service: service) { onSaved() }
        }
    }
}
