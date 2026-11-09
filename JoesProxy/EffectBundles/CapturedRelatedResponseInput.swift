import Foundation

struct CapturedRelatedResponseInput: Sendable {
    let sessionID: UUID
    let response: CapturedResponse
    let scope: CapturedMockScope
    let editsJSON: Data
    var targetSessionID: UUID? = nil
}

enum CapturedRelatedResponseDecoder {
    static func decode(_ input: CapturedRelatedResponseInput) throws -> CapturedRelatedResponse {
        guard input.editsJSON.count <= 65_536,
              case .object(let fields) = try CollectionMockCompiler.parse(input.editsJSON),
              Set(fields.keys).isSubset(of: ["edits", "images", "identityLinks", "ignoredQueryNames"]) else {
            throw CollectionMockAuthoringError.invalidRequest
        }
        func entries(_ key: String, maximum: Int) throws -> [[String: BookmarkJSONValue]] {
            guard let value = fields[key] else { return [] }
            guard case .array(let list) = value, list.count <= maximum else { throw CollectionMockAuthoringError.invalidRequest }
            return try list.map {
                guard case .object(let object) = $0 else { throw CollectionMockAuthoringError.invalidRequest }
                return object
            }
        }
        func text(_ value: BookmarkJSONValue?) throws -> String {
            guard case .string(let string) = value else { throw CollectionMockAuthoringError.invalidRequest }
            return string
        }
        let edits = try entries("edits", maximum: 100).map { entry -> CollectionMockEdit in
            guard Set(entry.keys) == ["pointer", "value"], let value = entry["value"] else { throw CollectionMockAuthoringError.invalidRequest }
            return .init(pointer: try text(entry["pointer"]), value: value)
        }
        let images = try entries("images", maximum: 16).map { entry -> CapturedRelatedResponse.ImageBinding in
            guard Set(entry.keys) == ["pointer", "assetID"] else { throw CollectionMockAuthoringError.invalidRequest }
            return .init(pointer: try text(entry["pointer"]), assetID: try text(entry["assetID"]))
        }
        let links = try entries("identityLinks", maximum: 32).map { entry -> CapturedRelatedResponse.IdentityLink in
            guard Set(entry.keys) == ["pointer", "primaryPointer"] else { throw CollectionMockAuthoringError.invalidRequest }
            return .init(pointer: try text(entry["pointer"]), primaryPointer: try text(entry["primaryPointer"]))
        }
        let response = input.response
        var ignored: [String]?
        if let supplied = fields["ignoredQueryNames"] {
            guard case .array(let values) = supplied else { throw CollectionMockAuthoringError.invalidRequest }
            let names = try values.map { try text($0) }
            guard CapturedQueryMatcher.canonicalPath("/", ignoring: names) != nil else {
                throw CollectionMockAuthoringError.invalidRequest
            }
            ignored = names
        }
        guard !response.bodyDeferred, !response.bodyTruncated, response.recordingBodyOmissionReason == nil,
              let body = response.bodyData else { throw CollectionMockAuthoringError.invalidRequest }
        guard body.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        guard let decoded = CapturedBodyDecoder.decode(bodyData: body, headers: response.headers,
            maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes), decoded.canUseAnalysisDataForInspection else { throw CollectionMockError.invalidJSON }
        return .init(source: decoded.analysisData, scope: input.scope, edits: edits, images: images,
            identityLinks: links, sourceSessionID: input.sessionID, targetSessionID: input.targetSessionID,
            ignoredQueryNames: ignored)
    }
}
