import Combine
import Foundation

/// Owned by ``AppPresentationState``, above any window. Failed preparation/save, Back, window close
/// and Compact/Inspector switches retain this draft; only an explicit discard or a successful save
/// replaces it.
/// Main-actor presentation state; compilation stays on the authoring actor and saving uses the
/// existing inactive import path. Never activates, stops, or infers source provenance.
@MainActor
final class CapturedMockAuthoringDraft: ObservableObject {
    @Published private(set) var source: SessionRecord? { didSet { textSuggestionRevision &+= 1 } }
    private(set) var textSuggestionRevision: UInt64 = 0
    @Published private(set) var replacementRevisionID: UUID?
    @Published var name = "Captured JSON fixture" { didSet { textSuggestionRevision &+= 1 } }
    @Published var clientAddress = "" { didSet { textSuggestionRevision &+= 1 } }
    @Published var guidedDraft = GuidedCollectionMockDraft() { didSet { itemPreview = nil; textSuggestionRevision &+= 1 } }
    @Published var relatedDrafts: [GuidedRelatedMockDraft] = [] { didSet { textSuggestionRevision &+= 1 } }
    @Published private(set) var itemPreview: CapturedMockItemPreview?
    @Published var advanced = false { didSet { textSuggestionRevision &+= 1 } }
    @Published var draftJSON = #"{"collectionPointer":"/items","item":{"id":"synthetic-item","image":""},"identityPointers":["/id"],"position":"append"}"#
    @Published var imagePointer = "/image" { didSet { textSuggestionRevision &+= 1 } }
    @Published var bindImageToPrimaryItem = true { didSet { textSuggestionRevision &+= 1 } }
    @Published var imageBookmark: String? { didSet { textSuggestionRevision &+= 1 } }
    @Published var imageName: String?
    @Published var additionalArtwork: [GuidedMockArtwork] = [] { didSet { textSuggestionRevision &+= 1 } }
    @Published private(set) var relatedPreviews: [CapturedRelatedMockPreview] = []
    @Published private(set) var preparedArtworkNames: [String: String] = [:]
    @Published var replacementImageSelected = false
    @Published var busy = false
    @Published var prepared: PreparedCapturedMockPackage?
    @Published var reviewed = false
    @Published var errorMessage: String?
    @Published private(set) var preflight: CapturedMockPreflight?
    @Published private(set) var collectionDiscovery: CapturedCollectionDiscovery?
    @Published private(set) var discoveringCollections = false
    private var preparationService: CollectionMockAuthoringService?
    private var retainedRevisionID: UUID?

    /// Value-owned PNG bytes; preparation and inactive save retain their own immutable copy.
    @discardableResult
    func addGeneratedArtwork(_ artwork: MockIconArtwork) -> Bool {
        guard !busy, !discoveringCollections, prepared == nil,
              additionalArtwork.count + (imageBookmark == nil ? 0 : 1) < 16 else { return false }
        let input = CapturedMockImageFile(itemPointer: nil, bookmarkRef: "", originalURL: nil,
                                         generatedPNG: artwork.png)
        guard (try? input.read()) != nil else {
            errorMessage = "The icon PNG is unavailable or invalid. Choose Joe’s Seal or another image."
            return false
        }
        additionalArtwork.append(.init(name: artwork.name, bookmark: "", generatedPNG: artwork.png))
        replacementImageSelected = true
        return true
    }

    /// Replaces bytes in one slot while preserving its identity, ordering and bindings.
    @discardableResult
    func replaceArtwork(id: UUID, name: String, bookmark: String = "", png: Data? = nil) -> Bool {
        guard !busy, !discoveringCollections, prepared == nil,
              let index = additionalArtwork.firstIndex(where: { $0.id == id }) else { return false }
        let input = CapturedMockImageFile(itemPointer: nil, bookmarkRef: bookmark, originalURL: nil,
                                         generatedPNG: png)
        guard (try? input.read()) != nil else {
            errorMessage = "Replacement artwork is unavailable or invalid. The previous image is unchanged."
            return false
        }
        additionalArtwork[index].name = name
        additionalArtwork[index].bookmark = bookmark
        additionalArtwork[index].generatedPNG = png
        reviewed = false
        replacementImageSelected = true
        errorMessage = nil
        return true
    }

