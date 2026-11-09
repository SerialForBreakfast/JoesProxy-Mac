import Foundation

/// Explicit authoring choices only; never infers identity, pagination, or count semantics.
struct GuidedCollectionMockDraft: Equatable, Sendable {
    struct FieldEdit: Identifiable, Equatable, Sendable {
        let id = UUID()
        var pointer = ""
        var valueJSON = "null"
    }
    var collectionPointer = "/items"
    var itemJSON = #"{"id":"synthetic-item","image":""}"#
    var identityPointers = "/id"
    var countPointers = ""
    var prepend = false
    var useTemplate = false
    var templateIndex = 0
    var edits: [FieldEdit] = []
    var expandTemplate = false
    var expansionItemsJSON = #"[{"edits":[{"pointer":"/id","value":"synthetic-1"}]},{"edits":[{"pointer":"/id","value":"synthetic-2"}]}]"#

    func encoded() throws -> Data {
        guard edits.count <= 100, useTemplate || itemJSON.utf8.count <= CollectionMockDraftDecoder.maximumInputBytes else {
            throw CollectionMockError.sizeLimit
        }
        var fields: [String: Any] = [
            "collectionPointer": collectionPointer,
            "identityPointers": Self.lines(identityPointers), "countPointers": Self.lines(countPointers),
            "position": prepend ? "prepend" : "append"
        ]
        if useTemplate { fields["templateIndex"] = templateIndex }
        else {
            let item: Any
            do { item = try JSONSerialization.jsonObject(with: Data(itemJSON.utf8), options: [.fragmentsAllowed]) }
            catch { throw CollectionMockError.invalidJSON }
            guard item is [String: Any] else { throw CollectionMockError.incompatibleType }
            fields["item"] = item
        }
        if useTemplate && expandTemplate {
            guard expansionItemsJSON.utf8.count <= CollectionMockDraftDecoder.maximumInputBytes else {
                throw CollectionMockError.sizeLimit
            }
            do {
                fields["expansionItems"] = try JSONSerialization.jsonObject(with: Data(expansionItemsJSON.utf8))
            } catch { throw CollectionMockError.invalidJSON }
        }
        var editBytes = 0
        fields["edits"] = try edits.enumerated().map { index, edit -> [String: Any] in
            try Task.checkCancellation()
            editBytes += edit.pointer.utf8.count + edit.valueJSON.utf8.count
            guard editBytes <= CollectionMockDraftDecoder.maximumInputBytes else { throw CollectionMockError.sizeLimit }
            return try CapturedMockPreparationFailure.atField("draftJSON.edits[\(index)]",
                recovery: "Supply a valid JSON Pointer and typed JSON value; quote strings, but not numbers, booleans, objects, arrays or null.") {
                _ = try CollectionMockCompiler.pointer(edit.pointer)
                let value: Any
                do { value = try JSONSerialization.jsonObject(with: Data(edit.valueJSON.utf8), options: [.fragmentsAllowed]) }
                catch { throw CollectionMockError.invalidJSON }
                return ["pointer": edit.pointer, "value": value]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        _ = try CollectionMockDraftDecoder.decode(data)
        return data
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
