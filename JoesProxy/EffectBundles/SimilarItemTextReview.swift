import SwiftUI

@MainActor
struct SimilarItemTextRequest: Identifiable {
    let id = UUID()
    let draft: CapturedMockAuthoringDraft
    let stamp: SimilarItemDraftStamp
    init(draft: CapturedMockAuthoringDraft) {
        self.draft = draft
        stamp = SimilarItemDraftStamp(draft)
    }
}

struct SimilarItemTextReview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    let request: SimilarItemTextRequest
    let service: any SimilarItemTextGenerating
    @ObservedObject var draft: CapturedMockAuthoringDraft
    @StateObject private var state = SimilarItemTextState()
    @State private var input: SimilarItemTextInput?
    @State private var selected: Set<String> = []
    @State private var retired = false
    @State private var applying = false
    @State private var applyTask: Task<Void, Never>?
    @State private var error: String?
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggest similar-item text").appFont(.headline, scale: textScale)
            Text("Choose only text you want to share with the on-device model. Review the exact projection. Nothing is saved or activated.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let input {
                        if input.fields.isEmpty { Text("No eligible text fields. Continue with manual edits.") }
                        ForEach(input.fields.keys.sorted(), id: \.self) { pointer in
                            Toggle(pointer, isOn: Binding(get: { selected.contains(pointer) }, set: { enabled in
                                applyTask?.cancel()
                                state.cancel()
                                if enabled { selected.insert(pointer) } else { selected.remove(pointer) }
                            }))
                            .accessibilityIdentifier("similarTextField-\(pointer)")
                        }
                        Text("Selected data (4 KiB total; 512 UTF-8 bytes per field)")
                        Text((try? input.projection(selected: selected)) ?? "Select 1–8 eligible text fields.")
                            .accessibilityIdentifier("similarTextProjection")
                        if let proposal = state.proposal {
                            ForEach(proposal.keys.sorted(), id: \.self) { pointer in
                                Text("\(pointer)\nBefore: \(input.fields[pointer] ?? "")\nAfter: \(proposal[pointer] ?? "")")
                                    .accessibilityIdentifier("similarTextChange-\(pointer)")
                            }
                        }
                    } else if error == nil { ProgressView("Inspecting selected template…") }
                }
            }.frame(maxHeight: 330)
            if let message = state.message { Text(message).accessibilityIdentifier("similarTextStatus") }
            if let error { Text(error).accessibilityIdentifier("similarTextError") }
            if retired { Text("The draft changed. Close this review and select the current template again.") }
            HStack {
                Button("Cancel") { applyTask?.cancel(); state.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).focused($closeFocused)
                    .accessibilityIdentifier("similarTextClose")
                if state.busy {
                    ProgressView().accessibilityLabel("Suggesting text")
                    Button("Cancel suggestion") { state.cancel() }.accessibilityIdentifier("similarTextCancel")
                } else {
                    Button("Suggest text") {
                        if let input { state.start(input: input, selected: selected, service: service) }
                    }.disabled(retired || applying || input.flatMap { try? $0.projection(selected: selected) } == nil)
                        .accessibilityIdentifier("similarTextSuggest")
                }
                Spacer()
                Button("Apply to draft") {
                    guard !retired, SimilarItemDraftStamp(draft) == request.stamp,
                          let proposal = state.proposal, let input else {
                        state.cancel(); retired = true
                        return
                    }
                    applying = true
                    applyTask = Task {
                        let applied = await draft.applySimilarText(proposal, input: input, selected: selected, stamp: request.stamp)
                        applying = false
                        state.cancel()
                        if applied { dismiss() } else { retired = true }
                    }
                }.disabled(retired || applying || state.proposal == nil)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint("Command Return applies reviewed text to the draft; it does not save or activate.")
                    .accessibilityIdentifier("similarTextApply")
            }
        }
        .appFont(.body, scale: textScale).padding(20).frame(width: 640)
        .task {
            closeFocused = true
            let stamp = request.stamp
            do {
                guard let response = stamp.source?.response, stamp.editable, !stamp.advanced else {
                    throw SimilarItemTextInput.Failure.invalidInput
                }
                let work = Task.detached {
                    try SimilarItemTextInput.inspect(response: response, guided: stamp.guided,
                                                    protectedPointers: stamp.protectedPointers)
                }
                let result = try await withTaskCancellationHandler { try await work.value }
                    onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard !retired, SimilarItemDraftStamp(draft) == stamp else { return }
                input = result
            } catch is CancellationError { }
            catch { self.error = "Select one complete captured template with a valid explicit identity. Your draft is unchanged." }
        }
        .onChange(of: SimilarItemDraftStamp(draft)) { _, _ in retired = true; state.cancel() }
        .onDisappear { applyTask?.cancel(); state.cancel() }
    }
}

extension CapturedMockAuthoringDraft {
    /// Applies only a validated proposal against the exact reviewed draft; preparation remains separate.
    func applySimilarText(_ output: [String: String], input: SimilarItemTextInput,
                          selected: Set<String>, stamp: SimilarItemDraftStamp) async -> Bool {
        guard stamp.editable, !stamp.advanced, SimilarItemDraftStamp(self) == stamp else { return false }
        let validation = Task.detached { try input.validate(output, selected: selected) }
        guard (try? await validation.value) != nil, !Task.isCancelled,
              SimilarItemDraftStamp(self) == stamp else { return false }
        var next = guidedDraft
        for pointer in output.keys.sorted() {
            guard let value = output[pointer], let encoded = try? JSONSerialization.data(withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys]) else { return false }
            next.edits.append(.init(pointer: pointer, valueJSON: String(decoding: encoded, as: UTF8.self)))
        }
        guidedDraft = next
        reviewed = false
        return true
    }
}
