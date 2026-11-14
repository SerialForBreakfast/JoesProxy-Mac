import CryptoKit
import Foundation

enum EffectBundleValidator {
    static func validateManifest(_ manifest: EffectBundleManifest) throws {
        guard (1...EffectBundleSchema.currentVersion).contains(manifest.schemaVersion) else {
            throw EffectBundleError.unsupportedSchema(manifest.schemaVersion)
        }
        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, manifest.name.utf8.count <= EffectBundleBudget.maxNameBytes else {
            throw EffectBundleError.invalidName
        }
        guard manifest.notes.utf8.count <= EffectBundleBudget.maxNotesBytes else {
            throw EffectBundleError.notesTooLarge
        }
        guard manifest.defaultTTLSeconds > 0, manifest.defaultTTLSeconds <= EffectBundleBudget.maxTTL else {
            throw EffectBundleError.invalidTTL
        }
        guard manifest.responseEffects.count <= EffectBundleBudget.maxResponseEffectCount else {
            throw EffectBundleError.tooManyResponseEffects(manifest.responseEffects.count)
        }
        guard manifest.hlsSubstitutions.count <= EffectBundleBudget.maxHLSSubstitutionCount else {
            throw EffectBundleError.tooManyHLSSubstitutions(manifest.hlsSubstitutions.count)
        }
        guard manifest.assets.count <= EffectBundleBudget.maxFileCount else {
            throw EffectBundleError.tooManyFiles(manifest.assets.count)
        }

        try requireUnique(manifest.assets.map(\.id))
        try requireUniqueUUIDs(manifest.responseEffects.map(\.id))
        try requireUniqueUUIDs(manifest.hlsSubstitutions.map(\.id))
        try validatePhases(manifest)

        var logicalPaths = Set<String>()
        var totalBytes = 0
        for asset in manifest.assets {
            guard isSafeRelativePath(asset.logicalPath) else {
                throw EffectBundleError.unsafePath(asset.logicalPath)
            }
            guard logicalPaths.insert(asset.logicalPath).inserted else {
                throw EffectBundleError.duplicateLogicalPath(asset.logicalPath)
            }
            guard isSHA256(asset.sha256) else {
                throw EffectBundleError.invalidDigest(asset.sha256)
            }
            guard asset.byteCount >= 0, asset.byteCount <= EffectBundleBudget.maxFileBytes else {
                throw EffectBundleError.fileTooLarge(path: asset.logicalPath, byteCount: asset.byteCount)
            }
            totalBytes += asset.byteCount
            guard totalBytes <= EffectBundleBudget.maxPackageBytes else {
                throw EffectBundleError.packageTooLarge(totalBytes)
            }
        }

        let assetIDs = Set(manifest.assets.map(\.id))
        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        if let authoring = manifest.authoring {
            guard manifest.schemaVersion >= 2, authoring.revisionID == manifest.id,
                  isSHA256(authoring.sourceDigest),
                  assetsByID[authoring.responseAssetID]?.role == .responseBody,
                  authoring.beforeCount >= 0, authoring.beforeCount < Int.max,
                  authoring.afterCount > authoring.beforeCount,
                  authoring.afterCount - authoring.beforeCount <= (manifest.schemaVersion >= 8 ? 100 : 1) else {
                throw EffectBundleError.invalidBodySource("authoring")
            }
            if let artwork = authoring.artwork {
                guard artwork.count <= 16, Set(artwork.map(\.assetID)).count == artwork.count,
                      try JSONEncoder().encode(artwork).count <= 128 * 1_024 else {
                    throw EffectBundleError.invalidBodySource("artworkMetadata")
                }
                for image in artwork {
                    guard let asset = assetsByID[image.assetID], asset.role == .localFile,
                          asset.sha256 == image.sha256, asset.byteCount == image.byteCount,
                          asset.contentType == image.contentType,
                          (1...32_768).contains(image.width), (1...32_768).contains(image.height),
                          image.url.utf8.count <= 4_096, (image.imageReference?.utf8.count ?? 0) <= 4_096,
                          let url = URLComponents(string: image.url),
                          url.scheme.map({ ["http", "https"].contains($0) }) == true, url.host != nil,
                          url.user == nil, url.password == nil, url.fragment == nil,
                          manifest.responseEffects.contains(where: {
                              $0.bodySource.assetIDs.contains(image.assetID) && $0.host == url.host &&
                              $0.requestMethod == "GET" && $0.requestScheme.rawValue == url.scheme &&
                              ($0.port ?? ($0.requestScheme == .https ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80)) &&
                              $0.path == url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
                          }) else {
                        throw EffectBundleError.invalidBodySource("artworkMetadata")
                    }
                }
            }
            if let related = authoring.relatedResponses {
                guard manifest.schemaVersion >= 3, related.count <= 8,
                      Set(related.map(\.assetID)).count == related.count,
                      try JSONEncoder().encode(related).count <= 256 * 1_024 else {
                    throw EffectBundleError.invalidBodySource("relatedAuthoring")
                }
                for response in related {
                    guard response.assetID != authoring.responseAssetID,
                          assetsByID[response.assetID]?.role == .responseBody,
                          isSHA256(response.sourceDigest), response.changedPointers.count <= 116,
                          response.images.count <= 16, !response.identityLinks.isEmpty,
                          response.identityLinks.count <= 32,
                          response.images.allSatisfy({ assetsByID[$0.assetID]?.role == .localFile }) else {
                        throw EffectBundleError.invalidBodySource("relatedAuthoring")
                    }
                    for pointer in response.changedPointers + response.images.map(\.pointer)
                        + response.identityLinks.flatMap({ [$0.pointer, $0.primaryPointer] }) {
                        _ = try CollectionMockCompiler.pointer(pointer)
                    }
                }
            }
        }
        for effect in manifest.responseEffects {
            if let names = effect.ignoredQueryNames {
                guard manifest.schemaVersion >= 3, effect.matchMode == .ignoreQuery,
                      let client = effect.sourceClientAddress, !client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      CapturedQueryMatcher.canonicalPath(effect.path, ignoring: names) != nil else {
                    throw EffectBundleError.invalidBodySource("scopedQueryMatcher")
                }
            }
            guard effect.sourceKind != .fixtureRun else {
                throw EffectBundleError.unsupportedInternalRule
            }
            for assetID in effect.bodySource.assetIDs where !assetIDs.contains(assetID) {
                throw EffectBundleError.missingAssetReference(assetID)
            }
            try validateBodySource(effect, schemaVersion: manifest.schemaVersion, assetsByID: assetsByID)
        }
        for substitution in manifest.hlsSubstitutions {
            if let policy = substitution.requestPolicy {
                guard manifest.schemaVersion >= 7 else { throw EffectBundleError.invalidBodySource("scopedHLS") }
                try policy.validate(scope: substitution.scope)
            }
            if let targetID = substitution.replacesSubstitutionID {
                guard manifest.schemaVersion >= 6, manifest.phases != nil,
                      let target = manifest.hlsSubstitutions.first(where: { $0.id == targetID }),
                      target.replacesSubstitutionID == nil, target.id != substitution.id,
                      target.origin == substitution.origin, target.scope == substitution.scope,
                      target.requestPolicy == substitution.requestPolicy,
                      target.playbackConfiguration == substitution.playbackConfiguration else {
                    throw EffectBundleError.invalidBodySource("preparedHLSReplacement")
                }
            }
            guard isSafeRelativePath(substitution.profileRootLogicalPath) else {
                throw EffectBundleError.unsafePath(substitution.profileRootLogicalPath)
            }
            for assetID in substitution.profileAssetIDs where !assetIDs.contains(assetID) {
                throw EffectBundleError.missingAssetReference(assetID)
            }
        }
    }