    func artworkUsageDescription(id: UUID) -> String {
        guard let index = additionalArtwork.firstIndex(where: { $0.id == id }) else { return "Artwork removed" }
        let artwork = additionalArtwork[index]
        let assetID = "image-\(index + (imageBookmark == nil ? 0 : 1))"
        var uses = ["Retains \(assetID) and existing bindings."]
        if !artwork.primaryPointer.isEmpty { uses.append("Primary item: \(artwork.primaryPointer).") }
        let related = relatedDrafts.filter { $0.artworkBindings.contains { $0.artworkID == id } }
        if !related.isEmpty { uses.append("Related responses: \(related.map(\.targetPath).joined(separator: ", ")).") }
        let json = advanced ? draftJSON : guidedDraft.expansionItemsJSON
        if json.utf8.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
            let entries = (object as? [[String: Any]]) ?? (object as? [String: Any])?["expansionItems"] as? [[String: Any]] ?? []
            let items = entries.prefix(100).enumerated().compactMap { offset, entry -> String? in
                let bindings = entry["images"] as? [[String: Any]] ?? []
                return bindings.contains { $0["assetID"] as? String == assetID } ? String(offset + 1) : nil
            }
            if !items.isEmpty { uses.append("Batch items: \(items.joined(separator: ", ")).") }
        }
        return uses.joined(separator: " ")
    }

    /// Keeps typed inputs while releasing the process-local prepared handle and review state.
    func editPreparedRevision() async -> Bool {
        guard !busy, !discoveringCollections else { return false }
        busy = true
        defer { busy = false }
        do {
            try await releaseRetainedRevision()
            prepared = nil
            reviewed = false
            preflight = nil
            relatedPreviews = []
            preparedArtworkNames = [:]
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not retire the prepared revision. Your draft is retained; retry before editing."
            return false
        }
    }

    private func releaseRetainedRevision() async throws {
        if let retainedRevisionID, let preparationService {
            try await preparationService.retire(id: retainedRevisionID, ownerID: EffectBundleOwner.localUser.ownerID)
        }
        retainedRevisionID = nil
        preparationService = nil
    }

    func addRelatedSource(_ session: SessionRecord) {
        guard !busy, !discoveringCollections, prepared == nil, relatedDrafts.count < 8,
              session.id != source?.id, session.request.method == "GET", session.response != nil,
              !relatedDrafts.contains(where: { $0.source.id == session.id }) else { return }
        relatedDrafts.append(.init(source: session))
    }

    func previewItem() async {
        guard !busy, !discoveringCollections, prepared == nil, !advanced,
              let response = source?.response else { return }
        let input = guidedDraft
        let sourceID = source?.id
        busy = true
        errorMessage = nil
        defer { busy = false }
        let work = Task.detached(priority: .userInitiated) {
            try CapturedMockItemPreview.inspect(response: response, draft: input)
        }
        do {
            let preview = try await withTaskCancellationHandler { try await work.value }
                onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard source?.id == sourceID, guidedDraft == input else { return }
            itemPreview = preview
        } catch is CancellationError { return }
        catch {
            itemPreview = nil
            errorMessage = CapturedMockPreparationFailure.describe(error)?.message
                ?? "Item preview failed. Check the selected template, typed edits and new identity. Your draft is retained."
        }
    }

    func refreshPreflight(using operation: (UUID) async throws -> CapturedMockPreflight) async {
        guard !busy, let revisionID = prepared?.manifest.id else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            let result = try await operation(revisionID)
            try Task.checkCancellation()
            guard prepared?.manifest.id == result.revisionID else { return }
            preflight = result
        } catch is CancellationError { return }
        catch { errorMessage = "Historical matcher check failed. The prepared revision is unchanged; retry the check before activation." }
    }

    func discoverCollections() async {
        guard !busy, !discoveringCollections, prepared == nil,
              let response = source?.response else { return }
        discoveringCollections = true
        errorMessage = nil
        defer { discoveringCollections = false }
        let work = Task.detached(priority: .userInitiated) {
            try CapturedCollectionDiscovery.inspect(response: response)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            collectionDiscovery = result
        } catch is CancellationError {
            return
        } catch {
            errorMessage = CapturedMockPreparationFailure.describe(error)?.message
                ?? "Collection discovery failed. Your draft is unchanged."
        }
    }

    func selectCollection(_ candidate: CapturedCollectionCandidate) {
        guard !busy, !discoveringCollections, prepared == nil,
              collectionDiscovery?.collections.contains(candidate) == true else { return }
        guidedDraft.collectionPointer = candidate.pointer
    }

    func prepare(service: CollectionMockAuthoringService) async {
        guard !busy, !discoveringCollections, prepared == nil else { return }
        guard replacementRevisionID == nil || ((imageBookmark != nil || !additionalArtwork.isEmpty) && replacementImageSelected) else {
            errorMessage = "Choose a replacement image explicitly. Your JSON draft has been retained."
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        guard let source, let response = source.response else { errorMessage = "Select a complete captured response."; return }
        let primaryImage = imageBookmark.map { CapturedMockImageFile(itemPointer: bindImageToPrimaryItem ? imagePointer : nil, bookmarkRef: $0, originalURL: nil) }
        let artwork = additionalArtwork
        let primaryName = imageName ?? "Primary image"
        let input = guidedDraft
        let rawDraft = advanced ? draftJSON : nil
        let related = relatedDrafts
        let client = clientAddress
        let packageName = name
        let hasImage = imageBookmark != nil
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let images = try GuidedMockArtworkInputs(primary: primaryImage, additional: artwork)
            var artworkNames: [String: String] = primaryImage == nil ? [:] : ["image-0": primaryName]
            for image in artwork {
                if let assetID = images.assetIDs[image.id] { artworkNames[assetID] = image.displayName }
            }
            let draftBytes = try rawDraft.map { Data($0.utf8) } ?? input.encoded()
            let relatedInputs = try related.enumerated().map { index, draft in
                try CapturedMockPreparationFailure.atField("relatedResponses[\(index)]",
                    recovery: "Check the related capture, target path, typed edits, chosen image and explicit identity links; your draft is retained.") {
                    try draft.input(clientAddress: client, hasImage: hasImage, artworkAssetIDs: images.assetIDs)
                }
            }
            return (draftBytes, relatedInputs, images.files, artworkNames)
        }
        do {
            let (draftBytes, relatedInputs, images, artworkNames) = try await withTaskCancellationHandler { try await work.value }
                onCancel: { work.cancel() }
            try Task.checkCancellation()
            try await releaseRetainedRevision()
            let package = try await service.prepareCapturedResponse(ownerID: EffectBundleOwner.localUser.ownerID,
                    idempotencyKey: UUID().uuidString, name: packageName, response: response, draftJSON: draftBytes,
                    scope: CapturedMockScope(host: source.request.host, scheme: source.request.scheme,
                        port: source.request.port ?? (source.request.scheme == .https ? 443 : 80),
                        path: source.request.path, clients: .address(client)),
                    appVersion: Bundle.main.marketingVersionOrDev, imageFiles: images, relatedInputs: relatedInputs)
            preparationService = service
            retainedRevisionID = package.manifest.id
            try Task.checkCancellation()
            let previewWork = Task.detached(priority: .userInitiated) {
                try CapturedRelatedMockPreview.make(inputs: relatedInputs, package: package)
            }
            let previews = try await withTaskCancellationHandler { try await previewWork.value }
                onCancel: { previewWork.cancel() }
            try Task.checkCancellation()
            relatedPreviews = previews
            preparedArtworkNames = artworkNames
            prepared = package
        } catch is CancellationError {
            try? await releaseRetainedRevision()
            return
        }
        catch {
            errorMessage = CapturedMockPreparationFailure.describe(error)?.message
                ?? "Preparation failed. Review the draft and complete captured inputs. Nothing was activated; your draft is retained."
        }
    }
    func save(_ package: PreparedCapturedMockPackage, repository: EffectBundleRepository,
              service: CollectionMockAuthoringService) async -> Bool {
        guard !busy, reviewed, prepared?.manifest.id == package.manifest.id else { return false }
        busy = true
        errorMessage = nil
            defer { busy = false }
            do {
                _ = try await repository.importPreparedRevision(id: package.manifest.id, owner: .localUser, authoringService: service)
                try await releaseRetainedRevision()
                prepared = nil
                reviewed = false
                return true
            } catch {
                errorMessage = "Saving failed. The fixture has not been activated. Your draft and preview are retained for retry."
                return false
            }
    }

    func selectSource(_ session: SessionRecord?, replacing revisionID: UUID? = nil) -> String? {
        guard !busy, !discoveringCollections else { return "Wait for the current operation to finish. Your draft has been retained." }
        guard let session else { return "That capture is unavailable. Select a retained JSON response; nothing will be fetched upstream." }
        guard session.request.method == "GET", let response = session.response else {
            return "Choose a captured GET request with a JSON response, not the image-delivery request."
        }
        guard !response.bodyDeferred, !response.bodyTruncated,
              response.recordingBodyOmissionReason == nil, response.bodyData != nil else {
            return "The selected response body is incomplete or unavailable. Load a complete recording or capture it again explicitly; the existing draft is unchanged."
        }
        if let contentType = response.headers.first(where: { $0.name.lowercased() == "content-type" })?.value
            .split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           contentType != "application/json", !contentType.hasSuffix("+json") {
            return "This response is not labeled JSON. Choose the JSON list/config capture, not the image request."
        }
        guard (response.bodyData?.count ?? 0) <= CollectionMockCompiler.maximumBodyBytes else {
            return "The captured body exceeds the supported JSON preparation budget. Choose a smaller fixture."
        }
        if source?.id != session.id { relatedDrafts = [] }
        source = session
        relatedPreviews = []
        preparedArtworkNames = [:]
        itemPreview = nil
        collectionDiscovery = nil
        replacementRevisionID = revisionID
        replacementImageSelected = false
        prepared = nil
        preflight = nil
        reviewed = false
        errorMessage = nil
        return nil
    }
}
