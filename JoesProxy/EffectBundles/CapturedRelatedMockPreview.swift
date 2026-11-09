import Foundation

/// Local-only bounded review of final compiled bytes, including generated artwork references.
struct CapturedRelatedMockPreview: Identifiable, Equatable, Sendable {
    let id: String
    let before: String
    let after: String
    let truncated: Bool

    static func make(inputs: [CapturedRelatedResponseInput], package: PreparedCapturedMockPackage) throws -> [Self] {
        guard inputs.count <= 8 else { throw CollectionMockError.sizeLimit }
        return try inputs.enumerated().map { index, input in
            try Task.checkCancellation()
            let original = try CapturedRelatedResponseDecoder.decode(input).source
            let id = "related-\(index)"
            guard let after = package.assetDataByID[id] else { throw CollectionMockAuthoringError.invalidRequest }
            return .init(id: id, before: String(decoding: original.prefix(4096), as: UTF8.self),
                         after: String(decoding: after.prefix(4096), as: UTF8.self),
                         truncated: original.count > 4096 || after.count > 4096)
        }
    }
}