    private static func validateBodySource(
        _ effect: EffectBundleResponseEffect,
        schemaVersion: Int,
        assetsByID: [String: EffectBundleAsset]
    ) throws {
        let body = effect.bodySource
        let validShape: Bool
        switch body.kind {
        case .none:
            validShape = body.assetIDs.isEmpty && body.rootLogicalPath == nil
        case .inline, .file:
            validShape = body.assetIDs.count == 1 && body.rootLogicalPath == nil
        case .directory:
            guard let root = body.rootLogicalPath, isSafeRelativePath(root) else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            validShape = !body.assetIDs.isEmpty && body.assetIDs.allSatisfy { id in
                guard let path = assetsByID[id]?.logicalPath else { return false }
                return path.hasPrefix(root + "/")
            }
        }

        let expectedKind: EffectBundleBodyKind
        switch effect.sourceKind {
        case .capturedResponse, .inlineText:
            expectedKind = .inline
        case .localFile:
            expectedKind = .file
        case .localDirectory:
            expectedKind = .directory
        case .block, .mapRemote, .bookmarkRewrite, .liveResponseRewrite:
            expectedKind = .none
        case .collectionMock:
            guard schemaVersion >= 4, effect.collectionMockPlan != nil, effect.mapRemoteHost == nil,
                  effect.mapRemotePort == nil, effect.mapRemoteScheme == nil,
                  effect.mapRemotePath == nil, effect.allowLoopbackDestination != true,
                  effect.preserveHostHeader != true, effect.bookmarkRewriteRequest == nil,
                  effect.liveResponseRewrites.isEmpty, effect.expectedSchemaFingerprint == nil else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            expectedKind = .none
        case .fixtureRun:
            throw EffectBundleError.unsupportedInternalRule
        }
        if effect.sourceKind == .collectionMock {
            guard let plan = effect.collectionMockPlan,
                  effect.bodySource == .none,
                  effect.dropConnection == false,
                  !plan.identityPointers.isEmpty,
                  Set(plan.identityPointers).count == plan.identityPointers.count,
                  Set(plan.countPointers).count == plan.countPointers.count else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            guard case .object = plan.item else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            let collectionPath = try CollectionMockCompiler.pointer(plan.collectionPointer)
            for pointer in plan.identityPointers {
                let path = try CollectionMockCompiler.pointer(pointer)
                let value = try CollectionMockCompiler.value(at: path, in: plan.item)
                guard value.kind == .string || value.kind == .number,
                      value != .string("") else {
                    throw EffectBundleError.invalidBodySource(effect.id.uuidString)
                }
            }
            for pointer in plan.countPointers {
                let path = try CollectionMockCompiler.pointer(pointer)
                guard !path.starts(with: collectionPath) else {
                    throw EffectBundleError.invalidBodySource(effect.id.uuidString)
                }
            }
        } else if effect.collectionMockPlan != nil {
            throw EffectBundleError.invalidBodySource(effect.id.uuidString)
        }
        guard validShape, body.kind == expectedKind else {
            throw EffectBundleError.invalidBodySource(effect.id.uuidString)
        }
    }

