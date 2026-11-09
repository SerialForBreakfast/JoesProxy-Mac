import Foundation

struct CapturedCollectionCandidate: Identifiable, Equatable, Sendable {
    var id: String { pointer }
    let pointer: String
    let count: Int
}

struct CapturedCollectionDiscovery: Equatable, Sendable {
    let collections: [CapturedCollectionCandidate]
    let truncated: Bool

    static func inspect(response: CapturedResponse) throws -> Self {
        guard !response.bodyDeferred, !response.bodyTruncated,
              response.recordingBodyOmissionReason == nil, let body = response.bodyData else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        guard body.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        guard let decoded = CapturedBodyDecoder.decode(bodyData: body, headers: response.headers,
            maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes), decoded.canUseAnalysisDataForInspection else {
            throw CollectionMockError.invalidJSON
        }
        return try inspect(decoded.analysisData)
    }

    /// Call off the main actor. Reports structure only, without selecting or copying item values.
    static func inspect(_ data: Data) throws -> Self {
        let root = try CollectionMockCompiler.parse(data)
        var collections: [CapturedCollectionCandidate] = []
        var visited = 0
        var truncated = false
        func visit(_ value: BookmarkJSONValue, pointer: String, depth: Int) throws {
            try Task.checkCancellation()
            guard visited < 2_000, depth <= 16, pointer.utf8.count <= 1_024,
                  collections.count < 64 else { truncated = true; return }
            visited += 1
            switch value {
            case .array(let items):
                collections.append(.init(pointer: pointer, count: items.count))
                for (index, item) in items.prefix(32).enumerated() {
                    try visit(item, pointer: "\(pointer)/\(index)", depth: depth + 1)
                    if visited >= 2_000 || collections.count >= 64 { truncated = true; break }
                }
                if items.count > 32 { truncated = true }
            case .object(let fields):
                for key in fields.keys.sorted().prefix(128) {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0")
                        .replacingOccurrences(of: "/", with: "~1")
                    if let child = fields[key] {
                        try visit(child, pointer: "\(pointer)/\(escaped)", depth: depth + 1)
                    }
                    if visited >= 2_000 || collections.count >= 64 { truncated = true; break }
                }
                if fields.count > 128 { truncated = true }
            default: break
            }
        }
        try visit(root, pointer: "", depth: 0)
        return .init(collections: collections, truncated: truncated)
    }
}
