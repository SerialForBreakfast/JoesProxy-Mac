import CryptoKit
import Foundation

enum CollectionMockAuthoringError: String, Error, Sendable {
    case invalidRequest, idempotencyConflict, revisionNotFound, revisionRetired, capacityExceeded, requestHistoryFull
}

struct PreparedCollectionRevision: Equatable, Sendable {
    let id: UUID
    let requestDigest: String
    let sourceDigest: String
    let bodyDigest: String
    let plan: CompiledCollectionMock
    let body: Data
    let beforeCount: Int
    let afterCount: Int
}

/// Preparation only: no rules, routing, approvals, or upstream requests are created here.
/// Actor isolation keeps CPU work off the main actor and serializes idempotency checks.
/// This bounded, process-local cache is not the persistent bundle repository.
actor CollectionMockAuthoringService {
    private struct Key: Hashable { let owner: String; let request: String }
    private var revisions: [Key: PreparedCollectionRevision] = [:]
    private var packages: [Key: (digest: String, package: PreparedCapturedMockPackage)] = [:]
    private var retainedCosts: [Key: Int] = [:]
    private var retired: [Key: UUID] = [:]
    private var retainedBytes = 0
    private let maximumRevisions: Int
    private let maximumRetainedBytes: Int
    private let maximumRequestHistory: Int
    private let preflightMatcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())

    init(maximumRevisions: Int = 20, maximumRetainedBytes: Int = 20 * 1_024 * 1_024,
         maximumRequestHistory: Int = 1_024) {
        self.maximumRevisions = max(0, maximumRevisions)
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
        self.maximumRequestHistory = max(0, maximumRequestHistory)
    }

    func prepare(ownerID: String, idempotencyKey: String, source: Data,
                 draft: CollectionMockDraft) throws -> PreparedCollectionRevision {
        guard !ownerID.isEmpty, !idempotencyKey.isEmpty,
              ownerID.utf8.count <= 256, idempotencyKey.utf8.count <= 256 else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        guard source.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let draftBytes = try encoder.encode(draft)
        guard draftBytes.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        let sourceDigest = digest(source)
        let requestDigest = digest(Data(sourceDigest.utf8) + draftBytes)
        let key = Key(owner: ownerID, request: idempotencyKey)
        guard retired[key] == nil else { throw CollectionMockAuthoringError.revisionRetired }
        guard packages[key] == nil else { throw CollectionMockAuthoringError.idempotencyConflict }
        if let previous = revisions[key] {
            guard previous.requestDigest == requestDigest else { throw CollectionMockAuthoringError.idempotencyConflict }
            return previous
        }
        guard revisions.count + packages.count < maximumRevisions else { throw CollectionMockAuthoringError.capacityExceeded }
        try checkRequestHistory()
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft)
        try Task.checkCancellation()
        guard case .applied(let body, let before, let after) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
            throw CollectionMockError.duplicateIdentity
        }
        let planBytes = try encoder.encode(plan).count
        guard body.count + planBytes <= maximumRetainedBytes - retainedBytes else {
            throw CollectionMockAuthoringError.capacityExceeded
        }
        try Task.checkCancellation()
        let revision = PreparedCollectionRevision(id: UUID(), requestDigest: requestDigest,
            sourceDigest: sourceDigest, bodyDigest: digest(body), plan: plan,
            body: body, beforeCount: before, afterCount: after)
        revisions[key] = revision
        retainedCosts[key] = body.count + planBytes
        retainedBytes += body.count + planBytes
        return revision
    }

    func inspect(id: UUID, ownerID: String) throws -> PreparedCollectionRevision {
        guard let revision = revisions.first(where: { $0.key.owner == ownerID && $0.value.id == id })?.value else {
            throw missingRevision(id: id, ownerID: ownerID)
        }
        return revision
    }

    func prepareCapturedPackage(ownerID: String, idempotencyKey: String, name: String,
                                source: Data, draft: CollectionMockDraft, scope: CapturedMockScope,
                                images: [CapturedMockImageBinding], appVersion: String,
                                createdAt: Date, relatedResponses: [CapturedRelatedResponse] = []) throws -> PreparedCapturedMockPackage {
        guard !ownerID.isEmpty, !idempotencyKey.isEmpty,
              ownerID.utf8.count <= 256, idempotencyKey.utf8.count <= 256 else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        guard images.count <= 16, relatedResponses.count <= 8,
              source.count <= CollectionMockCompiler.maximumBodyBytes else {
            throw CollectionMockError.sizeLimit
        }
        var inputBytes = source.count
        let relatedImageIDs = Set(relatedResponses.flatMap { $0.images.map(\.assetID) })
        let expansionImageIDs = Set((draft.expansionItems ?? []).flatMap { $0.images.map(\.assetID) })
        for (index, image) in images.enumerated() where image.itemPointer == nil {
            guard relatedImageIDs.contains("image-\(index)") || expansionImageIDs.contains("image-\(index)") else {
                throw CapturedMockPackageError.invalidImage
            }
        }
        for related in relatedResponses {
            guard related.source.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
            inputBytes += related.source.count
            guard inputBytes <= EffectBundleBudget.maxPackageBytes else { throw CollectionMockError.sizeLimit }
        }
        for image in images {
            guard image.bytes.count <= EffectBundleBudget.maxFileBytes else { throw CollectionMockError.sizeLimit }
            inputBytes += image.bytes.count
            guard inputBytes <= EffectBundleBudget.maxPackageBytes else { throw CollectionMockError.sizeLimit }
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = PackageFingerprint(name: name, sourceDigest: digest(source), draft: draft,
            scope: scope, images: images.map {
                ImageFingerprint(pointer: $0.itemPointer, digest: digest($0.bytes), originalURL: $0.originalURL?.absoluteString,
                    deliveryURL: $0.deliveryURL?.absoluteString, imageReference: $0.imageReference)
            }, appVersion: appVersion, relatedResponses: relatedResponses.map {
                RelatedFingerprint(sourceDigest: digest($0.source), sourceSessionID: $0.sourceSessionID,
                    targetSessionID: $0.targetSessionID, scope: $0.scope,
                    edits: $0.edits, images: $0.images, identityLinks: $0.identityLinks,
                    ignoredQueryNames: $0.ignoredQueryNames)
            })
        let encoded = try encoder.encode(fingerprint)
        guard encoded.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        let requestDigest = digest(encoded)
        let key = Key(owner: ownerID, request: idempotencyKey)
        guard retired[key] == nil else { throw CollectionMockAuthoringError.revisionRetired }
        guard revisions[key] == nil else { throw CollectionMockAuthoringError.idempotencyConflict }
        if let previous = packages[key] {
            guard previous.digest == requestDigest else { throw CollectionMockAuthoringError.idempotencyConflict }
            return previous.package
        }
        guard revisions.count + packages.count < maximumRevisions else { throw CollectionMockAuthoringError.capacityExceeded }
        try checkRequestHistory()
        let primaryPackage = try CapturedMockPackageCompiler.prepare(id: UUID(), name: name, source: source,
            draft: draft, scope: scope, images: images, appVersion: appVersion, createdAt: createdAt)
        let package = relatedResponses.isEmpty ? primaryPackage
            : try CapturedRelatedResponseCompiler.append(relatedResponses, to: primaryPackage)
        let bytes = package.assetDataByID.values.reduce(0) { $0 + $1.count } + (try encoder.encode(package.manifest).count)
        guard bytes <= maximumRetainedBytes - retainedBytes else { throw CollectionMockAuthoringError.capacityExceeded }
        try Task.checkCancellation()
        packages[key] = (requestDigest, package)
        retainedCosts[key] = bytes
        retainedBytes += bytes
        return package
    }

    func inspectCapturedPackage(id: UUID, ownerID: String) throws -> PreparedCapturedMockPackage {
        guard let package = packages.first(where: { $0.key.owner == ownerID && $0.value.package.manifest.id == id })?.value.package else {
            throw missingRevision(id: id, ownerID: ownerID)
        }
        return package
    }

    /// Serial cache retirement, not cancellation of an import already holding a package value.
    /// Tombstones prevent delayed retries from resurrecting content for this process lifetime.
    /// Reserve their bounded history at preparation time so retirement can always release bytes.
    @discardableResult
    func retire(id: UUID, ownerID: String) throws -> Bool {
        if retired.contains(where: { $0.key.owner == ownerID && $0.value == id }) { return false }
        let key = revisions.first(where: { $0.key.owner == ownerID && $0.value.id == id })?.key
            ?? packages.first(where: { $0.key.owner == ownerID && $0.value.package.manifest.id == id })?.key
        guard let key else { throw CollectionMockAuthoringError.revisionNotFound }
        revisions[key] = nil
        packages[key] = nil
        retainedBytes -= retainedCosts.removeValue(forKey: key) ?? 0
        retired[key] = id
        return true
    }

    private func missingRevision(id: UUID, ownerID: String) -> CollectionMockAuthoringError {
        retired.contains(where: { $0.key.owner == ownerID && $0.value == id }) ? .revisionRetired : .revisionNotFound
    }

    private func checkRequestHistory() throws {
        guard revisions.count + packages.count + retired.count < maximumRequestHistory else {
            throw CollectionMockAuthoringError.requestHistoryFull
        }
    }

    func preflight(id: UUID, ownerID: String, snapshot: CapturedMockPreflightSnapshot) async throws -> CapturedMockPreflight {
        let package = try inspectCapturedPackage(id: id, ownerID: ownerID)
        return try await preflightMatcher.preflight(manifest: package.manifest, snapshot: snapshot)
    }

    /// Decoding and JSON compilation stay actor-isolated, never on the UI or network event loop.
    func prepareCapturedResponse(ownerID: String, idempotencyKey: String, name: String,
                                 response: CapturedResponse, draftJSON: Data,
                                 scope: CapturedMockScope, appVersion: String,
                                 imageFiles: [CapturedMockImageFile] = [],
                                 relatedInputs: [CapturedRelatedResponseInput] = []) throws -> PreparedCapturedMockPackage {
        guard relatedInputs.count <= 8 else { throw CollectionMockError.sizeLimit }
        var related: [CapturedRelatedResponse] = []
        var relatedBytes = 0
        for (index, input) in relatedInputs.enumerated() {
            try Task.checkCancellation()
            let decoded: CapturedRelatedResponse
            do { decoded = try CapturedRelatedResponseDecoder.decode(input) }
            catch {
                if let failure = CapturedMockPreparationFailure.describe(error, field: "relatedResponses[\(index)]") {
                    throw failure
                }
                throw error
            }
            relatedBytes += decoded.source.count
            guard relatedBytes <= EffectBundleBudget.maxPackageBytes else { throw CollectionMockError.sizeLimit }
            related.append(decoded)
        }
        guard !response.bodyDeferred, !response.bodyTruncated,
              response.recordingBodyOmissionReason == nil, let body = response.bodyData else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        guard body.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        guard let decoded = CapturedBodyDecoder.decode(bodyData: body, headers: response.headers,
                maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes), decoded.canUseAnalysisDataForInspection else {
            throw CollectionMockError.invalidJSON
        }
        let draft = try CollectionMockDraftDecoder.decode(draftJSON)
        guard imageFiles.count <= 16 else { throw CapturedMockPackageError.tooManyImages }
        var images: [CapturedMockImageBinding] = []
        var bytes = decoded.analysisData.count
        for (index, file) in imageFiles.enumerated() {
            try Task.checkCancellation()
            let image: CapturedMockImageBinding
            do { image = try file.read() }
            catch {
                if let failure = CapturedMockPreparationFailure.describe(error, field: "images[\(index)].localFileBookmarkRef") {
                    throw failure
                }
                throw error
            }
            bytes += image.bytes.count
            guard bytes <= EffectBundleBudget.maxPackageBytes else { throw CollectionMockError.sizeLimit }
            images.append(image)
        }
        return try prepareCapturedPackage(ownerID: ownerID, idempotencyKey: idempotencyKey, name: name,
            source: decoded.analysisData, draft: draft, scope: scope, images: images, appVersion: appVersion,
            createdAt: Date(), relatedResponses: related)
    }

    private struct PackageFingerprint: Encodable {
        let name: String
        let sourceDigest: String
        let draft: CollectionMockDraft
        let scope: CapturedMockScope
        let images: [ImageFingerprint]
        let appVersion: String
        let relatedResponses: [RelatedFingerprint]
    }
    private struct RelatedFingerprint: Encodable {
        let sourceDigest: String
        let sourceSessionID: UUID?
        let targetSessionID: UUID?
        let scope: CapturedMockScope
        let edits: [CollectionMockEdit]
        let images: [CapturedRelatedResponse.ImageBinding]
        let identityLinks: [CapturedRelatedResponse.IdentityLink]
        let ignoredQueryNames: [String]?
    }
    private struct ImageFingerprint: Encodable {
        let pointer: String?
        let digest: String
        let originalURL: String?
        let deliveryURL: String?
        let imageReference: String?
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
