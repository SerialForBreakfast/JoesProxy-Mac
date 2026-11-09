import Foundation

/// Explicit local inspection only. Full compilation checks run off the main actor before projection.
struct CapturedMockItemPreview: Equatable, Sendable {
    let before: String
    let after: String
    let truncated: Bool
    let insertedItemPointer: String
    let changedPointers: [String]

    static func inspect(response: CapturedResponse, draft: GuidedCollectionMockDraft) throws -> Self {
        try Task.checkCancellation()
        guard !response.bodyDeferred, !response.bodyTruncated, response.recordingBodyOmissionReason == nil,
              let bytes = response.bodyData else { throw CollectionMockAuthoringError.invalidRequest }
        guard bytes.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        guard let decoded = CapturedBodyDecoder.decode(bodyData: bytes, headers: response.headers,
            maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes), decoded.canUseAnalysisDataForInspection else {
            throw CollectionMockError.invalidJSON
        }
        let specification = try CollectionMockDraftDecoder.decode(draft.encoded())
        let compiled = try CollectionMockCompiler.prepare(source: decoded.analysisData, draft: specification)
        try Task.checkCancellation()
        let root = try CollectionMockCompiler.parse(decoded.analysisData)
        guard case .array(let collection) = try CollectionMockCompiler.value(
            at: CollectionMockCompiler.pointer(specification.collectionPointer), in: root) else {
            throw CollectionMockError.incompatibleType
        }
        let beforeValue: BookmarkJSONValue
        if let index = specification.templateIndex { beforeValue = collection[index] }
        else { beforeValue = specification.item ?? .null }
        func encoded(_ value: BookmarkJSONValue) throws -> Data {
            try JSONSerialization.data(withJSONObject: CollectionMockCompiler.foundationValue(value), options: [.sortedKeys])
        }
        let beforeBytes = try encoded(beforeValue)
        let afterBytes = try encoded(compiled.item)
        return .init(before: String(decoding: beforeBytes.prefix(4096), as: UTF8.self),
            after: String(decoding: afterBytes.prefix(4096), as: UTF8.self),
            truncated: beforeBytes.count > 4096 || afterBytes.count > 4096,
            insertedItemPointer: "\(specification.collectionPointer)/\(specification.position == .prepend ? 0 : collection.count)",
            changedPointers: specification.edits.map(\.pointer))
    }
}
