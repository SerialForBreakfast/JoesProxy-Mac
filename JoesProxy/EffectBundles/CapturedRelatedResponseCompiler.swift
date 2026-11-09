import Foundation

struct CapturedRelatedResponse: Sendable {
    struct ImageBinding: Codable, Equatable, Sendable {
        let pointer: String
        let assetID: String
    }
    struct IdentityLink: Codable, Equatable, Sendable {
        let pointer: String
        let primaryPointer: String
    }
    let source: Data
    let scope: CapturedMockScope
    let edits: [CollectionMockEdit]
    let images: [ImageBinding]
    let identityLinks: [IdentityLink]
    var sourceSessionID: UUID? = nil
    var targetSessionID: UUID? = nil
    var ignoredQueryNames: [String]? = nil
}

/// Pure preparation. Invoke off the main actor/network event loop; never activates effects.
enum CapturedRelatedResponseCompiler {
    static func append(
        _ responses: [CapturedRelatedResponse],
        to package: PreparedCapturedMockPackage
    ) throws -> PreparedCapturedMockPackage {
        guard responses.count <= 8 else { throw CollectionMockError.sizeLimit }
        guard let primaryEffect = package.manifest.responseEffects.first,
            let client = primaryEffect.sourceClientAddress, !client.isEmpty,
            let primaryBody = package.assetDataByID["response"]
        else {
            throw CapturedMockPackageError.invalidScope
        }
        let primary = try CollectionMockCompiler.parse(primaryBody)
        var manifest = package.manifest
        var data = package.assetDataByID
        var total = data.values.reduce(0) { $0 + $1.count }
        for (index, response) in responses.enumerated() {
            try CapturedMockPreparationFailure.atField(
                "relatedResponses[\(index)]",
                recovery:
                    "Check this related response's scope, non-overlapping edits, image bindings and explicit identity links against the primary response; then prepare again."
            ) {
                try Task.checkCancellation()
                try CapturedMockPackageCompiler.validate(response.scope)
                guard response.scope.clients == .address(client),
                    response.edits.count <= 100, response.images.count <= 16,
                    !response.identityLinks.isEmpty, response.identityLinks.count <= 32
                else {
                    throw CapturedMockPackageError.invalidScope
                }
                // Conservatively reject competing query variants at one endpoint in this first slice.
                let basePath = response.scope.path.split(separator: "?", maxSplits: 1).first
                guard
                    !manifest.responseEffects.contains(where: {
                        $0.host.lowercased() == response.scope.host.lowercased()
                            && $0.port == response.scope.port && $0.requestScheme == response.scope.scheme
                            && $0.path.split(separator: "?", maxSplits: 1).first == basePath
                    })
                else { throw CapturedMockPackageError.invalidScope }
                var root = try CollectionMockCompiler.parse(response.source)
                let paths = response.edits.map(\.pointer) + response.images.map(\.pointer)
                let tokens = try paths.map(CollectionMockCompiler.pointer)
                for (offset, path) in tokens.enumerated() {
                    guard !path.isEmpty else { throw CollectionMockError.invalidPointer }
                    for other in tokens.dropFirst(offset + 1) {
                        guard !path.starts(with: other), !other.starts(with: path) else {
                            throw CapturedMockPackageError.duplicateBinding
                        }
                    }
                }
                var edits = response.edits
                for binding in response.images {
                    guard let image = package.images.first(where: { $0.assetID == binding.assetID }) else {
                        throw CapturedMockPackageError.invalidImage
                    }
                    edits.append(.init(pointer: binding.pointer, value: .string(image.imageReference ?? image.url)))
                }
                for (editIndex, edit) in edits.enumerated() {
                    let field =
                        editIndex < response.edits.count
                        ? "edits[\(editIndex)]" : "images[\(editIndex - response.edits.count)]"
                    try CapturedMockPreparationFailure.atField(
                        "relatedResponses[\(index)].\(field)",
                        recovery:
                            "Check this binding's pointer and value type against the related captured JSON. Do not change unrelated fields."
                    ) {
                        let path = try CollectionMockCompiler.pointer(edit.pointer)
                        let old = try CollectionMockCompiler.value(at: path, in: root)
                        guard old.kind == edit.value.kind || edit.value == .null else {
                            throw CollectionMockError.incompatibleType
                        }
                        root = try CollectionMockCompiler.replacing(path, in: root, with: edit.value)
                    }
                }
                for (linkIndex, link) in response.identityLinks.enumerated() {
                    try CapturedMockPreparationFailure.atField(
                        "relatedResponses[\(index)].identityLinks[\(linkIndex)]",
                        recovery:
                            "Point to matching nonempty string or numeric identities in the prepared primary and related responses; correct the explicit edit or identity pointers."
                    ) {
                        let actual = try CollectionMockCompiler.value(
                            at: CollectionMockCompiler.pointer(link.pointer), in: root)
                        let expected = try CollectionMockCompiler.value(
                            at: CollectionMockCompiler.pointer(link.primaryPointer), in: primary)
                        guard actual == expected, actual.kind == .number || actual.kind == .string,
                            actual != .string("")
                        else { throw CollectionMockError.missingIdentity }
                    }
                }
                let body = try JSONSerialization.data(
                    withJSONObject: CollectionMockCompiler.foundationValue(root), options: [.sortedKeys])
                guard body.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
                total += body.count
                guard total <= EffectBundleBudget.maxPackageBytes else { throw CollectionMockError.sizeLimit }
                let assetID = "related-\(index)"
                guard data[assetID] == nil else { throw CapturedMockPackageError.duplicateBinding }
                data[assetID] = body
                manifest.assets.append(
                    .init(
                        id: assetID, role: .responseBody, logicalPath: "\(assetID).json",
                        sha256: EffectBundleValidator.sha256Hex(body), byteCount: body.count,
                        contentType: "application/json"))
                var effect = CapturedMockPackageCompiler.effect(
                    id: UUID(), assetID: assetID,
                    contentType: "application/json", scope: response.scope)
                if let names = response.ignoredQueryNames {
                    guard let path = CapturedQueryMatcher.canonicalPath(effect.path, ignoring: names) else {
                        throw CapturedMockPackageError.invalidScope
                    }
                    effect.path = path
                    effect.matchMode = .ignoreQuery
                    effect.ignoredQueryNames = names
                }
                manifest.responseEffects.append(effect)
                if manifest.authoring?.relatedResponses == nil { manifest.authoring?.relatedResponses = [] }
                manifest.authoring?.relatedResponses?.append(
                    .init(
                        assetID: assetID,
                        sourceSessionID: response.sourceSessionID,
                        targetSessionID: response.targetSessionID,
                        sourceDigest: EffectBundleValidator.sha256Hex(response.source),
                        changedPointers: paths, images: response.images, identityLinks: response.identityLinks))
            }
        }
        try EffectBundleValidator.validateManifest(manifest)
        return .init(manifest: manifest, assetDataByID: data, images: package.images)
    }
}
