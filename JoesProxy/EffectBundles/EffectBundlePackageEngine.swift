import Foundation

struct EffectBundleInspection: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var name: String
    var notes: String
    var responseEffectCount: Int
    var hlsSubstitutionCount: Int
    var assetCount: Int
    var assetByteCount: Int
    var defaultTTLSeconds: TimeInterval
    var privacyWarning: String
}

struct EffectBundlePackageEngine {
    static let manifestFileName = "manifest.json"
    static let assetsDirectoryName = "assets"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspectPackage(at packageURL: URL) throws -> (manifest: EffectBundleManifest, inspection: EffectBundleInspection) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
            throw EffectBundleError.packageNotFound
        }
        guard isDirectory.boolValue else {
            throw EffectBundleError.packageIsNotDirectory
        }
        let packageValues = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        if packageValues.isSymbolicLink == true {
            throw EffectBundleError.symbolicLink(packageURL.lastPathComponent)
        }

        // FileManager's enumerator reports canonical paths. Normalize the root too so
        // system path aliases (for example /var and /private/var) cannot become a
        // spurious first component in an otherwise valid package-relative path.
        let resolvedPackageURL = packageURL.resolvingSymlinksInPath()

        let manifestURL = resolvedPackageURL.appendingPathComponent(Self.manifestFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw EffectBundleError.manifestMissing
        }
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if manifestValues.isSymbolicLink == true {
            throw EffectBundleError.symbolicLink(Self.manifestFileName)
        }
        guard manifestValues.isRegularFile == true else {
            throw EffectBundleError.manifestMissing
        }
        let manifestByteCount = manifestValues.fileSize ?? 0
        guard manifestByteCount <= EffectBundleBudget.maxManifestBytes else {
            throw EffectBundleError.manifestTooLarge(manifestByteCount)
        }

        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try JSONDecoder().decode(EffectBundleManifest.self, from: manifestData)
        try EffectBundleValidator.validateManifest(manifest)
        try validatePackageFiles(packageURL: resolvedPackageURL, manifest: manifest)

        return (
            manifest,
            EffectBundleInspection(
                schemaVersion: manifest.schemaVersion,
                id: manifest.id,
                name: manifest.name,
                notes: manifest.notes,
                responseEffectCount: manifest.responseEffects.count,
                hlsSubstitutionCount: manifest.hlsSubstitutions.count,
                assetCount: manifest.assets.count,
                assetByteCount: manifest.assets.reduce(0) { $0 + $1.byteCount },
                defaultTTLSeconds: manifest.defaultTTLSeconds,
                privacyWarning: manifest.privacy.warning
            )
        )
    }

    func writePackage(
        manifest: EffectBundleManifest,
        assetSourcesByID: [String: URL],
        to destinationURL: URL
    ) throws {
        try writePackage(manifest: manifest, to: destinationURL) { asset in
            guard let sourceURL = assetSourcesByID[asset.id] else { throw EffectBundleError.assetMissing(asset.id) }
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw EffectBundleError.symbolicLink(asset.logicalPath) }
            guard values.isRegularFile == true else { throw EffectBundleError.assetMissing(asset.id) }
            guard values.fileSize == asset.byteCount else { throw EffectBundleError.assetSizeMismatch(asset.id) }
            return try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        }
    }

    /// Writes already-prepared immutable bytes without creating temporary source files.
    func writePackage(manifest: EffectBundleManifest, assetDataByID: [String: Data], to destinationURL: URL) throws {
        try writePackage(manifest: manifest, to: destinationURL) { asset in
            guard let data = assetDataByID[asset.id] else { throw EffectBundleError.assetMissing(asset.id) }
            return data
        }
    }

    private func writePackage(manifest: EffectBundleManifest, to destinationURL: URL,
                              readAsset: (EffectBundleAsset) throws -> Data) throws {
        try EffectBundleValidator.validateManifest(manifest)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw EffectBundleError.destinationExists
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(".effect-bundle-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            let assetsURL = stagingURL.appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: false)

            var writtenDigests = Set<String>()
            for asset in manifest.assets {
                let data = try readAsset(asset)
                guard data.count == asset.byteCount else {
                    throw EffectBundleError.assetSizeMismatch(asset.id)
                }
                guard EffectBundleValidator.sha256Hex(data) == asset.sha256 else {
                    throw EffectBundleError.assetDigestMismatch(asset.id)
                }
                if writtenDigests.insert(asset.sha256).inserted {
                    try data.write(
                        to: assetsURL.appendingPathComponent(asset.sha256, isDirectory: false),
                        options: .atomic
                    )
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestData = try encoder.encode(manifest)
            guard manifestData.count <= EffectBundleBudget.maxManifestBytes else {
                throw EffectBundleError.manifestTooLarge(manifestData.count)
            }
            try manifestData.write(
                to: stagingURL.appendingPathComponent(Self.manifestFileName, isDirectory: false),
                options: .atomic
            )
            _ = try inspectPackage(at: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    private func validatePackageFiles(packageURL: URL, manifest: EffectBundleManifest) throws {
        let expectedAssetPaths = Set(manifest.assets.map(\.packageRelativePath))
        let allowedPaths = expectedAssetPaths.union([Self.manifestFileName])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw EffectBundleError.packageNotFound
        }

        var discoveredFiles = Set<String>()
        var physicalByteCount = 0
        let packagePathComponents = packageURL.pathComponents
        while let fileURL = enumerator.nextObject() as? URL {
            let filePathComponents = fileURL.resolvingSymlinksInPath().pathComponents
            guard filePathComponents.starts(with: packagePathComponents),
                  filePathComponents.count > packagePathComponents.count else {
                throw EffectBundleError.unexpectedFile(fileURL.lastPathComponent)
            }
            let relativePath = filePathComponents
                .dropFirst(packagePathComponents.count)
                .joined(separator: "/")
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw EffectBundleError.symbolicLink(relativePath)
            }
            if values.isDirectory == true {
                guard relativePath == Self.assetsDirectoryName else {
                    throw EffectBundleError.unexpectedFile(relativePath)
                }
                continue
            }
            guard values.isRegularFile == true, allowedPaths.contains(relativePath) else {
                throw EffectBundleError.unexpectedFile(relativePath)
            }
            discoveredFiles.insert(relativePath)
            physicalByteCount += values.fileSize ?? 0
            guard physicalByteCount <= EffectBundleBudget.maxPackageBytes else {
                throw EffectBundleError.packageTooLarge(physicalByteCount)
            }
        }

        for asset in manifest.assets {
            let relativePath = asset.packageRelativePath
            guard discoveredFiles.contains(relativePath) else {
                throw EffectBundleError.assetMissing(asset.id)
            }
            let fileURL = packageURL.appendingPathComponent(relativePath)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == asset.byteCount else {
                throw EffectBundleError.assetSizeMismatch(asset.id)
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard EffectBundleValidator.sha256Hex(data) == asset.sha256 else {
                throw EffectBundleError.assetDigestMismatch(asset.id)
            }
        }
    }
}
