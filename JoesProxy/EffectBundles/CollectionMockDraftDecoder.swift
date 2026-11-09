import Foundation

/// Transport-neutral natural JSON input; the persisted draft's tagged Codable form stays unchanged.
enum CollectionMockDraftDecoder {
    static let maximumInputBytes = 64 * 1_024

    struct ValidationError: Error, Equatable, Sendable {
        let field: String
        let reason: String
        let allowedValues: [String]
    }

    static func decode(_ data: Data) throws -> CollectionMockDraft {
        guard data.count <= maximumInputBytes else { throw CollectionMockError.sizeLimit }
        guard case .object(let fields) = try CollectionMockCompiler.parse(data) else {
            throw invalid("draft", "expectedObject")
        }
        try checkKeys(fields, allowed: ["collectionPointer", "item", "templateIndex", "edits",
            "identityPointers", "countPointers", "position", "identityPresence", "ignoredQueryNames", "expansionItems"], field: "draft")
        let collection = try pointer(fields["collectionPointer"], field: "collectionPointer")
        let item = fields["item"]
        let template = fields["templateIndex"]
        guard (item == nil) != (template == nil) else {
            throw invalid("item", "supplyExactlyOneItemOrTemplateIndex")
        }
        if let item {
            guard case .object = item else { throw invalid("item", "expectedObject") }
        }
        var templateIndex: Int?
        if let template {
            guard case .number(let number) = template, let index = Int(number), index >= 0 else {
                throw invalid("templateIndex", "expectedNonnegativeInteger")
            }
            templateIndex = index
        }
        let positionText: String
        if let value = fields["position"] {
            guard case .string(let text) = value else { throw invalid("position", "expectedString") }
            positionText = text
        } else { positionText = "append" }
        guard let position = CollectionMockDraft.Position(rawValue: positionText) else {
            throw ValidationError(field: "position", reason: "unsupportedValue", allowedValues: ["append", "prepend"])
        }
        let edits = try decodeEdits(fields["edits"], field: "edits")
        var expansionItems: [CollectionTemplateItem]?
        if let value = fields["expansionItems"] {
            guard templateIndex != nil, case .array(let entries) = value,
                  (1...CollectionTemplateExpansion.maximumItems).contains(entries.count) else {
                throw invalid("expansionItems", "requiresTemplateAndOneToOneHundredItems")
            }
            expansionItems = try entries.enumerated().map { index, entry in
                let field = "expansionItems[\(index)]"
                guard case .object(let fields) = entry else { throw invalid(field, "expectedObject") }
                try checkKeys(fields, allowed: ["edits", "images"], field: field)
                var images: [CollectionTemplateItem.ImageBinding] = []
                if let value = fields["images"] {
                    guard case .array(let bindings) = value, bindings.count <= 16 else {
                        throw invalid(field + ".images", "expectedAtMostSixteenBindings")
                    }
                    images = try bindings.enumerated().map { index, binding in
                        let field = field + ".images[\(index)]"
                        guard case .object(let fields) = binding else { throw invalid(field, "expectedObject") }
                        try checkKeys(fields, allowed: ["pointer", "assetID"], field: field)
                        guard case .string(let assetID) = fields["assetID"],
                              (0..<16).contains(where: { assetID == "image-\($0)" }) else {
                            throw invalid(field + ".assetID", "expectedImageAssetID")
                        }
                        return .init(pointer: try pointer(fields["pointer"], field: field + ".pointer"), assetID: assetID)
                    }
                }
                return CollectionTemplateItem(edits: try decodeEdits(fields["edits"], field: field + ".edits"), images: images)
            }
        }
        let identities = try pointers(fields["identityPointers"], field: "identityPointers")
        guard !identities.isEmpty else { throw invalid("identityPointers", "requiredNonemptyArray") }
        var presence: CollectionMockDraft.IdentityPresence?
        if let value = fields["identityPresence"] {
            guard case .string(let text) = value,
                  let parsed = CollectionMockDraft.IdentityPresence(rawValue: text) else {
                throw ValidationError(field: "identityPresence", reason: "unsupportedValue",
                    allowedValues: ["required", "wherePresent"])
            }
            presence = parsed
        }
        var ignored: [String]?
        if let value = fields["ignoredQueryNames"] {
            guard case .array(let values) = value else { throw invalid("ignoredQueryNames", "expectedArray") }
            let names = try values.map { value -> String in
                guard case .string(let name) = value else { throw invalid("ignoredQueryNames", "expectedString") }
                return name
            }
            guard CapturedQueryMatcher.canonicalPath("/", ignoring: names) != nil else {
                throw invalid("ignoredQueryNames", "requiresOneToSixteenUniqueNonemptyNames")
            }
            ignored = names
        }
        return CollectionMockDraft(collectionPointer: collection, item: item, templateIndex: templateIndex,
            edits: edits, identityPointers: identities,
            countPointers: try pointers(fields["countPointers"], field: "countPointers"), position: position,
            identityPresence: presence, ignoredQueryNames: ignored, expansionItems: expansionItems)
    }

    private static func decodeEdits(_ value: BookmarkJSONValue?, field: String) throws -> [CollectionMockEdit] {
        guard let value else { return [] }
        guard case .array(let entries) = value, entries.count <= 100 else {
            throw invalid(field, "expectedAtMostOneHundredEdits")
        }
        return try entries.enumerated().map { index, entry in
            let field = "\(field)[\(index)]"
            guard case .object(let edit) = entry else { throw invalid(field, "expectedObject") }
            try checkKeys(edit, allowed: ["pointer", "value"], field: field)
            guard let value = edit["value"] else { throw invalid(field + ".value", "required") }
            return .init(pointer: try pointer(edit["pointer"], field: field + ".pointer"), value: value)
        }
    }

    private static func pointers(_ value: BookmarkJSONValue?, field: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value else { throw invalid(field, "expectedArray") }
        let result = try values.map { try pointer($0, field: field) }
        guard Set(result).count == result.count else { throw invalid(field, "duplicatePointer") }
        return result
    }

    private static func pointer(_ value: BookmarkJSONValue?, field: String) throws -> String {
        guard case .string(let text) = value else { throw invalid(field, "requiredPointer") }
        do { _ = try CollectionMockCompiler.pointer(text) }
        catch { throw invalid(field, "invalidPointer") }
        return text
    }

    private static func checkKeys(_ fields: [String: BookmarkJSONValue], allowed: [String], field: String) throws {
        if !Set(fields.keys).isSubset(of: Set(allowed)) {
            throw ValidationError(field: field, reason: "unknownField", allowedValues: allowed.sorted())
        }
    }

    private static func invalid(_ field: String, _ reason: String) -> ValidationError {
        ValidationError(field: field, reason: reason, allowedValues: [])
    }
}
