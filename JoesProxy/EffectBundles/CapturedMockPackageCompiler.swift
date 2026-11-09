import Foundation
import ImageIO

struct CapturedMockScope: Codable, Equatable, Sendable {
    enum Clients: Codable, Equatable, Sendable { case allClients, address(String) }
    let host: String
    let scheme: SessionScheme
    let port: Int
    let path: String
    let clients: Clients
}

struct CapturedMockImageBinding: Sendable {
    let itemPointer: String?
    let bytes: Data
    let originalURL: URL?
    var deliveryURL: URL? = nil
    var imageReference: String? = nil
}

struct CapturedMockImagePreview: Codable, Equatable, Sendable {
    let assetID: String
    let url: String
    let sha256: String
    let contentType: String
    let width: Int
    let height: Int
    let byteCount: Int
    let retainsOriginalURL: Bool
    var imageReference: String? = nil
}

struct PreparedCapturedMockPackage: Sendable {
    let manifest: EffectBundleManifest
    let assetDataByID: [String: Data]
    let images: [CapturedMockImagePreview]
}

enum CapturedMockPackageError: String, Error, Sendable {
    case invalidScope, invalidImage, unsupportedImage, duplicateBinding, tooManyImages
}

/// Builds bytes and rules only. No file access, upstream requests, or effect activation.
enum CapturedMockPackageCompiler {
    static func prepare(id: UUID, name: String, source: Data, draft: CollectionMockDraft,
                        scope: CapturedMockScope, images: [CapturedMockImageBinding],
                        appVersion: String, createdAt: Date) throws -> PreparedCapturedMockPackage {
        try validate(scope)
        guard images.count <= 16 else { throw CapturedMockPackageError.tooManyImages }
        let primaryPointers = images.compactMap(\.itemPointer)
        guard Set(primaryPointers).count == primaryPointers.count,
              Set(primaryPointers).isDisjoint(with: Set(draft.edits.map(\.pointer))) else {
            throw CapturedMockPackageError.duplicateBinding
        }
        var assets: [EffectBundleAsset] = []
        var dataByID: [String: Data] = [:]
        var previews: [CapturedMockImagePreview] = []
        var effects: [EffectBundleResponseEffect] = []
        var edits = draft.edits
        var aggregateBytes = source.count
        for (index, binding) in images.enumerated() {
            aggregateBytes += binding.bytes.count
            guard aggregateBytes <= EffectBundleBudget.maxPackageBytes else {
                throw EffectBundleError.packageTooLarge(aggregateBytes)
            }
            guard binding.bytes.count <= EffectBundleBudget.maxFileBytes,
                  let imageSource = CGImageSourceCreateWithData(binding.bytes as CFData, nil),
                  CGImageSourceGetCount(imageSource) == 1,
                  let type = CGImageSourceGetType(imageSource) as String?,
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32_768, height <= 32_768 else {
                throw CapturedMockPackageError.invalidImage
            }
            let mime: String
            let ext: String
            switch type {
            case "public.png": mime = "image/png"; ext = "png"
            case "public.jpeg": mime = "image/jpeg"; ext = "jpg"
            case "org.webmproject.webp": mime = "image/webp"; ext = "webp"
            default: throw CapturedMockPackageError.unsupportedImage
            }
            let digest = EffectBundleValidator.sha256Hex(binding.bytes)
            let assetID = "image-\(index)"
            let generated = URL(string: "https://\(SyntheticAssetOriginServer.defaultHost)\(SyntheticAssetOriginServer.authoredRevisionPathPrefix)\(id.uuidString.lowercased())/\(digest).\(ext)")!
            guard (binding.deliveryURL == nil) == (binding.imageReference == nil),
                  binding.deliveryURL == nil || binding.originalURL == nil else {
                throw CapturedMockPackageError.invalidScope
            }
            if let reference = binding.imageReference {
                guard !reference.isEmpty, reference.utf8.count <= 4_096,
                      !reference.contains(where: { $0.isWhitespace || $0.isNewline }),
                      !reference.unicodeScalars.contains(where: { $0.value < 32 }),
                      !reference.contains("\\"), !reference.hasPrefix("//"),
                      let parts = URLComponents(string: reference), parts.scheme == nil,
                      parts.host == nil, parts.fragment == nil, !parts.path.isEmpty,
                      !parts.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
                    throw CapturedMockPackageError.invalidScope
                }
            }
            let url = binding.deliveryURL ?? binding.originalURL ?? generated
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil, components.fragment == nil,
                  let host = components.host,
                  let scheme = SessionScheme(rawValue: components.scheme ?? "") else {
                throw CapturedMockPackageError.invalidScope
            }
            let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            guard !SyntheticAssetOriginServer.isSyntheticHost(host)
                || path.lowercased().hasPrefix(SyntheticAssetOriginServer.authoredRevisionPathPrefix) else {
                throw CapturedMockPackageError.invalidScope
            }
            let imageScope = CapturedMockScope(host: host, scheme: scheme,
                port: components.port ?? (scheme == .https ? 443 : 80), path: path, clients: scope.clients)
            try validate(imageScope)
            assets.append(EffectBundleAsset(id: assetID, role: .localFile, logicalPath: "images/\(assetID).\(ext)",
                sha256: digest, byteCount: binding.bytes.count, contentType: mime))
            dataByID[assetID] = binding.bytes
            previews.append(CapturedMockImagePreview(assetID: assetID, url: url.absoluteString, sha256: digest,
                contentType: mime, width: width, height: height, byteCount: binding.bytes.count,
                retainsOriginalURL: binding.originalURL != nil, imageReference: binding.imageReference))
            if let pointer = binding.itemPointer {
                edits.append(CollectionMockEdit(pointer: pointer,
                    value: .string(binding.imageReference ?? url.absoluteString)))
            }
            effects.append(effect(id: UUID(), assetID: assetID, contentType: mime, scope: imageScope))
        }
        let boundDraft = CollectionMockDraft(collectionPointer: draft.collectionPointer, item: draft.item,
            templateIndex: draft.templateIndex, edits: edits, identityPointers: draft.identityPointers,
            countPointers: draft.countPointers, position: draft.position, identityPresence: draft.identityPresence)
        let body: Data
        let before: Int
        let after: Int
        let itemEdits: [[CollectionMockEdit]]
        if let items = draft.expansionItems {
            guard (1...CollectionTemplateExpansion.maximumItems).contains(items.count) else {
                throw CollectionMockError.invalidTemplate
            }
            itemEdits = try items.map { item in
                guard item.images.count <= 16 else { throw CapturedMockPackageError.tooManyImages }
                return item.edits + (try item.images.map { binding in
                    guard let image = previews.first(where: { $0.assetID == binding.assetID }) else {
                        throw CapturedMockPackageError.invalidImage
                    }
                    return CollectionMockEdit(pointer: binding.pointer, value: .string(image.imageReference ?? image.url))
                })
            }
            body = try CollectionTemplateExpansion.prepare(source: source, template: boundDraft, itemEdits: itemEdits)
            guard case .array(let collection) = try CollectionMockCompiler.value(
                at: CollectionMockCompiler.pointer(draft.collectionPointer), in: CollectionMockCompiler.parse(source)) else {
                throw CollectionMockError.incompatibleType
            }
            before = collection.count
            after = before + items.count
        } else {
            let plan = try CollectionMockCompiler.prepare(source: source, draft: boundDraft)
            guard case .applied(let updated, let originalCount, let newCount) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
                throw CollectionMockError.duplicateIdentity
            }
            body = updated
            before = originalCount
            after = newCount
            itemEdits = [[]]
        }
        let bodyID = "response"
        assets.append(EffectBundleAsset(id: bodyID, role: .responseBody, logicalPath: "response.json",
            sha256: EffectBundleValidator.sha256Hex(body), byteCount: body.count, contentType: "application/json"))
        dataByID[bodyID] = body
        var responseEffect = effect(id: UUID(), assetID: bodyID, contentType: "application/json", scope: scope)
        if let names = draft.ignoredQueryNames {
            guard case .address = scope.clients,
                  let path = CapturedQueryMatcher.canonicalPath(scope.path, ignoring: names) else {
                throw CapturedMockPackageError.invalidScope
            }
            responseEffect.path = path
            responseEffect.matchMode = .ignoreQuery
            responseEffect.ignoredQueryNames = names
        }
        effects.insert(responseEffect, at: 0)
        var manifest = EffectBundleManifest(schemaVersion: EffectBundleSchema.currentVersion, id: id, name: name,
            notes: "Prepared captured fixture. Target rendering remains unconfirmed.", createdAt: createdAt,
            appVersion: appVersion, privacy: .exactContent, defaultTTLSeconds: EffectBundleBudget.defaultTTL,
            assets: assets, responseEffects: effects, hlsSubstitutions: [])
        manifest.authoring = EffectBundleAuthoringMetadata(mode: .capturedFixture, revisionID: id,
            sourceDigest: EffectBundleValidator.sha256Hex(source), responseAssetID: bodyID,
            beforeCount: before, afterCount: after, artwork: previews)
        let changes = itemEdits.enumerated().flatMap { index, edits in
            let insertedPointer = "\(draft.collectionPointer)/\((draft.position == .prepend ? 0 : before) + index)"
            return ["Insert reviewed item at \(insertedPointer)"] + (boundDraft.edits + edits).map {
                "Set reviewed field at \(insertedPointer)\($0.pointer)"
            }
        } + draft.countPointers.map {
            "Adjust reviewed count at \($0)" + (after - before == 1 ? "" : " by \(after - before)")
        }
        manifest.authoring?.reviewedChanges = changes.prefix(32).map {
            $0.count > 256 ? String($0.prefix(256)) + " [truncated]" : $0
        }
        manifest.authoring?.reviewedChangesTruncated = changes.count > 32 || changes.contains { $0.count > 256 }
        try EffectBundleValidator.validateManifest(manifest)
        return PreparedCapturedMockPackage(manifest: manifest, assetDataByID: dataByID, images: previews)
    }

    static func validate(_ scope: CapturedMockScope) throws {
        guard !scope.host.isEmpty, !scope.host.contains("/"), !scope.host.contains("@"),
              !scope.host.contains(where: { $0.isWhitespace }), (1...65_535).contains(scope.port),
              scope.path.hasPrefix("/"), !scope.path.contains("#"),
              !scope.path.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw CapturedMockPackageError.invalidScope
        }
        if case .address(let address) = scope.clients, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CapturedMockPackageError.invalidScope
        }
    }

    static func effect(id: UUID, assetID: String, contentType: String,
                               scope: CapturedMockScope) -> EffectBundleResponseEffect {
        let address: String?
        switch scope.clients { case .allClients: address = nil; case .address(let value): address = value }
        return EffectBundleResponseEffect(id: id, label: "Prepared \(assetID)", requestMethod: "GET",
            requestScheme: scope.scheme, host: scope.host, port: scope.port, path: scope.path,
            matchMode: .exactPath, sourceKind: .localFile, statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
            bodySource: EffectBundleBodySource(kind: .file, assetIDs: [assetID], rootLogicalPath: nil),
            mapRemoteHost: nil, mapRemotePort: nil, mapRemoteScheme: nil, mapRemotePath: nil,
            mapRemoteQueryPolicy: .preserve, mapRemoteQuery: nil, bookmarkRewriteRequest: nil,
            liveResponseRewrites: [], expectedSchemaFingerprint: nil, dropConnection: false,
            forceNoCache: true, notFoundRelativePath: nil, missingFilePolicy: .strictLocal,
            graphQLOperationName: nil, matchQueryKey: nil, matchQueryValue: nil,
            matchHeaderName: nil, matchHeaderValue: nil, sourceClientAddress: address)
    }
}
