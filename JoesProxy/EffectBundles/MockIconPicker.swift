import SwiftUI

@MainActor
struct MockIconPickerRequest: Identifiable {
    let id = UUID()
    let draft: CapturedMockAuthoringDraft
    let sourceID: UUID?
    let replacingArtworkID: UUID?
    init(draft: CapturedMockAuthoringDraft, replacingArtworkID: UUID? = nil) {
        self.draft = draft
        sourceID = draft.source?.id
        self.replacingArtworkID = replacingArtworkID
    }
}

struct MockIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    let request: MockIconPickerRequest
    let suggestions: any MockIconSuggesting
    @StateObject private var suggestion = MockIconSuggestionState()
    @State private var jsonMode = false
    @State private var input = ""
    @State private var selectedFields: Set<String> = []
    @State private var query = ""
    @State private var selection = MockIconCatalog.sealID
    @State private var pixels = 256
    @State private var ink = MockIconRenderer.Ink.black
    @State private var opaque = false
    @State private var rendered: MockIconArtwork?
    @State private var renderedRecipe: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    private var recipe: String { "\(selection)-\(pixels)-\(ink.rawValue)-\(opaque)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I need an icon").appFont(.headline, scale: textScale)
            Text("Choose placeholder artwork for your mock. If nothing fits, use Joe’s Seal. Nothing is activated.")
                .appFont(.body, scale: textScale)
            if let id = request.replacingArtworkID {
                Text(request.draft.artworkUsageDescription(id: id))
                    .appFont(.caption, scale: textScale).accessibilityIdentifier("mockIconReplacementImpact")
            }
            suggestionControls
            TextField("Search symbols", text: $query)
                .focused($searchFocused).accessibilityIdentifier("mockIconSearch")
                .onChange(of: query) { _, _ in choose(MockIconCatalog.sealID) }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Button("Use Joe’s Seal") { choose(MockIconCatalog.sealID) }
                            .accessibilityIdentifier("mockIconSeal")
                        if MockIconCatalog.matching(query).isEmpty {
                            Text("No matching symbols. Joe’s Seal is ready to use.")
                                .accessibilityIdentifier("mockIconNoMatches")
                        }
                        ForEach(MockIconCatalog.matching(query)) { entry in
                            Button { choose(entry.id) } label: {
                                Text(entry.label)
                            }
                            .accessibilityIdentifier("mockIconChoice-\(entry.id)")
                            .accessibilityValue(selection == entry.id ? "Selected" : "Not selected")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 200, height: 250)
                VStack(alignment: .leading, spacing: 8) {
                    if let rendered, let image = NSImage(data: rendered.png) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 160, height: 160)
                            .background {
                                Canvas { context, size in
                                    for x in 0..<8 { for y in 0..<8 {
                                        context.fill(Path(CGRect(x: CGFloat(x) * size.width / 8,
                                            y: CGFloat(y) * size.height / 8, width: size.width / 8,
                                            height: size.height / 8)), with: .color((x + y) % 2 == 0 ? .gray.opacity(0.2) : .white))
                                    } }
                                }
                            }
                            .accessibilityLabel("Preview: \(rendered.name)")
                            .accessibilityIdentifier("mockIconPreview")
                        Text(rendered.name).accessibilityIdentifier("mockIconSelectedName")
                        if rendered.usedFallback {
                            Text("Original seal PNG; size and colors are preserved.")
                                .appFont(.caption, scale: textScale)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Picker("Pixels", selection: $pixels) {
                    ForEach([64, 128, 256, 512], id: \.self) { Text(verbatim: "\($0) × \($0)").tag($0) }
                }.accessibilityIdentifier("mockIconPixels")
                Picker("Ink", selection: $ink) {
                    ForEach(MockIconRenderer.Ink.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("White background", isOn: $opaque)
            }.disabled(selection == MockIconCatalog.sealID)
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("mockIconError") }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mockIconCancel")
                Spacer()
                Button("Use in mock") {
                    guard request.draft.source?.id == request.sourceID,
                          renderedRecipe == recipe,
                          let rendered, attach(rendered) else {
                        error = "The draft changed or its artwork limit was reached. Close this picker and review the draft."
                        return
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rendered == nil || renderedRecipe != recipe)
                .accessibilityIdentifier("mockIconAccept")
            }
        }
        .appFont(.body, scale: textScale)
        .padding(20).frame(width: 620)
        .task(id: recipe) {
            rendered = nil
            renderedRecipe = nil
            error = nil
            do {
                rendered = try MockIconRenderer.render(symbol: selection, pixels: pixels, ink: ink, opaque: opaque)
            } catch {
                rendered = try? MockIconRenderer.seal()
                if rendered == nil { self.error = "Joe’s Seal could not be loaded. Cancel and choose an artwork file." }
            }
            renderedRecipe = recipe
        }
        .onAppear { searchFocused = true }
        .onDisappear { suggestion.cancel() }
        .onChange(of: suggestion.candidate) { _, candidate in
            if let candidate { selection = candidate }
        }
    }

    private var projection: String? {
        jsonMode ? try? MockIconSuggestionInput.project(input, fields: selectedFields)
            : try? MockIconSuggestionInput.description(input)
    }

    private func attach(_ artwork: MockIconArtwork) -> Bool {
        if let id = request.replacingArtworkID {
            return request.draft.replaceArtwork(id: id, name: artwork.name, png: artwork.png)
        }
        return request.draft.addGeneratedArtwork(artwork)
    }

    private func choose(_ symbol: String) {
        suggestion.cancel()
        selection = symbol
    }

    private var suggestionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Suggest from", selection: $jsonMode) {
                Text("Description").tag(false)
                Text("JSON").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("mockIconInputMode")
                .onChange(of: jsonMode) { _, _ in
                    suggestion.cancel()
                    input = ""
                    selectedFields = []
                }
            TextField(jsonMode ? "Paste synthetic JSON (8 KiB maximum)" : "Describe your mock (2 KiB maximum)",
                      text: $input, axis: .vertical)
                .lineLimit(2...3).accessibilityIdentifier("mockIconSuggestionInput")
                .onChange(of: input) { _, _ in
                    suggestion.cancel()
                    selectedFields.formIntersection(MockIconSuggestionInput.availableFields(input))
                }
            if jsonMode {
                HStack {
                    ForEach(MockIconSuggestionInput.fields, id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { selectedFields.contains(field) }, set: { enabled in
                            suggestion.cancel()
                            if enabled { selectedFields.insert(field) } else { selectedFields.remove(field) }
                        }))
                        .disabled(!MockIconSuggestionInput.availableFields(input).contains(field))
                        .accessibilityIdentifier("mockIconField-\(field)")
                    }
                }
                Text("Selected data").appFont(.caption, scale: textScale)
                ScrollView {
                    Text(projection ?? "Select nonempty text fields. Each must fit within 512 UTF-8 bytes.")
                        .accessibilityIdentifier("mockIconProjection")
                }.frame(height: 55)
            }
            if !input.isEmpty && projection == nil {
                Text("Check the input type, selection and byte limits. Nothing will be sent.")
                    .accessibilityIdentifier("mockIconInputError")
            }
            HStack {
                Button("Suggest symbol") {
                    if let projection { suggestion.start(projection, service: suggestions) }
                }.disabled(projection == nil || suggestion.busy)
                    .accessibilityIdentifier("mockIconSuggest")
                if suggestion.busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Choosing a symbol")
                    Button("Cancel suggestion") { suggestion.cancel() }
                        .accessibilityIdentifier("mockIconCancelSuggestion")
                }
            }
            if let message = suggestion.message {
                Text(message).accessibilityIdentifier("mockIconSuggestionStatus")
            }
        }
    }
}
