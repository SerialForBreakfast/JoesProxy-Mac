import Foundation

struct EffectBundleRuntimeLayout: Sendable {
    var rootURL: URL
    var assetURLByID: [String: URL]
    var responseURLByID: [UUID: URL] = [:]
    var renderedSHA256ByID: [UUID: String] = [:]

    func url(forLogicalRoot logicalRoot: String) -> URL {
        rootURL.appendingPathComponent(logicalRoot, isDirectory: true)
    }
}

/// Expands content-addressed package assets into their validated logical paths for existing file,
/// directory, and HLS serving engines. The runtime tree is disposable and never exported.
struct EffectBundleRuntimeMaterializer: Sendable {
    private let rootURL: URL
    private var fileManager: FileManager { .default }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    }

    func materialize(manifest: EffectBundleManifest, packageURL: URL, anchor: Date? = nil) throws -> EffectBundleRuntimeLayout {
        try EffectBundleValidator.validateManifest(manifest)
        let destinationURL = runtimeURL(bundleID: manifest.id)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw EffectBundleError.activationConflict
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let stagingURL = rootURL.appendingPathComponent(".effect-bundle-runtime-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            var assetURLByID: [String: URL] = [:]
            for asset in manifest.assets {
                try Task.checkCancellation()
                let sourceURL = packageURL.appendingPathComponent(asset.packageRelativePath, isDirectory: false)
                let destination = stagingURL.appendingPathComponent(asset.logicalPath, isDirectory: false)
                let parent = destination.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                guard data.count == asset.byteCount else {
                    throw EffectBundleError.assetSizeMismatch(asset.id)
                }
                guard EffectBundleValidator.sha256Hex(data) == asset.sha256 else {
                    throw EffectBundleError.assetDigestMismatch(asset.id)
                }
                try data.write(to: destination, options: .atomic)
                assetURLByID[asset.id] = destination
            }
            var responsePaths: [UUID: String] = [:]
            var renderedHashes: [UUID: String] = [:]
            let bindings = (manifest.phases ?? []).flatMap(\.timestampBindings)
            for (effectID, group) in Dictionary(grouping: bindings, by: \.responseEffectID) {
                guard let anchor,
                      let effect = manifest.responseEffects.first(where: { $0.id == effectID }),
                      [.inlineText, .localFile].contains(effect.sourceKind),
                      effect.statusCode != 206,
                      !effect.headers.contains(where: { $0.name.lowercased() == "content-range" }),
                      effect.headers.allSatisfy({ $0.name.lowercased() != "content-encoding" || $0.value.lowercased() == "identity" }),
                      [.inline, .file].contains(effect.bodySource.kind),
                      effect.bodySource.assetIDs.count == 1,
                      let assetID = effect.bodySource.assetIDs.first,
                      let asset = manifest.assets.first(where: { $0.id == assetID }),
                      asset.contentType?.lowercased().split(separator: ";").first.map({ $0 == "application/json" || $0.hasSuffix("+json") }) == true,
                      asset.byteCount <= CollectionMockCompiler.maximumBodyBytes,
                      let source = assetURLByID[assetID] else {
                    throw EffectBundleError.invalidBodySource("timestampBinding:\(effectID.uuidString)")
                }
                let rendered = try EffectBundleTimestampRenderer.render(Data(contentsOf: source), bindings: group, anchor: anchor)
                // A fresh subdirectory prevents collisions with any reviewed logical asset path.
                let relative = "\(UUID().uuidString)/\(effectID.uuidString).json"
                let output = stagingURL.appendingPathComponent(relative)
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: false)
                try rendered.write(to: output, options: .atomic)
                responsePaths[effectID] = relative
                renderedHashes[effectID] = EffectBundleValidator.sha256Hex(rendered)
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            let resolvedAssets = assetURLByID.mapValues { stagedURL in
                destinationURL.appendingPathComponent(
                    String(stagedURL.path.dropFirst(stagingURL.path.count + 1)),
                    isDirectory: false
                )
            }
            return EffectBundleRuntimeLayout(rootURL: destinationURL, assetURLByID: resolvedAssets,
                responseURLByID: responsePaths.mapValues { destinationURL.appendingPathComponent($0) },
                renderedSHA256ByID: renderedHashes)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    func remove(bundleID: UUID) throws {
        let destinationURL = runtimeURL(bundleID: bundleID)
        guard destinationURL.deletingLastPathComponent().standardizedFileURL.path == rootURL.standardizedFileURL.path else {
            throw EffectBundleError.unsafePath(destinationURL.path)
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
    }

    private func runtimeURL(bundleID: UUID) -> URL {
        rootURL.appendingPathComponent(bundleID.uuidString.lowercased(), isDirectory: true)
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("EffectBundleRuntime", isDirectory: true)
    }
}
