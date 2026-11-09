import Combine
import Foundation

/// UI deadline and identity are independent of the provider's cancellation cooperation.
@MainActor
final class SimilarItemTextState: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var proposal: [String: String]?
    @Published private(set) var message: String?
    private var identity = UUID()
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func cancel() {
        identity = UUID()
        worker?.cancel(); deadline?.cancel()
        worker = nil; deadline = nil
        busy = false; proposal = nil; message = nil
    }

    func start(input: SimilarItemTextInput, selected: Set<String>, service: any SimilarItemTextGenerating,
               timeout: Duration = .seconds(8)) {
        guard !busy else { return }
        cancel()
        guard let projection = try? input.projection(selected: selected) else {
            message = "Choose 1–8 eligible fields within the byte limits. Nothing was sent."
            return
        }
        let request = identity
        busy = true
        message = "Suggesting text…"
        worker = Task { [weak self] in
            do {
                let output = try await service.generate(projection: projection)
                let validation = Task.detached { try input.validate(output, selected: selected) }
                _ = try await validation.value
                guard let self, self.identity == request else { return }
                self.proposal = output
                self.finish("Review the proposed text before applying it to the draft.")
            } catch {
                guard let self, self.identity == request else { return }
                self.finish(error is LocalMockInferenceGate.Failure
                    ? "Another suggestion is still finishing. You can edit manually."
                    : "Suggestion unavailable or invalid. Your draft is unchanged; you can edit manually.")
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.identity == request else { return }
            self.worker?.cancel()
            self.identity = UUID()
            self.finish("Suggestion timed out. Your draft is unchanged; you can edit manually.")
        }
    }

    private func finish(_ message: String) {
        busy = false
        self.message = message
        worker = nil
        deadline?.cancel(); deadline = nil
    }
}

/// Changes to source, mode, typed inputs or bindings retire review, even if values later revert.
struct SimilarItemDraftStamp: Equatable, Sendable {
    let revision: UInt64
    let source: SessionRecord?
    let guided: GuidedCollectionMockDraft
    let artwork: [GuidedMockArtwork]
    let related: [GuidedRelatedMockDraft]
    let imagePointer: String
    let imageBookmark: String?
    let bindsImage: Bool
    let advanced: Bool
    let name: String
    let client: String
    let editable: Bool

    @MainActor init(_ draft: CapturedMockAuthoringDraft) {
        revision = draft.textSuggestionRevision
        source = draft.source; guided = draft.guidedDraft
        artwork = draft.additionalArtwork; related = draft.relatedDrafts
        imagePointer = draft.imagePointer; imageBookmark = draft.imageBookmark
        bindsImage = draft.bindImageToPrimaryItem; advanced = draft.advanced
        name = draft.name; client = draft.clientAddress
        editable = !draft.busy && !draft.discoveringCollections && draft.prepared == nil
    }

    var protectedPointers: Set<String> {
        var pointers = Set(artwork.map(\.primaryPointer).filter { !$0.isEmpty })
        if bindsImage { pointers.insert(imagePointer) }
        return pointers
    }
}
