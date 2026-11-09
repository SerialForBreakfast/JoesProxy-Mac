import Foundation

/// Explicit finite fixture expansion. No inferred IDs, pagination or model execution.
/// Schedule off UI/network execution paths; publication belongs to the authoring owner.
enum CollectionTemplateExpansion {
    static let maximumItems = 100

    static func prepare(source: Data, template: CollectionMockDraft,
                        itemEdits: [[CollectionMockEdit]]) throws -> Data {
        guard template.item == nil, template.expansionItems == nil, let index = template.templateIndex,
              !itemEdits.isEmpty, itemEdits.count <= maximumItems else {
            throw CollectionMockError.invalidTemplate
        }
        guard template.edits.count <= 100 else { throw CollectionMockError.sizeLimit }
        let encoder = JSONEncoder()
        guard try encoder.encode(itemEdits).count <= CollectionMockDraftDecoder.maximumInputBytes,
              try encoder.encode(template).count <= CollectionMockDraftDecoder.maximumInputBytes else {
            throw CollectionMockError.sizeLimit
        }
        var root = try CollectionMockCompiler.parse(source)
        guard case .array(let collection) = try CollectionMockCompiler.value(
            at: CollectionMockCompiler.pointer(template.collectionPointer), in: root),
              collection.indices.contains(index) else { throw CollectionMockError.invalidTemplate }
        let original = collection[index]
        // Always copy the original selected item, even when prepending moves its array index.
        var insertedBytes = 0
        let orderedEdits = template.position == .prepend ? Array(itemEdits.reversed()) : itemEdits
        for edits in orderedEdits {
            try Task.checkCancellation()
            guard edits.count <= 100 else { throw CollectionMockError.sizeLimit }
            let combined = template.edits + edits
            var paths: [[String]] = []
            for edit in combined {
                let path = try CollectionMockCompiler.pointer(edit.pointer)
                guard !paths.contains(where: { $0.starts(with: path) || path.starts(with: $0) }) else {
                    throw CollectionMockError.invalidPointer
                }
                paths.append(path)
            }
            let draft = CollectionMockDraft(collectionPointer: template.collectionPointer,
                item: original, templateIndex: nil, edits: combined,
                identityPointers: template.identityPointers, countPointers: template.countPointers,
                position: template.position, identityPresence: template.identityPresence,
                ignoredQueryNames: template.ignoredQueryNames)
            let plan = try CollectionMockCompiler.prepare(root: root, draft: draft)
            insertedBytes += try CollectionMockCompiler.serialize(plan.item).count
            guard source.count + insertedBytes <= CollectionMockCompiler.maximumBodyBytes else {
                throw CollectionMockError.sizeLimit
            }
            guard let updated = try CollectionMockCompiler.apply(root: root, plan: plan) else {
                throw CollectionMockError.duplicateIdentity
            }
            root = updated.root
        }
        try Task.checkCancellation()
        return try CollectionMockCompiler.serialize(root)
    }
}