    private static func validatePhases(_ manifest: EffectBundleManifest) throws {
        guard let phases = manifest.phases else { return }
        guard manifest.schemaVersion >= 5, (1...8).contains(phases.count),
              Set(phases.map(\.id)).count == phases.count else {
            throw EffectBundleError.invalidBodySource("phases")
        }
        let responseIDs = Set(manifest.responseEffects.map(\.id))
        let hlsIDs = Set(manifest.hlsSubstitutions.map(\.id))
        var assignedResponses = Set<UUID>()
        var assignedHLS = Set<UUID>()
        var completedHLS = Set<UUID>()
        var totalDuration: TimeInterval = 0
        for phase in phases {
            for id in phase.hlsSubstitutionIDs {
                if let target = manifest.hlsSubstitutions.first(where: { $0.id == id })?.replacesSubstitutionID {
                    guard assignedHLS.contains(target), !completedHLS.contains(target) else {
                        throw EffectBundleError.invalidBodySource("preparedHLSReplacementOrder")
                    }
                }
            }
            guard !phase.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  phase.label.utf8.count <= EffectBundleBudget.maxNameBytes,
                  phase.durationSeconds.isFinite, phase.durationSeconds > 0,
                  Set(phase.responseEffectIDs).count == phase.responseEffectIDs.count,
                  Set(phase.hlsSubstitutionIDs).count == phase.hlsSubstitutionIDs.count,
                  Set(phase.timestampBindings.map(\.id)).count == phase.timestampBindings.count else {
                throw EffectBundleError.invalidBodySource("phase:\(phase.id.uuidString)")
            }
            totalDuration += phase.durationSeconds
            guard totalDuration <= EffectBundleBudget.maxTTL,
                  Set(phase.responseEffectIDs).isSubset(of: responseIDs),
                  Set(phase.hlsSubstitutionIDs).isSubset(of: hlsIDs),
                  assignedResponses.isDisjoint(with: phase.responseEffectIDs),
                  assignedHLS.isDisjoint(with: phase.hlsSubstitutionIDs) else {
                throw EffectBundleError.invalidBodySource("phase:\(phase.id.uuidString)")
            }
            if let completions = phase.completeHLSSubstitutionIDs {
                let switchTargets = Set(manifest.hlsSubstitutions.filter {
                    phase.hlsSubstitutionIDs.contains($0.id)
                }.compactMap(\.replacesSubstitutionID))
                guard manifest.schemaVersion >= 6,
                      Set(completions).count == completions.count,
                      Set(completions).isSubset(of: assignedHLS),
                      completions.allSatisfy({ id in manifest.hlsSubstitutions.first { $0.id == id }?.replacesSubstitutionID == nil }),
                      completedHLS.isDisjoint(with: completions) else {
                    throw EffectBundleError.invalidBodySource("phaseHLSCompletion")
                }
                guard switchTargets.isDisjoint(with: completions) else {
                    throw EffectBundleError.invalidBodySource("switchAndCompleteInSamePhase")
                }
                completedHLS.formUnion(completions)
            }
            assignedResponses.formUnion(phase.responseEffectIDs)
            assignedHLS.formUnion(phase.hlsSubstitutionIDs)
            guard phase.timestampBindings.count <= 128 else {
                throw EffectBundleError.invalidBodySource("timestampBindingLimit")
            }
            var boundPaths: [UUID: Set<[String]>] = [:]
            for binding in phase.timestampBindings {
                guard phase.responseEffectIDs.contains(binding.responseEffectID),
                      binding.offsetSeconds.isFinite,
                      abs(binding.offsetSeconds) <= EffectBundleBudget.maxTTL else {
                    throw EffectBundleError.invalidBodySource("timestampBinding:\(binding.id.uuidString)")
                }
                let path = try CollectionMockCompiler.pointer(binding.jsonPointer)
                guard boundPaths[binding.responseEffectID, default: []].insert(path).inserted else {
                    throw EffectBundleError.invalidBodySource("duplicateTimestampTarget")
                }
            }
        }
        guard assignedResponses == responseIDs, assignedHLS == hlsIDs else {
            throw EffectBundleError.invalidBodySource("phaseCoverage")
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func requireUnique(_ identifiers: [String]) throws {
        var seen = Set<String>()
        for identifier in identifiers {
            guard !identifier.isEmpty, seen.insert(identifier).inserted else {
                throw EffectBundleError.duplicateIdentifier(identifier)
            }
        }
    }

    private static func requireUniqueUUIDs(_ identifiers: [UUID]) throws {
        var seen = Set<UUID>()
        for identifier in identifiers where !seen.insert(identifier).inserted {
            throw EffectBundleError.duplicateIdentifier(identifier.uuidString)
        }
    }
}
