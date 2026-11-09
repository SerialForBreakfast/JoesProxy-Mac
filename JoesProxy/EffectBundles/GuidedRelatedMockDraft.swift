import Foundation

/// Frozen captured input with explicit edits. Uses the same decoder/compiler as MCP preparation.
struct GuidedRelatedMockDraft: Identifiable, Equatable, Sendable {
    struct IdentityLink: Identifiable, Equatable, Sendable {
        let id = UUID()
        var pointer = "/id"
        var primaryPointer = ""
    }
    let id = UUID()
    let source: SessionRecord
    var targetPath: String
    var edits: [GuidedCollectionMockDraft.FieldEdit] = []
    var identityLinks: [IdentityLink] = [.init()]
    var imagePointer = ""
    var artworkBindings: [GuidedMockArtworkBinding] = []

    init(source: SessionRecord) {
        self.source = source
        targetPath = source.request.path
    }

    func input(clientAddress: String, hasImage: Bool, artworkAssetIDs: [UUID: String] = [:]) throws -> CapturedRelatedResponseInput {
        guard source.request.method == "GET", let response = source.response,
              edits.count <= 100, !identityLinks.isEmpty, identityLinks.count <= 32 else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        guard imagePointer.isEmpty || hasImage else { throw CapturedMockPackageError.invalidImage }
        guard imagePointer.utf8.count <= 1_024 else { throw CollectionMockError.sizeLimit }
        if !imagePointer.isEmpty { _ = try CollectionMockCompiler.pointer(imagePointer) }
        var editBytes = 0
        let editValues = try edits.map { edit -> [String: Any] in
            try Task.checkCancellation()
            editBytes += edit.valueJSON.utf8.count + edit.pointer.utf8.count
            guard editBytes <= 65_536, edit.pointer.utf8.count <= 1_024 else {
                throw CollectionMockError.sizeLimit
            }
            _ = try CollectionMockCompiler.pointer(edit.pointer)
            return ["pointer": edit.pointer, "value": try JSONSerialization.jsonObject(
                with: Data(edit.valueJSON.utf8), options: [.fragmentsAllowed])]
        }
        let links = try identityLinks.map { link -> [String: String] in
            guard !link.pointer.isEmpty, !link.primaryPointer.isEmpty,
                  link.pointer.utf8.count <= 1_024, link.primaryPointer.utf8.count <= 1_024 else {
                throw CollectionMockError.missingIdentity
            }
            _ = try CollectionMockCompiler.pointer(link.pointer)
            _ = try CollectionMockCompiler.pointer(link.primaryPointer)
            return ["pointer": link.pointer, "primaryPointer": link.primaryPointer]
        }
        var images: [[String: String]] = imagePointer.isEmpty ? [] : [["pointer": imagePointer, "assetID": "image-0"]]
        guard artworkBindings.count + images.count <= 16 else { throw CapturedMockPackageError.tooManyImages }
        for binding in artworkBindings {
            guard let assetID = artworkAssetIDs[binding.artworkID] else {
                throw CapturedMockPreparationFailure(reason: "artworkUnavailable", field: "images",
                    recovery: "A bound artwork selection was removed. Select its replacement explicitly or remove the binding; no other image was substituted.")
            }
            guard !binding.pointer.isEmpty, binding.pointer.utf8.count <= 1_024 else { throw CollectionMockError.invalidPointer }
            _ = try CollectionMockCompiler.pointer(binding.pointer)
            images.append(["pointer": binding.pointer, "assetID": assetID])
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["edits": editValues,
            "identityLinks": links, "images": images], options: [.sortedKeys])
        guard bytes.count <= 65_536 else { throw CollectionMockError.sizeLimit }
        let scope = try CapturedMockExplicitTarget.scope(path: targetPath, source: source.request,
            clientAddress: clientAddress, field: "targetPath",
            hasObservedTarget: false, hasIgnoredQueryNames: false)
        return .init(sessionID: source.id, response: response, scope: scope, editsJSON: bytes,
                     targetSessionID: targetPath == source.request.path ? source.id : nil)
    }
}
